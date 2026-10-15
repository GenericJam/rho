defmodule Rho.Dyn.EngineTest do
  # Dyn generations load into the VM-wide code server.
  use ExUnit.Case, async: false

  import Rho.Test.Dyn

  alias Rho.Dyn
  alias Rho.Dyn.Compiler
  alias Rho.Dyn.Store
  alias Rho.ToolRegistry

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup do
    purge_all()
    on_exit(&purge_all/0)
  end

  defp counter(tag) do
    """
    defmodule TestHost.Dyn.Counter do
      alias TestHost.Dyn.Counter.Label

      def version, do: Label.tag()

      def wait do
        Process.sleep(200)
        {:done, version()}
      end
    end

    defmodule TestHost.Dyn.Counter.Label do
      def tag, do: #{inspect(tag)}
    end
    """
  end

  test "two generations of the same logical module load side by side and both run",
       %{tmp_dir: dir} do
    start_keeper(dir)

    n1 = activate!(%{"counter.ex" => counter("one")})
    {:ok, g1} = Dyn.lookup({:module, "Counter"})
    assert g1 == TestHost.Dyn.G1.Counter
    waiter = Task.async(fn -> g1.wait() end)

    n2 = activate!(%{"counter.ex" => counter("two")})
    {:ok, g2} = Dyn.lookup({:module, "Counter"})
    assert g2 == TestHost.Dyn.G2.Counter
    assert {n1, n2} == {1, 2}

    # Each generation's references were rewritten to its own modules.
    assert g1.version() == "one"
    assert g2.version() == "two"

    # A process already executing generation 1 keeps that generation's code.
    assert Task.await(waiter) == {:done, "one"}
  end

  test "a failing, hanging or memory-hungry selftest rejects the generation and leaves the current one",
       %{tmp_dir: dir} do
    start_keeper(dir, selftest_timeout_ms: 300, selftest_max_heap_mb: 8)
    n = activate!(%{"weather.ex" => tool("Weather", "weather")})
    {:ok, current} = Dyn.lookup({:tool, "weather"})

    for {selftest, expected} <- [
          {"{:error, :nope}", ~r/selftest\/0 returned \{:error, :nope\}/},
          {~s|raise "boom"|, ~r/RuntimeError.*boom/},
          {"(Process.sleep(:infinity); :ok)", ~r/timed out after 300 ms/},
          {"(1..10_000_000 |> Enum.to_list() |> length(); :ok)", ~r/killed: used more than 8 MB/}
        ] do
      :ok = Dyn.stage_reset()
      :ok = Dyn.stage_put("weather.ex", tool("Weather", "weather", selftest: selftest))

      assert {:error, %{stage: :selftest, n: bad, reason: reason, selftests: [result]}} =
               Dyn.propose("break it")

      assert reason =~ expected
      assert %{module: "TestHost.Dyn.Weather", kind: :tool, ok: false} = result
      assert Compiler.loaded(bad) == []
      assert {:ok, %{status: :rejected}} = Dyn.generation(bad)

      assert %{generation: ^n, pending: nil} = Dyn.status()
      assert Store.current(dir) == n
      assert Dyn.lookup({:tool, "weather"}) == {:ok, current}
    end
  end

  # Realistic screens (interpolation, brackets, ~MOB, compile-time attributes)
  # pass the static check and the compiled-code check.
  test "the bundled sample screens pass the whole pipeline", %{tmp_dir: dir} do
    start_keeper(dir)
    dir = Path.expand("../../fixtures/dyn_samples", __DIR__)
    files = Map.new(File.ls!(dir), &{&1, File.read!(Path.join(dir, &1))})

    %{selftests: tests, warnings: []} = propose!(files, "samples")

    assert Enum.map(tests, &{&1.module, &1.kind, &1.ok}) == [
             {"TestHost.Dyn.Checklist", :screen, true},
             {"TestHost.Dyn.Hello", :screen, true}
           ]
  end

  test "a static-check or compile failure is rejected with file and line", %{tmp_dir: dir} do
    start_keeper(dir)

    :ok =
      Dyn.stage_put(
        "evil.ex",
        "defmodule TestHost.Dyn.Evil do\n  def x, do: System.halt()\nend\n"
      )

    assert {:error, %{stage: :check, n: nil, reason: "evil.ex:2: calls System.halt/0" <> _}} =
             Dyn.propose("halt")

    # nothing was allocated for it
    assert Enum.map(Dyn.generations(), & &1.n) == [0]

    :ok = Dyn.stage_delete("evil.ex")

    :ok =
      Dyn.stage_put(
        "broken.ex",
        "defmodule TestHost.Dyn.Broken do\n  def x, do: %TestHost.Dyn.Nope{}\nend\n"
      )

    assert {:error, %{stage: :compile, n: n, reason: reason}} = Dyn.propose("broken")
    assert reason =~ "broken.ex:2:"
    assert reason =~ "TestHost.Dyn.G#{n}.Nope"
    assert Compiler.loaded(n) == []
  end

  test "the current generation's tools are the loop's tools; a revert takes them away",
       %{tmp_dir: dir} do
    start_supervised!({ToolRegistry, tool_sources: [Rho.Dyn.Source]})
    start_keeper(dir)
    n = activate!(%{"weather.ex" => tool("Weather", "weather")})

    assert {:ok, mod} = ToolRegistry.lookup("weather")
    assert Compiler.generation_of(mod) == n
    assert mod in ToolRegistry.list()
    assert Rho.Tools.Todo in ToolRegistry.list()
    assert mod.run(%{}, %{}) == {:ok, "ran weather"}

    # A Core tool's name can't be taken.
    :ok = Dyn.stage_put("my_todo.ex", tool("MyTodo", "todo"))
    assert {:error, %{stage: :names, reason: reason}} = Dyn.propose("shadow todo")
    assert reason =~ "todo is a Core tool's name"

    {:ok, token} = Dyn.request_approval({:revert_to, 0})
    assert {:ok, %{n: 0}} = Dyn.revert_to(0, token)
    assert ToolRegistry.lookup("weather") == :error
    refute mod in ToolRegistry.list()
  end

  test "screens must mount and render; a live screen's crash is reported", %{tmp_dir: dir} do
    start_keeper(dir)
    :ok = Dyn.subscribe()

    bad = """
    defmodule TestHost.Dyn.Bad do
      use Mob.Screen
      def mount(_params, _session, socket), do: {:ok, socket}
      def render(_assigns), do: :nope
    end
    """

    :ok = Dyn.stage_put("bad.ex", bad)
    assert {:error, %{stage: :selftest, reason: reason}} = Dyn.propose("bad screen")
    assert reason =~ "render/1 must return a view tree"

    :ok = Dyn.stage_delete("bad.ex")
    n = activate!(%{"notes.ex" => screen("Notes", "hello")})
    {:ok, gen} = Dyn.generation(n)

    assert [%{kind: :screen, ok: true, detail: "screen: mounted and rendered 2 nodes"}] =
             gen.selftests

    assert [{"Notes", mod}] = Dyn.screens()

    # A screen process, as mob's router runs one: mount, then a crash.
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = mod.mount(%{}, %{}, Mob.Socket.new(mod))
        send(test, :mounted)
        receive do: (:crash -> exit(:boom))
      end)

    assert_receive :mounted
    send(pid, :crash)
    assert %{gen: ^n, module: "TestHost.Dyn.Notes", kind: :crash} = await_dyn(:crash)
  end

  test "a protocol implementation for a Dyn module is part of its generation, and goes with it",
       %{tmp_dir: dir} do
    start_keeper(dir)

    source = """
    defmodule TestHost.Dyn.Card do
      defstruct [:title]

      defimpl String.Chars do
        def to_string(card), do: "card " <> card.title
      end

      defimpl Inspect, for: TestHost.Dyn.Deck do
        def inspect(_deck, _opts), do: "#Deck<>"
      end
    end

    defmodule TestHost.Dyn.Deck do
      defstruct cards: []
    end
    """

    %{n: n, modules: modules} = propose!(%{"card.ex" => source})
    chars = Module.concat(String.Chars, TestHost.Dyn.G1.Card)
    inspect_impl = Module.concat(Inspect, TestHost.Dyn.G1.Deck)

    assert Enum.map(modules, & &1.module) |> Enum.sort() == [
             "Inspect.TestHost.Dyn.Deck",
             "String.Chars.TestHost.Dyn.Card",
             "TestHost.Dyn.Card",
             "TestHost.Dyn.Deck"
           ]

    assert Compiler.generation_of(chars) == n
    assert chars in Compiler.loaded(n) and inspect_impl in Compiler.loaded(n)
    assert chars.to_string(struct(TestHost.Dyn.G1.Card, title: "ace")) == "card ace"

    # Discarding the proposal unloads the implementations with the rest.
    assert Dyn.discard(n) == :ok
    assert Compiler.loaded(n) == []
    refute :code.is_loaded(chars)
  end
end
