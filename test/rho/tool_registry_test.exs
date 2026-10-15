defmodule Rho.ToolRegistryTest do
  # async: false: the registry is a named singleton.
  use ExUnit.Case, async: false

  alias Rho.Test.Tools.Crash
  alias Rho.Test.Tools.Echo
  alias Rho.Test.Tools.Slow
  alias Rho.ToolRegistry

  defmodule Source do
    @moduledoc "A tool source whose set the test switches, as a Dyn generation would."
    @behaviour ToolRegistry.Source

    def put(tools), do: :persistent_term.put(__MODULE__, tools)

    @impl true
    def tools, do: :persistent_term.get(__MODULE__, [])

    @impl true
    def lookup(name) do
      case List.keyfind(tools(), name, 0) do
        {^name, mod} -> {:ok, mod}
        nil -> :error
      end
    end

    @impl true
    def watch(pid, module) do
      if test = :persistent_term.get({__MODULE__, :test}, nil),
        do: send(test, {:watch, pid, module})

      :ok
    end
  end

  defmodule Other do
    @moduledoc "A second source, asked after the first."
    @behaviour ToolRegistry.Source
    @impl true
    def tools, do: [{"echo", Crash}, {"slow", Slow}]
    @impl true
    def lookup("slow"), do: {:ok, Slow}
    def lookup(_), do: :error
  end

  setup do
    on_exit(fn ->
      :persistent_term.erase(Source)
      :persistent_term.erase({Source, :test})
    end)
  end

  test "core tools from the host, and new ones at runtime" do
    start_supervised!({ToolRegistry, tools: [Echo]})

    assert ToolRegistry.core_tools() == [Echo]
    assert {:ok, Echo} = ToolRegistry.lookup("echo")

    assert :ok = ToolRegistry.register(Crash)
    assert {:ok, Crash} = ToolRegistry.lookup("crash")
    assert {:error, :not_a_tool} = ToolRegistry.register(String)

    :ok = ToolRegistry.unregister("crash")
    assert ToolRegistry.lookup("crash") == :error
    assert ToolRegistry.list() == [Echo]
  end

  test "without a host list, rho's own tools" do
    start_supervised!(ToolRegistry)
    assert ToolRegistry.list() == [Rho.Tools.ReadArtifact, Rho.Tools.Todo]
  end

  test "sources are asked on every call: a switch shows at once; table, then sources in order" do
    start_supervised!({ToolRegistry, tools: [Echo], tool_sources: [Source, Other]})
    Source.put([{"crash", Crash}, {"echo", Slow}])

    # the table's echo wins over both sources'; crash from Source, slow from Other
    assert ToolRegistry.list() == [Crash, Echo, Slow]
    assert {:ok, Echo} = ToolRegistry.lookup("echo")
    assert {:ok, Crash} = ToolRegistry.lookup("crash")
    assert {:ok, Slow} = ToolRegistry.lookup("slow")

    Source.put([])
    assert ToolRegistry.list() == [Echo, Slow]
    assert ToolRegistry.lookup("crash") == :error
  end

  test "sources hear of every tool call before it runs, in its task" do
    start_supervised!({ToolRegistry, tools: [Echo], tool_sources: [Source, Other]})
    :persistent_term.put({Source, :test}, self())
    sup = start_supervised!(Task.Supervisor)

    call = %{"id" => "c1", "name" => "echo", "arguments" => %{"text" => "hi"}}
    task = Rho.ToolRunner.start(sup, self(), Echo, call, &Rho.ToolRunner.allow_all/2, %{})

    assert Task.await(task) == {:ok, "hi"}
    pid = task.pid
    assert_received {:watch, ^pid, Echo}
    assert_received {:tool_running, ^pid}
  end
end
