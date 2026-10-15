defmodule Rho.Budget do
  @moduledoc """
  The per-day cost cap: what the model calls cost today, priced by
  req_llm from each reply's usage (notional on a Claude or ChatGPT
  subscription), against the host's `Rho.Settings.daily_cap/1`.

  The ledger is `spend.json` in the data dir, `{"YYYY-MM-DD" => dollars}`
  by the device's local date, the last #{31} days kept. The loop checks
  `check/1` before every model call and `record/2`s every reply, across
  all sessions. A reply that runs past the cap still finishes (its cost
  is only known at the end); the next call is refused.
  """

  alias Rho.Settings

  @file_name "spend.json"
  @keep_days 31

  @doc "`:ok`, or `{:over, spent_today, cap}` once today's spend reached the cap."
  @spec check(Path.t(), Date.t()) :: :ok | {:over, float(), float()}
  def check(dir, date \\ today()) do
    spent = spent(dir, date)
    cap = Settings.daily_cap(dir)
    if spent >= cap, do: {:over, spent, cap}, else: :ok
  end

  @doc "Today's spend in dollars."
  @spec spent(Path.t(), Date.t()) :: float()
  def spent(dir, date \\ today()), do: Map.get(read(dir), Date.to_iso8601(date), 0.0) * 1.0

  @doc "Adds `cost` dollars to the day's spend (non-positive costs are ignored)."
  @spec record(Path.t(), number(), Date.t()) :: :ok
  def record(dir, cost, date \\ today())

  def record(dir, cost, date) when is_number(cost) and cost > 0 do
    key = Date.to_iso8601(date)
    oldest = date |> Date.add(-@keep_days) |> Date.to_iso8601()

    dir
    |> read()
    |> Map.update(key, cost * 1.0, &(&1 + cost))
    |> Map.reject(fn {day, _} -> day <= oldest end)
    |> then(&write(dir, &1))
  end

  def record(_dir, _cost, _date), do: :ok

  @doc "The phone's local date."
  @spec today() :: Date.t()
  def today do
    {date, _time} = :calendar.local_time()
    Date.from_erl!(date)
  end

  defp read(dir) do
    with {:ok, json} <- File.read(Path.join(dir, @file_name)),
         {:ok, %{} = map} <- Jason.decode(json) do
      for {day, n} <- map, is_number(n), into: %{}, do: {day, n * 1.0}
    else
      _ -> %{}
    end
  end

  # Temp file + rename: a crash mid-write leaves the old ledger.
  defp write(dir, map) do
    path = Path.join(dir, @file_name)
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(map))
    File.rename!(tmp, path)
  end
end
