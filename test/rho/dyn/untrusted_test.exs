defmodule Rho.Dyn.UntrustedTest do
  # Dyn code may give the Core terms whose code runs when they're turned
  # into text: an exception's message/1, its struct's Inspect, String.Chars
  # or Jason.Encoder. None of it may run in a trusted process (the loop, the
  # Keeper, a proposal's caller). Every hook here reports where it ran
  # (`{:probe, hook, pid}`) and then hangs, raises or exits, as asked.
  use ExUnit.Case, async: false

  import Rho.Test.Dyn
  import Rho.Test.LoopHelpers

  alias Rho.Dyn
  alias Rho.Dyn.Keeper
  alias Rho.Loop
  alias Rho.Session
  alias Rho.Test.FakeLLM

  @moduletag :tmp_dir
  @moduletag :capture_log

  @probe :rho_untrusted_probe
  @description :rho_untrusted_description

  setup do
    purge_all()
    Process.register(self(), @probe)

    on_exit(fn ->
      :persistent_term.erase(@description)
      purge_all()
    end)
  end

  @hostile """
  defmodule TestHost.Dyn.Hostile do
    defexception [:message, mode: :plain]

    def probe(hook) do
      send(:rho_untrusted_probe, {:probe, hook, self()})
    rescue
      ArgumentError -> :ok
    end

    def act(:loop), do: Process.sleep(:infinity)
    def act(:raise), do: raise(ArgumentError, "hostile code raised")

    def act(:exit),
      do: exit({%__MODULE__{message: "from message/1", mode: :loop}, [{__MODULE__, :act, 1, []}]})

    def act(_mode), do: :ok

    @impl true
    def message(e) do
      probe(:message)
      act(e.mode)
      "hostile message/1"
    end

    def compile_time, do: raise(__MODULE__, message: "compile boom", mode: :exit)

    def linked_exit do
      spawn_link(fn ->
        exit({%__MODULE__{message: "linked compile", mode: :loop}, [{__MODULE__, :act, 1, []}]})
      end)

      Process.sleep(:infinity)
    end

    defimpl Inspect do
      def inspect(e, _opts) do
        TestHost.Dyn.Hostile.probe(:inspect)
        TestHost.Dyn.Hostile.act(e.mode)
        "#Hostile<>"
      end
    end

    defimpl String.Chars do
      def to_string(e) do
        TestHost.Dyn.Hostile.probe(:to_string)
        TestHost.Dyn.Hostile.act(e.mode)
        "hostile"
      end
    end

    defimpl Jason.Encoder do
      def encode(e, _opts) do
        TestHost.Dyn.Hostile.probe(:json)
        TestHost.Dyn.Hostile.act(e.mode)
        ~s("hostile json")
      end
    end
  end
  """

  @hostile_tool """
  defmodule TestHost.Dyn.HostileTool do
    @behaviour Rho.Tool
    alias TestHost.Dyn.Hostile

    def name, do: "hostile"

    def description do
      case :persistent_term.get(:rho_untrusted_description, :fine) do
        :fine ->
          "A hostile tool."

        mode ->
          Hostile.probe(:description)
          Hostile.act(mode)
          "never"
      end
    end

    def parameter_schema, do: %{"type" => "object", "properties" => %{}}
    def timeout_ms, do: :soon
    def selftest, do: :ok

    def run(%{"mode" => "raise_plain"}, _ctx), do: raise(Hostile, message: "field", mode: :plain)
    def run(%{"mode" => "raise_loop"}, _ctx), do: raise(Hostile, message: "boom", mode: :loop)
    def run(%{"mode" => "raise_exit"}, _ctx), do: raise(Hostile, message: "boom2", mode: :exit)

    def run(%{"mode" => "linked"}, _ctx) do
      spawn_link(fn ->
        exit({%Hostile{message: "linked", mode: :loop}, [{Hostile, :act, 1, []}]})
      end)

      Process.sleep(:infinity)
    end

    def run(%{"mode" => "output"}, _ctx), do: {:ok, %Hostile{message: "out", mode: :loop}}
    def run(%{"mode" => "error"}, _ctx), do: {:error, %Hostile{message: "err", mode: :loop}}

    def run(%{"mode" => "details"}, _ctx) do
      details = %{
        card: %Hostile{message: "d", mode: :loop},
        list: [%Hostile{message: "x", mode: :plain}],
        fun: fn -> :ok end
      }

      {:ok, {:details, "see the details", details}}
    end
  end
  """

  @fragile """
  defmodule TestHost.Dyn.Fragile do
    use Mob.Screen
    alias TestHost.Dyn.Hostile

    def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :text, "fragile")}

    def render(assigns) do
      ~MOB\"\"\"
      <Column padding={:space_lg}>
        <Text text={assigns.text} text_color={:on_surface} />
      </Column>
      \"\"\"
    end

    def crash(:raise), do: raise(Hostile, message: "screen boom", mode: :loop)
    def crash(:exit), do: exit(%Hostile{message: "screen exit", mode: :loop})
    def crash(:bytes), do: raise(<<255, 254>>)
  end
  """

  # Probes from `pids` received so far.
  defp probes_from(pids) do
    receive_probes([]) |> Enum.filter(fn {_hook, pid} -> pid in pids end)
  end

  defp receive_probes(acc) do
    receive do
      {:probe, hook, pid} -> receive_probes([{hook, pid} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp results(events) do
    for %{type: :message_end, entry: %{"message" => %{"role" => "toolResult"} = m}} <- events,
        into: %{},
        do: {m["toolCallId"], {Session.text(m["content"]), m["isError"]}}
  end

  defp hostile_loop(dir, calls, opts \\ []) do
    start_keeper(dir)
    activate!(%{"hostile.ex" => @hostile, "hostile_tool.ex" => @hostile_tool})
    {:ok, tool} = Dyn.lookup({:tool, "hostile"})
    script = [calls, [{:text, "done"}]]
    start_loop(dir, script, [tools: [Rho.Test.Tools.Echo, tool]] ++ opts)
  end

  test "a Dyn tool's crash reaches the loop as text; none of its code runs in the loop",
       %{tmp_dir: dir} do
    calls = [
      {:tool_call, "plain", "hostile", %{"mode" => "raise_plain"}},
      {:tool_call, "loop", "hostile", %{"mode" => "raise_loop"}},
      {:tool_call, "exit", "hostile", %{"mode" => "raise_exit"}},
      {:tool_call, "linked", "hostile", %{"mode" => "linked"}}
    ]

    %{loop: loop} = hostile_loop(dir, calls)
    :ok = Loop.prompt(loop, "go")
    events = collect(5_000)
    results = results(events)

    # The task formats its own crash: the agent reads what message/1 says.
    assert results["plain"] ==
             {"Tool crashed: ** (TestHost.Dyn.G1.Hostile) hostile message/1", true}

    # message/1 hangs (raise_loop) or exits with another hostile exception
    # (raise_exit) while the task formats it: its fields are used instead.
    assert {"Tool crashed: ** (TestHost.Dyn.G1.Hostile) boom\n" <> _, true} = results["loop"]
    assert {"Tool crashed: ** (TestHost.Dyn.G1.Hostile) boom2\n" <> _, true} = results["exit"]

    # A linked process took the task down with a hostile reason: described in the loop.
    assert {"Tool crashed: ** (TestHost.Dyn.G1.Hostile) linked\n" <> stack, true} =
             results["linked"]

    assert stack =~ "TestHost.Dyn.G1.Hostile.act/1"
    assert List.last(events).reason == :done
    assert probes_from([loop]) == []
  end

  test "a Dyn tool's answer is plain data before it leaves its task", %{tmp_dir: dir} do
    calls = [
      {:tool_call, "output", "hostile", %{"mode" => "output"}},
      {:tool_call, "error", "hostile", %{"mode" => "error"}},
      {:tool_call, "details", "hostile", %{"mode" => "details"}}
    ]

    # The host keeps a Dyn tool's details whole: the loop JSON-encodes them.
    %{loop: loop} = hostile_loop(dir, calls, keep_details: fn _name, details -> details end)
    :ok = Loop.prompt(loop, "go")
    events = collect(5_000)
    results = results(events)

    assert {output, false} = results["output"]
    assert Jason.decode!(output) == %{"message" => "out", "mode" => "loop"}
    assert {error, true} = results["error"]
    assert Jason.decode!(error) == %{"message" => "err", "mode" => "loop"}

    assert %{details: details} =
             Enum.find(events, &match?(%{type: :tool_execution_end, id: "details"}, &1))

    assert %{card: %{message: "d", mode: :loop}, list: [%{message: "x", mode: :plain}]} =
             details

    refute is_struct(details.card)
    assert "#Function<" <> _ = details.fun

    # No Dyn protocol ran anywhere: the task encoded plain data.
    assert receive_probes([]) == []
    assert List.last(events).reason == :done
    _ = loop
  end

  test "a Dyn tool whose declaration hangs is left out; the loop never runs it",
       %{tmp_dir: dir} do
    %{loop: loop, llm: llm} = hostile_loop(dir, [{:text, "no tools"}])
    {:ok, tool} = Dyn.lookup({:tool, "hostile"})
    :persistent_term.put(@description, :loop)

    :ok = Loop.prompt(loop, "go")
    events = collect(5_000)
    assert List.last(events).reason == :done

    assert [request | _] = FakeLLM.requests(llm)
    assert Enum.map(request.tools, & &1.name) == ["echo"]
    assert Rho.Tool.info(tool) == :error
    assert probes_from([loop]) == []
  end

  test "a bad timeout_ms/0 of a Dyn tool means the default, read once outside the caller",
       %{tmp_dir: dir} do
    start_keeper(dir)
    activate!(%{"hostile.ex" => @hostile, "hostile_tool.ex" => @hostile_tool})
    {:ok, tool} = Dyn.lookup({:tool, "hostile"})

    assert Rho.Tool.timeout_ms(tool) == Rho.Tool.default_timeout_ms()
    assert {:ok, %{name: "hostile", description: "A hostile tool."}} = Rho.Tool.info(tool)
  end

  test "a Dyn screen crashing with a hostile exception or struct is a crash the Keeper describes",
       %{tmp_dir: dir} do
    start_keeper(dir, crash_limit: 3)
    n = activate!(%{"hostile.ex" => @hostile, "fragile.ex" => @fragile})
    :ok = Dyn.subscribe()
    keeper = Process.whereis(Keeper)
    {:ok, mod} = Dyn.lookup({:screen, "Fragile"})
    test = self()

    crash = fn how ->
      spawn(fn ->
        {:ok, _} = mod.mount(%{}, %{}, Mob.Socket.new(mod))
        send(test, :mounted)
        receive do: (:crash -> mod.crash(how))
      end)
      |> tap(fn _ -> assert_receive :mounted end)
      |> send(:crash)
    end

    crash.(:raise)
    assert %{gen: ^n, kind: :crash, reason: raised} = await_dyn(:crash)
    assert raised =~ "** (TestHost.Dyn.G#{n}.Hostile) screen boom"
    assert %{generation: ^n} = Dyn.status()

    crash.(:exit)
    assert %{kind: :crash, reason: exited} = await_dyn(:crash)
    assert exited =~ ~s(message: "screen exit")
    assert exited =~ "__struct__: TestHost.Dyn.G#{n}.Hostile"

    # A message that isn't UTF-8 is still logged (as JSON) and reported.
    crash.(:bytes)
    assert %{kind: :crash, reason: bytes} = await_dyn(:crash)
    assert bytes =~ "** (RuntimeError) <<255, 254>>"

    # All three counted: the generation is reverted.
    assert %{from: ^n, to: 0, crashes: crashes} = await_dyn(:reverted)
    assert Enum.map(crashes, & &1.reason) == [raised, exited, bytes]
    assert %{generation: 0} = Dyn.status()
    assert ["crash", "crash", "crash", "reverted"] = Enum.map(Dyn.log(), & &1.type)
    assert probes_from([keeper]) == []
  end

  # The proposal runs in a task, so a hang in its caller fails the test
  # instead of stalling it.
  defp propose_in_task(files) do
    task =
      Task.async(fn ->
        :ok = Dyn.stage_reset()
        Enum.each(files, fn {path, source} -> :ok = Dyn.stage_put(path, source) end)
        Dyn.propose("hostile")
      end)

    {Task.await(task, 10_000), task.pid}
  end

  test "a selftest failing with a hostile exception or exit is a plain rejection",
       %{tmp_dir: dir} do
    start_keeper(dir)

    raising = """
    defmodule TestHost.Dyn.SelfRaise do
      def selftest, do: raise(TestHost.Dyn.Hostile, message: "selftest boom", mode: :loop)
    end
    """

    linked = """
    defmodule TestHost.Dyn.SelfLinked do
      def selftest do
        Process.flag(:trap_exit, false)

        spawn_link(fn ->
          exit({%TestHost.Dyn.Hostile{message: "linked selftest", mode: :loop},
                [{TestHost.Dyn.Hostile, :act, 1, []}]})
        end)

        Process.sleep(:infinity)
      end
    end
    """

    {result, caller} =
      propose_in_task(%{"hostile.ex" => @hostile, "raise.ex" => raising, "linked.ex" => linked})

    assert {:error, %{stage: :selftest, reason: reason}} = result
    # Formatted in the test process; its message/1 hung, so its fields.
    assert reason =~ "TestHost.Dyn.SelfRaise: ** (TestHost.Dyn.G"
    assert reason =~ "Hostile) selftest boom"
    # The test process died of a linked hostile exit: described by the caller.
    assert reason =~ "TestHost.Dyn.SelfLinked: exited: ** (TestHost.Dyn.G"
    assert reason =~ "Hostile) linked selftest"
    assert probes_from([caller, self()]) == []
  end

  test "a compile that raises a hostile exception is a plain rejection", %{tmp_dir: dir} do
    start_keeper(dir)

    raising = """
    defmodule TestHost.Dyn.Raises do
      @boom TestHost.Dyn.Hostile.compile_time()
      def boom, do: @boom
    end
    """

    {result, caller} = propose_in_task(%{"a_hostile.ex" => @hostile, "raises.ex" => raising})

    assert {:error, %{stage: :compile, reason: reason}} = result
    assert reason =~ "raises.ex: ** (TestHost.Dyn.G"
    assert reason =~ "Hostile) compile boom"
    assert probes_from([caller, self()]) == []
  end

  test "a compile whose process a hostile exit takes down is a plain rejection",
       %{tmp_dir: dir} do
    start_keeper(dir)

    linked = """
    defmodule TestHost.Dyn.Links do
      @gone TestHost.Dyn.Hostile.linked_exit()
      def gone, do: @gone
    end
    """

    {result, caller} = propose_in_task(%{"a_hostile.ex" => @hostile, "links.ex" => linked})

    assert {:error, %{stage: :compile, reason: reason}} = result
    assert reason =~ "the compiler process died: ** (TestHost.Dyn.G"
    assert reason =~ "Hostile) linked compile"
    assert probes_from([caller, self()]) == []
  end
end
