defmodule Rho.Models.Codex do
  @moduledoc """
  The models the ChatGPT sign-in (`openai_codex:`) may use, and the Codex
  backend's request basics (`Rho.Images` draws through them too).

  The list is Codex's own: `GET https://chatgpt.com/backend-api/codex/models`,
  asked as Codex CLI 0.163.0 (the endpoint lists what a client of that
  version may use), in Codex's order (its picker's, by priority: the first
  is the sign-in's default), hidden ones left out. A model the catalog once
  listed may be refused by the backend ("… is not supported when using
  Codex with a ChatGPT account"); this list is what it accepts.

  Each sign-in has its own list, kept per data dir (`:data_dir`, default
  `Rho.Config.data_dir/0`: the node's sign-in, `Rho.Auth`; a loop uses its
  own `:data_dir` and `:credential`, so a host serving several accounts
  keeps one list per account): in memory (an ETS table this module's
  process owns; `Rho.Supervisor` starts it) and in the dir's
  `codex_models.json`, so a restart offline still has it. It is fetched
  again in the background (`refresh_async/1`) once 6 hours old, or 5
  minutes after a failed try, one fetch at a time per dir:
  `Rho.Models.catalog/1` asks with the node's sign-in, a loop starting a
  run on a ChatGPT model with its own. `config :rho, :codex_models_refresh,
  false` turns the background fetch off (tests).

  Before the first fetch the list is the one shipped in
  `priv/models/openai_codex.json` (Codex's on the date in the file), which
  only names models: whether one is accepted is known from a fetched list
  or from the backend refusing it (`refused/2`, remembered until the next
  fetch).
  """
  use GenServer

  require Logger

  alias Rho.Auth
  alias Rho.LLM.ReqLLM, as: Adapter

  @base_url "https://chatgpt.com/backend-api/codex"
  # The Codex CLI version whose model list `fetch/1` asks for (the current
  # release on 2026-10-18): an old one gets fewer models, a very old one
  # none. `:client_version` overrides it.
  @client_version "0.163.0"
  @originator "codex_cli_rs"

  @ttl_ms 6 * 60 * 60 * 1000
  @retry_ms 5 * 60 * 1000
  @file_name "codex_models.json"
  @table __MODULE__

  # Read at compile time and embedded: Application.app_dir/2 can't resolve
  # priv/ on a phone.
  @shipped_file Path.expand("../../../priv/models/openai_codex.json", __DIR__)
  @external_resource @shipped_file
  @shipped for m <- Jason.decode!(File.read!(@shipped_file))["models"],
               do: %{id: m["id"], name: m["name"], context: m["context"]}

  @type model :: %{id: String.t(), name: String.t(), context: pos_integer() | nil}

  # ── the table's owner ──

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  # ── the list ──

  @doc """
  The sign-in's models, in Codex's order: the fetched list (memory, else
  the data dir's file), else the shipped one, without any the backend has
  refused since. `opts`: `:data_dir`.
  """
  @spec models(keyword()) :: [model()]
  def models(opts \\ []) do
    dir = dir(opts)
    refused = get({:refused, dir}, [])

    case fetched(dir) do
      %{models: models} -> models
      nil -> @shipped
    end
    |> Enum.reject(&(&1.id in refused))
  end

  @doc "The sign-in's default model id: the first `models/1` lists, nil when none is left."
  @spec default(keyword()) :: String.t() | nil
  def default(opts \\ []) do
    case models(opts) do
      [%{id: id} | _] -> id
      [] -> nil
    end
  end

  @doc """
  The spec a saved ChatGPT model `spec` should run as instead: the
  sign-in's default (`"openai_codex:<id>"`) when a fetched list doesn't
  have it or the backend refused it; nil when it is accepted, when nothing
  says otherwise (no fetch yet, not refused), or for another provider's
  spec. `opts`: `:data_dir`.
  """
  @spec replacement(String.t(), keyword()) :: String.t() | nil
  def replacement(spec, opts \\ [])

  def replacement("openai_codex:" <> id, opts) do
    dir = dir(opts)

    gone =
      id in get({:refused, dir}, []) or
        case fetched(dir) do
          %{models: models} -> not Enum.any?(models, &(&1.id == id))
          nil -> false
        end

    if gone, do: default_spec(opts)
  end

  def replacement(_spec, _opts), do: nil

  @doc """
  The one-line notice for a conversation moved from `from` to `to` (specs)
  because the sign-in no longer accepts `from`; the models' names from the
  sign-in's list (`opts`: `:data_dir`), else the shipped one, else their ids.
  """
  @spec replaced_notice(String.t(), String.t(), keyword()) :: String.t()
  def replaced_notice(from, to, opts \\ []) do
    known = models(opts) ++ @shipped

    "#{name(from, known)} isn't offered on the ChatGPT sign-in any more; " <>
      "using #{name(to, known)} instead."
  end

  defp name("openai_codex:" <> id, known) do
    case Enum.find(known, &(&1.id == id)) do
      %{name: name} -> name
      nil -> id
    end
  end

  @doc "Whether a backend error message says the account refused the model."
  @spec refused?(String.t()) :: boolean()
  def refused?(message) when is_binary(message),
    do: String.contains?(message, "not supported when using Codex with a ChatGPT account")

  @doc """
  The backend refused `spec`: it is left out of the sign-in's list until
  the next fetch, which is asked for now in the background
  (`refresh_async/1`'s `opts`). Returns the spec to use instead, the
  sign-in's default; nil when no other model is listed. `opts`:
  `:data_dir`, and `fetch/1`'s for the fetch.
  """
  @spec refused(String.t(), keyword()) :: String.t() | nil
  def refused("openai_codex:" <> id, opts \\ []) do
    dir = dir(opts)

    if table?() do
      refused = get({:refused, dir}, [])
      unless id in refused, do: :ets.insert(@table, {{:refused, dir}, [id | refused]})
      # The list may be stale: the next fetch decides, now.
      :ets.delete(@table, {:tried, dir})
    end

    refresh_async(opts)

    # Not `id` itself, even when nothing could be remembered (no table).
    case Enum.find(models(opts), &(&1.id != id)) do
      %{id: default} -> "openai_codex:" <> default
      nil -> nil
    end
  end

  defp default_spec(opts) do
    case default(opts) do
      nil -> nil
      id -> "openai_codex:" <> id
    end
  end

  @doc """
  Fetches the list again in the background when it is stale (none yet, or
  6 hours old), no try was made in the last 5 minutes and none is under
  way for the same data dir. `opts`: `:data_dir`, and `fetch/1`'s. Does
  nothing with `config :rho, :codex_models_refresh, false`, or without
  this module's process.
  """
  @spec refresh_async(keyword()) :: :ok
  def refresh_async(opts \\ []) do
    dir = dir(opts)
    now = System.monotonic_time(:millisecond)

    if Application.get_env(:rho, :codex_models_refresh, true) and table?() and stale?(dir, now) and
         :ets.insert_new(@table, {{:fetching, dir}, now}) do
      :ets.insert(@table, {{:tried, dir}, now})

      Task.start(fn ->
        try do
          refresh(opts)
        catch
          kind, reason ->
            Logger.warning("[codex models] #{Exception.format_banner(kind, reason)}")
        after
          :ets.delete(@table, {:fetching, dir})
        end
      end)
    end

    :ok
  end

  defp stale?(dir, now) do
    tried = get({:tried, dir}, nil)

    (tried == nil or now - tried >= @retry_ms) and
      case fetched(dir) do
        %{fetched_at: at} -> System.os_time(:millisecond) - at >= @ttl_ms
        nil -> true
      end
  end

  @doc """
  Fetches the list (`fetch/1`) and keeps it for the data dir (`:data_dir`):
  in memory (with this module's process) and in the dir's file, forgetting
  the refusals before it. An empty list isn't kept.
  """
  @spec refresh(keyword()) :: {:ok, [model()]} | {:error, Rho.LLM.error()}
  def refresh(opts \\ []) do
    dir = dir(opts)

    case fetch(opts) do
      {:ok, [_ | _] = models} ->
        list = %{models: models, fetched_at: System.os_time(:millisecond)}

        if table?() do
          :ets.insert(@table, {{:list, dir}, list})
          :ets.delete(@table, {:refused, dir})
        end

        save(dir, list)
        {:ok, models}

      {:ok, []} ->
        {:error, {:other, "Codex listed no models for this account"}}

      {:error, reason} = error ->
        Logger.warning("[codex models] #{Rho.LLM.describe(reason)}")
        error
    end
  end

  @doc """
  Codex's model list for the sign-in, without keeping it. Options:
  `:credential` (`fn provider -> Rho.Auth.credential/1's answer end`,
  default `Rho.Auth.credential/1`), `:client_version`, `:base_url` and
  `:respond` (a test's `fn %Req.Request{} -> %Req.Response{} end`).
  """
  @spec fetch(keyword()) :: {:ok, [model()]} | {:error, Rho.LLM.error()}
  def fetch(opts \\ []) do
    credential = Keyword.get(opts, :credential, &Auth.credential/1)

    with {:ok, auth} <- Adapter.credential(:openai_codex, credential) do
      req =
        request(opts,
          method: :get,
          url: "/models",
          params: [client_version: Keyword.get(opts, :client_version, @client_version)],
          headers: headers(auth, "application/json"),
          receive_timeout: 15_000
        )

      case Req.request(req) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          listed(body)

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http, status, error_text(body)}}

        {:error, e} ->
          {:error, Adapter.normalize(e)}
      end
    end
  end

  # The picker's models (visibility "list"), by priority; anything else in
  # the list is skipped.
  defp listed(body) do
    case Jason.decode(body) do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok,
         models
         |> Enum.filter(
           &match?(%{"slug" => slug, "visibility" => "list"} when is_binary(slug), &1)
         )
         |> Enum.sort_by(&priority/1)
         |> Enum.map(&model/1)}

      _ ->
        {:error, {:other, "Codex's model list wasn't JSON with models"}}
    end
  end

  defp priority(%{"priority" => p}) when is_number(p), do: p
  defp priority(_model), do: 1_000

  defp model(%{"slug" => slug} = m) do
    %{
      id: slug,
      name: display_name(m["display_name"], slug),
      context:
        if(is_integer(m["context_window"]) and m["context_window"] > 0, do: m["context_window"])
    }
  end

  # Codex's "GPT-6.1-Sol" as the catalog writes it, "GPT-6.1 Sol".
  defp display_name(name, _slug) when is_binary(name) and name != "" do
    "^(GPT-\\d+(?:\\.\\d+)*)-"
    |> Regex.compile!()
    |> Regex.replace(String.slice(name, 0, 60), "\\1 ")
  end

  defp display_name(_name, slug), do: slug

  # The provider's own message, bounded; the status alone when it has none.
  @doc false
  @spec error_text(iodata()) :: String.t()
  def error_text(body) do
    case Jason.decode(to_string(body)) do
      {:ok, %{"error" => %{"message" => m}}} when is_binary(m) -> String.slice(m, 0, 300)
      {:ok, %{"error" => m}} when is_binary(m) -> String.slice(m, 0, 300)
      {:ok, %{"detail" => m}} when is_binary(m) -> String.slice(m, 0, 300)
      _ -> "no message"
    end
  end

  @doc false
  # A request to the Codex backend: `:base_url` and a test's `:respond`
  # from `opts`, the body left undecoded.
  @spec request(keyword(), keyword()) :: Req.Request.t()
  def request(opts, req_opts) do
    req =
      Req.new(
        [
          base_url: Keyword.get(opts, :base_url, @base_url),
          retry: false,
          decode_body: false,
          connect_options: [timeout: 15_000]
        ] ++ req_opts
      )

    case opts[:respond] do
      nil -> req
      respond -> Req.Request.append_request_steps(req, respond: &{&1, respond.(&1)})
    end
  end

  @doc false
  @spec headers(map(), String.t()) :: [{String.t(), String.t()}]
  def headers(auth, accept) do
    [
      {"authorization", "Bearer #{auth.token}"},
      {"originator", @originator},
      {"accept", accept}
    ] ++ if(auth[:account_id], do: [{"chatgpt-account-id", auth.account_id}], else: [])
  end

  # ── the kept lists ──

  defp dir(opts), do: Keyword.get_lazy(opts, :data_dir, &Rho.Config.data_dir/0)

  defp table?, do: :ets.whereis(@table) != :undefined

  defp get(key, default) do
    case table?() && :ets.lookup(@table, key) do
      [{^key, value}] -> value
      _ -> default
    end
  end

  # In memory, else read once from the dir's file (`:none` when it has no
  # list, so the file is read once per dir). Without the table, the file
  # each time.
  defp fetched(dir) do
    case get({:list, dir}, nil) do
      nil ->
        list = load(dir)
        if table?(), do: :ets.insert(@table, {{:list, dir}, list || :none})
        list

      :none ->
        nil

      list ->
        list
    end
  end

  defp load(dir) do
    with {:ok, json} <- File.read(Path.join(dir, @file_name)),
         {:ok, %{"fetched_at" => at, "models" => [_ | _] = models}} when is_integer(at) <-
           Jason.decode(json),
         [_ | _] = models <- for(%{"id" => id} = m <- models, is_binary(id), do: stored(m)) do
      %{models: models, fetched_at: at}
    else
      _ -> nil
    end
  end

  defp stored(m) do
    %{
      id: m["id"],
      name: if(is_binary(m["name"]), do: m["name"], else: m["id"]),
      context: if(is_integer(m["context"]), do: m["context"])
    }
  end

  defp save(dir, list) do
    path = Path.join(dir, @file_name)
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, Jason.encode!(list)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        Logger.warning("[codex models] not saved: #{inspect(reason)}")
    end
  end

  @doc false
  # Forgets every kept list in memory (tests).
  @spec reset() :: :ok
  def reset do
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end
end
