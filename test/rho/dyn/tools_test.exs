defmodule Rho.Dyn.ToolsTest do
  # Dyn generations load into the VM-wide code server.
  use ExUnit.Case, async: false

  import Rho.Test.Dyn

  alias Rho.Dyn
  alias Rho.Dyn.AutoApprove
  alias Rho.Tools.DynDelete
  alias Rho.Tools.DynEdit
  alias Rho.Tools.DynFiles
  alias Rho.Tools.DynPropose
  alias Rho.Tools.DynRead
  alias Rho.Tools.DynReset
  alias Rho.Tools.DynStatus
  alias Rho.Tools.DynWrite

  @moduletag :tmp_dir
  @moduletag :capture_log

  @tools [DynFiles, DynRead, DynWrite, DynEdit, DynDelete, DynReset, DynPropose, DynStatus]

  setup do
    purge_all()
    on_exit(&purge_all/0)
  end

  test "every dyn tool passes its own selftest" do
    for tool <- @tools, do: assert(tool.selftest() == :ok, inspect(tool))
  end

  test "edit the staging copy, propose it, and the human is asked to approve", %{tmp_dir: dir} do
    start_keeper(dir)
    ctx = %{}

    assert {:ok, "Staging is empty" <> _} = DynFiles.run(%{}, ctx)
    source = tool("Weather", "weather", run: ~s|{:ok, "sunny"}|)

    assert {:ok, "Wrote weather.ex (10 lines)."} =
             DynWrite.run(%{"path" => "weather.ex", "content" => source}, ctx)

    assert {:ok, listing} = DynFiles.run(%{}, ctx)
    assert listing =~ "weather.ex  #{byte_size(source)} bytes"
    assert listing =~ "changes against generation G0 that aren't proposed yet"

    assert {:ok, text} = DynRead.run(%{"path" => "weather.ex", "offset" => 4, "limit" => 1}, ctx)
    assert text == " 4|   def name, do: \"weather\"\n(lines 4-4 of 10)"

    assert {:ok, "Edited weather.ex at line 7."} =
             DynEdit.run(
               %{"path" => "weather.ex", "old_text" => ~s|"sunny"|, "new_text" => ~s|"rain"|},
               ctx
             )

    assert {:error, "old_text matches 5 times" <> _} =
             DynEdit.run(%{"path" => "weather.ex", "old_text" => "def ", "new_text" => "x"}, ctx)

    assert {:error, "bad path" <> _} =
             DynWrite.run(%{"path" => "/etc/x.ex", "content" => ""}, ctx)

    assert {:error, "bad path" <> _} = DynRead.run(%{"path" => "../a.ex"}, ctx)

    assert {:ok, text} = DynPropose.run(%{"rationale" => "A weather tool"}, ctx)
    assert text =~ "Proposed generation G1 (on top of G0): A weather tool"

    assert text =~
             "It is NOT active. The human has to approve it on the phone with the screen lock"

    assert text =~ "- TestHost.Dyn.Weather (tool): ok"
    assert text =~ ~s|+  def run(_args, _ctx), do: {:ok, "rain"}|

    assert {:ok, status} = DynStatus.run(%{}, ctx)
    assert status =~ "Running generation G0 (proven)."
    assert status =~ "Proposal G1 waits for the human's approval: A weather tool"
    assert %{generation: 0, pending: 1} = Dyn.status()

    assert {:ok, "Deleted weather.ex from staging."} =
             DynDelete.run(%{"path" => "weather.ex"}, ctx)

    assert {:error, _} = DynDelete.run(%{"path" => "weather.ex"}, ctx)
    assert {:ok, "Staging reset to generation G0 (0 files)."} = DynReset.run(%{}, ctx)
  end

  test "edits of one file made in parallel (one model turn's tool calls) all land", %{
    tmp_dir: dir
  } do
    start_keeper(dir)
    lines = for i <- 1..20, do: "line #{i}\n"
    :ok = Dyn.stage_put("many.ex", Enum.join(lines))

    results =
      1..20
      |> Enum.map(fn i ->
        Task.async(fn ->
          DynEdit.run(
            %{"path" => "many.ex", "old_text" => "line #{i}\n", "new_text" => "L#{i}\n"},
            %{}
          )
        end)
      end)
      |> Task.await_many()

    assert Enum.all?(results, &match?({:ok, "Edited many.ex at line " <> _}, &1))
    assert {:ok, after_edits} = Dyn.stage_read("many.ex")
    assert after_edits == Enum.map_join(1..20, &"L#{&1}\n")
  end

  test "with approve all on, the agent hears once the proposal is live, or that it isn't yet",
       %{tmp_dir: dir} do
    start_keeper(dir)
    on_exit(fn -> AutoApprove.disable() end)
    :ok = AutoApprove.enable()

    assert DynPropose.description() =~ "activated automatically"
    refute DynPropose.description() =~ "must approve"

    # Nothing activates it (no chat screen here): it says so, without waiting long.
    :ok = Dyn.stage_put("sunny.ex", tool("Sunny", "sunny"))
    ctx = %{activation_wait_ms: 200}
    assert {:ok, text} = DynPropose.run(%{"rationale" => "A sunny tool"}, ctx)
    assert text =~ "the phone activates it automatically, without asking, but G1 isn't active"
    refute text =~ "It is NOT active"

    # As the chat screen does with approve all on: activate the candidate as it arrives.
    test = self()

    activator =
      spawn_link(fn ->
        :ok = Dyn.subscribe()
        send(test, :subscribed)

        receive do
          {:rho_dyn, %{type: :candidate, gen: n}} ->
            {:ok, token} = Dyn.request_approval({:activate, n})
            {:ok, _} = Dyn.activate(n, token)
        end
      end)

    assert_receive :subscribed
    :ok = Dyn.stage_put("sunny.ex", tool("Sunny", "sunny", run: ~s|{:ok, "hot"}|))
    assert {:ok, text} = DynPropose.run(%{"rationale" => "hotter"}, %{activation_wait_ms: 5_000})
    assert text =~ "Activated: G2 is live (the human has approve all on)"
    assert Dyn.status().generation == 2
    ref = Process.monitor(activator)
    assert_receive {:DOWN, ^ref, :process, _, reason} when reason in [:normal, :noproc]

    :ok = AutoApprove.disable()
    assert DynPropose.description() =~ "the human must approve it"
    :ok = Dyn.stage_put("sunny.ex", tool("Sunny", "sunny", run: ~s|{:ok, "warm"}|))
    assert {:ok, text} = DynPropose.run(%{"rationale" => "warmer"}, ctx)
    assert text =~ "It is NOT active"
  end

  test "a refused proposal lists every error with file and line", %{tmp_dir: dir} do
    start_keeper(dir)
    ctx = %{}

    bad =
      "defmodule TestHost.Dyn.Evil do\n  def x, do: System.halt()\n  def y, do: File.rm(\"/\")\nend\n"

    {:ok, _} = DynWrite.run(%{"path" => "evil.ex", "content" => bad}, ctx)

    assert {:error, text} = DynPropose.run(%{"rationale" => "evil"}, ctx)
    assert text =~ "Rejected by the static check"
    assert text =~ "evil.ex:2: calls System.halt/0"
    assert text =~ "evil.ex:3: calls File.rm/1"

    broken = "defmodule TestHost.Dyn.Broken do\n  def x, do: %TestHost.Dyn.Nope{}\nend\n"
    {:ok, _} = DynReset.run(%{}, ctx)
    {:ok, _} = DynWrite.run(%{"path" => "broken.ex", "content" => broken}, ctx)
    assert {:error, text} = DynPropose.run(%{"rationale" => "broken"}, ctx)
    assert text =~ ~r/Rejected: generation G\d+ doesn't compile:\nbroken.ex:2:/
  end

  test "dyn_status shows crash reports to fix from", %{tmp_dir: dir} do
    start_keeper(dir)
    activate!(%{"boom.ex" => tool("Boom", "boom", run: ~s|raise "kaboom"|)})
    :ok = Dyn.subscribe()
    {:ok, mod} = Dyn.lookup({:tool, "boom"})

    {pid, ref} =
      spawn_monitor(fn ->
        :ok = Dyn.watch(self(), mod)
        mod.run(%{}, %{})
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    await_dyn(:crash)

    assert {:ok, status} = DynStatus.run(%{}, %{})
    assert status =~ "Running generation G1 (probation, parent G0)."
    assert status =~ "crash G1 TestHost.Dyn.Boom"
    assert status =~ "kaboom"
  end
end
