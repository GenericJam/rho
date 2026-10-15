defmodule Rho.LLMTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle
  alias Rho.LLM
  alias Rho.LLM.ReqLLM, as: Adapter

  test "a 402 raised mid-stream reads as the short payment message, without the response" do
    cause = %ReqLLM.Error.API.Request{
      status: 402,
      reason: "You requested up to 4096 tokens, but can only afford 2791.",
      response_body: %{"code" => 402},
      headers: [{"set-cookie", "__cf_bm=secret"}]
    }

    error =
      Adapter.normalize(%ReqLLM.Error.API.Stream{reason: "Stream failed: ...", cause: cause})

    assert error == {:http, 402, "You requested up to 4096 tokens, but can only afford 2791."}

    text = LLM.describe(error)
    assert text =~ "402 (payment required): You requested up to 4096 tokens"
    assert text =~ "lower max_tokens"
    refute text =~ "cookie"
  end

  test "a stream that stalls into a bare timeout is a transport error the loop retries" do
    assert Adapter.normalize(:timeout) == {:transport, :timeout}
    assert LLM.retryable?(Adapter.normalize(:timeout))
    assert LLM.retryable?(Adapter.normalize({:timeout, {GenServer, :call, []}}))
    refute LLM.retryable?(Adapter.normalize(:something_else))
  end

  test "pictures the model streams come back once as the reply's images; previews and links don't" do
    png = <<137, 80, 78, 71, 1>>
    jpeg = <<0xFF, 0xD8, 0xFF, 0xD9>>

    chunks = [
      StreamChunk.text("A fox:"),
      StreamChunk.content_part(ContentPart.image(<<0>>, "image/png"), %{stream_only?: true}),
      StreamChunk.content_part(ContentPart.image(png, "image/png")),
      StreamChunk.content_part(%ContentPart{type: :image_url, url: "https://example.com/a.png"}),
      StreamChunk.content_part(ContentPart.image(jpeg, "image/jpeg"))
    ]

    {:ok, model} = ReqLLM.model("google:gemini-2.5-flash")
    {:ok, handle} = MetadataHandle.start_link(fn -> %{finish_reason: :stop} end)

    stream = %StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: model,
      context: ReqLLM.Context.new([ReqLLM.Context.user("draw")])
    }

    {:ok, response} = StreamResponse.process_stream(stream)
    reply = Adapter.reply(response)

    assert reply.text == "A fox:"
    assert reply.images == [{"image/png", png}, {"image/jpeg", jpeg}]
  end

  describe "req_llm options per model prefix" do
    defp request(model, extra \\ %{}),
      do:
        Map.merge(
          %{model: model, system_prompt: "", messages: [], tools: [], max_tokens: 99},
          extra
        )

    defp signed_in(provider, token, account \\ nil) do
      fn
        ^provider -> {:ok, %{type: :oauth, token: token, account_id: account}}
        _other -> {:error, :signed_out}
      end
    end

    defp keyed(provider, key) do
      fn
        ^provider -> {:ok, %{type: :api_key, key: key}}
        _other -> {:error, :signed_out}
      end
    end

    test "anthropic: the subscription's OAuth token, Claude Code mode" do
      assert {:ok, opts} =
               Adapter.options(
                 request("anthropic:claude-haiku-4-5"),
                 signed_in(:anthropic, "at-1")
               )

      assert opts[:max_tokens] == 99
      # The loop owns retries: a 429 must come back as itself, not after
      # req_llm sleeps out its retry-after.
      assert opts[:max_retries] == 0
      refute Keyword.has_key?(opts, :tools)

      assert opts[:provider_options] == [
               auth_mode: :oauth,
               access_token: "at-1",
               with_claude_subscription: true,
               anthropic_prompt_cache: true,
               anthropic_cache_messages: -1
             ]
    end

    test "openai_codex: token, ChatGPT account and the session as session_id" do
      req = request("openai_codex:gpt-5", %{session_id: "s-1"})

      assert {:ok, opts} = Adapter.options(req, signed_in(:openai_codex, "at-2", "acct-9"))

      assert opts[:provider_options] == [
               auth_mode: :oauth,
               access_token: "at-2",
               chatgpt_account_id: "acct-9",
               session_id: "s-1"
             ]

      # no session (a compaction request), no account id: just left out
      assert {:ok, opts} =
               Adapter.options(request("openai_codex:gpt-5"), signed_in(:openai_codex, "at-2"))

      assert opts[:provider_options] == [auth_mode: :oauth, access_token: "at-2"]
    end

    test "a signed-out provider or a dead refresh says to sign in; other prefixes are refused" do
      assert {:error, {:signed_out, :openai_codex} = e} =
               Adapter.options(request("openai_codex:gpt-5"), signed_in(:anthropic, "x"))

      assert LLM.describe(e) =~ "sign in from the app's settings"
      refute LLM.retryable?(e)

      dead = fn :anthropic -> {:error, {:refresh_failed, "400 invalid_grant"}} end

      assert {:error, {:auth, :anthropic, "400 invalid_grant"} = e} =
               Adapter.options(request("anthropic:claude-haiku-4-5"), dead)

      assert LLM.describe(e) =~ "400 invalid_grant"
      assert LLM.describe(e) =~ "sign in again from the app's settings"

      assert {:error, {:other, message}} =
               Adapter.options(request("mistral:large"), signed_in(:anthropic, "x"))

      assert message =~ "can't call mistral:large"
    end

    test "API keys: the key as req_llm's api_key; Anthropic keeps its prompt cache" do
      assert {:ok, opts} =
               Adapter.options(request("anthropic:claude-haiku-4-5"), keyed(:anthropic, "sk-ant"))

      assert opts[:api_key] == "sk-ant"
      assert opts[:max_retries] == 0

      assert opts[:provider_options] == [
               anthropic_prompt_cache: true,
               anthropic_cache_messages: -1
             ]

      req = request("openai:gpt-5", %{session_id: "s-1"})
      assert {:ok, opts} = Adapter.options(req, keyed(:openai, "sk-proj"))
      assert opts[:api_key] == "sk-proj"
      assert opts[:provider_options] == [prompt_cache_key: "s-1"]

      assert {:ok, opts} = Adapter.options(request("openai:gpt-5"), keyed(:openai, "sk-proj"))
      assert opts[:provider_options] == []

      assert {:ok, opts} =
               Adapter.options(request("google:gemini-2.5-flash"), keyed(:google, "AIza"))

      assert opts[:api_key] == "AIza"
      assert opts[:provider_options] == [google_auth_header: true]
    end

    # The request req_llm would send, built offline from our options.
    defp finch(model, credential) do
      tool =
        ReqLLM.Tool.new!(
          name: "echo",
          description: "e",
          parameter_schema: [x: [type: :string]],
          callback: fn _ -> {:ok, ""} end
        )

      req = request(model, %{tools: [tool], session_id: "s-1"})
      {:ok, opts} = Adapter.options(req, credential)
      context = ReqLLM.Context.new([ReqLLM.Context.system("SYS"), ReqLLM.Context.user("hi")])
      {:ok, model} = ReqLLM.model(model)
      {:ok, mod} = ReqLLM.provider(model.provider)
      {:ok, finch} = mod.attach_stream(model, context, opts, nil)
      finch
    end

    defp body(model, provider, account \\ nil),
      do: Jason.decode!(finch(model, signed_in(provider, "tok", account)).body)

    defp header(finch, name),
      do: for({k, v} <- finch.headers, String.downcase(k) == name, do: v)

    test "each provider's API key goes where its API wants it, and only there" do
      anthropic = finch("anthropic:claude-haiku-4-5", keyed(:anthropic, "sk-ant-KEY"))
      assert header(anthropic, "x-api-key") == ["sk-ant-KEY"]
      assert header(anthropic, "authorization") == []
      # an API key isn't a Claude Code subscription
      refute Enum.any?(header(anthropic, "anthropic-beta"), &(&1 =~ "oauth"))
      assert [%{"cache_control" => _}] = Jason.decode!(anthropic.body)["tools"]

      openai = finch("openai:gpt-5", keyed(:openai, "sk-proj-KEY"))
      assert header(openai, "authorization") == ["Bearer sk-proj-KEY"]
      assert Jason.decode!(openai.body)["prompt_cache_key"] == "s-1"

      google = finch("google:gemini-2.5-flash", keyed(:google, "AIza-KEY"))
      assert header(google, "x-goog-api-key") == ["AIza-KEY"]
      refute google.path =~ "AIza-KEY"
      refute to_string(google.query) =~ "AIza-KEY"
    end

    test "anthropic requests carry cache breakpoints on tools, system and the last message; codex's don't" do
      body = body("anthropic:claude-haiku-4-5", :anthropic)
      cache = %{"type" => "ephemeral"}
      assert [%{"cache_control" => ^cache}] = body["tools"]
      assert %{"text" => "SYS", "cache_control" => ^cache} = List.last(body["system"])
      assert [%{"content" => [%{"text" => "hi", "cache_control" => ^cache}]}] = body["messages"]

      codex = body("openai_codex:gpt-5", :openai_codex, "acct")
      refute Jason.encode!(codex) =~ "cache_control"
      assert codex["prompt_cache_key"] == "s-1"
    end
  end

  describe "rate limits" do
    @now 1_800_000_000
    @model "anthropic:claude-haiku-4-5"
    @throttle {:http, 429, "This request would exceed your account's rate limit."}

    test "a throttle carries its retry-after, in seconds, ms or as a date" do
      assert {:rate_limited, %{retry_after_ms: 7_000, resets_at: nil, provider: :anthropic}} =
               Adapter.limit(@throttle, @model, [{"retry-after", "7"}], nil, %{}, @now)

      assert {:rate_limited, %{retry_after_ms: 1_500}} =
               Adapter.limit(@throttle, @model, %{"retry-after-ms" => ["1500"]}, nil, %{}, @now)

      date =
        @now
        |> Kernel.+(30)
        |> DateTime.from_unix!()
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      assert {:rate_limited, %{retry_after_ms: 30_000}} =
               Adapter.limit(@throttle, @model, [{"Retry-After", date}], nil, %{}, @now)

      assert LLM.describe(Adapter.limit(@throttle, @model, [], nil, %{}, @now)) =~
               "429 (rate limited)"
    end

    test "a used-up window: from the response's headers, a Codex body, else what Usage recorded" do
      at = @now + 4 * 3600

      headers = [
        {"anthropic-ratelimit-unified-5h-utilization", "1.0"},
        {"anthropic-ratelimit-unified-5h-reset", "#{at}"},
        {"anthropic-ratelimit-unified-7d-utilization", "0.4"}
      ]

      assert {:rate_limited, %{resets_at: ^at, window: "5 hours"}} =
               Adapter.limit(@throttle, @model, headers, nil, %{}, @now)

      codex = {:http, 429, "The usage limit has been reached"}
      body = %{"error" => %{"type" => "usage_limit_reached", "resets_at" => at}}

      assert {:rate_limited, %{resets_at: ^at, provider: :openai_codex}} =
               Adapter.limit(codex, "openai_codex:gpt-5", [], body, %{}, @now)

      # Anthropic's 5-hour window at 100 % answers like a throttle: the
      # windows the earlier calls recorded tell.
      state = %{
        "limits" => %{
          "anthropic" => %{
            "windows" => %{"5h" => %{"label" => "5 hours", "used" => 100.0, "resets_at" => at}}
          }
        }
      }

      assert {:rate_limited, %{resets_at: ^at, window: "5 hours"}} =
               Adapter.limit(@throttle, @model, [], nil, state, @now)

      # A recent short 429 is a throttle, not a used-up window.
      short = %{"rate_limited" => %{"anthropic" => %{"resets_at" => @now + 7}}}

      assert {:rate_limited, %{resets_at: nil}} =
               Adapter.limit(@throttle, @model, [], nil, short, @now)

      # Overloaded is never a used-up window; other errors pass through.
      assert {:rate_limited, %{status: 529, resets_at: nil}} =
               Adapter.limit({:http, 529, "Overloaded"}, @model, [], nil, state, @now)

      assert Adapter.limit({:http, 500, "x"}, @model, [], nil, state, @now) == {:http, 500, "x"}
    end
  end
end
