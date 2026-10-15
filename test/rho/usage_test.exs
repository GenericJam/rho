defmodule Rho.UsageTest do
  use ExUnit.Case, async: true

  alias Rho.Usage
  alias Rho.Usage.Fetch

  @moduletag :tmp_dir

  @now 1_800_000_000
  @today ~D[2026-10-06]
  @claude "anthropic:claude-sonnet-4-5"
  @codex "openai_codex:gpt-5.1-codex"

  @claude_headers [
    {"anthropic-ratelimit-unified-5h-utilization", "0.42"},
    {"anthropic-ratelimit-unified-5h-reset", "#{@now + 7500}"},
    {"anthropic-ratelimit-unified-7d-utilization", "0.18"},
    {"anthropic-ratelimit-unified-7d-reset", "#{@now + 3 * 86_400}"},
    {"anthropic-ratelimit-unified-status", "allowed"},
    {"content-type", "text/event-stream"}
  ]

  @codex_headers [
    {"X-Codex-Primary-Used-Percent", "7"},
    {"x-codex-primary-window-minutes", "300"},
    {"x-codex-primary-reset-at", "#{@now + 600}"},
    {"x-codex-secondary-used-percent", "61.5"},
    {"x-codex-secondary-window-minutes", "10080"},
    {"x-codex-secondary-reset-at", "#{@now + 86_400}"}
  ]

  @usage %{input_tokens: 1200, output_tokens: 300, cache_read_tokens: 1000, total_cost: 0.01}

  defp record(dir, model, call, now \\ @now, date \\ @today),
    do: Usage.record(dir, model, call, now, date)

  describe "response headers" do
    test "Claude: unified 5h / 7d utilization (a fraction) and reset (unix s)" do
      h = Map.new(@claude_headers)

      assert %{
               "5h" => %{"label" => "5 hours", "used" => 42.0, "resets_at" => r5},
               "7d" => %{"used" => 18.0, "resets_at" => r7}
             } = Usage.from_headers(:anthropic, h)

      assert {r5, r7} == {@now + 7500, @now + 3 * 86_400}
      assert Usage.from_headers(:anthropic, %{"content-type" => "x"}) == %{}
    end

    test "ChatGPT: primary / secondary percent, window minutes, reset" do
      h = Map.new(@codex_headers, fn {k, v} -> {String.downcase(k), v} end)

      assert Usage.from_headers(:openai_codex, h) == %{
               "5h" => %{"label" => "5 hours", "used" => 7.0, "resets_at" => @now + 600},
               "7d" => %{"label" => "7 days", "used" => 61.5, "resets_at" => @now + 86_400}
             }

      # no window length: named after the header
      assert %{"primary" => %{"used" => 3.0, "resets_at" => nil}} =
               Usage.from_headers(:openai_codex, %{"x-codex-primary-used-percent" => "3"})
    end
  end

  describe "record/5" do
    test "keeps the windows, tokens and cost per model, day and all time, across reloads",
         %{tmp_dir: dir} do
      :ok = record(dir, @claude, %{status: 200, headers: @claude_headers, usage: @usage})
      :ok = record(dir, @claude, %{status: 200, headers: [], usage: @usage}, @now + 60)

      :ok =
        record(
          dir,
          @codex,
          %{status: 200, headers: @codex_headers, usage: @usage},
          @now,
          Date.add(@today, -1)
        )

      state = Usage.load(dir)
      assert Usage.status_text(state, :anthropic, @now) == "5h 42% · wk 18%"
      assert Usage.status_text(state, :openai_codex, @now) == "5h 7% · wk 62%"
      # a call without the headers keeps the last numbers
      assert Usage.limits(state, :anthropic)["source"] == "headers"

      today = Usage.by_model(state, @today)
      assert Map.keys(today) == [@claude]

      assert %{
               "requests" => 2,
               "errors" => 0,
               "input" => 400,
               "cacheRead" => 2000,
               "output" => 600
             } =
               today[@claude]

      assert_in_delta today[@claude]["cost"], 0.02, 1.0e-9
      assert %{"requests" => 3} = Usage.sum(Usage.by_model(state, :total))
    end

    test "a 429 counts as a failed request and keeps when it resets", %{tmp_dir: dir} do
      headers = [
        {"anthropic-ratelimit-unified-5h-utilization", "1.0"},
        {"anthropic-ratelimit-unified-5h-reset", "#{@now + 3600}"},
        {"anthropic-ratelimit-unified-reset", "#{@now + 3600}"},
        {"retry-after", "60"}
      ]

      :ok =
        record(dir, @claude, %{
          status: 429,
          headers: headers,
          error: "rate_limit_error: limit reached"
        })

      state = Usage.load(dir)

      assert %{"at" => @now, "resets_at" => resets, "model" => @claude, "message" => message} =
               Usage.rate_limited(state, :anthropic)

      assert resets == @now + 3600
      assert message =~ "limit reached"

      assert %{"requests" => 1, "errors" => 1, "cost" => 0} =
               Usage.by_model(state, :total)[@claude]

      assert Usage.status_text(state, :anthropic, @now + 60) == "5h 100% · 429 59m"
      # once the reset has passed: the window starts again, the 429 is history
      assert Usage.status_text(state, :anthropic, @now + 3601) == "5h 0%"
    end

    test "a ChatGPT 429's reset from the error body", %{tmp_dir: dir} do
      body = %{"error" => %{"type" => "usage_limit_reached", "resets_at" => @now + 5000}}
      :ok = record(dir, @codex, %{status: 429, headers: [], body: body, error: "limit"})

      assert %{"resets_at" => resets} = Usage.rate_limited(Usage.load(dir), :openai_codex)
      assert resets == @now + 5000
    end

    test "old days drop off; all time keeps them", %{tmp_dir: dir} do
      :ok =
        record(
          dir,
          @claude,
          %{status: 200, headers: [], usage: @usage},
          @now,
          Date.add(@today, -40)
        )

      :ok = record(dir, @claude, %{status: 200, headers: [], usage: @usage})
      state = Usage.load(dir)

      assert Map.keys(state["days"]) == ["2026-10-06"]
      assert Usage.by_model(state, :total)[@claude]["requests"] == 2
    end

    test "concurrent writers don't lose each other's updates", %{tmp_dir: dir} do
      call = %{status: 200, headers: [], usage: @usage}

      1..20
      |> Enum.map(fn _ -> Task.async(fn -> record(dir, @claude, call) end) end)
      |> Task.await_many()

      assert Usage.by_model(Usage.load(dir), :total)[@claude]["requests"] == 20
    end
  end

  test "nothing recorded: an empty store, no status figure", %{tmp_dir: dir} do
    state = Usage.load(dir)
    assert Usage.status_text(state, :anthropic, @now) == nil
    assert Usage.windows(state, :openai_codex) == []
    assert Usage.sum(Usage.by_model(state, :total))["requests"] == 0

    File.write!(Path.join(dir, "usage.json"), "{torn")
    assert Usage.load(dir) == %{}
  end

  test "a session's counters from its assistant messages" do
    entries = [
      %{"type" => "message", "message" => %{"role" => "user", "content" => "hi"}},
      %{
        "type" => "message",
        "message" => %{
          "role" => "assistant",
          "stopReason" => "stop",
          "usage" => %{
            "input" => 10,
            "output" => 5,
            "cacheRead" => 100,
            "cost" => %{"total" => 0.5}
          }
        }
      },
      %{"type" => "message", "message" => %{"role" => "assistant", "stopReason" => "error"}}
    ]

    assert %{"requests" => 2, "errors" => 1, "input" => 10, "cacheRead" => 100, "cost" => 0.5} =
             Usage.session(entries)
  end

  describe "usage endpoints" do
    test "Claude: five_hour / seven_day in percent, ISO resets, per-model weekly limits" do
      body = %{
        "five_hour" => %{"utilization" => 34.0, "resets_at" => "2027-01-15T08:00:00+00:00"},
        "seven_day" => %{"utilization" => 61, "resets_at" => "2027-01-20T00:00:00Z"},
        "seven_day_opus" => nil,
        "limits" => [
          %{"kind" => "session", "percent" => 99, "resets_at" => nil},
          %{
            "kind" => "weekly_scoped",
            "percent" => 12,
            "scope" => %{"model" => %{"display_name" => "Claude Opus"}}
          }
        ]
      }

      assert {windows, nil} = Usage.from_endpoint(:anthropic, body, @now)
      # the bucket wins over limits[]
      assert windows["5h"] == %{
               "label" => "5 hours",
               "used" => 34.0,
               "resets_at" => DateTime.to_unix(~U[2027-01-15 08:00:00Z])
             }

      assert windows["7d"]["used"] == 61.0
      assert %{"label" => "7 days (Claude Opus)", "used" => 12.0} = windows["7d_claude_opus"]
      refute Map.has_key?(windows, "7d_opus")
    end

    test "ChatGPT: rate_limit windows, reset_after_seconds, plan, extra meters" do
      body = %{
        "plan_type" => "plus",
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 20,
            "limit_window_seconds" => 18_000,
            "reset_after_seconds" => 900
          },
          "secondary_window" => %{
            "used_percent" => 5,
            "limit_window_seconds" => 604_800,
            "reset_at" => @now + 9
          }
        },
        "additional_rate_limits" => [
          %{
            "limit_name" => "Spark",
            "rate_limit" => %{
              "primary_window" => %{"used_percent" => 1, "limit_window_seconds" => 18_000}
            }
          }
        ]
      }

      assert {windows, "plus"} = Usage.from_endpoint(:openai_codex, body, @now)
      assert windows["5h"] == %{"label" => "5 hours", "used" => 20.0, "resets_at" => @now + 900}
      assert windows["7d"]["resets_at"] == @now + 9
      assert %{"label" => "5 hours (Spark)"} = windows["5h_spark"]
    end

    test "refresh stores what the endpoint says; the token only in the request", %{tmp_dir: dir} do
      respond = fn req ->
        send(self(), {:asked, req.url, req.headers})

        Req.Response.new(
          status: 200,
          body:
            Jason.encode!(%{
              "five_hour" => %{"utilization" => 50, "resets_at" => "2027-02-15T08:00:00Z"}
            })
        )
      end

      token = fn :anthropic -> {:ok, %{type: :oauth, token: "secret-token", account_id: nil}} end

      assert :ok =
               Fetch.refresh(dir, :anthropic, credential: token, respond: respond, now: @now)

      assert_received {:asked, %URI{host: "api.anthropic.com", path: "/api/oauth/usage"}, headers}
      assert headers["authorization"] == ["Bearer secret-token"]
      assert headers["anthropic-beta"] == ["oauth-2025-04-20"]

      state = Usage.load(dir)
      assert Usage.status_text(state, :anthropic, @now) == "5h 50%"
      assert Usage.limits(state, :anthropic)["source"] == "endpoint"
      refute File.read!(Path.join(dir, "usage.json")) =~ "secret-token"
    end

    test "refresh errors: the endpoint's status and message, nothing stored", %{tmp_dir: dir} do
      respond = fn _req ->
        Req.Response.new(status: 429, body: ~s({"error":{"message":"Too many requests"}}))
      end

      token = fn :openai_codex -> {:ok, %{type: :oauth, token: "t", account_id: "acc"}} end

      assert {:error, "HTTP 429: Too many requests"} =
               Fetch.refresh(dir, :openai_codex, credential: token, respond: respond)

      assert {:error, "not signed in"} =
               Fetch.refresh(dir, :anthropic, credential: fn _ -> {:error, :signed_out} end)

      # an API key has no subscription windows: nothing is asked
      keyed = fn _ -> {:ok, %{type: :api_key, key: "sk"}} end

      assert {:error, "no subscription usage: Claude (Anthropic) is used with an API key"} =
               Fetch.refresh(dir, :anthropic, credential: keyed, respond: fn _ -> flunk() end)

      assert Usage.load(dir) == %{}
    end
  end
end
