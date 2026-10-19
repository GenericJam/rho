defmodule Rho.Auth.Vault do
  @moduledoc """
  One account's model-provider credentials, in this process's memory only:
  never written to disk, a store or a log. For a host that serves several
  accounts whose credentials live elsewhere (a website whose users keep
  their sign-ins on their phones): one vault per account, shared by all of
  that account's sessions, passed to each loop as functions:

      llm: {Rho.LLM.ReqLLM,
            credential: &Rho.Auth.Vault.credential(vault, &1),
            status: fn -> Rho.Auth.Vault.status(vault) end}

  The API mirrors `Rho.Auth`'s, with the vault first: the credentials are
  pi's `auth.json` entries (see `Rho.Auth`), `credential/2` answers exactly
  as `Rho.Auth.credential/1` does, and it keeps `Rho.Auth`'s rules for a
  rotating refresh token: one refresh per provider at a time (concurrent
  callers wait for it), a `put/3` or `delete/2` wins over a refresh in
  flight, and a refreshed sign-in is handed out only once it is kept.

  Kept means: when rho refreshed it (the old refresh token is spent),
  `:on_refresh` returned `:ok`. That is where the host sends the new
  credentials back to where the account keeps them. Until it does, the
  refreshed credentials wait here (retried every `:save_retry_ms` and on
  every call, never refreshed again from the spent token) and callers get
  `{:error, {:store_failed, reason}}`.

  Options:

    * `:on_refresh`: `fn provider, creds -> :ok | {:error, reason} end`,
      called in the vault's process after rho refreshed a sign-in (not
      after a `put/3`, nor a refresh `:refresher` did); it must not call
      the vault. Default: nothing to tell.
    * `:refresher`: `fn provider -> {:ok, creds} | :local end`, asked first
      whenever a sign-in needs refreshing, in a process of its own: someone
      else (the phone holding the account) refreshes it and answers with
      the new credentials, which the vault keeps without calling
      `:on_refresh`; `:local` (or a crash, invalid credentials, or no answer
      within `:refresher_timeout`, 20 s) and the vault refreshes itself. If
      the refreshed credentials arrive by `put/3` meanwhile, they win and
      the answer is dropped. Credentials that are valid but not fresh
      enough are refreshed here from their refresh token.
    * `:name`, `:save_retry_ms` (5 s), `:respond` (tests: answers the token
      endpoint, `Rho.Auth.OAuthFlow`).

  Subscribers (`subscribe/1`) get `{:rho_auth_vault, vault, :changed}` on
  every put, delete, refresh (done or failed) and failed `:on_refresh`.
  A vault that has stopped holds nothing: `get/2` is `:error`, `status/1`
  all signed out, `credential/2` `{:error, :signed_out}`.
  """
  @behaviour Rho.Auth.Keeper

  alias Rho.Auth
  alias Rho.Auth.Keeper
  alias Rho.Auth.OAuthFlow

  @refresher_timeout 20_000

  @doc false
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @doc "Starts an empty vault (options in the moduledoc)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    b = %{
      creds: %{},
      on_refresh: Keyword.get(opts, :on_refresh, fn _provider, _creds -> :ok end),
      refresher: opts[:refresher],
      refresher_timeout: Keyword.get(opts, :refresher_timeout, @refresher_timeout),
      oauth: Keyword.take(opts, [:respond])
    }

    Keeper.start_link(__MODULE__, b, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Holds `creds` for `provider`, replacing what it had. `{:error,
  :invalid_credentials}` when they don't fit the provider,
  `{:error, :unknown_provider}` for one rho doesn't know.
  """
  @spec put(GenServer.server(), Auth.provider(), Auth.creds()) :: :ok | {:error, term()}
  def put(vault, provider, creds) do
    cond do
      provider not in Auth.providers() -> {:error, :unknown_provider}
      not Keeper.valid?(provider, creds) -> {:error, :invalid_credentials}
      true -> GenServer.call(vault, {:put, provider, creds})
    end
  end

  @doc "Holds an API key for `provider` (surrounding whitespace dropped), as `put/3`."
  @spec put_api_key(GenServer.server(), Auth.provider(), String.t()) :: :ok | {:error, term()}
  def put_api_key(vault, provider, key) when is_binary(key),
    do: put(vault, provider, %{"type" => "api_key", "key" => String.trim(key)})

  @doc "Forgets `provider`'s credentials."
  @spec delete(GenServer.server(), Auth.provider()) :: :ok
  def delete(vault, provider), do: GenServer.call(vault, {:delete, provider})

  @doc "`provider`'s credentials as held (no refresh), or `:error`."
  @spec get(GenServer.server(), Auth.provider()) :: {:ok, Auth.creds()} | :error
  def get(vault, provider) do
    GenServer.call(vault, {:get, provider})
  catch
    :exit, _ -> :error
  end

  @doc "Does the vault hold credentials for `provider`?"
  @spec signed_in?(GenServer.server(), Auth.provider()) :: boolean()
  def signed_in?(vault, provider), do: match?({:ok, _}, get(vault, provider))

  @doc "As `Rho.Auth.status/0`, for the vault's credentials."
  @spec status(GenServer.server()) :: Auth.status()
  def status(vault) do
    GenServer.call(vault, :status)
  catch
    :exit, _ -> Keeper.status(fn _provider -> :error end)
  end

  @doc "As `Rho.Auth.credential/1`, from the vault (refreshing as the moduledoc says)."
  @spec credential(GenServer.server(), Auth.provider()) ::
          {:ok, Auth.credential()}
          | {:error, :signed_out | {:refresh_failed, String.t()} | {:store_failed, term()}}
  def credential(vault, provider) do
    if provider in Auth.providers(),
      do: GenServer.call(vault, {:credential, provider}, Keeper.refresh_call_ms()),
      else: {:error, :signed_out}
  catch
    :exit, {:noproc, _} -> {:error, :signed_out}
    :exit, {:normal, _} -> {:error, :signed_out}
    :exit, {:shutdown, _} -> {:error, :signed_out}
    :exit, reason -> {:error, {:refresh_failed, "the vault didn't answer (#{inspect(reason)})"}}
  end

  @doc "Sends the caller `{:rho_auth_vault, vault_pid, :changed}` after every change, until it exits."
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(vault), do: GenServer.call(vault, {:subscribe, self()})

  # ── Rho.Auth.Keeper: memory ──

  @impl Keeper
  def read(b, provider), do: Map.fetch(b.creds, provider)

  @impl Keeper
  def write(b, provider, creds, :refresh) do
    case b.on_refresh.(provider, creds) do
      :ok -> {:ok, put_in(b.creds[provider], creds)}
      {:error, _} = error -> error
    end
  end

  def write(b, provider, creds, _origin), do: {:ok, put_in(b.creds[provider], creds)}

  @impl Keeper
  def remove(b, provider), do: {:ok, %{b | creds: Map.delete(b.creds, provider)}}

  @impl Keeper
  def refresh(b, provider, creds),
    do: fn -> refreshed(b, provider, creds, delegate(b, provider)) end

  defp refreshed(b, provider, creds, :local), do: locally(b, provider, creds)

  defp refreshed(b, provider, creds, {:ok, new}) do
    cond do
      not Keeper.valid?(provider, new) -> locally(b, provider, creds)
      Keeper.fresh?(new) -> {:ok, new, :delegated}
      true -> locally(b, provider, new)
    end
  end

  @impl Keeper
  def changed(_b), do: {:rho_auth_vault, self(), :changed}

  defp locally(b, provider, creds) do
    case OAuthFlow.refresh(provider, creds, b.oauth) do
      {:ok, creds} -> {:ok, creds, :refresh}
      {:error, _} = error -> error
    end
  end

  # The refresher's answer within its timeout; anything else is `:local`.
  # It runs linked to this refresh (which the vault stops when a put
  # supersedes it), so it never outlives it.
  defp delegate(%{refresher: nil}, _provider), do: :local

  defp delegate(b, provider) do
    me = self()
    tag = make_ref()
    Process.flag(:trap_exit, true)
    pid = spawn_link(fn -> send(me, {tag, b.refresher.(provider)}) end)

    receive do
      {^tag, answer} ->
        if match?({:ok, %{}}, answer), do: answer, else: :local

      {:EXIT, ^pid, _reason} ->
        :local
    after
      b.refresher_timeout ->
        Process.exit(pid, :kill)
        :local
    end
  end
end
