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
  `{:rho_auth, :changed}` on every `put/2`, `delete/1` and failed
  refresh or save.

  Reads (`get/1`, `status/0`, a key or a fresh token from `credential/1`)
  don't go through the process. Secrets are never logged. Options (tests):
  `:respond` answers the token endpoint instead of the network
  (`Rho.Auth.OAuthFlow`), `:save_retry_ms` (5 s).
  """
  use GenServer

  alias Rho.Auth.OAuthFlow
  alias Rho.CredentialStore

  require Logger

  @type provider :: :anthropic | :openai_codex | :openai | :google
  @type creds :: %{String.t() => term()}
  @type credential ::
          %{type: :oauth, token: String.t(), account_id: String.t() | nil}
          | %{type: :api_key, key: String.t()}

  @providers [:anthropic, :openai_codex, :openai, :google]
  @oauth_providers [:anthropic, :openai_codex]
  @api_key_providers [:anthropic, :openai, :google]
  @refresh_margin_ms 5 * 60_000
  # Longer than a refresh's own timeouts (30 s) plus a queued one.
  @refresh_call_ms 75_000
  @save_retry_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

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

  @spec put(provider(), creds()) :: :ok | {:error, term()}
  def put(provider, creds) when provider in @providers do
    if valid?(provider, creds),
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

  @spec signed_in?(provider()) :: boolean()
  def signed_in?(provider), do: match?({:ok, _}, get(provider))

  @doc """
  Per provider: whether it has a credential, which kind, and for a
  sign-in its email and expiry.
  """
  @spec status() :: %{
          provider() => %{
            signed_in: boolean(),
            type: :oauth | :api_key | nil,
            email: String.t() | nil,
            expires: integer() | nil
          }
        }
  def status do
    Map.new(@providers, fn provider ->
      case get(provider) do
        {:ok, creds} ->
          {provider,
           %{
             signed_in: true,
             type: kind(creds),
             email: creds["email"],
             expires: creds["expires"]
           }}

        :error ->
          {provider, %{signed_in: false, type: nil, email: nil, expires: nil}}
      end
    end)
  end

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
        if fresh?(creds), do: {:ok, token(creds)}, else: via_server(provider)

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

  defp via_server(provider) do
    GenServer.call(__MODULE__, {:credential, provider}, @refresh_call_ms)
  catch
    :exit, reason ->
      {:error, {:refresh_failed, "the sign-in service didn't answer (#{inspect(reason)})"}}
  end

  # ── GenServer ──

  @impl true
  def init(opts) do
    {:ok,
     %{
       subscribers: %{},
       refreshing: %{},
       # provider => %{creds, reason, timer}: refreshed, not yet saved
       unsaved: %{},
       respond: opts[:respond],
       save_retry_ms: Keyword.get(opts, :save_retry_ms, @save_retry_ms)
     }}
  end

  # A replacement that didn't save changes nothing: a refresh in flight
  # (or one waiting to be saved) stays the sign-in.
  @impl true
  def handle_call({:put, provider, creds}, _from, s) do
    case store(provider, creds) do
      :ok -> {:reply, :ok, s |> supersede(provider) |> broadcast()}
      {:error, _} = error -> {:reply, error, s}
    end
  end

  def handle_call({:delete, provider}, _from, s) do
    case CredentialStore.delete(account(provider)) do
      :ok ->
        {:reply, :ok, s |> supersede(provider) |> broadcast()}

      {:error, reason} = error ->
        Logger.error("[auth] deleting #{provider} failed: #{inspect(reason)}")
        {:reply, error, s}
    end
  end

  def handle_call({:subscribe, pid}, _from, s) do
    subscribers = Map.put_new_lazy(s.subscribers, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{s | subscribers: subscribers}}
  end

  def handle_call({:credential, provider}, from, s), do: {:noreply, serve(s, provider, [from])}

  @impl true
  def handle_info({:refreshed, provider, result}, s) do
    case s.refreshing[provider] do
      %{ref: ref} ->
        Process.demonitor(ref, [:flush])
        {:noreply, refresh_done(s, provider, result)}

      nil ->
        {:noreply, s}
    end
  end

  def handle_info({:save, provider}, s), do: {:noreply, save_unsaved(s, provider)}

  def handle_info({:DOWN, ref, :process, pid, reason}, s) do
    case Enum.find(s.refreshing, fn {_p, r} -> r.ref == ref end) do
      {provider, _r} ->
        {:noreply, refresh_done(s, provider, {:error, "crashed: #{inspect(reason)}"})}

      nil ->
        {:noreply, %{s | subscribers: Map.delete(s.subscribers, pid)}}
    end
  end

  def handle_info(_msg, s), do: {:noreply, s}

  # ── refresh ──

  # Answers `waiters`: a refreshed sign-in that isn't saved yet is saved
  # first (or they get the save error); otherwise from what's stored, a
  # fresh token at once, else they join (or start) the provider's refresh.
  defp serve(s, provider, waiters) do
    s = save_unsaved(s, provider)

    case {s.refreshing[provider], s.unsaved[provider], get(provider)} do
      {%{} = r, _, _} ->
        put_in(s.refreshing[provider], %{r | waiters: r.waiters ++ waiters})

      {nil, %{reason: reason}, _} ->
        reply_all(waiters, {:error, {:store_failed, reason}})
        s

      {nil, nil, :error} ->
        reply_all(waiters, {:error, :signed_out})
        s

      {nil, nil, {:ok, creds}} ->
        if fresh?(creds) do
          reply_all(waiters, {:ok, token(creds)})
          s
        else
          start_refresh(s, provider, creds, waiters)
        end
    end
  end

  defp start_refresh(s, provider, creds, waiters) do
    owner = self()
    opts = if s.respond, do: [respond: s.respond], else: []

    {_pid, ref} =
      spawn_monitor(fn ->
        send(owner, {:refreshed, provider, OAuthFlow.refresh(provider, creds, opts)})
      end)

    put_in(s.refreshing[provider], %{ref: ref, waiters: waiters, superseded: false})
  end

  defp refresh_done(s, provider, result) do
    {r, refreshing} = Map.pop(s.refreshing, provider)
    s = %{s | refreshing: refreshing}

    case {r.superseded, result} do
      # A newer sign-in (or a sign-out) was saved meanwhile: it wins.
      {true, _} ->
        serve(s, provider, r.waiters)

      {false, {:ok, creds}} ->
        refreshed(s, provider, creds, r.waiters)

      {false, {:error, message}} ->
        Logger.warning("[auth] #{provider} token refresh failed: #{message}")
        reply_all(r.waiters, {:error, {:refresh_failed, message}})
        broadcast(s)
    end
  end

  # The old refresh token is spent once the refresh succeeds: the new
  # credentials are only handed out once saved, and kept here (never
  # refreshed again from the stored, spent one) until they are.
  defp refreshed(s, provider, creds, waiters) do
    s =
      save_unsaved(
        put_in(s.unsaved[provider], %{creds: creds, reason: nil, timer: nil}),
        provider
      )

    case s.unsaved[provider] do
      nil ->
        Logger.info("[auth] #{provider} token refreshed")
        reply_all(waiters, {:ok, token(creds)})
        s

      %{reason: reason} ->
        reply_all(waiters, {:error, {:store_failed, reason}})
        broadcast(s)
    end
  end

  # Saves the provider's unsaved refreshed sign-in, if any; on failure it
  # stays and a retry is scheduled.
  defp save_unsaved(s, provider) do
    case s.unsaved[provider] do
      nil -> s
      unsaved -> save_unsaved(s, provider, unsaved)
    end
  end

  defp save_unsaved(s, provider, %{creds: creds, timer: timer} = u) do
    if timer, do: Process.cancel_timer(timer)

    case store(provider, creds) do
      :ok ->
        if u.reason, do: Logger.info("[auth] the refreshed #{provider} sign-in is saved now")
        %{s | unsaved: Map.delete(s.unsaved, provider)}

      {:error, reason} ->
        Logger.error("[auth] saving the refreshed #{provider} sign-in failed: #{inspect(reason)}")
        timer = Process.send_after(self(), {:save, provider}, s.save_retry_ms)
        put_in(s.unsaved[provider], %{u | reason: reason, timer: timer})
    end
  end

  # A put or delete was saved: a refresh in flight is stale, and so is a
  # refreshed sign-in waiting to be saved.
  defp supersede(s, provider) do
    s =
      case s.unsaved[provider] do
        %{timer: timer} ->
          if timer, do: Process.cancel_timer(timer)
          %{s | unsaved: Map.delete(s.unsaved, provider)}

        nil ->
          s
      end

    case s.refreshing[provider] do
      nil -> s
      r -> put_in(s.refreshing[provider], %{r | superseded: true})
    end
  end

  defp reply_all(waiters, reply), do: Enum.each(waiters, &GenServer.reply(&1, reply))

  defp broadcast(s) do
    Enum.each(Map.keys(s.subscribers), &send(&1, {:rho_auth, :changed}))
    s
  end

  # ── helpers ──

  defp store(provider, creds), do: CredentialStore.put(account(provider), Jason.encode!(creds))

  defp account(provider), do: "auth:#{provider}"

  defp decode(provider, json) do
    case Jason.decode(json) do
      {:ok, creds} -> if valid?(provider, creds), do: {:ok, creds}, else: :error
      {:error, _} -> :error
    end
  end

  defp valid?(provider, %{
         "type" => "oauth",
         "access" => access,
         "refresh" => refresh,
         "expires" => expires
       })
       when provider in @oauth_providers and is_binary(access) and is_binary(refresh) and
              refresh != "" and is_integer(expires),
       do: true

  defp valid?(provider, %{"type" => "api_key", "key" => key})
       when provider in @api_key_providers and is_binary(key) and key != "",
       do: true

  defp valid?(_provider, _creds), do: false

  defp kind(%{"type" => "api_key"}), do: :api_key
  defp kind(%{"type" => "oauth"}), do: :oauth

  # An API key never expires.
  defp fresh?(%{"type" => "api_key"}), do: true

  defp fresh?(%{"access" => access, "expires" => expires}),
    do: access != "" and expires - System.os_time(:millisecond) > @refresh_margin_ms

  defp token(%{"type" => "api_key", "key" => key}), do: %{type: :api_key, key: key}

  defp token(creds),
    do: %{type: :oauth, token: creds["access"], account_id: creds["accountId"]}
end
