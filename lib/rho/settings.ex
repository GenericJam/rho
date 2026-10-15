defmodule Rho.Settings do
  @moduledoc """
  The user settings the loop reads, a host seam
  (`config :rho, :settings, Module`):

    * `fallback_model/1`: the model a run continues on when its own is
      rate limited past waiting (`Rho.Loop`), a req_llm spec, or nil
    * `daily_cap/1`: dollars of model calls a day before the loop refuses
      the next one (`Rho.Budget`)

  Each gets the loop's data dir and is read when needed (before each model
  call, at a fallback), so a change applies at once. The default,
  `Rho.Settings.File`, keeps them in `settings.json` in the data dir.
  """

  @callback fallback_model(data_dir :: Path.t()) :: String.t() | nil
  @callback daily_cap(data_dir :: Path.t()) :: float()

  @spec fallback_model(Path.t()) :: String.t() | nil
  def fallback_model(dir), do: Rho.Config.settings().fallback_model(dir)

  @spec daily_cap(Path.t()) :: float()
  def daily_cap(dir), do: Rho.Config.settings().daily_cap(dir)
end

defmodule Rho.Settings.File do
  @moduledoc """
  The default `Rho.Settings`: `settings.json` in the data dir (a missing
  or unreadable file means the defaults; other keys in it are kept, so a
  host may share the file). Each call reads the file.

    * `"daily_cap"`: default #{1.0}
    * `"fallback_model"`: none by default
  """
  @behaviour Rho.Settings

  @file_name "settings.json"
  @default_daily_cap 1.0

  @impl true
  def daily_cap(dir \\ Rho.Config.data_dir()) do
    case read(dir) do
      %{"daily_cap" => cap} when is_number(cap) and cap >= 0 -> cap * 1.0
      _ -> @default_daily_cap
    end
  end

  @spec put_daily_cap(number(), Path.t()) :: :ok
  def put_daily_cap(cap, dir \\ Rho.Config.data_dir()) when is_number(cap) and cap >= 0,
    do: write(dir, Map.put(read(dir), "daily_cap", cap * 1.0))

  @impl true
  def fallback_model(dir \\ Rho.Config.data_dir()) do
    case read(dir) do
      %{"fallback_model" => model} when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  @doc "Sets the fallback model (a req_llm spec); nil removes it."
  @spec put_fallback_model(String.t() | nil, Path.t()) :: :ok
  def put_fallback_model(model, dir \\ Rho.Config.data_dir())
      when is_binary(model) or is_nil(model),
      do: write(dir, Map.put(read(dir), "fallback_model", model))

  defp read(dir) do
    with {:ok, json} <- File.read(Path.join(dir, @file_name)),
         {:ok, %{} = map} <- Jason.decode(json) do
      map
    else
      _ -> %{}
    end
  end

  # Written to a temp file and renamed, so a crash mid-write leaves the old file.
  defp write(dir, map) do
    File.mkdir_p!(dir)
    path = Path.join(dir, @file_name)
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(map, pretty: true))
    File.rename!(tmp, path)
  end
end
