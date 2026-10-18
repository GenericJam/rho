defmodule Rho.LLMCostTest do
  # async: false: the providers' base URLs (req_llm's app env) and the
  # sign-ins (the app-wide credential store) are global.
  use ExUnit.Case, async: false

  alias Rho.Auth
  alias Rho.LLM.ReqLLM, as: Adapter
  alias Rho.Session
  alias Rho.Test.SSEServer

  @moduletag :capture_log

  # A Claude reply as the Messages API streams it (taken from a real one):
  # input_tokens is the uncached part, the cache's are beside it, and the
  # writes come split by TTL.
  @claude_sse """
  event: message_start
  data: {"type":"message_start","message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":14,"cache_creation_input_tokens":2000,"cache_read_input_tokens":10000,"cache_creation":{"ephemeral_5m_input_tokens":2000,"ephemeral_1h_input_tokens":0},"output_tokens":1,"service_tier":"standard","inference_geo":"global","speed":"standard"}}}

  event: content_block_start
  data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello there!"}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":0}

  event: message_delta
  data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":14,"cache_creation_input_tokens":2000,"cache_read_input_tokens":10000,"output_tokens":7}}

  event: message_stop
  data: {"type":"message_stop"}

  """

  # An OpenAI Responses stream: input_tokens counts the cached tokens too.
  defp responses_sse(model, usage) do
    completed = %{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_1",
        "status" => "completed",
        "model" => model,
        "service_tier" => "default",
        "output" => [
          %{
            "type" => "message",
            "id" => "msg_1",
            "role" => "assistant",
            "status" => "completed",
            "content" => [
              %{"type" => "output_text", "text" => "Hello there!", "annotations" => []}
            ]
          }
        ],
        "usage" => usage
      }
    }

    delta = %{
      "type" => "response.output_text.delta",
      "item_id" => "msg_1",
      "output_index" => 0,
      "content_index" => 0,
      "delta" => "Hello there!"
    }

    Enum.map_join([delta, completed], fn event ->
      "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end

  setup do
    start_supervised!({Auth, respond: fn _req -> flunk("no token refresh expected") end})

    on_exit(fn ->
      for p <- Auth.providers(), do: Rho.CredentialStore.delete("auth:#{p}")
      for p <- [:anthropic, :openai, :openai_codex], do: Application.delete_env(:req_llm, p)
    end)
  end

  defp serve(provider, body) do
    Application.put_env(:req_llm, provider, base_url: SSEServer.start!([body]))
  end

  defp sign_in(provider) do
    creds = %{
      "type" => "oauth",
      "access" => "at-1",
      "refresh" => "rt-1",
      "expires" => System.os_time(:millisecond) + 3_600_000,
      "accountId" => "acct-1"
    }

    :ok = Auth.put(provider, creds)
  end

  # One call through the adapter; the reply's usage as rho records it.
  defp call(model) do
    request = %{
      model: model,
      system_prompt: "Be brief.",
      messages: [ReqLLM.Context.user("Say hi.")],
      tools: [],
      max_tokens: 64
    }

    assert {:ok, reply} = Adapter.stream(request, [], fn _delta -> :ok end)
    assert reply.text == "Hello there!"
    Session.usage(reply.usage)
  end

  # What `tokens` cost at the model's list prices (llm_db's flat
  # per-million summary, a separate record from the tariff req_llm prices
  # by), in pi's split.
  defp list_price(model, tokens) do
    {:ok, %{cost: rates}} = ReqLLM.model(model)
    part = fn key, rate -> Map.get(tokens, key, 0) * Map.fetch!(rates, rate) / 1_000_000 end

    parts = %{
      "input" => part.("input", :input),
      "output" => part.("output", :output),
      "cacheRead" => part.("cacheRead", :cache_read),
      "cacheWrite" => if(tokens["cacheWrite"], do: part.("cacheWrite", :cache_write), else: 0)
    }

    Map.put(parts, "total", parts |> Map.values() |> Enum.sum())
  end

  defp assert_cost(usage, expected) do
    for {key, dollars} <- expected do
      assert_in_delta usage["cost"][key], dollars, 1.0e-9, "cost #{key}"
    end
  end

  @claude_tokens %{"input" => 14, "output" => 7, "cacheRead" => 10_000, "cacheWrite" => 2000}

  test "a Claude API-key call is priced, its cache reads and writes included" do
    model = "anthropic:claude-opus-5-5"
    :ok = Auth.put_api_key(:anthropic, "sk-ant-test")
    serve(:anthropic, @claude_sse)

    usage = call(model)
    assert_received {SSEServer, :request, "/v1/messages"}

    # the uncached input as Anthropic reports it, not less the cache's tokens
    assert Map.take(usage, ~w(input output cacheRead cacheWrite)) == @claude_tokens
    assert usage["totalTokens"] == 12_021

    expected = list_price(model, @claude_tokens)
    assert expected["total"] > 0.012
    assert_cost(usage, expected)
  end

  test "a Claude subscription call is priced at what it would cost on an API key" do
    model = "anthropic:claude-opus-5-5"
    sign_in(:anthropic)
    serve(:anthropic, @claude_sse)

    usage = call(model)
    assert_cost(usage, list_price(model, @claude_tokens))
  end

  test "an OpenAI API-key call is priced: cached input apart, cache writes, long-context tiers settled" do
    # gpt-5.6's prices carry batch, flex / priority / fast tiers, regional
    # processing and long-context bands.
    model = "openai:gpt-5.6"
    :ok = Auth.put_api_key(:openai, "sk-proj-test")

    serve(
      :openai,
      responses_sse("gpt-5.6", %{
        "input_tokens" => 12_000,
        "input_tokens_details" => %{"cached_tokens" => 10_000, "cache_write_tokens" => 1500},
        "output_tokens" => 50,
        "output_tokens_details" => %{"reasoning_tokens" => 20},
        "total_tokens" => 12_050
      })
    )

    usage = call(model)
    assert_received {SSEServer, :request, "/responses"}

    tokens = %{"input" => 500, "output" => 50, "cacheRead" => 10_000, "cacheWrite" => 1500}
    assert Map.take(usage, ~w(input output cacheRead cacheWrite)) == tokens
    assert_cost(usage, list_price(model, tokens))
  end

  test "a ChatGPT subscription (Codex) call is priced as the same OpenAI model's" do
    model = "openai_codex:gpt-5.5"
    sign_in(:openai_codex)

    serve(
      :openai_codex,
      responses_sse("gpt-5.5", %{
        "input_tokens" => 12_000,
        "input_tokens_details" => %{"cached_tokens" => 10_000},
        "output_tokens" => 50,
        "total_tokens" => 12_050
      })
    )

    usage = call(model)
    tokens = %{"input" => 2000, "output" => 50, "cacheRead" => 10_000}
    assert Map.take(usage, ~w(input output cacheRead)) == tokens
    assert usage["cacheWrite"] == 0

    expected = list_price("openai:gpt-5.5", tokens)
    assert expected["total"] > 0
    assert_cost(usage, expected)
  end
end
