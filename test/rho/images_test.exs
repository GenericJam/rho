defmodule Rho.ImagesTest do
  use ExUnit.Case, async: true

  alias Rho.Images
  alias Rho.Usage

  @moduletag :tmp_dir

  @now 1_800_000_000
  @png <<137, 80, 78, 71, 13, 10, 26, 10, "png-bytes">>
  @token "secret-token"

  defp signed_in(:openai_codex), do: {:ok, %{type: :oauth, token: @token, account_id: "acc-1"}}

  defp sse(events),
    do: Enum.map_join(events, fn e -> "event: x\ndata: #{Jason.encode!(e)}\n\n" end)

  defp image_item(overrides \\ %{}) do
    %{
      "type" => "response.output_item.done",
      "item" =>
        Map.merge(
          %{
            "type" => "image_generation_call",
            "status" => "completed",
            "action" => "generate",
            "output_format" => "png",
            "revised_prompt" => "An ark, gilded.",
            "size" => "1536x1024",
            "result" => Base.encode64(@png)
          },
          overrides
        )
    }
  end

  @completed %{
    "type" => "response.completed",
    "response" => %{
      "usage" => %{
        "input_tokens" => 2300,
        "input_tokens_details" => %{"cached_tokens" => 300},
        "output_tokens" => 50
      }
    }
  }

  @codex_headers %{
    "x-codex-primary-used-percent" => ["31"],
    "x-codex-primary-window-minutes" => ["300"],
    "x-codex-primary-reset-at" => ["#{@now + 900}"]
  }

  defp opts(dir, respond, extra \\ []),
    do: [credential: &signed_in/1, respond: respond, data_dir: dir, now: @now] ++ extra

  # Answers each request with the next of `responses` and tells the test
  # what was asked.
  defp scripted(responses) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn req ->
      body = if req.body, do: Jason.decode!(IO.iodata_to_binary(req.body)), else: nil
      send(test, {:asked, req.method, req.url, req.headers, body})
      Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
    end
  end

  describe "generate/2" do
    test "draws on the sign-in: the request, the picture, the usage recorded", %{tmp_dir: dir} do
      respond =
        scripted([
          Req.Response.new(
            status: 200,
            headers: @codex_headers,
            body: sse([%{"type" => "response.created"}, image_item(), @completed])
          )
        ])

      reference = {"image/jpeg", "jpeg-bytes"}

      assert {:ok, picture} =
               Images.generate(
                 "Draw the ark.",
                 opts(dir, respond,
                   references: [reference],
                   size: "1536x1024",
                   quality: "low",
                   format: "png"
                 )
               )

      assert %{
               mime: "image/png",
               bytes: @png,
               revised_prompt: "An ark, gilded.",
               size: "1536x1024",
               action: "generate",
               model: "gpt-5.6-luna"
             } = picture

      assert_received {:asked, :post, url, headers, body}
      assert url.host == "chatgpt.com" and url.path == "/backend-api/codex/responses"
      assert headers["authorization"] == ["Bearer #{@token}"]
      assert headers["chatgpt-account-id"] == ["acc-1"]
      assert headers["accept"] == ["text/event-stream"]

      assert %{
               "model" => "gpt-5.6-luna",
               "stream" => true,
               "store" => false,
               "tools" => [
                 %{
                   "type" => "image_generation",
                   "size" => "1536x1024",
                   "quality" => "low",
                   "output_format" => "png"
                 }
               ],
               "tool_choice" => %{"type" => "image_generation"},
               "input" => [%{"role" => "user", "content" => content}]
             } = body

      assert content == [
               %{"type" => "input_text", "text" => "Draw the ark."},
               %{
                 "type" => "input_image",
                 "image_url" => "data:image/jpeg;base64,#{Base.encode64("jpeg-bytes")}"
               }
             ]

      state = Usage.load(dir)

      assert %{"requests" => 1, "input" => 2000, "cacheRead" => 300, "output" => 50} =
               Usage.by_model(state, :total)["openai_codex:gpt-5.6-luna"]

      assert Usage.status_text(state, :openai_codex, @now) =~ "31%"
      refute File.read!(Path.join(dir, "usage.json")) =~ @token
    end

    test "the picture's type follows the format it was drawn in", %{tmp_dir: dir} do
      respond =
        scripted([
          Req.Response.new(
            status: 200,
            body: sse([image_item(%{"output_format" => "jpeg", "action" => "edit"}), @completed])
          )
        ])

      assert {:ok, %{mime: "image/jpeg", action: "edit"}} =
               Images.generate("Make it dusk.", opts(dir, respond, format: :jpeg))

      assert_received {:asked, :post, _url, _headers, %{"tools" => [tool]}}
      assert tool == %{"type" => "image_generation", "output_format" => "jpeg"}
    end

    test "a model the account refuses: draws with the lightest one Codex lists", %{tmp_dir: dir} do
      refused =
        ~s({"detail":"The 'gpt-5.5' model is not supported when using Codex with a ChatGPT account."})

      models = %{
        "models" => [
          %{"slug" => "gpt-big", "visibility" => "list", "priority" => 1},
          %{"slug" => "codex-auto-review", "visibility" => "hide", "priority" => 43},
          %{"slug" => "gpt-small", "visibility" => "list", "priority" => 9},
          %{"slug" => "gpt-mid", "visibility" => "list", "priority" => 5}
        ]
      }

      respond =
        scripted([
          Req.Response.new(status: 400, body: refused),
          Req.Response.new(status: 200, body: Jason.encode!(models)),
          Req.Response.new(status: 200, body: sse([image_item(), @completed]))
        ])

      assert {:ok, %{model: "gpt-small", bytes: @png}} =
               Images.generate("Draw.", opts(dir, respond, model: "gpt-5.5"))

      assert_received {:asked, :post, _, _, %{"model" => "gpt-5.5"}}

      assert_received {:asked, :get, %URI{path: "/backend-api/codex/models", query: query}, _,
                       nil}

      assert URI.decode_query(query)["client_version"]
      assert_received {:asked, :post, _, _, %{"model" => "gpt-small"}}
    end

    test "refused, and the list's model is the one refused: the 400 as it came", %{tmp_dir: dir} do
      refused = ~s({"detail":"not supported when using Codex with a ChatGPT account."})
      models = %{"models" => [%{"slug" => "gpt-x", "visibility" => "list", "priority" => 1}]}

      respond =
        scripted([
          Req.Response.new(status: 400, body: refused),
          Req.Response.new(status: 200, body: Jason.encode!(models))
        ])

      assert {:error, {:http, 400, "not supported when using Codex with a ChatGPT account."}} =
               Images.generate("Draw.", opts(dir, respond, model: "gpt-x"))
    end

    test "a used-up subscription: rate limited until the Codex body's reset", %{tmp_dir: dir} do
      body =
        Jason.encode!(%{
          "error" => %{
            "type" => "usage_limit_reached",
            "message" => "The usage limit has been reached",
            "resets_at" => @now + 3600
          }
        })

      respond = scripted([Req.Response.new(status: 429, body: body)])

      assert {:error, {:rate_limited, limit}} = Images.generate("Draw.", opts(dir, respond))

      assert %{status: 429, provider: :openai_codex, resets_at: reset} = limit
      assert reset == @now + 3600
      assert Rho.LLM.describe({:rate_limited, limit}) =~ "ChatGPT"

      assert %{"resets_at" => ^reset, "model" => "openai_codex:gpt-5.6-luna"} =
               Usage.rate_limited(Usage.load(dir), :openai_codex)
    end

    test "no picture: the stream's error, else what the model said", %{tmp_dir: dir} do
      failed = %{
        "type" => "response.failed",
        "response" => %{
          "error" => %{"message" => "Your request was rejected by the safety system."}
        }
      }

      respond = scripted([Req.Response.new(status: 200, body: sse([failed]))])

      assert {:error, {:other, "Your request was rejected by the safety system."}} =
               Images.generate("Draw.", opts(dir, respond))

      said = [
        %{"type" => "response.output_text.delta", "delta" => "I can't "},
        %{"type" => "response.output_text.delta", "delta" => "draw that."},
        @completed
      ]

      respond = scripted([Req.Response.new(status: 200, body: sse(said))])

      assert {:error, {:other, "the model answered without a picture: I can't draw that."}} =
               Images.generate("Draw.", opts(dir, respond))

      assert %{"requests" => 2, "errors" => 1} =
               Usage.by_model(Usage.load(dir), :total)["openai_codex:gpt-5.6-luna"]
    end

    test "signed out, or a sign-in that can't refresh: nothing is asked", %{tmp_dir: dir} do
      never = fn _req -> flunk("asked the network") end

      assert {:error, {:signed_out, :openai_codex}} =
               Images.generate("Draw.",
                 credential: fn _ -> {:error, :signed_out} end,
                 respond: never,
                 data_dir: dir
               )

      assert {:error, {:auth, :openai_codex, "invalid_grant"}} =
               Images.generate("Draw.",
                 credential: fn _ -> {:error, {:refresh_failed, "invalid_grant"}} end,
                 respond: never,
                 data_dir: dir
               )
    end

    test "a rejected token: the 401 and its message", %{tmp_dir: dir} do
      respond =
        scripted([Req.Response.new(status: 401, body: ~s({"error":{"message":"Token expired"}}))])

      assert {:error, {:http, 401, "Token expired"}} =
               Images.generate("Draw.", opts(dir, respond))
    end
  end

  describe "models/1" do
    test "the listed ids in Codex's order, hidden ones left out" do
      body =
        Jason.encode!(%{
          "models" => [
            %{"slug" => "b", "visibility" => "list", "priority" => 5},
            %{"slug" => "hidden", "visibility" => "hide", "priority" => 4},
            %{"slug" => "a", "visibility" => "list", "priority" => 1}
          ]
        })

      respond = scripted([Req.Response.new(status: 200, body: body)])

      assert {:ok, ["a", "b"]} = Images.models(credential: &signed_in/1, respond: respond)
    end
  end
end
