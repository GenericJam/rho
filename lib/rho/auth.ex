defmodule Rho.Auth do
  @moduledoc """
  The model-provider credentials, one per provider, each pi's `auth.json`
  entry as JSON in the credential store (`Rho.CredentialStore`) under
  `"auth:<provider>"`:

    * a subscription sign-in (omp's `/login anthropic` and
      `/login openai-codex`, `Rho.Auth.Login`): `%{"type" => "oauth",
      "access", "refresh", "expires" (ms since the epoch), "accountId",
      "email"}`, for `:anthropic` (Claude Pro/Max) and `:openai_codex`
      (ChatGPT Plus/Pro)
    * an API key (`put_api_key/2`): `%{"type" => "api_key", "key"}`, for
      `:anthropic`, `:openai` and `:google` (Gemini)

  A provider holds one or the other: storing one replaces the other.

  `credential/1` hands out what a model call needs: the key, or the access
  token, refreshing it first when it is within 5 minutes of expiry (or
  empty: a login moved over from another device may carry only the
  refresh token). Refreshes run in this process, one per provider
  at a time: concurrent callers wait for the same refresh. A refresh spends
  the old refresh token, so its result is saved before anyone gets the new
  access token; if saving fails, the new credentials stay in this process
  (retried every few seconds and on every call, never refreshed again from
  the spent token) and callers get `{:error, {:store_failed, reason}}` until
  they are saved. A `put/2` or `delete/1` takes effect only once written;
  then it wins over a refresh in flight. Subscribers (`subscribe/0`) get
  `{:rho_auth, :changed}` on every `put/2`, `delete/1`, refresh (done or
  failed) and failed save.

  Reads (`get/1`, `status/0`, a key or a fresh token from `credential/1`)
  don't go through the process. Secrets are never logged. Options (tests):
  `:respond` answers the token endpoint instead of the network
  (`Rho.Auth.OAuthFlow`), `:save_retry_ms` (5 s).

  This is the node's one set of credentials. A host serving several
  accounts (a website whose users' sign-ins live on their phones) keeps
  each account's in a `Rho.Auth.Vault` instead and starts `Rho.Supervisor`
  with `auth: false`; without this process `credential/1` answers
  `{:error, :signed_out}` for anything the store doesn't hold.
  """
  @behaviour Rho.Auth.Keeper

  alias Rho.Auth.Keeper
  alias Rho.Auth.OAuthFlow
  alias Rho.CredentialStore

  require Logger

  @type provider :: :anthropic | :openai_codex | :openai | :google
  @type creds :: %{String.t() => term()}
  @type credential ::
          %{type: :oauth, token: String.t(), account_id: String.t() | nil}
          | %{type: :api_key, key: String.t()}
  @type status :: %{
          provider() => %{
            signed_in: boolean(),
            type: :oauth | :api_key | nil,
            email: String.t() | nil,
            expires: integer() | nil
          }
        }

  @providers [:anthropic, :openai_codex, :openai, :google]
  @oauth_providers [:anthropic, :openai_codex]
  @api_key_providers [:anthropic, :openai, :google]

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Started by `Rho.Supervisor` (its `:auth` option holds `opts`, see the moduledoc)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: Keeper.start_link(__MODULE__, Keyword.take(opts, [:respond]), opts, name: __MODULE__)

  @doc "Every provider rho can sign in to, in display order."
  @spec providers() :: [provider()]
  def providers, do: @providers

  @doc "How `provider` can be signed in to: `:oauth` (a subscription) and/or `:api_key`."
  @spec kinds(provider()) :: [:oauth | :api_key]
  def kinds(provider) do
    Enum.filter(
      [oauth: @oauth_providers, api_key: @api_key_providers],
      fn {_kind, providers} -> provider in providers end
    )
    |> Keyword.keys()
  end

  @doc "The provider's name for the user, e.g. `\"Claude (Anthropic)\"`."
  @spec label(provider()) :: String.t()
  def label(:anthropic), do: "Claude (Anthropic)"
  def label(:openai_codex), do: "ChatGPT (OpenAI Codex)"
  def label(:openai), do: "OpenAI"
  def label(:google), do: "Gemini (Google)"

  @doc """
  The provider whose credential a req_llm model spec needs:
  `"anthropic:…"`, `"openai_codex:…"`, `"openai:…"`, `"google:…"`.
  """
  @spec provider_for_model(String.t()) :: {:ok, provider()} | :error
  def provider_for_model("anthropic:" <> _), do: {:ok, :anthropic}
  def provider_for_model("openai_codex:" <> _), do: {:ok, :openai_codex}
  def provider_for_model("openai:" <> _), do: {:ok, :openai}
  def provider_for_model("google:" <> _), do: {:ok, :google}
  def provider_for_model(_spec), do: :error

  @doc """
  Stores `provider`'s credentials (the shapes in the moduledoc), replacing
  what it had. `{:error, :invalid_credentials}` when `creds` doesn't fit
  the provider, `{:error, :unknown_provider}` for a provider rho doesn't
  know, `{:error, reason}` when the store failed.
  """
  @spec put(provider(), creds()) :: :ok | {:error, term()}
  def put(provider, creds) when provider in @providers do
    if Keeper.valid?(provider, creds),
      do: GenServer.call(__MODULE__, {:put, provider, creds}),
      else: {:error, :invalid_credentials}
  end

  def put(_provider, _creds), do: {:error, :unknown_provider}

  @doc """
  Stores an API key for `provider` (`:anthropic`, `:openai` or `:google`),
  replacing its sign-in if it had one. Surrounding whitespace is dropped.
  """
  @spec put_api_key(provider(), String.t()) :: :ok | {:error, term()}
  def put_api_key(provider, key) when is_binary(key),
    do: put(provider, %{"type" => "api_key", "key" => String.trim(key)})

  @doc """
  `provider`'s stored credentials as they are (no refresh: use
  `credential/1` for a model call); `:error` when there are none or the
  store can't be read.
  """
  @spec get(provider()) :: {:ok, creds()} | :error
  def get(provider) when provider in @providers do
    case CredentialStore.get(account(provider)) do
      {:ok, json} when is_binary(json) ->
        decode(provider, json)

      :error ->
        :error

      # Signing in says why (a phone store without its native code fails closed).
      {:error, :secure_store_unavailable} ->
        :error

      {:error, reason} ->
        Logger.error("[auth] reading #{provider} failed: #{inspect(reason)}")
        :error
    end
  end

  @doc "Signs out of `provider`; an error means the sign-in is still stored."
  @spec delete(provider()) :: :ok | {:error, term()}
  def delete(provider) when provider in @providers,
    do: GenServer.call(__MODULE__, {:delete, provider})

  @doc "Does `provider` have stored credentials (`get/1`)?"
  @spec signed_in?(provider()) :: boolean()
  def signed_in?(provider), do: match?({:ok, _}, get(provider))

  @doc """
  Per provider: whether it has a credential, which kind, and for a
  sign-in its email and expiry.
  """
  @spec status() :: status()
  def status, do: Keeper.status(&get/1)

  @doc """
  What a model call needs: `%{type: :api_key, key}`, or for a sign-in a
  usable access token (and the ChatGPT account id for OpenAI Codex),
  refreshed first when it's within 5 minutes of expiry.
  `{:error, :signed_out}` when there is no credential;
  `{:error, {:refresh_failed, message}}` when the
  refresh didn't work (a dead grant needs signing in again);
  `{:error, {:store_failed, reason}}` while a refreshed sign-in couldn't be
  saved yet (it is retried; the old refresh token is spent, so it is never
  used again).
  """
  @spec credential(provider()) ::
          {:ok, credential()}
          | {:error, :signed_out | {:refresh_failed, String.t()} | {:store_failed, term()}}
  def credential(provider) when provider in @providers do
    case get(provider) do
      {:ok, creds} ->
        if Keeper.fresh?(creds), do: {:ok, Keeper.token(creds)}, else: via_server(provider)

      # A refreshed sign-in waiting to be saved lives only in the server.
      :error ->
        via_server(provider)
    end
  end

  @doc "What a store error means for the user."
  @spec describe_error(term()) :: String.t()
  def describe_error(:secure_store_unavailable),
    do: "the device's secure store isn't available in this build"

  def describe_error(reason), do: inspect(reason)

  @doc "Sends the caller `{:rho_auth, :changed}` after every change, until it exits."
  @spec subscribe() :: :ok
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  # Not started (`Rho.Supervisor`'s `auth: false`): nobody here is signed in.
  defp via_server(provider) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:credential, provider}, Keeper.refresh_call_ms()),
      else: {:error, :signed_out}
  catch
    :exit, reason ->
      {:error, {:refresh_failed, "the sign-in service didn't answer (#{inspect(reason)})"}}
  end

  # ── Rho.Auth.Keeper: the credential store ──

  @impl Keeper
  def read(_opts, provider), do: get(provider)

  @impl Keeper
  def write(opts, provider, creds, _origin) do
    case CredentialStore.put(account(provider), Jason.encode!(creds)) do
      :ok -> {:ok, opts}
      {:error, _} = error -> error
    end
  end

  @impl Keeper
  def remove(opts, provider) do
    case CredentialStore.delete(account(provider)) do
      :ok -> {:ok, opts}
      {:error, _} = error -> error
    end
  end

  @impl Keeper
  def refresh(opts, provider, creds) do
    fn ->
      case OAuthFlow.refresh(provider, creds, opts) do
        {:ok, creds} -> {:ok, creds, :refresh}
        {:error, _} = error -> error
      end
    end
  end

  @impl Keeper
  def changed(_opts), do: {:rho_auth, :changed}

  # ── helpers ──

  defp account(provider), do: "auth:#{provider}"

  defp decode(provider, json) do
    case Jason.decode(json) do
      {:ok, creds} -> if Keeper.valid?(provider, creds), do: {:ok, creds}, else: :error
      {:error, _} -> :error
    end
  end
end
