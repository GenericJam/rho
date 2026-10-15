defmodule Rho.Tools.DynCopyTest do
  # The Keeper is app-named, as in the other Dyn tool tests.
  use ExUnit.Case, async: false

  import Rho.Test.Dyn

  alias Rho.Dyn
  alias Rho.Tools.DynCopy

  @moduletag :tmp_dir
  @moduletag :capture_log

  @source """
  defmodule TestHost.Dyn.Showcase.Phone.Rec do
    @moduledoc "TestHost.Dyn.Showcase.Phone.Rec records."
    alias TestHost.Dyn.Showcase.Phone.Rec.State
    alias TestHost.Dyn.Showcase.Phone.Recorder

    def state, do: %State{}
    def other, do: {Recorder, TestHost.Dyn.Showcase.Phone.Rec_old, :"TestHost.Dyn.Showcase.Phone.Rec2"}
    def me, do: TestHost.Dyn.Showcase.Phone.Rec.state()
    def root, do: Elixir.TestHost.Dyn.Showcase.Phone.Rec.state()
  end

  defmodule TestHost.Dyn.Showcase.Phone.Rec.State do
    defstruct [:at]
  end
  """

  setup %{tmp_dir: dir} do
    start_keeper(dir)
    :ok = Dyn.stage_put("showcase/phone/rec.ex", @source, Dyn.Keeper)
    :ok
  end

  test "passes its own selftest" do
    assert DynCopy.selftest() == :ok
  end

  test "renames the module and its nested modules, nothing that merely shares a prefix" do
    assert {:ok, text} =
             DynCopy.run(
               %{
                 "from" => "showcase/phone/rec.ex",
                 "to" => "memo.ex",
                 "module" => "TestHost.Dyn.Memo"
               },
               %{}
             )

    assert text =~ "TestHost.Dyn.Memo"
    assert {:ok, copy} = Dyn.stage_read("memo.ex", Dyn.Keeper)

    assert copy == """
           defmodule TestHost.Dyn.Memo do
             @moduledoc "TestHost.Dyn.Memo records."
             alias TestHost.Dyn.Memo.State
             alias TestHost.Dyn.Showcase.Phone.Recorder

             def state, do: %State{}
             def other, do: {Recorder, TestHost.Dyn.Showcase.Phone.Rec_old, :"TestHost.Dyn.Showcase.Phone.Rec2"}
             def me, do: TestHost.Dyn.Memo.state()
             def root, do: Elixir.TestHost.Dyn.Memo.state()
           end

           defmodule TestHost.Dyn.Memo.State do
             defstruct [:at]
           end
           """

    # The original is untouched.
    assert Dyn.stage_read("showcase/phone/rec.ex", Dyn.Keeper) == {:ok, @source}
  end

  test "the reply numbers the copy's lines as dyn_read does" do
    assert {:ok, text} = DynCopy.run(%{"from" => "showcase/phone/rec.ex", "to" => "memo.ex"}, %{})
    assert text =~ ~r/^ 1\| defmodule TestHost\.Dyn\.Memo do$/m
    assert text =~ ~r/^15\| $/m
  end

  test "a long file is shown in part, with where to read on" do
    long = "defmodule TestHost.Dyn.Long do\n" <> String.duplicate("  # x\n", 300) <> "end\n"
    :ok = Dyn.stage_put("long.ex", long, Dyn.Keeper)
    assert {:ok, text} = DynCopy.run(%{"from" => "long.ex", "to" => "longer.ex"}, %{})
    assert text =~ ~r/^250\| /m
    refute text =~ ~r/^251\| /m
    assert text =~ "251"
  end

  test "the module defaults to one named after the new path" do
    assert {:ok, _} =
             DynCopy.run(
               %{"from" => "showcase/phone/rec.ex", "to" => "screens/date_slider.ex"},
               %{}
             )

    assert {:ok, "defmodule TestHost.Dyn.Screens.DateSlider do\n" <> _} =
             Dyn.stage_read("screens/date_slider.ex", Dyn.Keeper)
  end

  test "refuses a `to` that exists, leaving it as it was" do
    :ok = Dyn.stage_put("memo.ex", "mine", Dyn.Keeper)

    assert {:error, text} =
             DynCopy.run(%{"from" => "showcase/phone/rec.ex", "to" => "memo.ex"}, %{})

    assert text =~ "memo.ex already exists"
    assert Dyn.stage_read("memo.ex", Dyn.Keeper) == {:ok, "mine"}
  end

  test "concurrent copies cannot replace the winner" do
    results =
      1..8
      |> Task.async_stream(
        fn _ -> DynCopy.run(%{"from" => "showcase/phone/rec.ex", "to" => "memo.ex"}, %{}) end,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, "memo.ex already exists" <> _}, &1)) == 7

    assert {:ok, "defmodule TestHost.Dyn.Memo do\n" <> _} =
             Dyn.stage_read("memo.ex", Dyn.Keeper)
  end

  test "reading the source module does not intern source-controlled identifiers" do
    identifier = "copy_probe_#{System.unique_integer([:positive])}"
    source = "defmodule TestHost.Dyn.AtomSafe do\n  def #{identifier}, do: :ok\nend\n"
    :ok = Dyn.stage_put("atom_safe.ex", source, Dyn.Keeper)

    assert_raise ArgumentError, fn -> String.to_existing_atom(identifier) end
    assert {:ok, _} = DynCopy.run(%{"from" => "atom_safe.ex", "to" => "atom_copy.ex"}, %{})
    assert_raise ArgumentError, fn -> String.to_existing_atom(identifier) end
  end

  test "refuses an unknown `from`" do
    assert {:error, text} = DynCopy.run(%{"from" => "nope.ex", "to" => "memo.ex"}, %{})
    assert text =~ "nope.ex is not in staging"
    assert Dyn.stage_read("memo.ex", Dyn.Keeper) == {:error, :not_found}
  end

  test "refuses module names outside TestHost.Dyn.* and the generations' own" do
    for module <- ["Foo.Memo", "TestHost.Dyn.G3.Memo", "TestHost.Dyn.memo", "TestHost.Dyn"] do
      assert {:error, _} =
               DynCopy.run(
                 %{"from" => "showcase/phone/rec.ex", "to" => "memo.ex", "module" => module},
                 %{}
               ),
             module
    end

    assert Dyn.stage_read("memo.ex", Dyn.Keeper) == {:error, :not_found}
  end
end
