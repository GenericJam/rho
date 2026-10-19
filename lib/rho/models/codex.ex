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

  A fetched list is kept in memory and in the data dir
  (`codex_models.json`), so a restart offline still has it, and fetched
  again in the background (`refresh_async/1`) once it is 6 hours old, or
  5 minutes after a failed try: `Rho.Models.catalog/1` asks with the node's
  sign-in (`Rho.Auth`), a loop starting a run on a ChatGPT model with its
  own. `config :rho, :codex_models_refresh, false` turns the background
  fetch off (tests). Before the first fetch the list is the one shipped in
  `priv/models/openai_codex.json` (Codex's on the date in the file), which
  only names models: whether one is accepted is known from a fetched list
  (`replacement/1`) or from the backend refusing it (`refused/2`).
  """

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

  # Read at compile time and embedded: Application.app_dir/2 can't resolve
  # priv/ on a phone.
  @shipped_file Path.expand("../../../priv/models/openai_codex.json", __DIR__)
  @external_resource @shipped_file
  @shipped for m <- Jason.decode!(File.read!(@shipped_file))["models"],
               do: %{id: m["id"], name: m["name"], context: m["context"]}

  @list_key {__MODULE__, :list}
  @tried_key {__MODULE__, :tried_at}

  @type model :: %{id: String.t(), name: String.t(), context: pos_integer() | nil}

  @doc """
  The sign-in's models, in Codex's order: the fetched list (memory, else
  the data dir's file), else the shipped one.
  """
  @spec models() :: [model()]
  def models do
    case fetched() do
      %{models: [_ | _] = models} -> models
      _ -> @shipped
    end
  end

  @doc "The sign-in's default model id: the first `models/0` lists."
  @spec default() :: String.t()
  def default, do: hd(models()).id

  @doc """
  The spec a saved ChatGPT model `spec` should run as instead: the
  sign-in's default (`"openai_codex:<id>"`) when a fetched list doesn't
  have it; nil when it does, when nothing has been fetched yet, or for
  another provider's spec.
  """
  @spec replacement(String.t()) :: String.t() | nil
  def replacement("openai_codex:" <> id) do
    case fetched() do
      %{models: [%{id: default} | _] = models} ->
        if Enum.any?(models, &(&1.id == id)), do: nil, else: "openai_codex:" <> default

      _ ->
        nil
    end
  end

  def replacement(_spec), do: nil

  @doc """
  The one-line notice for a conversation moved from `from` to `to` (specs)
  because the sign-in no longer accepts `from`.
  """
  @spec replaced_notice(String.t(), String.t()) :: String.t()
  def replaced_notice(from, to),
    do: "#{name(from)} isn't offered on the ChatGPT sign-in any more; using #{name(to)} instead."

  defp name("openai_codex:" <> id) do
    case Enum.find(models() ++ @shipped, &(&1.id == id)) do
      %{name: name} -> name
      nil -> id
    end
  end

  @doc "Whether a backend error message says the account refused the model."
  @spec refused?(String.t()) :: boolean()
  def refused?(message) when is_binary(message),
    do: String.contains?(message, "not supported when using Codex with a ChatGPT account")

  @doc """
  The backend refused `spec`: the list in memory (fetched or shipped) no
  longer has it and counts as stale, so `replacement/1` moves the next run
  off it too and a fresh list is asked for in the background
  (`refresh_async/1`'s `opts`; the next fetch decides). Returns the spec to
  use instead, the sign-in's default; nil when no other model is listed.
  """
  @spec refused(String.t(), keyword()) :: String.t() | nil
  def refused("openai_codex:" <> id, opts \\ []) do
    kept = Enum.reject(models(), &(&1.id == id))
    :persistent_term.put(@list_key, %{models: kept, fetched_at: 0})
    :persistent_term.erase(@tried_key)
    refresh_async(opts)

    case kept do
      [%{id: default} | _] -> "openai_codex:" <> default
      [] -> nil
    end
  end

  @doc """
  Fetches the list again in the background when it is stale (none yet, or
  6 hours old) and no try was made in the last 5 minutes. `opts`:
  `fetch/1`'s. Does nothing with `config :rho, :codex_models_refresh, false`.
  """
  @spec refresh_async(keyword()) :: :ok
  def refresh_async(opts \\ []) do
    now = System.monotonic_time(:millisecond)

    if Application.get_env(:rho, :codex_models_refresh, true) and stale?(now) do
      :persistent_term.put(@tried_key, now)

      Task.start(fn ->
        try do
          refresh(opts)
        catch
          kind, reason ->
            Logger.warning("[codex models] #{Exception.format_banner(kind, reason)}")
        end
      end)
    end

    :ok
  end

  defp stale?(now) do
    tried = :persistent_term.get(@tried_key, nil)
    (tried == nil or now - tried >= @retry_ms) and old?(fetched())
  end

  defp old?(%{fetched_at: at}), do: System.os_time(:millisecond) - at >= @ttl_ms
  defp old?(nil), do: true

  @doc """
  Fetches the list (`fetch/1`) and keeps it, in memory and in the data dir
  (`:data_dir`, default `Rho.Config.data_dir/0`). An empty list isn't kept.
  """
  @spec refresh(keyword()) :: {:ok, [model()]} | {:error, Rho.LLM.error()}
  def refresh(opts \\ []) do
    case fetch(opts) do
      {:ok, [_ | _] = models} ->
        list = %{models: models, fetched_at: System.os_time(:millisecond)}
        :persistent_term.put(@list_key, list)
        save(list, opts)
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

  # ── the kept list ──

  # In memory, else read once from the data dir's file (`:none` when it has
  # no list, so the file is read once per node).
  defp fetched do
    case :persistent_term.get(@list_key, nil) do
      nil ->
        list = load()
        :persistent_term.put(@list_key, list || :none)
        list

      :none ->
        nil

      list ->
        list
    end
  end

  defp path(opts \\ []),
    do: Path.join(Keyword.get_lazy(opts, :data_dir, &Rho.Config.data_dir/0), @file_name)

  defp load do
    with {:ok, json} <- File.read(path()),
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

  defp save(list, opts) do
    path = path(opts)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Jason.encode!(list)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> Logger.warning("[codex models] not saved: #{inspect(reason)}")
    end
  end

  @doc false
  # Forgets the kept list in memory (tests).
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@list_key)
    :persistent_term.erase(@tried_key)
    :ok
  end
end
