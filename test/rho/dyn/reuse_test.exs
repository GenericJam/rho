defmodule Rho.Dyn.ReuseTest do
  # Dyn generations load into the VM-wide code server.
  use ExUnit.Case, async: false

  import Rho.Test.Dyn

  alias Rho.Dyn
  alias Rho.Dyn.Compiler
  alias Rho.Dyn.Reuse
  alias Rho.Dyn.Store

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: dir} do
    purge_all()
    on_exit(&purge_all/0)
    start_keeper(dir)
    %{dir: dir}
  end

  defp name(value) do
    """
    defmodule TestHost.Dyn.Name do
      def value, do: #{inspect(value)}
    end
    """
  end

  # Files around TestHost.Dyn.Name, each depending on it a different way.
  defp files(value) do
    %{
      "name.ex" => name(value),
      # Names it at run time only.
      "greeter.ex" => """
      defmodule TestHost.Dyn.Greeter do
        def hello, do: "hello " <> TestHost.Dyn.Name.value()
        def screens, do: [%{module: TestHost.Dyn.Name}]
      end
      """,
      # Calls it at compile time.
      "frozen.ex" => """
      defmodule TestHost.Dyn.Frozen do
        @value TestHost.Dyn.Name.value()
        def value, do: @value
      end
      """,
      # Calls, at compile time, a module that names it at run time.
      "relay.ex" => """
      defmodule TestHost.Dyn.Relay do
        def value, do: TestHost.Dyn.Name.value()
      end
      """,
      "via.ex" => """
      defmodule TestHost.Dyn.Via do
        @value TestHost.Dyn.Relay.value()
        def value, do: @value
      end
      """,
      # A struct whose default comes from it, and a module expanding that struct.
      "card.ex" => """
      defmodule TestHost.Dyn.Card do
        defstruct title: TestHost.Dyn.Name.value()
      end
      """,
      "deck.ex" => """
      defmodule TestHost.Dyn.Deck do
        alias TestHost.Dyn.Card
        def first, do: %Card{}
      end
      """,
      # Unrelated: a plain struct and a module using it.
      "plain.ex" => """
      defmodule TestHost.Dyn.Plain do
        defstruct label: "plain"
      end
      """,
      "user.ex" => """
      defmodule TestHost.Dyn.User do
        alias TestHost.Dyn.Plain
        def plain, do: %Plain{}.label
        def greeting, do: TestHost.Dyn.Greeter.hello()
      end
      """,
      # Its own (versioned) name as a string, frozen at compile time.
      "label.ex" => """
      defmodule TestHost.Dyn.Label do
        @label inspect(__MODULE__)
        def label, do: @label
      end
      """
    }
  end

  defp mod(n, name), do: Module.concat(["TestHost.Dyn.G#{n}", name])
  defp call(n, name, fun), do: apply(mod(n, name), fun, [])

  test "a change recompiles what depends on it at compile time and reuses the rest",
       %{dir: dir} do
    one = activate!(files("one"))
    assert %{"files" => %{"greeter.ex" => %{"needs" => []}}} = Store.deps(dir, one)

    assert %{"needs" => ["TestHost.Dyn.Relay"]} = Store.deps(dir, one)["files"]["via.ex"]
    assert %{"needs" => ["TestHost.Dyn.Card"]} = Store.deps(dir, one)["files"]["deck.ex"]

    assert %{reused: reused, n: two} = propose!(%{"name.ex" => name("two")})
    {:ok, token} = Dyn.request_approval({:activate, two})
    {:ok, _} = Dyn.activate(two, token)

    # Reused (renamed): their calls reach the new generation.
    assert call(two, "Greeter", :hello) == "hello two"
    assert call(two, "Greeter", :screens) == [%{module: mod(two, "Name")}]
    assert call(two, "User", :greeting) == "hello two"
    assert call(two, "User", :plain) == "plain"
    assert call(two, "Relay", :value) == "two"
    # Recompiled: they froze the old value at compile time.
    assert call(two, "Frozen", :value) == "two"
    assert call(two, "Via", :value) == "two"
    assert call(two, "Deck", :first) == struct(mod(two, "Card"), title: "two")
    # Recompiled from source: its code held the old generation's name.
    assert call(two, "Label", :label) == "TestHost.Dyn.G#{two}.Label"

    # greeter, relay, plain, user; name, frozen, via, card, deck, label compiled.
    assert reused == 4
    assert {:ok, %{compile_ms: _}} = Dyn.generation(two)
    # The old generation still runs its own code.
    assert call(one, "Greeter", :hello) == "hello one"

    # The reused generation is itself reused from, and its deps carry over.
    assert Store.deps(dir, two)["files"]["via.ex"] == Store.deps(dir, one)["files"]["via.ex"]

    assert %{reused: 9} =
             propose!(%{"label.ex" => String.replace(files("x")["label.ex"], "label", "tag")})
  end

  # Dyn names held every way a reused binary keeps them.
  defp holders(value) do
    %{
      "name.ex" => name(value),
      "plain.ex" => files(value)["plain.ex"],
      # Literals: a map, an improper list, a struct, an external fun.
      "holder.ex" => """
      defmodule TestHost.Dyn.Holder do
        def held,
          do: %{module: TestHost.Dyn.Name, list: [TestHost.Dyn.Name | :tail], plain: %TestHost.Dyn.Plain{}}

        def fun, do: &TestHost.Dyn.Name.value/0
      end
      """,
      "board.ex" =>
        screen("Board", "",
          mount: "{:ok, Mob.Socket.assign(socket, :text, TestHost.Dyn.Name.value())}"
        ),
      # Its own name in a charlist with a character past latin-1.
      "chars.ex" => """
      defmodule TestHost.Dyn.Chars do
        @chars String.to_charlist(inspect(__MODULE__) <> " ✓")
        def chars, do: @chars
      end
      """
    }
  end

  defp activate_reused!(files) do
    %{n: n, reused: reused} = propose!(files)
    {:ok, token} = Dyn.request_approval({:activate, n})
    {:ok, _} = Dyn.activate(n, token)
    {n, reused}
  end

  defp beam(dir, n, name), do: List.keyfind(Store.beams(dir, n), mod(n, name), 0) |> elem(1)

  defp line_table(dir, n, name) do
    {:ok, {_, [{~c"Line", table}]}} = :beam_lib.chunks(beam(dir, n, name), [~c"Line"])
    table
  end

  defp board_text(n) do
    board = mod(n, "Board")
    {:ok, socket} = board.mount(%{}, %{}, Mob.Socket.new(board))
    Mob.ScreenCase.text(board.render(socket.assigns))
  end

  test "a reused binary is renamed, not recompiled, through any number of generations",
       %{dir: dir} do
    one = activate!(holders("one"))

    {two, reused} = activate_reused!(%{"name.ex" => name("two")})
    # plain, holder, board; chars holds its old name: compiled from source.
    assert reused == 3

    assert call(two, "Holder", :held) == %{
             module: mod(two, "Name"),
             list: [mod(two, "Name") | :tail],
             plain: struct(mod(two, "Plain"))
           }

    assert call(two, "Holder", :fun).() == "two"
    assert board_text(two) =~ "two"
    assert call(two, "Chars", :chars) == ~c"TestHost.Dyn.G#{two}.Chars ✓"
    # The line table still names the parent's copy of the source.
    assert line_table(dir, two, "Holder") == line_table(dir, one, "Holder")

    # Reused from a reused binary: its debug info names its own generation.
    {three, 3} = activate_reused!(%{"name.ex" => name("three")})
    assert call(three, "Holder", :fun).() == "three"
    assert call(three, "Holder", :held).plain == struct(mod(three, "Plain"))
    assert board_text(three) =~ "three"
    assert call(three, "Chars", :chars) == ~c"TestHost.Dyn.G#{three}.Chars ✓"
    assert line_table(dir, three, "Holder") == line_table(dir, one, "Holder")

    holder = beam(dir, three, "Holder")

    assert Reuse.refs(mod(three, "Holder"), holder, three) == [
             "TestHost.Dyn.Name",
             "TestHost.Dyn.Plain"
           ]

    {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(holder, [:abstract_code])

    assert {:ok, compiled, _} = :compile.forms(forms, [:binary])
    assert compiled == mod(three, "Holder")
  end

  test "nothing is reused from a parent built by another runtime or without deps",
       %{dir: dir} do
    one = activate!(files("one"))
    {:ok, _} = Store.update_generation(dir, one, &%{&1 | runtime: "an older app"})
    assert %{reused: 0} = propose!(%{"name.ex" => name("two")})

    {:ok, _} = Store.update_generation(dir, one, &%{&1 | runtime: Compiler.runtime()})

    File.rm!(Path.join([dir, "gens", "#{one}", "deps.json"]))
    assert %{reused: 0} = propose!(%{"name.ex" => name("three")})
  end

  test "the names a module's code holds are read through struct and improper-list literals",
       %{dir: dir} do
    literals = """
    defmodule TestHost.Dyn.Literals do
      def meta, do: %URI{host: "x", path: TestHost.Dyn.Name}
      def pair, do: [TestHost.Dyn.Name | :tail]
    end
    """

    one = activate!(%{"name.ex" => name("one"), "literals.ex" => literals})
    assert Store.deps(dir, one)["refs"]["TestHost.Dyn.Literals"] == ["TestHost.Dyn.Name"]
  end

  test "a file that defines a protocol implementation is compiled, not renamed", %{dir: dir} do
    card = """
    defmodule TestHost.Dyn.Card do
      defstruct [:title]

      defimpl String.Chars do
        def to_string(card), do: "card " <> card.title
      end
    end
    """

    plain = "defmodule TestHost.Dyn.Plain do\n  def x, do: 1\nend\n"
    one = activate!(%{"name.ex" => name("one"), "card.ex" => card, "plain.ex" => plain})
    impl = Module.concat(String.Chars, mod(one, "Card"))
    assert impl in Compiler.loaded(one)

    assert Store.deps(dir, one)["files"]["card.ex"]["modules"] == [
             "String.Chars.TestHost.Dyn.Card",
             "TestHost.Dyn.Card"
           ]

    # card.ex and plain.ex are unchanged and need nothing that changed:
    # plain.ex is reused, card.ex compiled from source.
    {two, reused} =
      activate_reused!(%{"name.ex" => name("two"), "card.ex" => card, "plain.ex" => plain})

    assert reused == 1
    impl = Module.concat(String.Chars, mod(two, "Card"))
    assert impl.to_string(struct(mod(two, "Card"), title: "x")) == "card x"
  end

  test "plan: unchanged files are reused unless a compile-time need reaches a change" do
    deps = %{
      "files" => %{
        "a.ex" => %{"modules" => ["A"], "needs" => []},
        "b.ex" => %{"modules" => ["B"], "needs" => ["A"]},
        "c.ex" => %{"modules" => ["C"], "needs" => ["B"]},
        "d.ex" => %{"modules" => ["D"], "needs" => ["E"]},
        "e.ex" => %{"modules" => ["E"], "needs" => []},
        "f.ex" => %{"modules" => ["F"], "needs" => nil},
        "g.ex" => %{"modules" => ["G"], "needs" => ["H"]},
        "h.ex" => %{"modules" => ["H"], "needs" => []}
      },
      # E names A at run time; H has no recorded names.
      "refs" => %{"A" => [], "B" => [], "C" => [], "D" => [], "E" => ["A"], "F" => [], "G" => []}
    }

    all = MapSet.new(Map.keys(deps["files"]))

    # Nothing changed: all but f (its needs are unknown) and g (it needs H,
    # whose names are unknown, while f is dirty).
    assert Reuse.plan(deps, all) == MapSet.new(~w(a.ex b.ex c.ex d.ex e.ex h.ex))

    # a changed: b needs it; c needs b (now dirty); d needs e, which names a.
    assert Reuse.plan(deps, MapSet.delete(all, "a.ex")) == MapSet.new(~w(e.ex h.ex))
    assert Reuse.plan(nil, all) == MapSet.new()
  end
end
