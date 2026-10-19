defmodule Rho.Auth.Keeper do
  @moduledoc false
  # The process both credential holders run: `Rho.Auth` (the node's
  # sign-ins, in `Rho.CredentialStore`) and `Rho.Auth.Vault` (one account's,
  # in memory). It owns the rules a rotating refresh token needs:
  #
  #   * one refresh per provider at a time; concurrent callers wait for it
  #   * a refreshed sign-in is written (the backend's `write/4`) before any
  #     waiter gets its access token; if writing fails it stays here, retried
  #     every `save_retry_ms` and on every call, never refreshed again from
  #     the spent token, and callers get `{:error, {:store_failed, reason}}`
  #   * a `put` or `delete` takes effect once written, and then wins over a
  #     refresh in flight (the refresh's result is dropped)
  #   * subscribers hear of every put, delete, refresh (done or failed) and
  #     failed save
  #
  # The backend says where credentials live and how one is refreshed.

  use GenServer

  alias Rho.Auth

  require Logger

  @type bstate :: term()
  # :put (put/delete from the host), :refresh (rho refreshed it: the old
  # refresh token is spent), :delegated (someone else refreshed it and
  # already holds the result)
  @type origin :: :put | :refresh | :delegated

  @callback read(bstate(), Auth.provider()) :: {:ok, Auth.creds()} | :error
  @callback write(bstate(), Auth.provider(), Auth.creds(), origin()) ::
              {:ok, bstate()} | {:error, term()}
  @callback remove(bstate(), Auth.provider()) :: {:ok, bstate()} | {:error, term()}
  # Runs in a process of its own; must not call the keeper.
  @callback refresh(bstate(), Auth.provider(), Auth.creds()) ::
              (-> {:ok, Auth.creds(), origin()} | {:error, String.t()})
  @callback changed(bstate()) :: term()

  @refresh_margin_ms 5 * 60_000
  # Longer than a refresh's own timeouts (10 s to connect, 30 s to answer)
  # plus a queued one.
  @refresh_call_ms 90_000
  @save_retry_ms 5_000

  @spec start_link(module(), bstate(), keyword(), keyword()) :: GenServer.on_start()
  def start_link(backend, bstate, opts, gen_opts),
    do: GenServer.start_link(__MODULE__, {backend, bstate, opts}, gen_opts)

  @spec refresh_call_ms() :: pos_integer()
  def refresh_call_ms, do: @refresh_call_ms

  # ── shared helpers ──

  @spec valid?(Auth.provider(), term()) :: boolean()
  def valid?(provider, %{
        "type" => "oauth",
        "access" => access,
        "refresh" => refresh,
        "expires" => expires
      })
      when is_binary(access) and is_binary(refresh) and refresh != "" and is_integer(expires),
      do: :oauth in Auth.kinds(provider)

  def valid?(provider, %{"type" => "api_key", "key" => key}) when is_binary(key) and key != "",
    do: :api_key in Auth.kinds(provider)

  def valid?(_provider, _creds), do: false

  # An API key never expires.
  @spec fresh?(Auth.creds()) :: boolean()
  def fresh?(%{"type" => "api_key"}), do: true

  def fresh?(%{"access" => access, "expires" => expires}),
    do: access != "" and expires - System.os_time(:millisecond) > @refresh_margin_ms

  @spec token(Auth.creds()) :: Auth.credential()
  def token(%{"type" => "api_key", "key" => key}), do: %{type: :api_key, key: key}

  def token(creds),
    do: %{type: :oauth, token: creds["access"], account_id: creds["accountId"]}

  @doc false
  # `Rho.Auth.status/0`'s map over `read`, `fn provider -> {:ok, creds} | :error end`.
  @spec status((Auth.provider() -> {:ok, Auth.creds()} | :error)) :: map()
  def status(read) do
    Map.new(Auth.providers(), fn provider ->
      case read.(provider) do
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

  defp kind(%{"type" => "api_key"}), do: :api_key
  defp kind(%{"type" => "oauth"}), do: :oauth

  # ── GenServer ──

  @impl true
  def init({backend, bstate, opts}) do
    {:ok,
     %{
       backend: backend,
       b: bstate,
       subscribers: %{},
       refreshing: %{},
       # provider => %{creds, origin, reason, timer}: refreshed, not yet written
       unsaved: %{},
       save_retry_ms: Keyword.get(opts, :save_retry_ms, @save_retry_ms)
     }}
  end

  # A replacement that didn't write changes nothing: a refresh in flight
  # (or one waiting to be written) stays the sign-in.
  @impl true
  def handle_call({:put, provider, creds}, _from, s) do
    case s.backend.write(s.b, provider, creds, :put) do
      {:ok, b} -> {:reply, :ok, %{s | b: b} |> supersede(provider) |> broadcast()}
      {:error, _} = error -> {:reply, error, s}
    end
  end

  def handle_call({:delete, provider}, _from, s) do
    case s.backend.remove(s.b, provider) do
      {:ok, b} ->
        {:reply, :ok, %{s | b: b} |> supersede(provider) |> broadcast()}

      {:error, reason} = error ->
        Logger.error("[auth] deleting #{provider} failed: #{inspect(reason)}")
        {:reply, error, s}
    end
  end

  def handle_call({:get, provider}, _from, s), do: {:reply, read(s, provider), s}

  def handle_call(:status, _from, s), do: {:reply, status(&read(s, &1)), s}

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

  def handle_info({:DOWN, ref, :process, pid, _reason}, s) do
    case Enum.find(s.refreshing, fn {_p, r} -> r.ref == ref end) do
      # The reason may hold the credentials: it isn't passed on.
      {provider, _r} ->
        {:noreply, refresh_done(s, provider, {:error, "the refresh stopped unexpectedly"})}

      nil ->
        {:noreply, %{s | subscribers: Map.delete(s.subscribers, pid)}}
    end
  end

  def handle_info(_msg, s), do: {:noreply, s}

  # Crash reports and :sys.get_status/1 never show a credential.
  @impl true
  def format_status(status) do
    status
    |> Map.update(:state, nil, fn
      %{b: _} = s -> %{s | b: :redacted, unsaved: Map.keys(s.unsaved)}
      other -> other
    end)
    |> Map.update(:message, nil, fn
      {:refreshed, provider, _result} -> {:refreshed, provider, :redacted}
      {:put, provider, _creds} -> {:put, provider, :redacted}
      other -> other
    end)
  end

  # ── refresh ──

  defp read(s, provider), do: s.backend.read(s.b, provider)

  # Answers `waiters`: a refreshed sign-in that isn't written yet is written
  # first (or they get the write error); otherwise from what's held, a
  # fresh token at once, else they join (or start) the provider's refresh.
  defp serve(s, provider, waiters) do
    s = save_unsaved(s, provider)

    case {s.refreshing[provider], s.unsaved[provider], read(s, provider)} do
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

  # The refresh runs in a worker of its own (the keeper keeps answering),
  # under a runner that ends it when the keeper goes (a stopped vault never
  # spends a refresh token afterwards) or the refresh is superseded.
  defp start_refresh(s, provider, creds, waiters) do
    owner = self()
    run = s.backend.refresh(s.b, provider, creds)

    {pid, ref} = spawn_monitor(fn -> run_refresh(owner, provider, run) end)

    put_in(s.refreshing[provider], %{pid: pid, ref: ref, waiters: waiters, superseded: false})
  end

  defp run_refresh(owner, provider, run) do
    owner_ref = Process.monitor(owner)
    Process.flag(:trap_exit, true)
    me = self()
    worker = spawn_link(fn -> send(me, {:result, run.()}) end)

    receive do
      {:result, result} ->
        send(owner, {:refreshed, provider, result})

      {:EXIT, ^worker, _reason} ->
        send(owner, {:refreshed, provider, {:error, "the refresh stopped unexpectedly"}})

      {:DOWN, ^owner_ref, :process, _, _} ->
        Process.exit(worker, :kill)

      :stop ->
        Process.exit(worker, :kill)
    end
  end

  defp refresh_done(s, provider, result) do
    {r, refreshing} = Map.pop(s.refreshing, provider)
    s = %{s | refreshing: refreshing}

    case {r.superseded, result} do
      # A newer sign-in (or a sign-out) was written meanwhile: it wins.
      {true, _} ->
        serve(s, provider, r.waiters)

      {false, {:ok, creds, origin}} ->
        refreshed(s, provider, creds, origin, r.waiters)

      {false, {:error, message}} ->
        Logger.warning("[auth] #{provider} token refresh failed: #{message}")
        reply_all(r.waiters, {:error, {:refresh_failed, message}})
        broadcast(s)
    end
  end

  # The old refresh token is spent once the refresh succeeds: the new
  # credentials are only handed out once written, and kept here (never
  # refreshed again from the held, spent one) until they are.
  defp refreshed(s, provider, creds, origin, waiters) do
    s =
      save_unsaved(
        put_in(s.unsaved[provider], %{creds: creds, origin: origin, reason: nil, timer: nil}),
        provider
      )

    case s.unsaved[provider] do
      nil ->
        Logger.info("[auth] #{provider} token refreshed")
        reply_all(waiters, {:ok, token(creds)})
        broadcast(s)

      %{reason: reason} ->
        reply_all(waiters, {:error, {:store_failed, reason}})
        broadcast(s)
    end
  end

  # Writes the provider's unwritten refreshed sign-in, if any; on failure
  # it stays and a retry is scheduled.
  defp save_unsaved(s, provider) do
    case s.unsaved[provider] do
      nil -> s
      unsaved -> save_unsaved(s, provider, unsaved)
    end
  end

  defp save_unsaved(s, provider, %{creds: creds, origin: origin, timer: timer} = u) do
    if timer, do: Process.cancel_timer(timer)

    case s.backend.write(s.b, provider, creds, origin) do
      {:ok, b} ->
        if u.reason, do: Logger.info("[auth] the refreshed #{provider} sign-in is saved now")
        %{s | b: b, unsaved: Map.delete(s.unsaved, provider)}

      {:error, reason} ->
        Logger.error("[auth] saving the refreshed #{provider} sign-in failed: #{inspect(reason)}")
        timer = Process.send_after(self(), {:save, provider}, s.save_retry_ms)
        put_in(s.unsaved[provider], %{u | reason: reason, timer: timer})
    end
  end

  # A put or delete was written: a refresh in flight is stale (its result
  # would be dropped, so it is stopped: one not sent yet then never spends
  # the refresh token), and so is a refreshed sign-in waiting to be written.
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
      nil ->
        s

      r ->
        send(r.pid, :stop)
        put_in(s.refreshing[provider], %{r | superseded: true})
    end
  end

  defp reply_all(waiters, reply), do: Enum.each(waiters, &GenServer.reply(&1, reply))

  defp broadcast(s) do
    message = s.backend.changed(s.b)
    Enum.each(Map.keys(s.subscribers), &send(&1, message))
    s
  end
end
