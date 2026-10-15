defmodule Rho.Usage do
  @moduledoc """
  How much of each provider subscription is left, and what the model calls
  used, for the host's usage page and status line.

  The windows (percent used, reset time) come from the providers' rate-limit
  headers on every model call (`record/3`, from `Rho.LLM.ReqLLM`)
  and from their OAuth usage endpoints on demand (`put_endpoint/5`, with
  `Rho.Usage.Fetch`), as omp reads them:

    * Claude: `anthropic-ratelimit-unified-{5h,7d,7d_oi}-utilization` (a
      fraction) and `-reset` (unix seconds); `GET /api/oauth/usage` gives
      `five_hour` / `seven_day` / `limits[]` in percent with ISO resets.
    * ChatGPT: `x-codex-{primary,secondary}-used-percent`,
      `-window-minutes`, `-reset-at` (unix seconds); `GET
      /backend-api/wham/usage` gives `rate_limit.{primary,secondary}_window`.

  Everything is kept in `usage.json` in the data dir (no tokens, no
  secrets; it survives restarts):

    * `"limits"`: per provider, `"windows"` (id such as `"5h"` / `"7d"` →
      `%{"label", "used" (percent), "resets_at" (unix s or nil)}`),
      `"checked_at"`, `"source"` (`"headers"` or `"endpoint"`), `"plan"`
    * `"rate_limited"`: per provider, the last 429's `"at"`, `"resets_at"`,
      `"model"` and `"message"`
    * `"days"` (`"YYYY-MM-DD"` → model → counters, the last #{31} days) and
      `"total"` (model → counters): `"requests"`, `"errors"`, `"input"`,
      `"output"`, `"cacheRead"`, `"cacheWrite"`, `"cost"` (dollars,
      notional on a subscription)
  """

  alias Rho.Budget
  alias Rho.Session

  @file_name "usage.json"
  @keep_days 31
  @counters ~w(requests errors input output cacheRead cacheWrite cost)
  @message_max 300
  @registry Rho.Usage.Registry

  @typedoc "One model call as the adapter saw it; `usage` (req_llm's) only on success."
  @type call :: %{
          required(:status) => integer() | nil,
          required(:headers) => [{String.t(), String.t()}] | map(),
          optional(:usage) => map() | nil,
          optional(:body) => term(),
          optional(:error) => String.t() | nil
        }

  @doc "The registry of `subscribe/0`'s processes, under `Rho.Supervisor`."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: Registry.child_spec(keys: :duplicate, name: @registry)

  @doc """
  Sends the caller `{:rho_usage, :changed}` after every change to the
  store (a model call, an endpoint refresh), so the chat's status line
  follows calls made anywhere. A no-op while `Rho.Supervisor` isn't running.
  """
  @spec subscribe() :: :ok
  def subscribe do
    if Process.whereis(@registry), do: {:ok, _} = Registry.register(@registry, :changed, nil)
    :ok
  end

  # ── reading ──

  @doc "Everything recorded so far (an empty store when there's no readable file)."
  @spec load(Path.t()) :: map()
  def load(dir) do
    with {:ok, json} <- File.read(Path.join(dir, @file_name)),
         {:ok, %{} = state} <- Jason.decode(json) do
      state
    else
      _ -> %{}
    end
  end

  @doc "A provider's windows, `5h` then `7d` then the rest by id: `[{id, window}]`."
  @spec windows(map(), atom()) :: [{String.t(), map()}]
  def windows(state, provider) do
    state
    |> get_in(["limits", to_string(provider), "windows"])
    |> Kernel.||(%{})
    |> Enum.sort_by(fn {id, _} -> {Map.get(%{"5h" => 0, "7d" => 1}, id, 2), id} end)
  end

  @doc "A provider's `\"limits\"` entry (`checked_at`, `source`, `plan`), or nil."
  @spec limits(map(), atom()) :: map() | nil
  def limits(state, provider), do: get_in(state, ["limits", to_string(provider)])

  @doc "A provider's last 429, or nil."
  @spec rate_limited(map(), atom()) :: map() | nil
  def rate_limited(state, provider), do: get_in(state, ["rate_limited", to_string(provider)])

  @doc """
  Is `provider`'s subscription used up at `now`: a window at 100 % that
  resets later (the latest such reset), else a 429 recorded with a reset
  still ahead? `%{window: label | nil, resets_at: unix s}` or nil.
  """
  @spec exhausted(map(), atom(), integer()) ::
          %{window: String.t() | nil, resets_at: integer()} | nil
  def exhausted(state, provider, now \\ now()) do
    full =
      for {_id, %{"used" => used, "resets_at" => at} = w} <- windows(state, provider),
          is_number(used) and used >= 100 and is_integer(at) and at > now,
          do: %{window: w["label"], resets_at: at}

    case {full, rate_limited(state, provider)} do
      {[_ | _], _} -> Enum.max_by(full, & &1.resets_at)
      {[], %{"resets_at" => at}} when is_integer(at) and at > now -> %{window: nil, resets_at: at}
      _ -> nil
    end
  end

  @doc "Counters per model for `date` (`:total` for all time)."
  @spec by_model(map(), Date.t() | :total) :: %{String.t() => map()}
  def by_model(state, :total), do: state["total"] || %{}
  def by_model(state, %Date{} = date), do: get_in(state, ["days", Date.to_iso8601(date)]) || %{}

  @doc "Counters summed over every model."
  @spec sum(%{String.t() => map()}) :: map()
  def sum(by_model), do: Enum.reduce(Map.values(by_model), zero(), &add/2)

  @doc """
  A session's counters from its entries: every assistant message is a
  request, `stopReason: "error"` an error.
  """
  @spec session([map()]) :: map()
  def session(entries) do
    for %{"type" => "message", "message" => %{"role" => "assistant"} = m} <- entries,
        reduce: zero() do
      acc ->
        u = m["usage"] || %{}

        add(acc, %{
          "requests" => 1,
          "errors" => if(m["stopReason"] == "error", do: 1, else: 0),
          "input" => u["input"] || 0,
          "output" => u["output"] || 0,
          "cacheRead" => u["cacheRead"] || 0,
          "cacheWrite" => u["cacheWrite"] || 0,
          "cost" => get_in(u, ["cost", "total"]) || 0
        })
    end
  end

  @doc """
  The status line's figure for `provider`: `"5h 42% · wk 18%"`, plus
  `" · 429 2h 5m"` while its last rate limit hasn't reset; nil before any
  numbers. A window whose reset has passed counts as 0%.
  """
  @spec status_text(map(), atom(), integer()) :: String.t() | nil
  def status_text(state, provider, now \\ now()) do
    windows = Map.new(windows(state, provider))

    parts =
      for {id, short} <- [{"5h", "5h"}, {"7d", "wk"}], w = windows[id], w != nil do
        "#{short} #{percent(w, now)}%"
      end

    limited =
      case rate_limited(state, provider) do
        %{"resets_at" => at} when is_integer(at) and at > now -> ["429 #{duration(at - now)}"]
        _ -> []
      end

    case parts ++ limited do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  @doc "A window's percent used now, rounded (0 once its reset time has passed)."
  @spec percent(map(), integer()) :: non_neg_integer()
  def percent(%{"resets_at" => at}, now) when is_integer(at) and at <= now, do: 0
  def percent(%{"used" => used}, _now) when is_number(used), do: round(used)
  def percent(_window, _now), do: 0

  @doc "`2h 5m`, `3d 4h`, `12m`, `<1m`."
  @spec duration(integer()) :: String.t()
  def duration(s) when s < 60, do: "<1m"
  def duration(s) when s < 3600, do: "#{div(s, 60)}m"
  def duration(s) when s < 86_400, do: "#{div(s, 3600)}h #{rem(div(s, 60), 60)}m"
  def duration(s), do: "#{div(s, 86_400)}d #{rem(div(s, 3600), 24)}h"

  # ── recording ──

  @doc """
  Records one model call to `model`: a request (an error unless it carries
  `usage`) with its tokens and cost, the windows its headers report, and a
  429 with when it resets.
  """
  @spec record(Path.t(), String.t(), call(), integer(), Date.t()) :: :ok
  def record(dir, model, call, now \\ now(), date \\ Budget.today()) do
    headers = headers(call.headers)
    provider = provider(model)

    update(dir, fn state ->
      windows = if provider, do: from_headers(provider, headers), else: %{}

      state
      |> count(model, call, date)
      |> put_windows(provider, windows, "headers", nil, now)
      |> put_rate_limit(provider, model, call, headers, windows, now)
    end)
  end

  @doc "Stores what a provider's usage endpoint returned (`windows` from `from_endpoint/3`)."
  @spec put_endpoint(Path.t(), atom(), map(), String.t() | nil, integer()) :: :ok
  def put_endpoint(dir, provider, windows, plan, now \\ now()),
    do: update(dir, &put_windows(&1, provider, windows, "endpoint", plan, now))

  # ── parsing ──

  @doc "The windows a model call's response headers report (`%{}` without any)."
  @spec from_headers(atom(), %{String.t() => String.t()}) :: %{String.t() => map()}
  def from_headers(:anthropic, h) do
    for {id, label} <- [{"5h", "5 hours"}, {"7d", "7 days"}, {"7d_oi", "7 days (Fable)"}],
        used = number(h["anthropic-ratelimit-unified-#{id}-utilization"]),
        used != nil,
        into: %{} do
      reset = number(h["anthropic-ratelimit-unified-#{id}-reset"])
      {id, window(label, used * 100, reset && reset > 0 && trunc(reset))}
    end
  end

  def from_headers(:openai_codex, h) do
    for key <- ["primary", "secondary"],
        used = number(h["x-codex-#{key}-used-percent"]),
        used != nil,
        into: %{} do
      minutes = number(h["x-codex-#{key}-window-minutes"])
      {id, label} = codex_window(minutes && minutes * 60, key)
      reset = number(h["x-codex-#{key}-reset-at"])
      {id, window(label, used, reset && reset > 0 && trunc(reset))}
    end
  end

  def from_headers(_provider, _headers), do: %{}

  @doc "The windows and plan a usage endpoint's JSON reports: `{windows, plan}`."
  @spec from_endpoint(atom(), map(), integer()) :: {%{String.t() => map()}, String.t() | nil}
  def from_endpoint(:anthropic, body, _now) do
    buckets =
      for {key, id, label} <- [
            {"five_hour", "5h", "5 hours"},
            {"seven_day", "7d", "7 days"},
            {"seven_day_opus", "7d_opus", "7 days (Opus)"},
            {"seven_day_sonnet", "7d_sonnet", "7 days (Sonnet)"}
          ],
          %{} = b <- [body[key]],
          is_number(b["utilization"]),
          into: %{} do
        {id, window(label, b["utilization"], iso(b["resets_at"]))}
      end

    {Map.merge(anthropic_limits(body["limits"]), buckets), nil}
  end

  def from_endpoint(:openai_codex, body, now) do
    main = codex_rate_limit(body["rate_limit"], nil, now)

    extra =
      for %{} = meter <- List.wrap(body["additional_rate_limits"]),
          name = meter["limit_name"] || meter["metered_feature"],
          is_binary(name),
          reduce: %{} do
        acc -> Map.merge(acc, codex_rate_limit(meter["rate_limit"], name, now))
      end

    plan = if is_binary(body["plan_type"]), do: body["plan_type"]
    {Map.merge(extra, main), plan}
  end

  # `limits[]`: session / weekly_all where the buckets are missing, and the
  # per-model weekly limits.
  defp anthropic_limits(limits) do
    for %{"kind" => kind} = l <- List.wrap(limits), is_number(l["percent"]), into: %{} do
      reset = iso(l["resets_at"])

      case {kind, get_in(l, ["scope", "model", "display_name"])} do
        {"session", _} ->
          {"5h", window("5 hours", l["percent"], reset)}

        {"weekly_all", _} ->
          {"7d", window("7 days", l["percent"], reset)}

        {_, name} when is_binary(name) ->
          {"7d_" <> slug(name), window("7 days (#{name})", l["percent"], reset)}

        {other, _} ->
          {other, window(other, l["percent"], reset)}
      end
    end
  end

  defp codex_rate_limit(%{} = rl, meter, now) do
    for key <- ["primary", "secondary"],
        %{} = w <- [rl["#{key}_window"]],
        is_number(w["used_percent"]),
        into: %{} do
      {id, label} = codex_window(w["limit_window_seconds"], key)

      {id, label} =
        if meter, do: {"#{id}_#{slug(meter)}", "#{label} (#{meter})"}, else: {id, label}

      {id, window(label, w["used_percent"], codex_reset(w, now))}
    end
  end

  defp codex_rate_limit(_rl, _meter, _now), do: %{}

  defp codex_reset(%{"reset_at" => at}, _now) when is_number(at) and at > 1_000_000_000_000,
    do: div(trunc(at), 1000)

  defp codex_reset(%{"reset_at" => at}, _now) when is_number(at) and at > 0, do: trunc(at)

  defp codex_reset(%{"reset_after_seconds" => s}, now) when is_number(s), do: now + trunc(s)
  defp codex_reset(_w, _now), do: nil

  # A Codex window's id and label from its length (300 minutes is `5h`).
  defp codex_window(seconds, _key) when is_number(seconds) and seconds > 0 do
    if seconds >= 86_400 do
      d = round(seconds / 86_400)
      {"#{d}d", "#{d} day#{if d == 1, do: "", else: "s"}"}
    else
      h = max(round(seconds / 3600), 1)
      {"#{h}h", "#{h} hour#{if h == 1, do: "", else: "s"}"}
    end
  end

  defp codex_window(_seconds, key), do: {key, "#{key} window"}

  defp window(label, used, resets_at),
    do: %{
      "label" => label,
      "used" => min(max(used * 1.0, 0.0), 100.0),
      "resets_at" => resets_at || nil
    }

  # ── updates ──

  defp count(state, model, call, date) do
    counters =
      case {call[:usage], call[:error]} do
        {%{} = usage, nil} ->
          u = Session.usage(usage)

          %{
            "requests" => 1,
            "input" => u["input"],
            "output" => u["output"],
            "cacheRead" => u["cacheRead"],
            "cacheWrite" => u["cacheWrite"],
            "cost" => u["cost"]["total"]
          }

        _ ->
          %{"requests" => 1, "errors" => 1}
      end

    day = Date.to_iso8601(date)
    oldest = date |> Date.add(-@keep_days) |> Date.to_iso8601()

    days =
      (state["days"] || %{})
      |> Map.update(day, %{model => add(zero(), counters)}, fn models ->
        Map.update(models, model, add(zero(), counters), &add(&1, counters))
      end)
      |> Map.reject(fn {d, _} -> d <= oldest end)

    total = Map.update(state["total"] || %{}, model, add(zero(), counters), &add(&1, counters))
    Map.merge(state, %{"days" => days, "total" => total})
  end

  defp put_windows(state, provider, windows, _source, _plan, _now)
       when provider == nil or windows == %{},
       do: state

  defp put_windows(state, provider, windows, source, plan, now) do
    old = limits(state, provider) || %{}

    entry =
      Map.merge(old, %{
        "windows" => Map.merge(old["windows"] || %{}, windows),
        "checked_at" => now,
        "source" => source
      })

    entry = if plan, do: Map.put(entry, "plan", plan), else: entry
    put_in(state, [Access.key("limits", %{}), to_string(provider)], entry)
  end

  defp put_rate_limit(state, provider, model, %{status: 429} = call, h, windows, now)
       when provider != nil do
    # The latest of: retry-after, Claude's unified reset, an exhausted
    # window's reset, the Codex error body's `resets_at`.
    retry = number(h["retry-after-ms"])
    retry = (retry && retry / 1000) || number(h["retry-after"])

    candidates =
      [
        retry && now + ceil(retry),
        number(h["anthropic-ratelimit-unified-reset"]),
        body_resets_at(call[:body])
        | for({_, %{"used" => u, "resets_at" => at}} <- windows, u >= 100, do: at)
      ]
      |> Enum.filter(&(is_number(&1) and &1 > now))

    entry = %{
      "at" => now,
      "resets_at" => if(candidates == [], do: nil, else: trunc(Enum.max(candidates))),
      "model" => model,
      "message" => call[:error] |> to_string() |> String.slice(0, @message_max)
    }

    put_in(state, [Access.key("rate_limited", %{}), to_string(provider)], entry)
  end

  defp put_rate_limit(state, _provider, _model, _call, _h, _windows, _now), do: state

  defp body_resets_at(%{"error" => %{"resets_at" => at}}) when is_number(at), do: at
  defp body_resets_at(%{"resets_at" => at}) when is_number(at), do: at
  defp body_resets_at(_body), do: nil

  # Read, change, write under a lock (model calls of several loops, and the
  # usage page's refresh, may write at once); a failed write keeps the old file.
  defp update(dir, fun) do
    # Resource per data dir, requester per process: one writer at a time.
    lock = {{__MODULE__, Path.expand(dir)}, self()}
    :global.trans(lock, fn -> write(dir, fun.(load(dir))) end, [node()])
    notify()
    :ok
  end

  defp notify do
    if Process.whereis(@registry), do: Registry.dispatch(@registry, :changed, &changed/1)
  end

  defp changed(entries), do: for({pid, _} <- entries, do: send(pid, {:rho_usage, :changed}))

  defp write(dir, state) do
    path = Path.join(dir, @file_name)
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, Jason.encode!(state))
    File.rename!(tmp, path)
  end

  # ── helpers ──

  defp zero, do: Map.new(@counters, &{&1, 0})

  defp add(acc, counters) do
    Map.new(@counters, fn k -> {k, (acc[k] || 0) + (counters[k] || 0)} end)
  end

  defp provider(model) do
    case Rho.Auth.provider_for_model(model) do
      {:ok, provider} -> provider
      :error -> nil
    end
  end

  defp headers(%{} = headers), do: headers(Map.to_list(headers))

  defp headers(headers) when is_list(headers) do
    Map.new(headers, fn {k, v} -> {String.downcase(to_string(k)), header_value(v)} end)
  end

  defp headers(_), do: %{}

  defp header_value([v | _]), do: to_string(v)
  defp header_value(v), do: to_string(v)

  defp number(n) when is_number(n), do: n

  defp number(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp number(_), do: nil

  defp iso(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp iso(_), do: nil

  defp slug(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")

  defp now, do: System.os_time(:second)
end
