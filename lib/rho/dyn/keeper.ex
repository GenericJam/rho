defmodule Rho.Dyn.Keeper do
  @moduledoc """
  The Core process that decides which Dyn generation runs (the pipeline's
  steps 6–7, and safe mode, see `Rho.Dyn`), like sloppy_joe's CanvasKeeper. It owns
  the registry table (`Rho.Dyn.Registry`) and is the only writer
  of the `current` pointer.

  **Activation** (`activate/3`, approval required) loads the generation,
  flips the pointer, then swaps the registry: a crash between the two
  leaves the old pointer, or the new pointer and a registry the next start
  rebuilds from it. The new generation is on **probation** until it has
  run 60 s without a Dyn crash (`quiet`) and a later app start reached
  stable (`restarted`); then it is proven. An approval token is accepted
  once (see `Rho.Dyn.Approval`).

  **Crashes.** Dyn processes are watched (`watch/3`: tool calls through
  `Rho.ToolRunner` and `Rho.Dyn.Source`, screens through the wrapper the
  compiler adds to their entry function, `Rho.Dyn.Screens`). An abnormal
  exit (crash, kill, timeout) is written to the
  log and sent to subscribers as `{:rho_dyn, %{type: :crash, ...}}`, its
  `reason` a string that describes the exit without running any of it
  (`Rho.Untrusted.exit_text/2`).
  3 crashes of the current generation within 60 s while it is on probation
  revert it to its parent (`%{type: :reverted, crashes: [...]}`, the crash
  reports the agent fixes from): the parent is loaded first (generation 0,
  no Dyn at all, if the parent can't be), then the pointer flips. If the
  pointer can't be written, `:revert_failed` is reported and the crashes
  stay counted, so the next one tries again. A proven generation's crashes
  are only reported.

  **Launches** (`boot/2`, once per app start). `boot.json` counts the
  launches since the last one that reached stable (`mark_stable/1`). In the
  app a launch is stable once its first frame was drawn (the host's
  `c:Rho.Dyn.Screens.after_first_render/1`) and then either
  `:stable_delay_ms` passed or the app went to the background (the user
  left it, `c:Rho.Dyn.Screens.left_app?/1`: a quick close is not a failed
  launch; a crash before the first frame or within the delay is). If the
  previous launch never got there and
  the current generation is still unproven, it is reverted before anything
  loads (boot probation). Two such launches in a row: **safe mode**, the
  Core boots without any Dyn module and `Rho.Dyn.safe_mode?/0`
  says so; activations and reverts then only move the pointer, for the
  next launch. A generation that can't be loaded (say its rebuild for a new
  app version fails its selftests) is reported as `:load_failed`, the
  launch runs without it, and it goes back on probation. The pointer only
  ever names a generation that was active once (`:probation`, `:proven`,
  or `:candidate` / `:reverted` caught between the pointer and manifest
  writes); anything else falls back to generation 0.

  **Rebuilds** for a new Core (its binaries were built by another runtime,
  `Rho.Dyn.Compiler.stale?/1`) don't hold up the launch: the
  terminal never waits for Dyn code. `boot/2` returns at once with the
  generation current but nothing of it in the registry (no Dyn tools,
  screens or theme; `Rho.Dyn.Registry.rebuilding/1` says so), a
  linked worker rebuilds and selftests it, and the Keeper then stores and
  registers it and sends `%{type: :loaded}` (or reports `:load_failed`).
  Proposals wait for it (`{:error, :rebuilding}`, `await_rebuild/1`), and
  so does the launch's **stable** mark: a rebuild that takes the app down
  counts as a failed launch, exactly as when it ran before the first frame,
  so boot probation and safe mode still catch it.

  **Core updates** (the host's own release path, say mob_deliver) share that launch: the
  `:on_stable` MFA runs when a launch reaches stable (it ends a delivered
  update's probation). `boot/2` records the update a launch runs (`core:`,
  in `boot.json`); when mob_deliver has rolled back exactly that update
  (`core_rolled_back:`), the failed launch doesn't count against the Dyn
  generation: no boot revert and no step towards safe mode for it.

  **Old generations** stay loaded while anything may run them: the current
  one, its parent (instant revert), the pending candidate, and any
  generation with a live watched process; the rest are unloaded with
  `Rho.Dyn.Compiler.unload/1`, retried every `:gc_retry_ms`.

  **Proposals** per launch are capped (`:max_proposals`, and none while
  the atom table is over 80 % full): every proposal creates atoms (module
  names `Dyn.G<n>.*`, parsed identifiers) and atoms are never
  freed.

  Options (defaults from `config :rho, :dyn`, `Rho.Dyn.Config`): `:name`
  (also the registry table's name), `:dir`, `:approval`
  (`Rho.Dyn.Approval.Biometric`), `:probation_ms` (60 000),
  `:crash_limit` (3), `:crash_window_ms` (60 000), `:stable_delay_ms`
  (10 000), `:gc_retry_ms` (30 000), `:max_proposals` (50), `:on_stable`
  (`{module, function, args}` run in its own process when a launch
  reaches stable, or `nil`), and the compile / selftest limits
  (`:compile_timeout_ms`, `:compile_max_heap_mb`, `:selftest_timeout_ms`,
  `:selftest_max_heap_mb`); a background rebuild's compile, and loading a
  generation that isn't loaded (a revert to an older one), get
  `:rebuild_timeout_ms` (300 000: it compiles the whole generation, which
  can take minutes on a slow phone).
  """
  use GenServer

  alias Rho.Dyn.Approval
  alias Rho.Dyn.Compiler
  alias Rho.Dyn.Config
  alias Rho.Dyn.Generation
  alias Rho.Dyn.Store
  alias Rho.Untrusted

  require Logger

  @defaults [
    approval: Rho.Dyn.Approval.Biometric,
    probation_ms: 60_000,
    crash_limit: 3,
    crash_window_ms: 60_000,
    stable_delay_ms: 10_000,
    gc_retry_ms: 30_000,
    max_proposals: 50,
    rebuild_timeout_ms: 300_000,
    on_stable: nil
  ]
  @build_opts [
    :compile_timeout_ms,
    :compile_max_heap_mb,
    :selftest_timeout_ms,
    :selftest_max_heap_mb
  ]

  @type boot_report :: %{
          mode: :normal | :safe,
          generation: non_neg_integer(),
          status: Generation.status(),
          reverted: nil | %{from: pos_integer(), to: non_neg_integer()},
          failed_launches: non_neg_integer(),
          load_ms: non_neg_integer(),
          rebuilding: boolean()
        }

  # ── API ──

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts =
      @defaults
      |> Keyword.merge(Application.get_env(:rho, :dyn, []))
      |> Keyword.merge(opts)
      |> Keyword.put_new(:name, __MODULE__)

    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  The launch's Dyn boot: launch markers, boot probation, safe mode, loading
  the current generation. Options: `core:` the delivered Core update
  (mob_deliver manifest id) this launch runs, `nil` for the build's own
  code, recorded with the launch; `core_rolled_back:` the update
  mob_deliver rolled back during this launch, if any. When it is the one
  the last counted launch ran, that launch failed on the Core and doesn't
  count against the Dyn generation (see the moduledoc).
  """
  @spec boot(GenServer.server(), keyword()) :: boot_report()
  def boot(server, opts \\ []), do: GenServer.call(server, {:boot, opts}, :infinity)

  @doc """
  Counts a proposal against this launch's cap; `{:error, :proposal_limit}`
  once it's reached, `{:error, :rebuilding}` during a background rebuild.
  """
  @spec reserve_proposal(GenServer.server()) :: :ok | {:error, :proposal_limit | :rebuilding}
  def reserve_proposal(server), do: GenServer.call(server, :reserve_proposal)

  @doc """
  Returns once this launch's background rebuild (see the moduledoc) is
  over, at once if none runs.
  """
  @spec await_rebuild(GenServer.server()) :: :ok
  def await_rebuild(server), do: GenServer.call(server, :await_rebuild, :infinity)

  @doc "Records a proposal that passed (see `Rho.Dyn.propose/2`); supersedes the previous one."
  @spec candidate(GenServer.server(), Generation.t(), [module()]) :: :ok | {:error, :superseded}
  def candidate(server, gen, mods), do: GenServer.call(server, {:candidate, gen, mods})

  @doc """
  Makes `gen` (built from the seed, `Rho.Dyn.seed/3`; its modules
  `mods` loaded) current and proven at once, without approval: the seed
  ships with the Core. Only on top of the current generation, in normal
  mode and with no proposal pending; records it as the install's seed.
  """
  @spec install_seed(GenServer.server(), Generation.t(), [module()]) ::
          :ok | {:error, :safe_mode | :proposal_pending | :stale | term()}
  def install_seed(server, gen, mods),
    do: GenServer.call(server, {:install_seed, gen, mods}, :infinity)

  @doc "Drops the pending candidate `n` (unloads it; no approval needed)."
  @spec discard(GenServer.server(), pos_integer()) :: :ok | {:error, :not_pending}
  def discard(server, n), do: GenServer.call(server, {:discard, n})

  @spec activate(GenServer.server(), pos_integer(), Approval.token()) ::
          {:ok, Generation.t()} | {:error, term()}
  def activate(server, n, token), do: GenServer.call(server, {:activate, n, token}, :infinity)

  @spec revert_to(GenServer.server(), non_neg_integer(), Approval.token()) ::
          {:ok, Generation.t()} | {:error, term()}
  def revert_to(server, n, token), do: GenServer.call(server, {:revert_to, n, token}, :infinity)

  @doc "This launch reached stable: launch markers reset; may end a generation's probation."
  @spec mark_stable(GenServer.server()) :: :ok
  def mark_stable(server), do: GenServer.call(server, :mark_stable)

  @doc "The `:after_first_render` hook (mob appends the screen): stable after `:stable_delay_ms`."
  @spec first_render(GenServer.server(), module() | nil) :: :ok
  def first_render(server, _screen), do: GenServer.cast(server, :first_render)

  @doc """
  Watches `pid`, which runs Dyn module `mod`: its abnormal exit counts as
  a crash of `mod`'s generation. A no-op without a Keeper.
  """
  @spec watch(GenServer.server(), pid(), module()) :: :ok
  def watch(server, pid, mod) do
    case GenServer.whereis(server) do
      nil -> :ok
      keeper -> GenServer.call(keeper, {:watch, pid, mod})
    end
  catch
    :exit, _ -> :ok
  end

  @doc "Stops watching `pid`: its exit is no longer a crash (an orderly stop). A no-op without a Keeper."
  @spec unwatch(GenServer.server(), pid()) :: :ok
  def unwatch(server, pid) do
    case GenServer.whereis(server) do
      nil -> :ok
      keeper -> GenServer.call(keeper, {:unwatch, pid})
    end
  catch
    :exit, _ -> :ok
  end

  @doc "Sends `pid` `{:rho_dyn, event}` for every crash, revert, activation, ... until it exits."
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})

  @spec status(GenServer.server()) :: %{
          generation: non_neg_integer(),
          status: Generation.status(),
          parent: non_neg_integer() | nil,
          mode: :booting | :normal | :safe,
          pending: pos_integer() | nil
        }
  def status(server), do: GenServer.call(server, :status)

  # ── GenServer ──

  @impl true
  def init(opts) do
    :ok = Config.validate!()
    # The runtime generations are built for is the Core as this launch
    # started it: fixed now, before code hot-loaded later (a dev deploy, an
    # IEx session) can count in it (`Rho.Dyn.Compiler.runtime/0`).
    _ = Compiler.runtime()
    name = Keyword.fetch!(opts, :name)
    dir = Keyword.get_lazy(opts, :dir, &Store.default_root/0)
    File.mkdir_p!(dir)
    table = :ets.new(name, [:named_table, :protected, read_concurrency: true])

    config = %{
      dir: dir,
      keeper: name,
      approval: Keyword.fetch!(opts, :approval),
      build: Keyword.take(opts, @build_opts) |> Keyword.put(:keeper, name),
      # Background compiles (the seed) get as long as a rebuild.
      rebuild_timeout_ms: Keyword.fetch!(opts, :rebuild_timeout_ms)
    }

    :ets.insert(table, {:config, config})
    screens = Config.screens()
    :ok = screens.subscribe_app_events()

    s = %{
      name: name,
      table: table,
      dir: dir,
      approval: config.approval,
      build: config.build,
      screens: screens,
      opts: Map.new(Keyword.take(opts, Keyword.keys(@defaults))),
      mode: :booting,
      current: 0,
      current_status: :proven,
      current_parent: nil,
      booted: nil,
      booted_on_probation: false,
      rendered: false,
      stable: false,
      stable_timer: nil,
      stable_due: false,
      rebuilding: nil,
      proposals: 0,
      used: MapSet.new(),
      pending: nil,
      loaded: %{},
      old: [],
      watched: %{},
      crashes: [],
      quiet: nil,
      gc_timer: nil,
      subscribers: %{}
    }

    {:ok, restore(s)}
  end

  @impl true
  def handle_call({:boot, opts}, _from, s) do
    markers = Store.boot_markers(s.dir)
    failed = failed_launches(markers, Keyword.get(opts, :core_rolled_back))
    launch_markers = %{boot_attempts: failed + 1, stable: false, core: Keyword.get(opts, :core)}

    case Store.put_boot_markers(s.dir, launch_markers) do
      :ok -> :ok
      {:error, e} -> Logger.error("[dyn] can't write launch markers: #{inspect(e)}")
    end

    {us, {s, reverted}} = :timer.tc(fn -> launch(s, failed) end)
    s = remember_launch(s)

    report = %{
      mode: s.mode,
      generation: s.current,
      status: s.current_status,
      reverted: reverted,
      failed_launches: failed,
      load_ms: div(us, 1000),
      rebuilding: s.rebuilding != nil
    }

    Logger.info("[dyn] boot: #{inspect(report)}")
    {:reply, report, s}
  end

  def handle_call(:reserve_proposal, _from, %{rebuilding: %{}} = s),
    do: {:reply, {:error, :rebuilding}, s}

  def handle_call(:reserve_proposal, _from, s) do
    if s.proposals < s.opts.max_proposals and not atoms_near_limit?(),
      do: {:reply, :ok, remember_launch(%{s | proposals: s.proposals + 1})},
      else: {:reply, {:error, :proposal_limit}, s}
  end

  def handle_call({:candidate, gen, mods}, _from, s) do
    if s.pending != nil and s.pending > gen.n do
      drop(s, gen.n, mods, :superseded)
      {:reply, {:error, :superseded}, s}
    else
      if s.pending, do: drop(s, s.pending, Map.get(s.loaded, s.pending, []), :superseded)
      s = %{s | pending: gen.n, loaded: Map.put(Map.delete(s.loaded, s.pending), gen.n, mods)}
      broadcast(s, %{type: :candidate, gen: gen.n, rationale: gen.rationale})
      {:reply, :ok, s}
    end
  end

  def handle_call({:install_seed, gen, mods}, _from, s) do
    cond do
      s.mode != :normal -> {:reply, {:error, :safe_mode}, s}
      s.pending != nil -> {:reply, {:error, :proposal_pending}, s}
      gen.parent != s.current -> {:reply, {:error, :stale}, s}
      true -> install_seed(%{s | loaded: Map.put(s.loaded, gen.n, mods)}, gen)
    end
  end

  def handle_call({:discard, n}, _from, %{pending: n} = s) when is_integer(n) do
    drop(s, n, Map.get(s.loaded, n, []), :discarded)
    {:reply, :ok, %{s | pending: nil, loaded: Map.delete(s.loaded, n)}}
  end

  def handle_call({:discard, _n}, _from, s), do: {:reply, {:error, :not_pending}, s}

  def handle_call({:activate, n, token}, _from, s) do
    case approve(s, {:activate, n}, token) do
      {:ok, s} -> activate(s, n)
      {error, s} -> {:reply, error, s}
    end
  end

  def handle_call({:revert_to, n, token}, _from, s) do
    case approve(s, {:revert_to, n}, token) do
      {:ok, s} -> revert_to(s, n)
      {error, s} -> {:reply, error, s}
    end
  end

  def handle_call(:mark_stable, _from, s), do: {:reply, :ok, stable(s)}

  def handle_call({:watch, pid, mod}, _from, s) do
    case Compiler.generation_of(mod) do
      nil ->
        {:reply, :ok, s}

      n ->
        # One process mounting several screens of a generation is one watch:
        # its exit is one crash.
        if Enum.any?(s.watched, &match?({_, {^pid, _, ^n}}, &1)) do
          {:reply, :ok, s}
        else
          ref = Process.monitor(pid)
          {:reply, :ok, %{s | watched: Map.put(s.watched, ref, {pid, mod, n})}}
        end
    end
  end

  def handle_call({:unwatch, pid}, _from, s) do
    {mine, rest} = Enum.split_with(s.watched, &match?({_, {^pid, _, _}}, &1))
    Enum.each(mine, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
    {:reply, :ok, %{s | watched: Map.new(rest)}}
  end

  def handle_call({:subscribe, pid}, _from, s) do
    if Map.has_key?(s.subscribers, pid),
      do: {:reply, :ok, s},
      else: {:reply, :ok, %{s | subscribers: Map.put(s.subscribers, pid, Process.monitor(pid))}}
  end

  def handle_call(:await_rebuild, _from, %{rebuilding: nil} = s), do: {:reply, :ok, s}

  def handle_call(:await_rebuild, from, %{rebuilding: r} = s),
    do: {:noreply, %{s | rebuilding: %{r | waiters: [from | r.waiters]}}}

  def handle_call(:status, _from, s) do
    {:reply,
     %{
       generation: s.current,
       status: s.current_status,
       parent: s.current_parent,
       mode: s.mode,
       pending: s.pending
     }, s}
  end

  @impl true
  def handle_cast(:first_render, %{stable: false, stable_timer: nil} = s) do
    timer = Process.send_after(self(), :stable, s.opts.stable_delay_ms)
    {:noreply, remember_launch(%{s | rendered: true, stable_timer: timer})}
  end

  def handle_cast(:first_render, s), do: {:noreply, s}

  @impl true
  def handle_info(:stable, s), do: {:noreply, stable(%{s | stable_timer: nil})}

  def handle_info({:quiet, n, ref}, %{quiet: ref, current: n} = s) do
    s = %{s | quiet: nil}

    case Store.update_generation(s.dir, n, &%{&1 | quiet: true}) do
      {:ok, gen} -> {:noreply, maybe_prove(s, gen)}
      {:error, _} -> {:noreply, s}
    end
  end

  def handle_info({:quiet, _n, _ref}, s), do: {:noreply, s}

  def handle_info({:DOWN, ref, :process, pid, reason}, s) do
    case Map.pop(s.watched, ref) do
      {{^pid, mod, n}, watched} ->
        s = %{s | watched: watched}
        if crash?(reason), do: {:noreply, crashed(s, n, mod, reason)}, else: {:noreply, s}

      {nil, _} ->
        {:noreply, %{s | subscribers: Map.delete(s.subscribers, pid)}}
    end
  end

  def handle_info({:rebuilt, ref, result}, %{rebuilding: %{ref: ref} = r} = s) do
    :ets.delete(s.table, :rebuilding)
    s = rebuilt(%{s | rebuilding: nil}, r.n, result)
    Enum.each(r.waiters, &GenServer.reply(&1, :ok))
    s = if s.stable_due, do: stable(%{s | stable_due: false}), else: s
    {:noreply, remember_launch(s)}
  end

  def handle_info(:gc, s), do: {:noreply, gc(%{s | gc_timer: nil})}

  # The user left a launch that had drawn its first frame: it got going.
  def handle_info(message, s) do
    if s.rendered and s.screens.left_app?(message),
      do: {:noreply, stable(s)},
      else: {:noreply, s}
  end

  # ── activation and reverts by hand ──

  defp activate(s, n) do
    with {:ok, gen} <- fetch(s, n),
         :ok <- expect(gen.status == :candidate, {:not_a_candidate, gen.status}),
         :ok <-
           expect(gen.parent == s.current, {:stale, %{parent: gen.parent, current: s.current}}),
         {:ok, s, gen} <- ensure_loaded(s, gen),
         :ok <- flip(s, n) do
      gen = %{
        gen
        | status: :probation,
          activated_at: Generation.now(),
          quiet: false,
          restarted: false
      }

      persist(s, gen)
      s = %{s | pending: if(s.pending == n, do: nil, else: s.pending)}
      s = s |> switch(gen) |> start_quiet()
      broadcast(s, %{type: :activated, gen: n, parent: gen.parent})
      {:reply, {:ok, gen}, gc_soon(s)}
    else
      {:error, _} = error -> {:reply, error, s}
    end
  end

  defp install_seed(s, gen) do
    case flip(s, gen.n) do
      :ok ->
        now = Generation.now()

        # The merged generation carries the current one's code: code still on
        # probation stays on probation, the seed doesn't prove it.
        gen =
          if s.current_status == :probation,
            do: %{gen | status: :probation, activated_at: now, quiet: false, restarted: false},
            else: %{
              gen
              | status: :proven,
                activated_at: now,
                proven_at: now,
                quiet: true,
                restarted: true
            }

        persist(s, gen)

        case Store.put_seed(s.dir, gen.n) do
          :ok -> :ok
          {:error, e} -> Logger.error("[dyn] can't record the seed generation: #{inspect(e)}")
        end

        # Staging follows what runs, with the agent's unproposed edits kept.
        Store.reset_staging(s.dir, replay_staging(s.dir, gen))
        s = s |> switch(gen) |> start_quiet()
        broadcast(s, %{type: :activated, gen: gen.n, parent: gen.parent, seed: true})
        {:reply, :ok, gc_soon(s)}

      {:error, _} = error ->
        {:reply, error, %{s | loaded: Map.delete(s.loaded, gen.n)}}
    end
  end

  # The seed generation's sources plus what staging changed against its parent
  # (writes and deletions).
  defp replay_staging(dir, gen) do
    base = Store.sources(dir, gen.parent)
    staged = if Store.staging?(dir), do: Store.staged(dir), else: base
    deleted = Map.keys(base) -- Map.keys(staged)
    changed = Map.filter(staged, fn {path, src} -> Map.get(base, path) != src end)

    dir |> Store.sources(gen.n) |> Map.drop(deleted) |> Map.merge(changed)
  end

  defp revert_to(s, n) do
    with {:ok, gen} <- fetch(s, n),
         :ok <- expect(n != s.current, :already_current),
         :ok <- expect(Generation.ever_active?(gen), {:never_active, gen.status}),
         {:ok, s, gen} <- ensure_loaded(s, gen),
         :ok <- flip(s, n) do
      from = s.current
      reason = "reverted by hand to generation #{n}"
      if s.current_status == :probation, do: mark_reverted(s, from, reason)
      gen = if gen.status == :reverted, do: reactivate(s, gen), else: gen
      s = s |> switch(gen) |> start_quiet()
      report(s, %{type: :reverted, from: from, to: n, reason: reason, crashes: []})
      {:reply, {:ok, gen}, gc_soon(s)}
    else
      {:error, _} = error -> {:reply, error, s}
    end
  end

  defp reactivate(s, gen) do
    gen = %{
      gen
      | status: :probation,
        activated_at: Generation.now(),
        quiet: false,
        restarted: false,
        reason: nil
    }

    persist(s, gen)
    gen
  end

  # ── launches ──

  # The last counted launch ran a Core update that mob_deliver has rolled
  # back since: the Core failed, not this generation. Only that launch: one
  # that died before reaching the Keeper recorded nothing, and the markers
  # still name what the launch before it ran.
  defp failed_launches(%{boot_attempts: attempts, core: core}, core)
       when attempts > 0 and is_binary(core) do
    Logger.info(
      "[dyn] the last launch failed on Core update #{core}, rolled back since; " <>
        "not counted against the Dyn generation"
    )

    attempts - 1
  end

  defp failed_launches(%{boot_attempts: attempts}, _core_rolled_back), do: attempts

  defp launch(s, failed) do
    s = %{
      s
      | mode: :normal,
        stable: false,
        rendered: false,
        booted: nil,
        booted_on_probation: false,
        proposals: 0
    }

    gen = current_generation(s)

    {s, gen, reverted} =
      if gen.status == :probation and failed >= 1 do
        boot_revert(s, gen)
      else
        {s, gen, nil}
      end

    unless Store.staging?(s.dir), do: Store.reset_staging(s.dir, Store.sources(s.dir, gen.n))
    s = %{s | current: gen.n, current_status: gen.status, current_parent: gen.parent}

    s =
      if failed >= 2 do
        safe_mode(s, failed)
      else
        s |> load_current(gen) |> start_quiet()
      end

    {s, reverted}
  end

  # The pointed-at generation. One the pointer reached without its manifest
  # saying so (a crash between the two writes) is unproven; one that was
  # never approved can't be current at all.
  defp current_generation(s) do
    n = Store.current(s.dir)

    case fetch(s, n) do
      {:ok, %{status: status} = gen} when status in [:probation, :proven] ->
        gen

      {:ok, %{status: status} = gen} when status in [:candidate, :reverted] ->
        gen = %{gen | status: :probation, quiet: false, restarted: false}
        persist(s, gen)
        gen

      {:ok, gen} ->
        invalid_pointer(s, n, "is #{gen.status}")

      {:error, _} ->
        invalid_pointer(s, n, "has no manifest")
    end
  end

  defp invalid_pointer(s, n, why) do
    reason = "the current pointer names generation #{n}, which #{why}; using generation 0"
    Logger.error("[dyn] " <> reason)
    _ = flip(s, 0)
    report(s, %{type: :load_failed, gen: n, reason: reason})
    Generation.empty()
  end

  defp boot_revert(s, gen) do
    to = gen.parent || 0
    reason = "the launch after it was activated never reached stable"

    case flip(s, to) do
      :ok ->
        mark_reverted(s, gen.n, reason)
        report(s, %{type: :reverted, from: gen.n, to: to, reason: reason, crashes: []})

        target =
          case fetch(s, to) do
            {:ok, target} -> target
            {:error, _} -> Generation.empty()
          end

        {s, target, %{from: gen.n, to: to}}

      {:error, e} ->
        Logger.error("[dyn] boot probation couldn't revert generation #{gen.n}: #{inspect(e)}")
        {s, gen, nil}
    end
  end

  defp safe_mode(s, failed) do
    s = %{s | mode: :safe}
    :ets.insert(s.table, [{:mode, :safe}, {:generation, s.current, %{}}])

    report(s, %{
      type: :safe_mode,
      gen: s.current,
      reason: "#{failed} launches in a row never reached stable; Dyn not loaded"
    })

    s
  end

  defp load_current(s, gen) do
    :ets.insert(s.table, {:mode, :normal})

    if Compiler.stale?(gen) and not Map.has_key?(s.loaded, gen.n) do
      start_rebuild(s, gen)
    else
      case ensure_loaded(s, gen) do
        {:ok, s, gen} ->
          %{s | booted: gen.n, booted_on_probation: gen.status == :probation} |> switch(gen)

        {:error, {:load_failed, reason}} ->
          load_failed(s, gen, reason)
      end
    end
  end

  defp load_failed(s, gen, reason) do
    report(s, %{type: :load_failed, gen: gen.n, reason: reason})
    :ets.insert(s.table, {:generation, gen.n, %{}})

    if gen.status == :proven,
      do: persist(s, %{gen | status: :probation, quiet: false, restarted: false}),
      else: :ok

    %{s | current_status: :probation}
  end

  # In a linked worker (the rebuild only touches the code server and reads
  # the store); it never exits abnormally, so the link only takes it down
  # with the Keeper. Nothing of the generation is registered meanwhile.
  defp start_rebuild(s, gen) do
    :ets.insert(s.table, [{:generation, gen.n, %{}}, {:rebuilding, gen.n}])
    keeper = self()
    ref = make_ref()
    {root, opts} = {s.dir, Keyword.put(s.build, :compile_timeout_ms, s.opts.rebuild_timeout_ms)}

    _ =
      spawn_link(fn ->
        result =
          try do
            Compiler.rebuild(root, gen, opts)
          catch
            # Linked to the Keeper: nothing caught here runs.
            kind, reason ->
              {:error,
               "the rebuild crashed: " <> Untrusted.caught_text(kind, reason, __STACKTRACE__)}
          end

        send(keeper, {:rebuilt, ref, result})
      end)

    %{s | rebuilding: %{n: gen.n, ref: ref, waiters: []}}
  end

  # The worker's result. Stored and registered only if generation `n` is
  # still the one to run (a revert by hand may have moved on meanwhile).
  defp rebuilt(%{mode: :normal, current: n} = s, n, {:ok, build, tests}) do
    mods = Enum.map(build.modules, &elem(&1, 0))

    with {:ok, gen} <- fetch(s, n),
         {:ok, gen} <- Compiler.store_rebuild(s.dir, gen, build, tests) do
      s =
        %{
          s
          | loaded: Map.put(s.loaded, n, mods),
            booted: n,
            booted_on_probation: gen.status == :probation
        }
        |> switch(gen)
        |> start_quiet()

      broadcast(s, %{type: :loaded, gen: n})
      s
    else
      {:error, reason} ->
        Compiler.purge(mods)
        rebuild_failed(s, n, if(is_binary(reason), do: reason, else: inspect(reason)))
    end
  end

  defp rebuilt(%{mode: :normal, current: n} = s, n, {:error, reason}),
    do: rebuild_failed(s, n, reason)

  defp rebuilt(s, n, result) do
    with {:ok, build, _tests} <- result, do: Compiler.purge(Enum.map(build.modules, &elem(&1, 0)))
    Logger.info("[dyn] generation #{n}'s rebuild ended after it stopped being current")
    s
  end

  defp rebuild_failed(s, n, reason) do
    case fetch(s, n) do
      {:ok, gen} ->
        load_failed(s, gen, reason)

      {:error, _} ->
        _ = report(s, %{type: :load_failed, gen: n, reason: reason})
        s
    end
  end

  defp stable(%{stable: true} = s), do: s

  # Not before the rebuild is over (see the moduledoc).
  defp stable(%{rebuilding: %{}} = s) do
    if s.stable_timer, do: Process.cancel_timer(s.stable_timer)
    %{s | stable_due: true, stable_timer: nil}
  end

  defp stable(s) do
    if s.stable_timer, do: Process.cancel_timer(s.stable_timer)

    case Store.put_boot_markers(s.dir, %{boot_attempts: 0, stable: true}) do
      :ok -> :ok
      {:error, e} -> Logger.error("[dyn] can't write launch markers: #{inspect(e)}")
    end

    s = remember_launch(%{s | stable: true, stable_timer: nil})
    run_on_stable(s.opts.on_stable)

    with true <- s.mode == :normal and s.booted_on_probation and s.booted == s.current,
         :probation <- s.current_status,
         {:ok, gen} <- Store.update_generation(s.dir, s.current, &%{&1 | restarted: true}) do
      maybe_prove(s, gen)
    else
      _ -> s
    end
  end

  # Its own process: the callee may block (mob_deliver's watchdog writes to
  # disk), and its failure is its own.
  defp run_on_stable({module, fun, args}) do
    _ = spawn(module, fun, args)
    :ok
  end

  defp run_on_stable(nil), do: :ok

  # A Keeper restarted within a launch picks up where the last one was.
  defp restore(s) do
    case :persistent_term.get(launch_key(s), nil) do
      nil ->
        :ets.insert(s.table, [{:mode, :booting}, {:generation, 0, %{}}])
        s

      launch ->
        s = Map.merge(s, launch)
        gen = current_generation(s)
        s = %{s | current: gen.n, current_status: gen.status, current_parent: gen.parent}
        :ets.insert(s.table, {:mode, s.mode})
        mods = if gen.n > 0, do: Compiler.loaded(gen.n), else: []

        if s.mode == :normal and length(mods) == length(gen.modules) do
          %{s | loaded: %{gen.n => mods}} |> switch(gen) |> start_quiet()
        else
          :ets.insert(s.table, {:generation, gen.n, %{}})
          s
        end
    end
  end

  defp remember_launch(s) do
    launch = Map.take(s, [:mode, :booted, :booted_on_probation, :stable, :rendered, :proposals])
    :persistent_term.put(launch_key(s), launch)
    s
  end

  defp launch_key(s), do: {__MODULE__, s.name, s.dir}

  defp atoms_near_limit?,
    do: :erlang.system_info(:atom_count) > :erlang.system_info(:atom_limit) * 0.8

  # ── generations ──

  defp fetch(s, n) do
    case Store.generation(s.dir, n) do
      {:ok, gen} -> {:ok, gen}
      {:error, :not_found} -> {:error, {:no_generation, n}}
    end
  end

  # The generation as loaded: a rebuild for a new runtime changes it.
  defp ensure_loaded(%{mode: :safe} = s, gen), do: {:ok, s, gen}

  # Loading a generation that isn't loaded (a revert to an older one, built
  # for another Core) compiles all of it, like a background rebuild: give it
  # that time. A proposal's compile is incremental and keeps the short limit.
  defp ensure_loaded(s, gen) do
    if gen.n == 0 or Map.has_key?(s.loaded, gen.n) do
      {:ok, s, gen}
    else
      build = Keyword.put(s.build, :compile_timeout_ms, s.opts.rebuild_timeout_ms)

      case Compiler.load_generation(s.dir, gen, build) do
        {:ok, mods, gen} -> {:ok, %{s | loaded: Map.put(s.loaded, gen.n, mods)}, gen}
        {:error, reason} -> {:error, {:load_failed, reason}}
      end
    end
  end

  defp flip(s, n) do
    case Store.put_current(s.dir, n) do
      :ok -> :ok
      {:error, e} -> {:error, {:pointer_not_written, e}}
    end
  end

  # Makes `gen` current; the registry follows unless in safe mode.
  defp switch(s, gen) do
    if s.mode == :normal, do: :ets.insert(s.table, {:generation, gen.n, entries(s, gen)})

    %{
      s
      | current: gen.n,
        current_status: gen.status,
        current_parent: gen.parent,
        crashes: [],
        quiet: nil
    }
  end

  defp entries(s, gen) do
    by_name = Map.new(Map.get(s.loaded, gen.n, []), &{inspect(&1), &1})

    for m <- gen.modules, {:ok, mod} <- [Map.fetch(by_name, m.versioned)], into: %{} do
      {{m.kind, m.name}, mod}
    end
  end

  defp persist(s, gen) do
    case Store.put_generation(s.dir, gen) do
      :ok ->
        :ok

      {:error, e} ->
        Logger.error("[dyn] can't write generation #{gen.n}'s manifest: #{inspect(e)}")
    end
  end

  defp mark_reverted(s, n, reason) do
    _ =
      Store.update_generation(s.dir, n, fn gen ->
        %{gen | status: :reverted, reverted_at: Generation.now(), reason: reason}
      end)

    :ok
  end

  # A candidate that won't run: superseded by a newer one, or discarded.
  defp drop(s, n, mods, status) do
    Compiler.purge(mods)
    _ = Store.update_generation(s.dir, n, &%{&1 | status: status})
    broadcast(s, %{type: status, gen: n})
  end

  defp approve(s, _subject, nil), do: {{:error, :approval_required}, s}

  defp approve(s, subject, token) do
    if MapSet.member?(s.used, token) do
      {{:error, :approval_used}, s}
    else
      case s.approval.verify(token, subject) do
        :ok -> {:ok, %{s | used: MapSet.put(s.used, token)}}
        error -> {error, s}
      end
    end
  end

  defp expect(true, _error), do: :ok
  defp expect(false, error), do: {:error, error}

  # ── probation ──

  defp start_quiet(%{rebuilding: %{n: n}, current: n} = s), do: s

  defp start_quiet(%{mode: :normal, current_status: :probation} = s) do
    ref = make_ref()
    Process.send_after(self(), {:quiet, s.current, ref}, s.opts.probation_ms)
    %{s | quiet: ref}
  end

  defp start_quiet(s), do: s

  defp maybe_prove(s, %Generation{status: :probation, quiet: true, restarted: true} = gen) do
    gen = %{gen | status: :proven, proven_at: Generation.now()}
    persist(s, gen)
    broadcast(s, %{type: :proven, gen: gen.n})
    %{s | current_status: :proven, quiet: nil}
  end

  defp maybe_prove(s, _gen), do: s

  # ── crashes ──

  defp crash?(:normal), do: false
  defp crash?(:shutdown), do: false
  defp crash?({:shutdown, _}), do: false
  # monitored after it was gone: the reason is unknown
  defp crash?(:noproc), do: false
  defp crash?(_reason), do: true

  # A candidate's processes (its selftests) are the proposal's business.
  defp crashed(s, n, mod, reason) do
    if n == s.pending or not (n == s.current or Map.has_key?(s.loaded, n)) do
      s
    else
      entry = %{
        type: :crash,
        gen: n,
        module: Compiler.logical(mod),
        kind: if(reason == :killed, do: :killed, else: :crash),
        # A Dyn process's exit reason: described, nothing of it runs here.
        reason: Untrusted.exit_text(reason, 2000),
        status: if(n == s.current, do: s.current_status, else: :old)
      }

      entry = report(s, entry)

      if n == s.current and s.current_status == :probation and s.mode == :normal,
        do: count(s, entry),
        else: s
    end
  end

  defp count(s, entry) do
    now = System.monotonic_time(:millisecond)
    window = s.opts.crash_window_ms
    recent = [{now, entry} | Enum.filter(s.crashes, fn {t, _} -> now - t < window end)]
    s = %{s | crashes: recent}

    if length(recent) >= s.opts.crash_limit do
      crashes = recent |> Enum.reverse() |> Enum.map(&elem(&1, 1))
      reason = "#{length(recent)} crashes within #{div(window, 1000)} s on probation"
      revert(s, reason, crashes)
    else
      start_quiet(s)
    end
  end

  # Load the target first (the parent, or no Dyn at all), then flip.
  defp revert(s, reason, crashes) do
    from = s.current
    {:ok, s, target} = load_first(s, Enum.uniq([s.current_parent || 0, 0]))

    case flip(s, target.n) do
      :ok ->
        mark_reverted(s, from, reason)
        s = s |> switch(target) |> start_quiet()
        report(s, %{type: :reverted, from: from, to: target.n, reason: reason, crashes: crashes})
        gc_soon(s)

      {:error, e} ->
        Logger.error("[dyn] couldn't revert generation #{from}: #{inspect(e)}")
        report(s, %{type: :revert_failed, gen: from, to: target.n, reason: inspect(e)})
        s
    end
  end

  # Generation 0 always loads (there is nothing to load).
  defp load_first(s, [n | rest]) do
    with {:ok, gen} <- fetch(s, n),
         {:ok, s, gen} <- ensure_loaded(s, gen) do
      {:ok, s, gen}
    else
      error ->
        report(s, %{type: :load_failed, gen: n, reason: inspect(error)})
        load_first(s, rest)
    end
  end

  # ── reporting ──

  # Logged (crashes, reverts, safe mode) and sent to subscribers.
  defp report(s, event) do
    event = Map.put(event, :at, Generation.now())
    Store.append_log(s.dir, event)
    broadcast(s, event)
    event
  end

  defp broadcast(s, event) do
    Enum.each(Map.keys(s.subscribers), &send(&1, {:rho_dyn, event}))
  end

  # ── unloading old generations ──

  defp gc_soon(%{gc_timer: nil} = s), do: %{s | gc_timer: Process.send_after(self(), :gc, 0)}
  defp gc_soon(s), do: s

  defp gc(s) do
    keep = MapSet.new([s.current, s.current_parent, s.pending])
    busy = MapSet.new(Map.values(s.watched), fn {_pid, _mod, n} -> n end)

    {loaded, old, waiting?} =
      s.loaded
      |> Enum.reject(fn {n, _mods} -> MapSet.member?(keep, n) end)
      |> Enum.reduce({s.loaded, s.old, false}, fn {n, mods}, acc ->
        unload(n, mods, MapSet.member?(busy, n), acc)
      end)

    old = Compiler.purge_old(old)
    s = %{s | loaded: loaded, old: old}

    if waiting? or old != [],
      do: %{s | gc_timer: Process.send_after(self(), :gc, s.opts.gc_retry_ms)},
      else: s
  end

  # A generation with a live watched process is in use, whatever its code does.
  defp unload(_n, _mods, true = _busy, {loaded, old, _waiting?}), do: {loaded, old, true}

  defp unload(n, mods, false, {loaded, old, waiting?}) do
    case Compiler.unload(mods) do
      :in_use -> {loaded, old, true}
      {:ok, stuck} -> {Map.delete(loaded, n), old ++ stuck, waiting?}
    end
  end
end
