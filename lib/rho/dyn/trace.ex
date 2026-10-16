defmodule Rho.Dyn.Trace do
  @moduledoc """
  An Elixir compiler tracer for Dyn compiles (`Code.put_compiler_option(:tracers, ...)`):
  which modules of the generation a file needs **at compile time**, so
  `Rho.Dyn.Compiler` knows when a file compiled for an earlier
  generation can be reused as it is (`Rho.Dyn.Reuse`).

  A file needs module `M` at compile time when it expands `%M{}`, imports
  or requires `M`, uses one of its macros, or calls `M` outside a function
  body (in a module attribute, say): its compiled code then depends on
  `M`'s code, not only on its name. Calls inside function bodies only name
  `M` and don't count.

  It records only while `collect/2` runs in the calling process (the
  tracer runs in the process that expands the code), so other compiles in
  the VM are untouched. `collect/2` also reports the modules the file
  defined (`:on_module`); a caller that sees fewer than it compiled treats
  the file's needs as unknown.

  It is also the gate on what a Dyn compile may define, before anything
  loads (`guard/3`, in the compiling process): when a module's definition
  starts (`:defmodule`) it is reported to the compiler, which undoes what
  the compile defined outside the generation, and refused (the compile of
  that file fails) unless it is `<ns>.G<n>.*` (the namespace,
  `Rho.Dyn.Config`) or named as a protocol's implementation for one
  (`Inspect.<ns>.G<n>.X`, with
  `Inspect` a protocol). A `Protocol.derive/2` for a stdlib type or a
  library macro's module elsewhere never replaces anything.
  """

  alias Rho.Dyn.Config

  @key {__MODULE__, :file}
  @guard {__MODULE__, :guard}

  # Events whose module is needed at compile time wherever they happen.
  @always [
    :import,
    :require,
    :struct_expansion,
    :remote_macro,
    :imported_macro,
    :imported_quoted
  ]
  # Function calls: only outside a function body.
  @calls [:remote_function, :imported_function]

  @doc "Adds this tracer to the compiler's (once per VM)."
  @spec install() :: :ok
  def install do
    tracers = Code.get_compiler_option(:tracers)
    unless __MODULE__ in tracers, do: Code.put_compiler_option(:tracers, tracers ++ [__MODULE__])
    :ok
  end

  @doc """
  Runs `fun` (one file's compile) and returns its result with what it
  traced: the modules defined and the modules named `prefix*` it needed
  at compile time.
  """
  @spec collect(String.t(), (-> result)) ::
          {result, %{defined: MapSet.t(module()), needs: MapSet.t(module())}}
        when result: term()
  def collect(prefix, fun) do
    Process.put(@key, %{prefix: prefix, defined: MapSet.new(), needs: MapSet.new()})

    try do
      result = fun.()
      %{defined: defined, needs: needs} = Process.get(@key)
      {result, %{defined: defined, needs: needs}}
    after
      Process.delete(@key)
    end
  end

  @doc """
  From now on in this process, every module definition that starts is
  sent to `pid` as `{ref, :defmodule, module, prior}` (`prior`: the md5
  and file of the version loaded under that name until then, or nil), and
  one outside generation `n` (see the moduledoc) raises instead of being
  defined.
  """
  @spec guard(pos_integer(), pid(), reference()) :: :ok
  def guard(n, pid, ref) do
    ns = Config.namespace_name()
    Process.put(@guard, %{own: "Elixir.#{ns}.G#{n}.", ns: ns, pid: pid, ref: ref})
    :ok
  end

  @doc """
  May a compile for generation `own` (`"Elixir.Dyn.G<n>."`) define
  `mod`: one of its own, or a protocol's implementation for one?
  """
  @spec allowed?(module(), String.t()) :: boolean()
  def allowed?(mod, "Elixir." <> own_name = own) do
    name = Atom.to_string(mod)

    String.starts_with?(name, own) or
      case :binary.split(name, "." <> own_name) do
        ["Elixir." <> _ = protocol, rest] when rest != "" ->
          protocol?(String.to_existing_atom(protocol))

        _ ->
          false
      end
  rescue
    ArgumentError -> false
  end

  defp protocol?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :__protocol__, 1)
  end

  defp check_module(%{module: mod}) do
    case Process.get(@guard) do
      nil ->
        :ok

      %{own: own, ns: ns, pid: pid, ref: ref} ->
        prior =
          if :erlang.module_loaded(mod), do: {mod.module_info(:md5), :code.which(mod)}

        send(pid, {ref, :defmodule, mod, prior})

        unless allowed?(mod, own) do
          raise "defines #{inspect(mod)}: a Dyn generation may only define " <>
                  "#{ns}.* modules and protocol implementations for them"
        end

        :ok
    end
  end

  @doc false
  @spec trace(tuple() | atom(), Macro.Env.t()) :: :ok
  # `:defmodule` is an atom on Elixir 1.20, `{:defmodule, meta}` before.
  def trace(:defmodule, env), do: check_module(env)
  def trace({:defmodule, _meta}, env), do: check_module(env)

  def trace(event, env) do
    case Process.get(@key) do
      nil -> :ok
      acc -> Process.put(@key, record(event, env, acc))
    end

    :ok
  end

  defp record({:on_module, _bytecode, _}, env, acc),
    do: %{acc | defined: MapSet.put(acc.defined, env.module)}

  defp record({kind, _meta, mod, _} = _event, _env, acc) when kind in @always,
    do: need(acc, mod)

  defp record({kind, _meta, mod, _name, _arity}, _env, acc) when kind in @always,
    do: need(acc, mod)

  defp record({kind, _meta, mod, _name, _arity}, %{function: nil}, acc) when kind in @calls,
    do: need(acc, mod)

  defp record(_event, _env, acc), do: acc

  defp need(acc, mod) when is_atom(mod) do
    if String.starts_with?(Atom.to_string(mod), acc.prefix),
      do: %{acc | needs: MapSet.put(acc.needs, mod)},
      else: acc
  end

  defp need(acc, _mod), do: acc
end
