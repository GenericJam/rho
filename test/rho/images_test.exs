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

    test "a model the account refuses: draws with Codex's default, the first it lists",
         %{tmp_dir: dir} do
      refused =
        ~s({"detail":"The 'gpt-5.5' model is not supported when using Codex with a ChatGPT account."})

      models = %{
        "models" => [
          %{"slug" => "gpt-mid", "visibility" => "list", "priority" => 5},
          %{"slug" => "secret", "visibility" => "hide", "priority" => 0},
          %{"slug" => "gpt-default", "visibility" => "list", "priority" => 1},
          %{"slug" => "gpt-small", "visibility" => "list", "priority" => 9}
        ]
      }

      respond =
        scripted([
          Req.Response.new(status: 400, body: refused),
          Req.Response.new(status: 200, body: Jason.encode!(models)),
          Req.Response.new(status: 200, body: sse([image_item(), @completed]))
        ])

      assert {:ok, %{model: "gpt-default", bytes: @png}} =
               Images.generate("Draw.", opts(dir, respond, model: "gpt-5.5"))

      assert_received {:asked, :post, _, _, %{"model" => "gpt-5.5"}}

      assert_received {:asked, :get, %URI{path: "/backend-api/codex/models", query: query}, _,
                       nil}

      assert URI.decode_query(query)["client_version"] =~ ~r/^\d+\.\d+\.\d+$/
      assert_received {:asked, :post, _, _, %{"model" => "gpt-default"}}
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

  describe "generate/2 over a real connection" do
    alias Rho.Test.SSEServer

    defp live_opts(dir, url, extra \\ []),
      do: [credential: &signed_in/1, base_url: url, data_dir: dir, now: @now] ++ extra

    test "a stream in pieces: the picture, though a blank line and the base64 straddle chunks",
         %{tmp_dir: dir} do
      created = ~s(event: x\ndata: {"type":"response.created"}\n)
      body = created <> "\n" <> sse([image_item(), @completed])

      # Split right inside the first event's blank line, and inside the picture.
      first = byte_size(created)
      middle = first + 200

      chunks = [
        binary_part(body, 0, first),
        {:sleep, 20},
        binary_part(body, first, middle - first),
        {:sleep, 20},
        binary_part(body, middle, byte_size(body) - middle)
      ]

      url = SSEServer.start!([chunks])

      assert {:ok, %{bytes: @png, mime: "image/png", action: "generate"}} =
               Images.generate("Draw.", live_opts(dir, url))

      assert_received {SSEServer, :request, "/responses"}

      assert %{"requests" => 1, "errors" => 0, "input" => 2000} =
               Usage.by_model(Usage.load(dir), :total)["openai_codex:gpt-5.6-luna"]
    end

    test "a failure's body through the stream: a usage limit", %{tmp_dir: dir} do
      body =
        ~s({"error":{"type":"usage_limit_reached","message":"limit","resets_at":#{@now + 60}}})

      url = SSEServer.start!([{429, [body]}])

      assert {:error, {:rate_limited, %{resets_at: reset, message: "limit"}}} =
               Images.generate("Draw.", live_opts(dir, url))

      assert reset == @now + 60
    end

    test "past :timeout, even while it streams: a transport timeout, recorded", %{tmp_dir: dir} do
      tick = ~s(data: {"type":"response.in_progress"}\n\n)
      url = SSEServer.start!([List.duplicate([tick, {:sleep, 50}], 40) |> List.flatten()])

      assert {:error, {:transport, :timeout}} =
               Images.generate("Draw.", live_opts(dir, url, timeout: 300))

      assert %{"requests" => 1, "errors" => 1} =
               Usage.by_model(Usage.load(dir), :total)["openai_codex:gpt-5.6-luna"]
    end

    test "CRLF lines, the blank line split between chunks", %{tmp_dir: dir} do
      body = sse([%{"type" => "response.created"}, image_item(), @completed])
      body = String.replace(body, "\n", "\r\n")
      # Inside the first event's "\r\n\r\n".
      [first, _] = :binary.split(body, "\r\n\r\n")
      cut = byte_size(first) + 3

      url =
        SSEServer.start!([
          [binary_part(body, 0, cut), {:sleep, 20}, binary_part(body, cut, byte_size(body) - cut)]
        ])

      assert {:ok, %{bytes: @png}} = Images.generate("Draw.", live_opts(dir, url))
    end

    test "a picture whose stream ends before response.completed: drawn, not an error",
         %{tmp_dir: dir} do
      url = SSEServer.start!([sse([image_item()])])

      assert {:ok, %{bytes: @png, usage: nil}} = Images.generate("Draw.", live_opts(dir, url))

      assert %{"requests" => 1, "errors" => 0} =
               Usage.by_model(Usage.load(dir), :total)["openai_codex:gpt-5.6-luna"]
    end
  end
end
