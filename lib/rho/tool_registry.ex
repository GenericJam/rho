defmodule Rho.ToolRegistry do
  @moduledoc """
  The tools the agent can call, by name, from three places:

    * the host's **core tools**, given when the registry starts (the
      `:tools` option, else `config :rho, :tools`, else
      `builtin_tools/0`), and
    * tools **registered at runtime** (`register/1`, `unregister/1`); both
      live in one ETS table owned by this process;
    * **sources** (`Rho.ToolRegistry.Source`, the `:tool_sources` option or
      `config :rho, :tool_sources`): modules asked on every call, so a
      source whose tool set changes (a generation of agent-written tools
      switching) changes what is offered at once, with nothing to
      register or unregister. This is where agent-written (Dyn) tools
      plug in.

  A name in the table always wins over a source's, and an earlier source
  over a later one. The loop reads the list at the start of every model
  call, so a new tool is offered from the next call on.
  """
  use GenServer

  alias Rho.Tool

  @table __MODULE__
  # The core list and the sources, in a table of their own owned by this
  # process: they go with it, so a stopped registry has none.
  @meta Module.concat(__MODULE__, Meta)
  @builtin [Rho.Tools.ReadArtifact, Rho.Tools.Todo]

  @doc "Started by `Rho.Supervisor`. Options: `:tools`, `:tool_sources` (see the moduledoc)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Adds `module` under its `c:Rho.Tool.name/0`, replacing a tool of that name.
  `{:error, :not_a_tool}` if it doesn't implement `Rho.Tool`.
  """
  @spec register(module()) :: :ok | {:error, :not_a_tool}
  def register(module), do: GenServer.call(__MODULE__, {:register, module})

  @doc "Removes the tool named `name` from the table (a source's tools aren't affected)."
  @spec unregister(String.t()) :: :ok
  def unregister(name), do: GenServer.call(__MODULE__, {:unregister, name})

  @doc "The tool module offered as `name`: the table's, else the first source's that has it."
  @spec lookup(String.t()) :: {:ok, module()} | :error
  def lookup(name) do
    case :ets.lookup(@table, name) do
      [{^name, module}] -> {:ok, module}
      [] -> Enum.find_value(sources(), :error, &found(&1.lookup(name)))
    end
  end

  defp found({:ok, module}), do: {:ok, module}
  defp found(_), do: nil

  @doc "All tool modules (the table's, then the sources'), sorted by name."
  @spec list() :: [module()]
  def list do
    core = :ets.tab2list(@table)

    from_sources =
      sources()
      |> Enum.flat_map(& &1.tools())
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.reject(fn {name, _mod} -> :ets.member(@table, name) end)

    (core ++ from_sources) |> Enum.sort() |> Enum.map(&elem(&1, 1))
  end

  @doc "The core tools the registry started with (a source's tool may not take their names)."
  @spec core_tools() :: [module()]
  def core_tools, do: meta(:core)

  @doc "The registry's sources, in order (none while the registry isn't running)."
  @spec sources() :: [module()]
  def sources, do: meta(:sources)

  # No table (the registry isn't running, or died between the check and the
  # read) means none.
  defp meta(key) do
    @meta |> :ets.lookup(key) |> Keyword.get(key, [])
  rescue
    ArgumentError -> []
  end

  @doc "rho's own tools: `read_artifact` (paging a cut tool output) and `todo`."
  @spec builtin_tools() :: [module()]
  def builtin_tools, do: @builtin

  @doc """
  Tells every source a tool call of `module` is about to run in `pid`
  (`Rho.ToolRunner` calls it), so a source can watch its own tools' calls
  (crashes, timeouts) through `c:Rho.ToolRegistry.Source.watch/2`.
  """
  @spec watch(pid(), module()) :: :ok
  def watch(pid, module) do
    for source <- sources(), function_exported?(source, :watch, 2), do: source.watch(pid, module)
    :ok
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    :ets.new(@meta, [:named_table, :protected, read_concurrency: true])
    core = Keyword.get_lazy(opts, :tools, fn -> Application.get_env(:rho, :tools, @builtin) end)

    sources =
      Keyword.get_lazy(opts, :tool_sources, fn -> Application.get_env(:rho, :tool_sources, []) end)

    Enum.each(sources, &Code.ensure_loaded!/1)
    :ets.insert(@meta, core: core, sources: sources)
    Enum.each(core, &put/1)
    {:ok, nil}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    if Tool.tool?(module),
      do: {:reply, put(module), state},
      else: {:reply, {:error, :not_a_tool}, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    :ets.delete(@table, name)
    {:reply, :ok, state}
  end

  # A Dyn module's name is read bounded, not in this process (`Rho.Tool.offered_name/1`).
  defp put(module) do
    case Tool.offered_name(module) do
      nil ->
        {:error, :not_a_tool}

      name ->
        true = :ets.insert(@table, {name, module})
        :ok
    end
  end
end

defmodule Rho.ToolRegistry.Source do
  @moduledoc """
  A source of tools the registry asks on every call, for tool sets that
  change while the app runs (the Dyn layer's generations, `Rho.Dyn.Source`:
  tools the agent writes, compiles and activates on the device). Configure with
  `{Rho.Supervisor, tool_sources: [MySource]}` or
  `config :rho, :tool_sources, [MySource]`.

  `c:tools/0` and `c:lookup/1` run in the caller's process (the loop, at the
  start of every model call) and must be cheap: read an ETS table or a
  persistent term, don't call a process that may be busy.
  """

  @doc "The source's current tools as `{name, module}`."
  @callback tools() :: [{String.t(), module()}]

  @doc "The source's current tool named `name`."
  @callback lookup(name :: String.t()) :: {:ok, module()} | :error

  @doc """
  A call of `module` (any tool, not only this source's) is about to run in
  the task `pid`: a source that keeps its tools on probation can monitor
  it. Runs in that task, before the tool; it must return quickly.
  """
  @callback watch(pid(), module()) :: :ok

  @optional_callbacks watch: 2
end
