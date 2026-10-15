defmodule Rho.Tools.TodoTest do
  use ExUnit.Case, async: true

  alias Rho.Tools.Todo

  @moduletag :tmp_dir

  defp todo(args, dir, session \\ "s1"),
    do: Todo.run(args, %{data_dir: dir, session_id: session, call_id: "c"})

  test "passes its own selftest" do
    assert Todo.selftest() == :ok
  end

  test "done moves progress to the next pending item, by index or text", %{tmp_dir: dir} do
    assert {:ok, "1. [>] plan\n2. [ ] build\n3. [ ] test\n0 of 3 done."} =
             todo(%{"action" => "set", "items" => ["plan", " build ", "", "test"]}, dir)

    assert {:ok, "1. [x] plan\n2. [>] build\n3. [ ] test\n1 of 3 done."} =
             todo(%{"action" => "done", "text" => "plan"}, dir)

    # Finishing a later item out of order keeps the one in progress.
    assert {:ok, "1. [x] plan\n2. [>] build\n3. [x] test\n2 of 3 done."} =
             todo(%{"action" => "done", "index" => 3}, dir)

    assert {:ok, "1. [x] plan\n2. [x] build\n3. [x] test\nAll done."} =
             todo(%{"action" => "done", "index" => 2}, dir)

    assert {:ok, "1. [x] plan\n2. [x] build\n3. [x] test\n4. [>] ship\n3 of 4 done."} =
             todo(%{"action" => "add", "items" => ["ship"]}, dir)
  end

  test "removing the item in progress starts the next one", %{tmp_dir: dir} do
    {:ok, _} = todo(%{"action" => "set", "items" => ["a", "b"]}, dir)
    assert {:ok, "1. [>] b\n0 of 1 done."} = todo(%{"action" => "remove", "index" => 1}, dir)
    assert {:ok, "(no todo list)"} = todo(%{"action" => "remove", "text" => "b"}, dir)
  end

  test "bad references and arguments are errors that change nothing", %{tmp_dir: dir} do
    assert {:error, "the todo list is empty" <> _} =
             todo(%{"action" => "done", "index" => 1}, dir)

    assert {:error, "set needs `items`" <> _} = todo(%{"action" => "set"}, dir)

    assert {:error, "`items` has no non-empty strings"} =
             todo(%{"action" => "set", "items" => [" "]}, dir)

    {:ok, list} = todo(%{"action" => "set", "items" => ["a"]}, dir)
    assert {:error, "no item 2; the list has 1"} = todo(%{"action" => "done", "index" => 2}, dir)

    assert {:error, "no item with the exact text" <> _} =
             todo(%{"action" => "done", "text" => "A"}, dir)

    assert {:error, "give the item's `index`" <> _} = todo(%{"action" => "remove"}, dir)

    assert {:error, "51 items is too many" <> _} =
             todo(%{"action" => "add", "items" => Enum.map(1..50, &"i#{&1}")}, dir)

    assert {:ok, ^list} = todo(%{"action" => "view"}, dir)

    assert {:error, "the todo list needs a session"} =
             Todo.run(%{"action" => "view"}, %{data_dir: dir})
  end

  test "the list persists per session, and open_items lists what isn't done", %{tmp_dir: dir} do
    {:ok, _} = todo(%{"action" => "set", "items" => ["a", "b", "c"]}, dir)
    {:ok, _} = todo(%{"action" => "done", "index" => 1}, dir)
    {:ok, _} = todo(%{"action" => "set", "items" => ["other"]}, dir, "s2")

    assert Todo.open_items(dir, "s1") == ["b", "c"]
    assert Todo.open_items(dir, "s2") == ["other"]
    assert Todo.open_items(dir, "none") == []
    assert {:ok, "1. [x] a\n2. [>] b\n3. [ ] c\n1 of 3 done."} = todo(%{"action" => "view"}, dir)

    {:ok, _} = todo(%{"action" => "done", "text" => "b"}, dir)
    {:ok, _} = todo(%{"action" => "done", "text" => "c"}, dir)
    assert Todo.open_items(dir, "s1") == []
  end

  test "a session id can't name a file outside the todos dir", %{tmp_dir: dir} do
    {:ok, _} = todo(%{"action" => "set", "items" => ["a"]}, dir, "../../x")
    assert File.ls!(Path.join(dir, "todos")) == ["______x.json"]
    assert Todo.open_items(dir, "../../x") == ["a"]
  end
end
