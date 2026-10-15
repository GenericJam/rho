defmodule Rho.ArtifactsTest do
  use ExUnit.Case, async: true

  import Rho.Test.LoopHelpers

  alias Rho.Artifacts
  alias Rho.Loop
  alias Rho.Session
  alias Rho.Tools.ReadArtifact

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp numbered(n), do: Enum.map_join(1..n, "\n", &"line #{&1}")

  test "under the budget a result is given whole; over it, head + tail and the rest kept",
       %{tmp_dir: dir} do
    exact = String.duplicate("x", Artifacts.budget())
    assert Artifacts.limit(exact, dir, "s1", "c0") == exact
    refute File.exists?(Path.join(dir, "artifacts"))

    big = numbered(5_000)
    cut = Artifacts.limit(big, dir, "s1", "call_1")

    assert byte_size(cut) < Artifacts.budget()
    assert cut =~ ~r/\Aline 1\nline 2\n/
    assert String.ends_with?(cut, "line 4999\nline 5000")
    assert cut =~ "the output has 5000 lines"
    assert cut =~ "artifact://call_1"
    # cut at line ends: whole lines either side of the marker
    assert cut =~ ~r/\nline \d+\n\[… \d+ bytes omitted/
    assert cut =~ ~r/offset and limit in lines\)\.\]\nline \d+\n/

    assert {:ok, path} = Artifacts.find(dir, "s1", "call_1")
    assert File.read!(path) == big
  end

  test "never splits a UTF-8 character, even with no newlines", %{tmp_dir: dir} do
    big = String.duplicate("é€😀", 3_000)
    cut = Artifacts.limit(big, dir, "s1", "u")
    assert String.valid?(cut)
  end

  test "ids from the model can't leave the session's artifact dir", %{tmp_dir: dir} do
    _ = Artifacts.limit(numbered(5_000), dir, "s1", "../../evil")
    assert [_] = Path.wildcard(Path.join([dir, "artifacts", "s1", "*.txt"]))
    refute File.exists?(Path.join(dir, "evil.txt"))
    # another session doesn't see it
    assert Artifacts.find(dir, "s2", "../../evil") == {:error, :not_found}
  end

  test "read_artifact pages by lines and says where to continue", %{tmp_dir: dir} do
    _ = Artifacts.limit(numbered(5_000), dir, "s1", "c1")
    ctx = %{data_dir: dir, session_id: "s1"}

    assert {:ok, page} = ReadArtifact.run(%{"id" => "c1", "offset" => 10, "limit" => 3}, ctx)
    assert page == "line 10\nline 11\nline 12\n[lines 10-12 of 5000; continue with offset 13]"

    assert {:ok, last} = ReadArtifact.run(%{"id" => "c1", "offset" => 4999}, ctx)
    assert last =~ "line 5000\n[lines 4999-5000 of 5000; end]"

    # a page stays under the budget however many lines are asked for
    assert {:ok, many} = ReadArtifact.run(%{"id" => "c1", "limit" => 100_000}, ctx)
    assert byte_size(many) < Artifacts.budget()
    assert many =~ ~r/continue with offset \d+\]\z/

    assert {:ok, past} = ReadArtifact.run(%{"id" => "c1", "offset" => 9_999}, ctx)
    assert past =~ "past the end"

    assert {:error, msg} = ReadArtifact.run(%{"id" => "c1"}, %{ctx | session_id: "s2"})
    assert msg =~ "no artifact"
    assert ReadArtifact.selftest() == :ok
  end

  test "the loop gives the model the cut result; the full one is readable", %{tmp_dir: dir} do
    big = numbered(5_000)

    %{loop: loop, session: session} =
      start_loop(dir, [
        [{:tool_call, "t1", "echo", %{"text" => big}}],
        [{:text, "done"}]
      ])

    :ok = Loop.prompt(loop, "go")
    events = collect()

    [result] =
      for %{type: :message_end, entry: %{"message" => %{"role" => "toolResult"} = m}} <- events,
          do: Session.text(m["content"])

    assert result =~ "artifact://t1"
    assert byte_size(result) < Artifacts.budget()
    assert {:ok, path} = Artifacts.find(dir, session.id, "t1")
    assert File.read!(path) == big
  end
end
