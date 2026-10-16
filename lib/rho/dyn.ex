defmodule Rho.Dyn do
  @moduledoc """
  The Dyn layer: code the agent writes, compiles and runs on the device
  itself (tools and screens), next to the fixed Core (the loop, sessions,
  sign-in, the core tools, the approval gate and the repair path, which
  ship in the app and which the agent can't change). The Core changes Dyn
  only through this module, one generation at a time:

      stage_put/3 ... ──► propose/2 ──► activate/3 ──► probation ──► proven
       (staging copy)     check,         (approval)     │
                          compile G<n>,                 └─► reverted (crashes,
                          selftest                           failed launch, by hand)

  1. **Stage**: edits go to a staging copy of the current generation's
     sources (`stage_reset/1`, `stage_put/3`, `stage_delete/2`).
  2. **Propose** (`propose/2`): static check (`Rho.Dyn.Check`),
     compile into `Dyn.G<n>.*` next to the running generation
     (`Rho.Dyn.Compiler`), selftest each module in a contained
     process (`Rho.Dyn.Selftest`). Nothing live changes: the
     result is a proposal (generation, diff, rationale, test results) or a
     rejection saying which step refused and why.
  3. **Activate** (`activate/3`) with a token from the approval seam
     (`request_approval/2`, `Rho.Dyn.Approval`): the human approves with
     the screen lock.
  4. **Probation, revert, safe mode**: `Rho.Dyn.Keeper`. A new generation
     is unproven until it ran 60 s without a Dyn crash and survived an app
     restart; 3 crashes in 60 s, or a launch that dies before it is
     stable, revert it; two failed launches in a row start the next one in
     safe mode, with no Dyn code loaded, so the Core can always repair it.

  **Generations, not files**: every accepted change is a generation, its
  full source set, binaries, selftests and diff (`Rho.Dyn.Store`);
  activation and revert flip a pointer. **Versioned modules**: the agent
  writes `Dyn.Foo` (the namespace is the host's, `Rho.Dyn.Config`) and
  generation `n` compiles it as `Dyn.G<n>.Foo`, so a candidate loads next
  to the running code, never over it (no purge kills a running process);
  an old generation is unloaded only once no process runs its code.
  The registry maps logical names (`{:tool, "weather"}`, `{:screen,
  "Notes"}`) to the current generation's modules (`Rho.Dyn.Registry`);
  the loop sees Dyn tools through `Rho.ToolRegistry` (`Rho.Dyn.Source`),
  from the next model call after a switch.

  **No Dyn code in a Core process** through what Dyn hands over
  (`Rho.Untrusted`): crashes are formatted where they happened (the tool's
  task, the selftest's or the compile's process, bounded), and the loop,
  the Keeper and a proposal's caller only describe a reason they get,
  without an exception's `message/1` or a Dyn struct's protocols. A Dyn
  tool's answer is plain data before it leaves its task, and its
  declaration is read in a bounded process outside the loop and kept (see
  `Rho.Tool`).
  A Dyn screen's own process runs its code, so whatever the host's screen
  layer does with its crash is the host's (mob's) business.

  **Threat model**: Dyn guards against the model's mistakes (a built tool
  that crashes, hangs, or calls something it shouldn't by accident), not
  against deliberately hostile code. The static check is a best-effort
  deny-list, not a sandbox (`Rho.Dyn.Check` lists the known ways around
  it); `Rho.Untrusted` and `Rho.Dyn.LogGuard` lower the chance that a Dyn
  crash takes a trusted process down.

  Dyn compiles Elixir on the device: the app must ship the Elixir compiler
  (`:elixir`'s compiler modules and `:compiler`), so no slim build that
  strips them.

  The host's seams (`Rho.Dyn.Config`): the namespace, the Core's module
  prefixes and what Dyn code may call (`Rho.Dyn.Check`), the screen
  integration (`Rho.Dyn.Screens`), the approval (`Rho.Dyn.Approval`), the
  launch's boot (`boot/1`) and `:on_stable` hook, and the seed it ships
  (`Rho.Dyn.Seed`).

  Every function takes the Keeper (its registered name, which is also the
  registry table's) last, defaulting to the app's.
  """

  alias Rho.Dyn.Approval
  alias Rho.Dyn.Check
  alias Rho.Dyn.Compiler
  alias Rho.Dyn.Config
  alias Rho.Dyn.Diff
  alias Rho.Dyn.Generation
  alias Rho.Dyn.Keeper
  alias Rho.Dyn.Registry
  alias Rho.Dyn.Selftest
  alias Rho.Dyn.Store
  alias Rho.ToolRegistry

  require Logger

  @keeper Keeper
  @log_keys [:type, :at, :gen, :module, :kind, :reason, :status, :from, :to, :crashes]

  @type proposal :: %{
          n: pos_integer(),
          parent: non_neg_integer(),
          rationale: String.t(),
          diff: String.t(),
          modules: [Generation.module_entry()],
          selftests: [Generation.selftest()],
          compile_ms: non_neg_integer(),
          reused: non_neg_integer(),
          warnings: [String.t()]
        }
  @type rejection :: %{
          n: pos_integer() | nil,
          stage: :check | :compile | :selftest | :names | :superseded | :install,
          reason: String.t(),
          violations: [Check.violation()],
          selftests: [Generation.selftest()]
        }

  # ── launch ──

  @doc """
  The Dyn step of the host's boot: loads the current generation (or
  decides on boot probation / safe mode, see `Rho.Dyn.Keeper`) and has the
  first rendered frame start the clock to "stable" (the host's
  `c:Rho.Dyn.Screens.after_first_render/1`). `opts` go to
  `Rho.Dyn.Keeper.boot/2` (`core:`, `core_rolled_back:`).
  """
  @spec boot(keyword()) :: Keeper.boot_report()
  def boot(opts \\ []) do
    report = Keeper.boot(@keeper, opts)
    :ok = Config.screens().after_first_render({Keeper, :first_render, [@keeper]})
    report
  end

  # ── staging ──

  @spec staged(atom()) :: %{String.t() => String.t()}
  def staged(keeper \\ @keeper), do: with_dir(keeper, %{}, &Store.staged/1)

  @doc "Resets staging to the current generation's sources."
  @spec stage_reset(atom()) :: :ok | {:error, :not_running}
  def stage_reset(keeper \\ @keeper) do
    with {:ok, %{dir: dir}} <- Registry.config(keeper),
         do: Store.reset_staging(dir, Store.sources(dir, status(keeper).generation))
  end

  @doc "Writes `source` to `path` (relative, `.ex`) in staging."
  @spec stage_put(String.t(), String.t(), atom()) :: :ok | {:error, :bad_path | :not_running}
  def stage_put(path, source, keeper \\ @keeper) do
    with {:ok, %{dir: dir}} <- Registry.config(keeper), do: Store.stage_put(dir, path, source)
  end

  @doc "Creates `path` in staging without replacing an existing source."
  @spec stage_create(String.t(), String.t(), atom()) ::
          :ok | {:error, :bad_path | :exists | :not_running | File.posix()}
  def stage_create(path, source, keeper \\ @keeper) do
    with {:ok, %{dir: dir}} <- Registry.config(keeper),
         do: Store.stage_create(dir, path, source)
  end

  @spec stage_delete(String.t(), atom()) :: :ok | {:error, :bad_path | :not_running}
  def stage_delete(path, keeper \\ @keeper) do
    with {:ok, %{dir: dir}} <- Registry.config(keeper), do: Store.stage_delete(dir, path)
  end

  @spec stage_read(String.t(), atom()) ::
          {:ok, String.t()} | {:error, :bad_path | :not_found | :not_running}
  def stage_read(path, keeper \\ @keeper) do
    with {:ok, %{dir: dir}} <- Registry.config(keeper), do: Store.stage_read(dir, path)
  end

  @doc """
  Reads `path` from staging, passes its source to `fun` and writes back what
  `fun` returns as `{:ok, new_source}` (anything else is returned and nothing
  is written), as one step: edits of the same file never interleave, so two
  `dyn_edit` calls the model makes in parallel both land. Returns
  `{:ok, old_source}` after writing.
  """
  @spec stage_update(String.t(), (String.t() -> {:ok, String.t()} | term()), atom()) ::
          {:ok, String.t()} | term()
  def stage_update(path, fun, keeper \\ @keeper) do
    with {:ok, %{dir: dir}} <- Registry.config(keeper) do
      # A lock on this node only, per staged file.
      lock = {{__MODULE__, :stage, dir, path}, self()}
      :global.trans(lock, fn -> update(dir, path, fun) end, [node()])
    end
  end

  defp update(dir, path, fun) do
    with {:ok, source} <- Store.stage_read(dir, path),
         {:ok, edited} <- fun.(source),
         :ok <- Store.stage_put(dir, path, edited),
         do: {:ok, source}
  end

  # ── proposals ──

  @doc """
  Turns the staged sources into a candidate generation without activating
  it. `{:error, rejection}` names the step that refused (`:check`,
  `:compile`, `:selftest`, `:names`) and why; a rejected generation's
  modules are unloaded and the current one is untouched.
  `{:error, :proposal_limit}`: this launch made too many proposals (see
  `Rho.Dyn.Keeper`); the app has to restart first.
  `{:error, :rebuilding}`: the current generation is being rebuilt for a
  new Core in the background; propose once it's loaded.
  """
  @spec propose(String.t(), atom()) ::
          {:ok, proposal()}
          | {:error,
             rejection()
             | :no_changes
             | :rationale_required
             | :not_running
             | :proposal_limit
             | :rebuilding}
  def propose(rationale, keeper \\ @keeper) do
    with {:ok, config} <- Registry.config(keeper),
         {:ok, rationale} <- rationale(rationale),
         parent = status(keeper).generation,
         base = Store.sources(config.dir, parent),
         staged = Store.staged(config.dir),
         :ok <- if(staged == base, do: {:error, :no_changes}, else: :ok),
         :ok <- Keeper.reserve_proposal(keeper) do
      info = %{parent: parent, rationale: rationale, finish: &candidate(keeper, &1, &2)}
      check(config, info, base, staged)
    end
  end

  defp candidate(keeper, gen, mods) do
    case Keeper.candidate(keeper, gen, mods) do
      :ok -> :ok
      {:error, :superseded} -> {:error, :superseded, "a newer proposal replaced it"}
    end
  end

  @doc """
  Installs the seed (`Rho.Dyn.Seed`, the default front) or a
  newer one: `merge` gets the current generation's sources and returns the
  full source set to install (`Rho.Dyn.Seed.merge/3` keeps the
  user's edits). It is checked, compiled and selftested like a proposal,
  then made current and proven by `Rho.Dyn.Keeper.install_seed/3`
  with no approval, because the seed ships with the Core and the merge
  only replaces seed files nobody changed. Waits (an error, retried next
  launch) in safe mode or while a proposal is pending; `{:error,
  :no_changes}` when the merge changes nothing.
  """
  @spec seed((%{String.t() => String.t()} -> %{String.t() => String.t()}), String.t(), atom()) ::
          {:ok, pos_integer()}
          | {:error, :no_changes | :safe_mode | :proposal_pending | :not_running | rejection()}
  def seed(merge, rationale, keeper \\ @keeper) when is_function(merge, 1) do
    with {:ok, config} <- Registry.config(keeper),
         status = status(keeper),
         :ok <- seedable(status) do
      base = Store.sources(config.dir, status.generation)
      staged = merge.(base)
      info = %{parent: status.generation, rationale: rationale, finish: &install(keeper, &1, &2)}
      # In the background, nobody waiting: as long as a rebuild may take.
      config = %{
        config
        | build: Keyword.put(config.build, :compile_timeout_ms, config.rebuild_timeout_ms)
      }

      seed_proposal(config, info, base, staged)
    end
  end

  defp seed_proposal(config, info, base, staged) do
    with :ok <- if(staged == base, do: {:error, :no_changes}, else: :ok),
         {:ok, proposal} <- check(config, info, base, staged),
         do: {:ok, proposal.n}
  end

  defp seedable(status) do
    cond do
      status.mode != :normal -> {:error, :safe_mode}
      status.pending -> {:error, :proposal_pending}
      true -> :ok
    end
  end

  defp install(keeper, gen, mods) do
    case Keeper.install_seed(keeper, gen, mods) do
      :ok ->
        :ok

      {:error, reason} ->
        Compiler.purge(mods)
        {:error, :install, "the seed wasn't installed: #{inspect(reason)}"}
    end
  end

  defp check(config, info, base, staged) do
    case Check.run(staged) do
      {:ok, parsed} ->
        info = Map.put(info, :n, Store.allocate(config.dir))
        build(config, info, base, staged, parsed)

      {:error, violations} ->
        {:error, rejection(nil, :check, Check.format(violations), violations: violations)}
    end
  end

  defp rationale(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :rationale_required}
      text -> {:ok, text}
    end
  end

  defp build(config, %{n: n} = info, base, staged, parsed) do
    dir = config.dir

    gen = %Generation{
      n: n,
      parent: info.parent,
      created_at: Generation.now(),
      rationale: info.rationale,
      status: :building,
      files: staged |> Map.keys() |> Enum.sort(),
      runtime: Compiler.runtime()
    }

    Store.put_sources(dir, n, staged)
    :ok = Store.put_generation(dir, gen)

    opts =
      config.build
      |> Keyword.put(:src_dir, Store.src_dir(dir, n))
      |> Keyword.put(:reuse, reuse(dir, info.parent, base, staged))

    with {:ok, build} <- step(Compiler.compile(parsed, n, opts)),
         :ok <- step(Check.beam(build.modules, n)),
         mods = Enum.map(build.modules, &elem(&1, 0)),
         {test_us, tests} = :timer.tc(fn -> Selftest.run(mods, opts) end),
         {:ok, tests} <- step(tests),
         {:ok, entries} <- names(build.modules, tests) do
      Logger.info(
        "[dyn] generation #{n}: #{map_size(staged) - length(build.reused)} files compiled, " <>
          "#{length(build.reused)} reused, in #{build.compile_ms} ms; " <>
          "selftests #{div(test_us, 1000)} ms"
      )

      diff = Diff.unified(base, staged)

      gen = %{
        gen
        | status: :candidate,
          modules: entries,
          selftests: Enum.map(tests, &Map.delete(&1, :name)),
          compile_ms: build.compile_ms,
          warnings: build.warnings
      }

      Store.put_beams(dir, n, build.modules)
      Store.put_deps(dir, n, build.deps)
      Store.put_diff(dir, n, diff)
      :ok = Store.put_generation(dir, gen)

      case info.finish.(gen, mods) do
        :ok ->
          {:ok,
           %{
             n: n,
             parent: gen.parent,
             rationale: gen.rationale,
             diff: diff,
             modules: entries,
             selftests: gen.selftests,
             compile_ms: build.compile_ms,
             reused: length(build.reused),
             warnings: build.warnings
           }}

        {:error, :superseded, reason} ->
          {:error, rejection(n, :superseded, reason)}

        {:error, stage, reason} ->
          _ = Store.put_generation(dir, %{gen | status: :rejected, reason: "#{stage}: #{reason}"})
          {:error, rejection(n, stage, reason)}
      end
    else
      {:error, stage, reason, extra} ->
        # A compile failure purged its own modules (and may have refused
        # because another generation `n` is loaded: not ours to touch).
        if stage != :compile, do: Compiler.purge(Compiler.loaded(n))
        tests = Keyword.get(extra, :selftests, [])

        _ =
          Store.put_generation(dir, %{
            gen
            | status: :rejected,
              reason: "#{stage}: #{reason}",
              selftests: Enum.map(tests, &Map.delete(&1, :name))
          })

        {:error, rejection(n, stage, reason, extra)}
    end
  end

  # The parent's binaries and deps, for an incremental compile
  # (Rho.Dyn.Reuse): only from a parent built by this runtime,
  # and only binaries its manifest vouches for.
  defp reuse(dir, parent, base, staged) do
    with true <- parent > 0,
         {:ok, gen} <- Store.generation(dir, parent),
         false <- Compiler.stale?(gen),
         %{} = deps <- Store.deps(dir, parent) do
      hashes = Map.new(gen.modules, &{"Elixir." <> &1.versioned, &1.sha256})

      beams =
        for {mod, bin} <- Store.beams(dir, parent),
            name = Atom.to_string(mod),
            Map.get(hashes, name) == Compiler.sha256(bin),
            into: %{},
            do: {name, bin}

      unchanged = for {rel, src} <- staged, Map.get(base, rel) == src, into: MapSet.new(), do: rel
      %{n: parent, deps: deps, beams: beams, unchanged: unchanged}
    else
      _ -> nil
    end
  end

  defp step({:ok, _} = ok), do: ok
  defp step(:ok), do: :ok
  defp step({:error, {:compile, text}}), do: {:error, :compile, text, []}

  defp step({:error, [%{file: _, message: _} | _] = violations}),
    do: {:error, :check, Check.format(violations), violations: violations}

  defp step({:error, [%{ok: _} | _] = tests}) do
    failed = for %{ok: false} = t <- tests, do: "#{t.module}: #{t.detail}"
    {:error, :selftest, Enum.join(failed, "\n"), selftests: tests}
  end

  # Registry names: a tool's own name (unique, not a Core tool's), else the
  # module name below the namespace.
  defp names(modules, tests) do
    by_module = Map.new(tests, &{&1.module, &1})
    core = MapSet.new(ToolRegistry.core_tools(), & &1.name())
    ns = Config.namespace_name() <> "."

    entries =
      for {mod, bin} <- modules do
        logical = Compiler.logical(mod)
        test = by_module[logical]
        # A protocol implementation (`Inspect.Dyn.Card`) keeps its whole name.
        short = String.replace_prefix(logical, ns, "")

        %{
          module: logical,
          versioned: inspect(mod),
          kind: test.kind,
          name: if(test.kind == :tool, do: test.name, else: short),
          sha256: Compiler.sha256(bin)
        }
      end

    tools = for %{kind: :tool, name: name} <- entries, do: name
    dupes = Enum.uniq(tools -- Enum.uniq(tools))
    clashes = Enum.filter(tools, &MapSet.member?(core, &1))

    cond do
      dupes != [] -> {:error, :names, "two tools are named #{Enum.join(dupes, ", ")}", []}
      clashes != [] -> {:error, :names, "#{Enum.join(clashes, ", ")} is a Core tool's name", []}
      true -> {:ok, entries}
    end
  end

  defp rejection(n, stage, reason, extra \\ []) do
    %{
      n: n,
      stage: stage,
      reason: reason,
      violations: Keyword.get(extra, :violations, []),
      selftests: Keyword.get(extra, :selftests, [])
    }
  end

  # ── approval, activation, revert ──

  @doc """
  A token for `subject` from the configured approval (in the app: only
  after `Rho.Dyn.Approval.Biometric.confirm/1`).
  """
  @spec request_approval(Approval.subject(), atom()) :: {:ok, Approval.token()} | {:error, term()}
  def request_approval(subject, keeper \\ @keeper) do
    with {:ok, %{approval: approval}} <- Registry.config(keeper), do: approval.request(subject)
  end

  @doc "Drops the pending candidate `n` (no approval needed: nothing that runs changes)."
  @spec discard(pos_integer(), atom()) :: :ok | {:error, :not_pending | :not_running}
  def discard(n, keeper \\ @keeper) do
    if GenServer.whereis(keeper), do: Keeper.discard(keeper, n), else: {:error, :not_running}
  end

  @doc "Activates candidate generation `n` (it goes on probation). Needs an approval token."
  @spec activate(pos_integer(), Approval.token(), atom()) ::
          {:ok, Generation.t()} | {:error, term()}
  def activate(n, token, keeper \\ @keeper), do: Keeper.activate(keeper, n, token)

  @doc "Makes generation `n` (one that was active once, or 0) current. Needs an approval token."
  @spec revert_to(non_neg_integer(), Approval.token(), atom()) ::
          {:ok, Generation.t()} | {:error, term()}
  def revert_to(n, token, keeper \\ @keeper), do: Keeper.revert_to(keeper, n, token)

  # ── state ──

  @doc "The current generation, its status, its parent, the mode and the pending candidate."
  @spec status(atom()) :: map()
  def status(keeper \\ @keeper) do
    if GenServer.whereis(keeper),
      do: Keeper.status(keeper),
      else: %{generation: 0, status: :proven, parent: nil, mode: :off, pending: nil}
  end

  @doc "Did this launch start in safe mode (no Dyn module loaded)?"
  @spec safe_mode?(atom()) :: boolean()
  def safe_mode?(keeper \\ @keeper), do: Registry.mode(keeper) == :safe

  @doc """
  The generation this launch is rebuilding for a new Core in the
  background (nothing of it is registered yet), or nil.
  """
  @spec rebuilding(atom()) :: pos_integer() | nil
  def rebuilding(keeper \\ @keeper), do: Registry.rebuilding(keeper)

  @doc "Returns once this launch's background rebuild is over (at once if none runs)."
  @spec await_rebuild(atom()) :: :ok
  def await_rebuild(keeper \\ @keeper) do
    if GenServer.whereis(keeper), do: Keeper.await_rebuild(keeper), else: :ok
  end

  @doc "Every generation, newest first, generation 0 last."
  @spec generations(atom()) :: [Generation.t()]
  def generations(keeper \\ @keeper), do: with_dir(keeper, [], &Store.generations/1)

  @spec generation(non_neg_integer(), atom()) :: {:ok, Generation.t()} | {:error, term()}
  def generation(n, keeper \\ @keeper),
    do: with_dir(keeper, {:error, :not_running}, &Store.generation(&1, n))

  @doc "Generation `n`'s unified diff against its parent."
  @spec diff(non_neg_integer(), atom()) :: String.t()
  def diff(n, keeper \\ @keeper), do: with_dir(keeper, "", &Store.diff(&1, n))

  @doc """
  The last `limit` reports (crashes, reverts, safe mode, load failures),
  oldest first. Values are as stored (strings for atoms).
  """
  @spec log(pos_integer(), atom()) :: [map()]
  def log(limit \\ 50, keeper \\ @keeper) do
    with_dir(keeper, [], fn dir -> Enum.map(Store.log(dir, limit), &log_entry/1) end)
  end

  defp log_entry(entry) do
    for key <- @log_keys, Map.has_key?(entry, Atom.to_string(key)), into: %{} do
      {key, entry[Atom.to_string(key)]}
    end
  end

  @doc "`{:rho_dyn, event}` for every crash, revert, activation, proof, candidate, safe mode."
  @spec subscribe(atom()) :: :ok
  def subscribe(keeper \\ @keeper) do
    if GenServer.whereis(keeper), do: Keeper.subscribe(keeper), else: :ok
  end

  # ── the registry ──

  @spec lookup(Registry.key(), atom()) :: {:ok, module()} | :error
  def lookup(key, keeper \\ @keeper), do: Registry.lookup(key, keeper)

  @doc "The current generation's tools, `[{name, module}]`."
  @spec tools(atom()) :: [{String.t(), module()}]
  def tools(keeper \\ @keeper), do: Registry.all(:tool, keeper)

  @doc "The current generation's screens, `[{name, module}]`."
  @spec screens(atom()) :: [{String.t(), module()}]
  def screens(keeper \\ @keeper), do: Registry.all(:screen, keeper)

  # ── containment ──

  @doc """
  Has the app's Keeper watch `pid` if `module` is Dyn code, so its crash
  counts against the generation (`Rho.ToolRunner` calls this for every
  tool call, through `Rho.Dyn.Source`; a host calls it for a process of
  its own that runs Dyn code, a screen say). Its abnormal exit is a
  crash; exiting with `{:rho_crash, text}` (`Rho.Untrusted.crash/3`)
  reports `text` as it is. A no-op for Core modules.
  """
  @spec watch(pid(), module()) :: :ok
  def watch(pid, module) do
    if dyn_module?(module), do: Keeper.watch(@keeper, pid, module), else: :ok
  end

  @doc """
  Stops watching `pid` (`watch/2`): its exit is no longer a crash, for a
  host that stops a process it watched in an orderly way.
  """
  @spec unwatch(pid()) :: :ok
  def unwatch(pid), do: Keeper.unwatch(@keeper, pid)

  @spec dyn_module?(module()) :: boolean()
  def dyn_module?(module), do: Compiler.generation_of(module) != nil

  @doc "Generation `n`'s sources (what runs, for the current one)."
  @spec sources(non_neg_integer(), atom()) :: %{String.t() => String.t()}
  def sources(n, keeper \\ @keeper), do: with_dir(keeper, %{}, &Store.sources(&1, n))

  # ── the agent's view ──

  @doc """
  The system prompt section that explains the Dyn layer and its tools to
  the agent: rho's rules, the screen rules of the host's
  `Rho.Dyn.Screens`, then the host's own (`Rho.Dyn.Config`'s `:guide`).
  """
  @spec agent_guide() :: String.t()
  def agent_guide do
    ns = Config.namespace_name()
    screens = Config.screens().guide()
    allowed = Enum.map_join(Config.allowed(), ", ", &"`#{&1}`")

    """
    ## Changing yourself: the Dyn layer

    You can add your own tools#{if screens, do: " and screens"}. They live in the Dyn layer: \
    Elixir sources you edit in a staging copy with `dyn_files`, `dyn_read`, `dyn_write`, \
    `dyn_edit`, `dyn_delete` and `dyn_reset` (back to what runs now).

    Rules (a static check enforces them and reports file:line):
    - Each `.ex` file holds one or more `defmodule #{ns}.<Name>`, nothing else at the \
    top level. Refer to your other modules as `#{ns}.<Name>` (an `alias` is fine).
    - `Path` is fine except `Path.wildcard`. No `File`, `System.cmd`, `Port`, `:os`, `Code`, \
    `Module`, `:code`, `Node`#{nif_rule()}; no tracing, suspending or listing processes; no \
    `:logger`, `:telemetry` or `Logger.add_translator`/`configure` (logging with `Logger.info` \
    is fine); no \
    `:persistent_term.put`; no `defmacro`, `quote` or `unquote`; no `apply`/`spawn` on a \
    module held in a variable; no `String.to_atom`. None of the app's own modules except \
    #{allowed}.
    - A tool: `@behaviour Rho.Tool` with `name/0` (lowercase, unique, not a core \
    tool's), `description/0`, `parameter_schema/0` (JSON Schema, string keys), \
    `run(args, ctx)` returning `{:ok, result}` or `{:error, reason}`, and a `selftest/0` \
    returning `:ok` (required; keep it pure and fast).
    #{screens || "- `selftest/0` is optional for other modules."}

    The cycle: `dyn_propose` (with a one-line rationale) checks, compiles and selftests the \
    staging copy as a new generation and shows its diff. Nothing changes yet: the human \
    approves it #{Rho.Config.hint(:approve)}; you can't activate it yourself (if the \
    user turned approve all on, it activates as soon as it passes: the result says \
    which). Once active \
    it is on probation: 3 crashes within 60 s, or an app launch that dies, revert it to the \
    previous generation automatically. `dyn_status` shows what runs, the pending proposal and \
    recent crash reports: read them, fix the sources, propose again.
    #{host_guide()}\
    """
  end

  defp host_guide do
    case Config.guide() do
      nil -> ""
      text -> "\n" <> text
    end
  end

  # The guide names the ban on Mob's native layer only while the check has it.
  defp nif_rule do
    if Map.has_key?(Check.policy().banned_erlang, :mob_nif),
      do: ", `:mob_nif` (use Mob's modules)",
      else: ""
  end

  defp with_dir(keeper, default, fun) do
    case Registry.config(keeper) do
      {:ok, %{dir: dir}} -> fun.(dir)
      {:error, :not_running} -> default
    end
  end
end
