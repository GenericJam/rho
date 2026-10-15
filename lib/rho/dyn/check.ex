defmodule Rho.Dyn.Check do
  @moduledoc """
  The static check every staged file passes before it is compiled (the
  pipeline's step 2, see `Rho.Dyn`), and `beam/2`, a second pass over the
  compiled binaries.

  **Defence in depth, not a sandbox.** The BEAM has no capability isolation:
  code that really wants to can still reach a forbidden function (an atom
  handed to it as data and called without parentheses, a function value
  smuggled in through a message). This check stops the obvious and the
  accidental and makes the rest deliberate. What actually keeps the phone
  safe is the rest of the pipeline: versioned modules, selftests in
  contained processes, screen-lock approval, probation and automatic revert.

  Source rules (each violation carries `file:line`; `<ns>` is the
  namespace, `Rho.Dyn.Config`):

    * only `defmodule` at the top level of a file, named `<ns>.*`
      (`<ns>.G<n>` is reserved for compiled generations); no
      `defprotocol`, macros (`defmacro`, `quote`, `unquote`) or `@on_load`;
      `defimpl` only inside a module and for a Dyn module (`for:` left out,
      or a `<ns>.*` module), so the implementation is compiled as
      `<Protocol>.<ns>.G<n>.X`, which `beam/2` lets through;
    * no calls to, or references of: `:code`, `Code`, `Module`, `Port`,
      `Node`, `Mob.Dist`, `MobDeliver` (the Core's own updates), `File`
      (Dyn code's files go through a Core module the host allows, inside
      its roots), `Path.wildcard/2`,
      `:init`, `:file`, `:os.cmd`, `:erlang.halt` and the other code-loading
      and node-control functions listed in the `:partial` defaults,
      `System.halt/stop/cmd`, `Application.start/stop/put_env`, dynamic
      atoms (`String.to_atom`, ...), `:erlang.binary_to_term` (it makes any
      atom, a forbidden one too, and funs), and `Protocol.derive` /
      `consolidate` (they define or replace implementations for any type,
      the stdlib's too; `@derive` and `defimpl` for a Dyn module are the way);
    * nothing that controls or watches other processes or the VM: tracing
      (`:erlang.trace*`, `:trace`, `:seq_trace`, `:dbg`, `:erl_tracer`),
      `:erlang.suspend_process/resume_process`, `system_monitor` /
      `system_profile`, `:erts_debug`, `:erts_internal`, `:observer_backend`,
      and listing every process (`Process.list/0`, `:erlang.processes/0`);
      `:persistent_term` only to read (`put` / `erase` change VM-wide state
      and trigger a global GC);
    * not the router's name, `:mob_screen`: whatever arrives there is handed
      to the front host as a native reply, so a front screen sending to it
      could forge a capability grant (a picked file); nor `:mob_file_result`,
      the tag of a raw native file result, which the front host decodes and
      grants when one arrives (`:forging`);
    * the Core's own modules (`Rho.*` and the host's `:core` prefixes) are
      off limits except `Rho.Tool` (the behaviour a Dyn tool implements)
      and the host's `:allowed` ones, and so is the sign-in store
      (`MobSecureStore`, its NIF `:mob_secure_store_nif`); of Mob only the
      app-facing modules (screens, UI, theming, device features; the
      `:gated` defaults), and of `Mob.Screen` not the functions that start
      or drive screens outside the front (`start_root/3`, ...); the
      capability plugins (`MobCamera`, `MobLocation`, `MobSensors`,
      `MobMishka`, `MobThemes`, ...), `Nx` and `NxTfliteMob` are allowed;
    * `Process.exit/2` only on `self()`; `apply/3`, `spawn/3` and friends
      only with a module written out literally; no calls on a module held in
      a variable (`mod.fun()`); no `:"Elixir.Foo"` atoms; modules with
      forbidden functions (`System`, `:erlang`, `Process`, ...) may be
      called but not passed around as values or imported.

  Aliases (`alias System, as: S`), multi-aliases and `~MOB` templates (whose
  `{...}` expressions only exist once the sigil expands, `:sigils`) are
  resolved first, so `S.halt()` and `<Text text={System.halt()} />` are
  caught too.

  The lists are a host seam (`config :rho, :dyn, check: [...]`, merged over
  `defaults/0`: Operator's lists minus the entries naming Operator's own
  code; see `Rho.Dyn.Config`).
  """

  alias Rho.Dyn.Config

  @type violation :: %{file: String.t(), line: non_neg_integer() | nil, message: String.t()}
  @type target :: :dyn | :dynamic | {:elixir, String.t()} | {:erlang, atom()}

  # Core code the compiler injects into Dyn modules (see Compiler).
  @injected ["Rho.Dyn.Keeper"]

  # Mob's app-facing modules. Not the router, renderer, listener, composite
  # or component registries (they'd let a screen replace the root view the
  # toggle sits in, or run its code in the shell), nor `Mob.Storage`, nor
  # `Mob.Link` (registering would take every app:// link from the
  # terminal: sign-ins, handoffs, the update server). And the built-in
  # themes a screen may hand `Mob.Theme.set/1`.
  @mob_allowed ~w(Mob.Screen Mob.Socket Mob.Sigil Mob.UI Mob.Style Mob.Theme Mob.SizeClass
                  Mob.List Mob.Font Mob.Motion Mob.Haptic Mob.Clipboard Mob.Alert Mob.Share
                  Mob.Event Mob.Canvas Mob.Speech Mob.State Mob.Permissions Mob.Device
                  Mob.Audio Mob.Files Mob.Notification Mob.WebView Mob.Wake
                  Mob.Scene3d Mob.Scene3d.Projection Mob.Scene3d.IR Mob.Scene3d.IR.Entity
                  Mob.Scene3d.IR.Transform Mob.Scene3d.IR.Material Mob.Scene3d.IR.Model
                  Mob.Scene3d.IR.Animation Mob.Scene3d.IR.Camera Mob.Scene3d.IR.Light
                  Mob.Scene3d.IR.Environment
                  Mob.Theme.Dark Mob.Theme.Light Mob.Theme.Adaptive)

  # Banned outright (the module and everything below it).
  @banned_elixir %{
    "Code" => "compiles or evaluates code",
    "Module" => "defines or changes modules at runtime",
    "Port" => "runs OS processes",
    "GenServer" => "reaches named Core processes directly",
    "Registry" => "discovers processes outside the front host",
    "Node" => "controls distribution",
    "File" => "touches the file system directly",
    "IEx" => "is the interactive shell",
    "Mix" => "is the build tool",
    "Mob.Dist" => "controls distribution",
    "Mob.Test" => "drives the app remotely",
    "Mob.Storage" => "reads and writes the app's files (the Dyn store, the settings)",
    "MobDeliver" => "installs and proves the Core's own updates (only the Mac releases the Core)",
    "MobSecureStore" => "holds the sign-ins"
  }

  @banned_erlang %{
    code: "loads and purges code",
    mob_secure_store_nif: "holds the sign-ins",
    init: "stops or restarts the node",
    file: "touches the file system",
    prim_file: "touches the file system",
    filelib: "touches the file system",
    erl_prim_loader: "loads code",
    net_kernel: "controls distribution",
    net_adm: "controls distribution",
    rpc: "calls other nodes",
    erpc: "calls other nodes",
    erl_eval: "evaluates code",
    compile: "compiles code",
    erl_ddll: "loads drivers",
    c: "is the shell",
    shell: "is the shell",
    gen: "calls arbitrary processes through the raw OTP protocol",
    gen_server: "calls arbitrary OTP servers",
    global: "discovers globally registered processes",
    sys: "reaches into other processes' state",
    application: "starts and stops applications",
    seq_trace: "traces other processes",
    dbg: "traces other processes",
    trace: "traces other processes",
    erl_tracer: "traces other processes",
    erts_debug: "reaches into the VM's internals",
    erts_internal: "reaches into the VM's internals",
    observer_backend: "inspects other processes and the VM"
  }

  # Allowed modules with forbidden functions (may only be called directly).
  @partial %{
    System => ~w(halt stop cmd shell restart put_env delete_env trap_signal untrap_signal)a,
    Application =>
      ~w(start stop load unload ensure_started ensure_all_started ensure_loaded put_env
         put_all_env delete_env)a,
    String => ~w(to_atom to_existing_atom)a,
    List => ~w(to_atom to_existing_atom)a,
    Function => ~w(capture)a,
    Protocol => ~w(derive __derive__ consolidate)a,
    Process => ~w(list info whereis registered)a,
    Path => [:wildcard],
    Kernel => [],
    Mob.Screen => ~w(start_root start_link dispatch get_socket get_current_module get_nav_history
         get_screen_pid)a,
    :erlang => ~w(halt open_port load_module purge_module delete_module check_old_code load_nif
         set_cookie system_flag make_fun binary_to_atom list_to_atom binary_to_existing_atom
         binary_to_term
         list_to_existing_atom suspend_process resume_process trace trace_pattern
         trace_delivered trace_info system_monitor system_profile processes process_info whereis
         registered)a,
    :os => ~w(cmd putenv unsetenv set_signal)a,
    :persistent_term => ~w(put erase)a
  }

  # Atoms front code could forge a native reply with (a capability grant).
  @forging %{
    mob_screen:
      ":mob_screen is the router: native replies reach a front screen only through its host",
    mob_file_result:
      ":mob_file_result is native's own reply: the front host decodes it, so match the " <>
        "decoded message ({:audio, :recorded, %{path: ...}}, ...)"
  }

  # `Mob.Wake.register(id, trigger, {Mod, :fun})` / `{Mod, :fun, args}`
  # calls the handler later, outside any check: checked as if called now.
  @handlers [{Mob.Wake, :register, 3, 2}]

  # `{module, function, arity}` taking a module + function as data (index 0, 1).
  @mfa [
    {{:elixir, "Kernel"}, :apply, 3},
    {{:elixir, "Kernel"}, :spawn, 3},
    {{:elixir, "Kernel"}, :spawn_link, 3},
    {{:elixir, "Kernel"}, :spawn_monitor, 3},
    {{:elixir, "Process"}, :spawn, 4},
    {{:elixir, "Task"}, :start, 3},
    {{:elixir, "Task"}, :start_link, 3},
    {{:elixir, "Task"}, :async, 3},
    {{:erlang, :erlang}, :apply, 3},
    {{:erlang, :erlang}, :spawn, 3},
    {{:erlang, :erlang}, :spawn_link, 3},
    {{:erlang, :erlang}, :spawn_monitor, 3},
    {{:erlang, :erlang}, :spawn_opt, 4}
  ]

  @remote_spawns [{{:erlang, :erlang}, :spawn, 4}, {{:erlang, :erlang}, :spawn_link, 4}]
  @exits [{{:elixir, "Process"}, :exit, 2}, {{:erlang, :erlang}, :exit, 2}]
  @kernel_mfa [:apply, :spawn, :spawn_link, :spawn_monitor]
  @forbidden_forms %{
    defmacro: "defines a macro",
    receive: "blocks the shared front host and can intercept Core messages",
    defmacrop: "defines a macro",
    quote: "uses quote (macros are not allowed)",
    unquote: "uses unquote (macros are not allowed)",
    unquote_splicing: "uses unquote_splicing (macros are not allowed)",
    defprotocol: "defines a protocol"
  }

  @doc """
  The default lists, as `config :rho, :dyn, check: [...]` takes them:
  Operator's, except for the entries that name Operator's own code (its
  sign-in NIF `:operator_secure_store`, and the caller-side functions of
  `Operator.Core.Files`), which its config adds. The host's entries are
  merged over these, keys written as modules or strings alike (a `nil`
  value drops one; `:handlers` replaces the list).
  """
  @spec defaults() :: keyword()
  def defaults do
    [
      banned: @banned_elixir,
      banned_erlang: @banned_erlang,
      partial: @partial,
      gated: %{"Mob" => @mob_allowed},
      forging: @forging,
      sigils: %{sigil_MOB: Mob.Sigil},
      handlers: @handlers
    ]
  end

  @doc "The template sigils whose expressions are code (`:sigils`), as their macro names."
  @spec sigils() :: [atom()]
  def sigils, do: Map.keys(merge(defaults()[:sigils], Config.check()[:sigils], & &1))

  @doc "The check's rules as they apply now: the defaults with the host's config over them."
  @spec policy() :: map()
  def policy do
    defaults = defaults()
    host = Config.check()
    merged = fn key, norm -> merge(defaults[key], host[key], norm) end
    name_key = fn {mod, value} -> {Config.name(mod), value} end

    handlers =
      for {mod, fun, arity, index} <- Keyword.get(host, :handlers, defaults[:handlers]),
          do: {{target(mod), fun, arity}, index}

    %{
      ns: Config.namespace_name(),
      ns_segs: Config.namespace_segments(),
      core: Config.core(),
      allowed: Config.allowed(),
      banned: merged.(:banned, name_key),
      banned_erlang: merged.(:banned_erlang, & &1),
      partial: merged.(:partial, fn {mod, funs} -> {target(mod), funs} end),
      gated:
        Map.new(merged.(:gated, name_key), fn {prefix, mods} ->
          {prefix, Enum.map(mods, &Config.name/1)}
        end),
      forging: merged.(:forging, & &1),
      sigils: merged.(:sigils, & &1),
      handlers: handlers
    }
  end

  # The host's map over the default, both with their keys normalised by
  # `norm` first (so `File` and `"File"` are one key); `nil` drops an entry.
  defp merge(default, host, norm) do
    default
    |> Map.new(norm)
    |> Map.merge(Map.new(host || %{}, norm))
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  # A module as the check names it: `MyApp.Files` / "MyApp.Files" is Elixir's, `:os` Erlang's.
  defp target(name) when is_binary(name), do: {:elixir, Config.name(name)}

  defp target(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> name -> {:elixir, name}
      _ -> {:erlang, atom}
    end
  end

  @doc """
  Parses and checks `sources` (`%{relative_path => source}`). Returns the
  parsed files, or every violation found.
  """
  @spec run(%{String.t() => String.t()}) ::
          {:ok, [{String.t(), Macro.t()}]} | {:error, [violation()]}
  def run(sources) do
    policy = policy()

    {parsed, violations} =
      sources
      |> Enum.sort()
      |> Enum.map_reduce([], fn {file, source}, acc ->
        case parse(file, source) do
          {:ok, ast} -> {{file, ast}, acc ++ check_file(file, ast, policy)}
          {:error, violation} -> {nil, acc ++ [violation]}
        end
      end)

    if violations == [], do: {:ok, parsed}, else: {:error, violations}
  end

  @doc """
  The backstop on compiled generation `n`: every module of the result is
  the generation's (`<ns>.G<n>.*`) or a protocol implementation for one of
  them, named as Elixir names it (`Inspect.<ns>.G<n>.X`, from a `defimpl`
  or a library's `use`), and none may call a forbidden function (import
  table) or name a forbidden module (atom table), whatever macro produced
  the code.
  """
  @spec beam([{module(), binary()}], pos_integer()) :: :ok | {:error, [violation()]}
  def beam(binaries, n) do
    policy = policy()
    own = "#{policy.ns}.G#{n}."
    mods = MapSet.new(binaries, &elem(&1, 0))

    violations =
      for {mod, bin} <- binaries,
          {:ok, {^mod, [imports: imports, atoms: atoms, attributes: attributes]}} <-
            [:beam_lib.chunks(bin, [:imports, :atoms, :attributes])],
          message <-
            beam_name(mod, attributes, own, mods, policy) ++
              beam_atoms(atoms, own, policy) ++ beam_imports(imports, policy),
          do: %{file: inspect(mod), line: nil, message: message <> " (in the compiled code)"}

    if violations == [], do: :ok, else: {:error, violations}
  end

  defp beam_name(mod, attributes, own, mods, policy) do
    if String.starts_with?(inspect(mod), own) or
         impl_of_own?(mod, attributes[:__impl__], own, mods),
       do: [],
       else: [
         "is outside #{policy.ns}: only a protocol implementation for a Dyn module may be"
       ]
  end

  @doc """
  Is `mod` (`bin`) one of generation `n`'s modules, or a protocol
  implementation for one of the build's (`mods`), named as Elixir names it?
  """
  @spec generation_module?(module(), binary(), pos_integer(), MapSet.t(module())) :: boolean()
  def generation_module?(mod, bin, n, mods) do
    case :beam_lib.chunks(bin, [:attributes]) do
      {:ok, {^mod, [attributes: attributes]}} ->
        ns = Config.namespace_name()
        beam_name(mod, attributes, "#{ns}.G#{n}.", mods, %{ns: ns}) == []

      _ ->
        false
    end
  end

  defp impl_of_own?(mod, [protocol: protocol, for: target], own, mods) do
    MapSet.member?(mods, target) and String.starts_with?(inspect(target), own) and
      Module.concat(protocol, target) == mod
  end

  defp impl_of_own?(_mod, _impl, _own, _mods), do: false

  @spec format([violation()]) :: String.t()
  def format(violations) do
    Enum.map_join(violations, "\n", fn
      %{file: f, line: nil, message: m} -> "#{f}: #{m}"
      %{file: f, line: l, message: m} -> "#{f}:#{l}: #{m}"
    end)
  end

  # ── parsing and top level ──

  defp parse(file, source) do
    case Code.string_to_quoted(source, file: file, emit_warnings: false) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {meta, message, token}} ->
        {:error,
         %{file: file, line: line(meta), message: "syntax error: #{text(message)}#{token}"}}
    end
  end

  defp text({prefix, suffix}), do: "#{prefix}#{suffix}"
  defp text(message), do: to_string(message)

  defp line(meta) when is_list(meta), do: meta[:line]
  defp line(line) when is_integer(line), do: line
  defp line(_), do: nil

  defp check_file(file, ast, policy) do
    forms =
      case ast do
        {:__block__, _, forms} -> forms
        form -> [form]
      end

    ctx = %{file: file, aliases: aliases(ast, policy), expanded: false, policy: policy}

    violations =
      if forms == [],
        do: [violation(ctx, [], "defines no module")],
        else: Enum.reduce(forms, [], &top_level(&1, ctx, &2))

    Enum.reverse(violations)
  end

  defp top_level({:defmodule, meta, [name, body]}, ctx, acc) do
    ns = ctx.policy.ns

    acc =
      case dyn_segment(name, ctx.policy) do
        {:ok, seg} ->
          if reserved?(Atom.to_string(seg)),
            do: add(acc, ctx, meta, "#{ns}.G<n> is reserved for compiled generations"),
            else: acc

        :error ->
          add(
            acc,
            ctx,
            meta,
            "defines #{Macro.to_string(name)}: Dyn modules must be #{ns}.*"
          )
      end

    walk(body, ctx, acc)
  end

  defp top_level(form, ctx, acc),
    do: add(acc, ctx, meta(form), "only defmodule is allowed at the top level of a file")

  # `<ns>.Seg...` written out: the first segment below the namespace.
  defp dyn_segment({:__aliases__, _, segs}, %{ns_segs: ns_segs}) when is_list(segs) do
    case Enum.split(segs, length(ns_segs)) do
      {^ns_segs, [seg | _]} when is_atom(seg) -> {:ok, seg}
      _ -> :error
    end
  end

  defp dyn_segment(_name, _policy), do: :error

  # `G` and digits: a compiled generation's segment.
  defp reserved?("G" <> digits),
    do: digits != "" and Enum.all?(String.to_charlist(digits), &(&1 in ?0..?9))

  defp reserved?(_segment), do: false

  # ── the walk ──

  # `a |> f(b)` is checked as `f(a, b)`, so arity-specific rules see it.
  defp walk({:|>, _, [left, {call, meta, args}]}, ctx, acc) when is_list(args),
    do: walk({call, meta, [left | args]}, ctx, acc)

  # &Mod.fun/arity
  defp walk({:&, meta, [{:/, _, [{{:., _, [recv, fun]}, _, []}, arity]}]}, ctx, acc)
       when is_atom(fun) and is_integer(arity) do
    remote(recv, fun, arity, meta, ctx, acc)
  end

  # &apply/3 and friends
  defp walk({:&, meta, [{:/, _, [{name, _, context}, 3]}]}, ctx, acc)
       when name in @kernel_mfa and is_atom(context),
       do: add(acc, ctx, meta, "captures #{name}/3: call it directly with a literal module")

  defp walk({{:., _, [recv, fun]}, meta, args}, ctx, acc) when is_atom(fun) and is_list(args) do
    {args, acc} = router_args(args, meta, ctx, acc)
    acc = remote(recv, fun, args, meta, ctx, acc)

    case module_ref(recv, ctx) do
      :none ->
        walk(args, ctx, walk(recv, ctx, acc))

      targets ->
        mfa? = Enum.any?(targets, &({&1, fun, length(args)} in @mfa))
        walk(if(mfa?, do: mfa_rest(args, ctx), else: args), ctx, acc)
    end
  end

  defp walk({:defmodule, meta, [name, body]}, ctx, acc) do
    acc =
      case name do
        {:__aliases__, _, [head | _]} when is_atom(head) and head != :"Elixir" -> acc
        _ -> add(acc, ctx, meta, "nested module names must be plain aliases")
      end

    walk(body, ctx, acc)
  end

  defp walk({form, meta, [target | _]}, ctx, acc) when form in [:alias, :require] do
    verb = if form == :alias, do: "aliases", else: "requires"

    target
    |> alias_targets(ctx.aliases)
    |> Enum.reduce(acc, fn t, acc ->
      case classify(t, ctx.policy) do
        {:banned, why} -> add(acc, ctx, meta, "#{verb} #{name(t)}, which #{why}")
        _ -> acc
      end
    end)
  end

  defp walk({form, meta, [target | opts]}, ctx, acc) when form in [:import, :use] do
    acc =
      Enum.reduce(resolve(target, ctx.aliases), acc, fn t, acc ->
        case classify(t, ctx.policy) do
          :ok -> acc
          {:banned, why} -> add(acc, ctx, meta, "#{form}s #{name(t)}, which #{why}")
          {:partial, _} when form == :use or t == {:elixir, "Kernel"} -> acc
          {:partial, _} -> add(acc, ctx, meta, "#{form}s #{name(t)}: call its functions directly")
        end
      end)

    walk(opts, ctx, acc)
  end

  defp walk({:defdelegate, meta, [head, opts]}, ctx, acc) when is_list(opts) do
    {fun, arity} = head_name(head)
    fun = Keyword.get(opts, :as, fun)

    case module_ref(Keyword.get(opts, :to), ctx) do
      :none -> add(acc, ctx, meta, "defdelegate needs a module written out in to:")
      targets -> Enum.reduce(targets, acc, &check_call(&1, fun, arity, meta, ctx, &2))
    end
  end

  # An implementation for a Dyn module: compiled as
  # `<Protocol>.<ns>.G<n>.X`, inside the generation (`beam/2`).
  defp walk({:defimpl, meta, [protocol, [do: _] = body]}, ctx, acc),
    do: walk([protocol, body], ctx, impl_target(nil, meta, ctx, acc))

  defp walk({:defimpl, meta, [protocol, [for: target], [do: _] = body]}, ctx, acc),
    do: walk([protocol, body], ctx, impl_target(target, meta, ctx, acc))

  defp walk({:defimpl, meta, args}, ctx, acc) when is_list(args),
    do: walk(args, ctx, add(acc, ctx, meta, defimpl_message(ctx)))

  defp walk({:@, meta, [{:on_load, _, _}]}, ctx, acc),
    do: add(acc, ctx, meta, "@on_load runs code outside the selftest")

  defp walk({form, meta, args}, ctx, acc)
       when is_map_key(@forbidden_forms, form) and is_list(args) do
    walk(args, ctx, add(acc, ctx, meta, @forbidden_forms[form]))
  end

  defp walk({form, meta, [_, _, _] = args}, ctx, acc) when form in @kernel_mfa do
    acc = special({:elixir, "Kernel"}, form, args, meta, ctx, acc)
    walk(mfa_rest(args, ctx), ctx, acc)
  end

  defp walk({:__aliases__, meta, _} = alias_ast, ctx, acc),
    do: Enum.reduce(resolve(alias_ast, ctx.aliases), acc, &value(&1, meta, ctx, &2))

  # a variable
  defp walk({name, _meta, context}, _ctx, acc) when is_atom(name) and is_atom(context), do: acc

  # A template sigil (`~MOB`): its expressions are code once it expands.
  defp walk({sigil, meta, [{:<<>>, _, [template]}, _mods]} = node, ctx, acc)
       when is_atom(sigil) and is_binary(template) do
    case Map.fetch(ctx.policy.sigils, sigil) do
      {:ok, module} ->
        case expand_sigil(node, module, ctx) do
          {:ok, expanded} -> walk(expanded, %{ctx | expanded: true}, acc)
          {:error, message} -> add(acc, ctx, meta, "#{sigil_name(sigil)} template: " <> message)
        end

      :error ->
        walk_form(node, ctx, acc)
    end
  end

  defp walk({_form, _meta, args} = node, ctx, acc) when is_list(args),
    do: walk_form(node, ctx, acc)

  defp walk({left, right}, ctx, acc), do: walk(right, ctx, walk(left, ctx, acc))
  defp walk(list, ctx, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, ctx, &2))

  # The router's registered name, and the raw native result's tag: whatever
  # carries them reaches the front host as a native reply (a capability
  # grant), so front code using them could forge one. As a call's argument
  # they're reported with the call's line (`router_args/4`); anywhere else,
  # here.
  defp walk(atom, ctx, acc) when is_atom(atom) do
    case Map.fetch(ctx.policy.forging, atom) do
      {:ok, why} ->
        add(acc, ctx, [], why)

      :error ->
        case resolve_atom(atom) do
          {:elixir, _} = t when ctx.expanded -> value(t, [], ctx, acc)
          {:elixir, _} -> add(acc, ctx, [], "#{inspect(atom)}: write module names as aliases")
          _ -> acc
        end
    end
  end

  defp walk(_literal, _ctx, acc), do: acc

  defp walk_form({form, meta, args}, ctx, acc) do
    {args, acc} = router_args(args, meta, ctx, acc)
    walk(args, ctx, walk(form, ctx, acc))
  end

  defp router_args(args, meta, ctx, acc) do
    forging = ctx.policy.forging

    case Enum.find(args, &(is_atom(&1) and is_map_key(forging, &1))) do
      nil -> {args, acc}
      atom -> {Enum.reject(args, &(&1 == atom)), add(acc, ctx, meta, forging[atom])}
    end
  end

  # ── calls ──

  defp remote(recv, fun, args, meta, ctx, acc) do
    case module_ref(recv, ctx) do
      :none ->
        if is_list(args) and not Keyword.get(meta, :no_parens, false),
          do:
            add(acc, ctx, meta, "calls #{fun} on a module held in a variable (dynamic dispatch)"),
          else: acc

      targets ->
        acc =
          if written_atom?(recv, meta, ctx),
            do: add(acc, ctx, meta, "#{inspect(recv)}: write module names as aliases"),
            else: acc

        Enum.reduce(targets, acc, &check_call(&1, fun, args, meta, ctx, &2))
    end
  end

  # `:"Elixir.Foo".bar()` as the agent wrote it; the parser itself calls
  # `Kernel.to_string/1` for interpolation and `Access.get/2` for brackets.
  defp written_atom?(recv, meta, ctx) do
    is_atom(recv) and not ctx.expanded and match?({:elixir, _}, resolve_atom(recv)) and
      not Keyword.get(meta, :from_interpolation, false) and
      not Keyword.get(meta, :from_brackets, false)
  end

  # `args` is the argument list, or an arity (a capture, a defdelegate).
  defp check_call(target, fun, args, meta, ctx, acc) do
    arity = if is_list(args), do: length(args), else: args
    acc = special(target, fun, args, meta, ctx, acc)

    case classify(target, ctx.policy) do
      {:banned, why} ->
        add(acc, ctx, meta, "calls #{name(target)}.#{fun}/#{arity}, which #{why}")

      {:partial, banned} ->
        if fun in banned,
          do:
            add(acc, ctx, meta, "calls #{name(target)}.#{fun}/#{arity}, which Dyn code may not"),
          else: acc

      :ok ->
        acc
    end
  end

  defp special(target, fun, args, meta, ctx, acc) do
    key = {target, fun, if(is_list(args), do: length(args), else: args)}
    handler = List.keyfind(ctx.policy.handlers, key, 0)

    cond do
      handler && is_list(args) ->
        handler_check(key, Enum.at(args, elem(handler, 1)), meta, ctx, acc)

      key in @mfa and is_list(args) ->
        mfa(target, fun, args, meta, ctx, acc)

      message = special_message(key, args, handler) ->
        add(acc, ctx, meta, message)

      true ->
        acc
    end
  end

  defp handler_check({target, fun, _arity}, {mod, f}, meta, ctx, acc),
    do: mfa(target, fun, [mod, f], meta, ctx, acc)

  defp handler_check({target, fun, _arity}, {:{}, _, [mod, f, extra]}, meta, ctx, acc),
    do: mfa(target, fun, [mod, f, extra], meta, ctx, acc)

  defp handler_check({target, fun, arity}, _handler, meta, ctx, acc) do
    add(
      acc,
      ctx,
      meta,
      "#{name(target)}.#{fun}/#{arity} takes a literal {Module, :function} handler"
    )
  end

  # `args` is an arity when the function is captured or applied, else the call's args.
  defp special_message({target, fun, arity} = key, args, handler) when is_integer(args) do
    cond do
      handler -> "#{name(target)}.#{fun}/#{arity} may only be called directly"
      key in @remote_spawns -> "#{name(target)}.#{fun}/#{arity} spawns on another node"
      key in @mfa -> "#{name(target)}.#{fun}/#{arity} may only be called directly"
      key in @exits -> "#{name(target)}.exit/2 may only be called directly"
      true -> nil
    end
  end

  defp special_message({target, fun, arity} = key, args, _handler) do
    cond do
      key in @remote_spawns ->
        "#{name(target)}.#{fun}/#{arity} spawns on another node"

      key in @exits and not match?([{:self, _, []} | _], args) ->
        "#{name(target)}.exit/2 may only exit self()"

      true ->
        nil
    end
  end

  defp mfa(target, fun, [mod, f | rest], meta, ctx, acc) do
    arity =
      case rest do
        [list | _] when is_list(list) -> length(list)
        _ -> 0
      end

    case module_ref(mod, ctx) do
      :none ->
        add(acc, ctx, meta, "#{name(target)}.#{fun} with a module held in a variable")

      targets when is_atom(f) ->
        Enum.reduce(targets, acc, &check_call(&1, f, arity, meta, ctx, &2))

      targets ->
        targets
        |> Enum.reject(&(classify(&1, ctx.policy) == :ok))
        |> Enum.reduce(acc, fn t, acc ->
          add(acc, ctx, meta, "#{name(target)}.#{fun} on #{name(t)} with a computed function")
        end)
    end
  end

  # An MFA call's literal module was checked as a call target, not a value.
  defp mfa_rest([mod | rest] = args, ctx) do
    if module_ref(mod, ctx) == :none, do: args, else: rest
  end

  # A module used as a value (not called): fine unless it is forbidden or
  # has forbidden functions (passing it around is how they'd get called).
  defp value(target, meta, ctx, acc) do
    case classify(target, ctx.policy) do
      :ok -> acc
      {:banned, why} -> add(acc, ctx, meta, "refers to #{name(target)}, which #{why}")
      {:partial, _} -> add(acc, ctx, meta, "uses #{name(target)} as a value: call it directly")
    end
  end

  # `defimpl`'s `for:`: left out (the module it's in), `__MODULE__`, or a
  # Dyn module written out in full. Never through an alias: the file's
  # aliases ignore scope, so a short name could be a Dyn module's in one
  # module and a stdlib one (`Atom`) where the defimpl is. `beam/2` checks
  # what it compiled to, and the compiler undoes anything else it loaded.
  defp impl_target(nil, _meta, _ctx, acc), do: acc
  defp impl_target({:__MODULE__, _, c}, _meta, _ctx, acc) when is_atom(c), do: acc

  defp impl_target(target, meta, ctx, acc) do
    case dyn_segment(target, ctx.policy) do
      {:ok, seg} ->
        if reserved?(Atom.to_string(seg)) or Map.has_key?(ctx.aliases, hd(ctx.policy.ns_segs)),
          do: add(acc, ctx, meta, defimpl_message(ctx)),
          else: acc

      :error ->
        add(acc, ctx, meta, defimpl_message(ctx))
    end
  end

  defp defimpl_message(%{policy: %{ns: ns}}) do
    "defimpl: a protocol implementation must be for a Dyn module, written out in full " <>
      "(for: #{ns}.X, for: __MODULE__, or no for: inside the module)"
  end

  # ── module names ──

  @spec classify(target(), map()) :: :ok | {:banned, String.t()} | {:partial, [atom()]}
  defp classify(:dyn, _policy), do: :ok
  defp classify(:dynamic, _policy), do: {:banned, "isn't written out as a module name"}

  defp classify({:elixir, name} = t, policy) do
    cond do
      Config.under?(name, policy.ns) -> classify_dyn(name, policy.ns)
      core?(name, policy) -> classify_core(name, t, policy)
      prefix = gate(name, policy) -> classify_gated(name, t, prefix, policy)
      why = banned_elixir(name, policy) -> {:banned, why}
      Map.has_key?(policy.partial, t) -> {:partial, policy.partial[t]}
      true -> :ok
    end
  end

  defp classify({:erlang, mod} = t, policy) do
    cond do
      Map.has_key?(policy.banned_erlang, mod) -> {:banned, policy.banned_erlang[mod]}
      Map.has_key?(policy.partial, t) -> {:partial, policy.partial[t]}
      true -> :ok
    end
  end

  # The namespace, or a Dyn module (not a compiled generation's name).
  defp classify_dyn(ns, ns), do: :ok

  defp classify_dyn(name, ns) do
    rest = binary_part(name, byte_size(ns) + 1, byte_size(name) - byte_size(ns) - 1)

    if reserved?(rest |> String.split(".") |> hd()),
      do: {:banned, "is reserved for compiled generations"},
      else: :ok
  end

  defp classify_core(name, t, policy) do
    if name in policy.allowed,
      do: policy.partial |> Map.get(t) |> partial(),
      else: {:banned, "is the Core's own code (Dyn code may only use #{list(policy.allowed)})"}
  end

  defp classify_gated(name, t, prefix, policy) do
    cond do
      why = banned_elixir(name, policy) -> {:banned, why}
      name in policy.gated[prefix] -> policy.partial |> Map.get(t) |> partial()
      true -> {:banned, "is not one of #{prefix}'s app-facing modules"}
    end
  end

  defp partial(nil), do: :ok
  defp partial(banned), do: {:partial, banned}

  # Below a Core prefix (the prefix module itself is not the Core's code).
  defp core?(name, policy), do: Enum.any?(policy.core, &String.starts_with?(name, &1 <> "."))

  defp gate(name, policy),
    do: Enum.find(Map.keys(policy.gated), &String.starts_with?(name, &1 <> "."))

  defp banned_elixir(name, policy) do
    Enum.find_value(policy.banned, fn {banned, why} ->
      if Config.under?(name, banned), do: why
    end)
  end

  defp list([one]), do: one
  defp list(names), do: Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)

  defp name({:elixir, name}), do: name
  defp name({:erlang, mod}), do: inspect(mod)
  defp name(:dyn), do: "__MODULE__"
  defp name(:dynamic), do: "a computed module"

  defp module_ref({:__aliases__, _, _} = a, ctx), do: resolve(a, ctx.aliases)
  defp module_ref({:__MODULE__, _, c}, _ctx) when is_atom(c), do: [:dyn]

  defp module_ref(atom, _ctx) when is_atom(atom) and atom not in [nil, true, false],
    do: [resolve_atom(atom)]

  defp module_ref(_other, _ctx), do: :none

  defp resolve({:__aliases__, _, [:"Elixir" | rest]}, _aliases) when rest != [],
    do: [{:elixir, join(rest)}]

  defp resolve({:__aliases__, _, [head | tail]}, aliases) when is_atom(head) do
    literal = {:elixir, join([head | tail])}

    case Map.fetch(aliases, head) do
      {:ok, targets} -> Enum.uniq(Enum.map(targets, &extend(&1, tail)) ++ [literal])
      :error -> [literal]
    end
  end

  defp resolve({:__aliases__, _, [{:__MODULE__, _, c} | _]}, _aliases) when is_atom(c), do: [:dyn]
  defp resolve({:__MODULE__, _, c}, _aliases) when is_atom(c), do: [:dyn]
  defp resolve(atom, _aliases) when is_atom(atom), do: [resolve_atom(atom)]
  defp resolve(_other, _aliases), do: [:dynamic]

  defp resolve_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> name -> {:elixir, name}
      _ -> {:erlang, atom}
    end
  end

  defp extend(target, []), do: target
  defp extend(:dyn, _tail), do: :dyn
  defp extend({:elixir, name}, tail), do: {:elixir, name <> "." <> join(tail)}
  defp extend(_target, _tail), do: :dynamic

  defp join(segments), do: Enum.map_join(segments, ".", &Atom.to_string/1)

  # `alias A.{B, C}` → [A.B, A.C]; anything else → resolve/2.
  defp alias_targets({{:., _, [base, :{}]}, _, kids}, aliases) do
    for b <- resolve(base, aliases),
        {:__aliases__, _, segs} <- kids,
        do: extend(b, segs)
  end

  defp alias_targets(target, aliases), do: resolve(target, aliases)

  # Every alias the file declares (and the implicit one of each nested
  # module), file-wide. Aliases are lexically scoped and this ignores
  # scope, so an aliased name resolves to every target it was given *and*
  # to its literal self, and all of them are checked.
  defp aliases(ast, policy) do
    top = [hd(policy.ns_segs), :"Elixir"]

    {_, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [target]} = node, acc ->
          {node, put_alias(acc, target, nil)}

        {:alias, _, [target, opts]} = node, acc when is_list(opts) ->
          {node, put_alias(acc, target, Keyword.get(opts, :as))}

        {:defmodule, _, [{:__aliases__, _, [head | _]}, _]} = node, acc
        when is_atom(head) ->
          if head in top, do: {node, acc}, else: {node, Map.put(acc, head, [:dyn])}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp put_alias(acc, {{:., _, [base, :{}]}, _, kids}, _as) do
    Enum.reduce(kids, acc, fn
      {:__aliases__, _, segs}, acc when is_list(segs) ->
        short = List.last(segs)
        targets = for b <- resolve(base, acc), do: extend(b, segs)
        if is_atom(short), do: add_alias(acc, short, targets), else: acc

      _, acc ->
        acc
    end)
  end

  defp put_alias(acc, target, as) do
    short =
      case {as, target} do
        {{:__aliases__, _, [short]}, _} -> short
        {nil, {:__aliases__, _, segs}} -> List.last(segs)
        _ -> nil
      end

    if is_atom(short) and short != nil,
      do: add_alias(acc, short, resolve(target, acc)),
      else: acc
  end

  defp add_alias(acc, short, targets),
    do: Map.update(acc, short, targets, &Enum.uniq(&1 ++ targets))

  # ── template sigils (~MOB) ──

  # The template's `{...}` expressions are only code once the sigil expands,
  # so expand it with its module's own macro and check the result.
  defp expand_sigil({_, meta, _} = node, module, ctx) do
    # `assigns` counts as bound: the sigil wants it for `@field`, and
    # whether it really is in scope is the compiler's business, not this check's.
    env = %{
      __ENV__
      | file: ctx.file,
        line: meta[:line] || 1,
        module: nil,
        function: nil,
        versioned_vars: %{{:assigns, nil} => 0}
    }

    {:ok, env} = Macro.Env.define_require(env, meta, module)
    {:ok, env} = Macro.Env.define_import(env, meta, module, only: :macros)
    {:ok, Macro.expand_once(node, env)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp sigil_name(sigil) do
    case Atom.to_string(sigil) do
      "sigil_" <> name -> "~" <> name
      other -> other
    end
  end

  # ── compiled code ──

  defp beam_atoms(atoms, own, policy) do
    for {_, atom} <- atoms,
        why <- [beam_atom(atom, own, policy)],
        why != nil,
        do: why
  end

  defp beam_atom(atom, own, policy) do
    case Map.fetch(policy.forging, atom) do
      {:ok, why} ->
        why

      :error ->
        with "Elixir." <> name <- Atom.to_string(atom),
             why when is_binary(why) <- beam_module(name, own, policy) do
          "names #{name}, which #{why}"
        else
          _ -> nil
        end
    end
  end

  defp beam_module(name, own, policy) do
    cond do
      String.starts_with?(name, own) or name in @injected or name in policy.allowed -> nil
      core?(name, policy) or Config.under?(name, policy.ns) -> "is outside this generation"
      true -> banned_elixir(name, policy)
    end
  end

  defp beam_imports(imports, policy) do
    for {mod, fun, arity} <- imports,
        target <- [resolve_atom(mod)],
        why <- [beam_call(target, fun, policy)],
        why != nil,
        do: "calls #{name(target)}.#{fun}/#{arity}, which #{why}"
  end

  defp beam_call({:elixir, name} = t, fun, policy) do
    cond do
      fun in Map.get(policy.partial, t, []) -> "Dyn code may not call"
      core?(name, policy) or Config.under?(name, policy.ns) -> nil
      why = banned_elixir(name, policy) -> why
      true -> nil
    end
  end

  defp beam_call({:erlang, mod} = t, fun, policy) do
    cond do
      Map.has_key?(policy.banned_erlang, mod) -> policy.banned_erlang[mod]
      fun in Map.get(policy.partial, t, []) -> "Dyn code may not call"
      true -> nil
    end
  end

  # ── helpers ──

  defp head_name({:when, _, [head | _]}), do: head_name(head)
  defp head_name({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp head_name({name, _, _}) when is_atom(name), do: {name, 0}

  defp meta({_, meta, _}) when is_list(meta), do: meta
  defp meta(_), do: []

  defp violation(ctx, meta, message), do: %{file: ctx.file, line: meta[:line], message: message}
  defp add(acc, ctx, meta, message), do: [violation(ctx, meta, message) | acc]
end
