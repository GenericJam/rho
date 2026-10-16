defmodule Rho.Dyn.KeeperTest do
  # Dyn generations load into the VM-wide code server.
  use ExUnit.Case, async: false

  import Rho.Test.Dyn

  alias Rho.Dyn
  alias Rho.Dyn.Compiler
  alias Rho.Dyn.Keeper
  alias Rho.Dyn.Store
  alias Rho.ToolRunner

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup do
    purge_all()
    on_exit(&purge_all/0)
    # Tool calls reach the Keeper through the registry's Dyn source, as in the app.
    start_supervised!({Rho.ToolRegistry, tool_sources: [Rho.Dyn.Source]})
    :ok
  end

  defp tools do
    %{
      "boom.ex" => tool("Boom", "boom", run: ~s|raise "boom"|),
      "slow.ex" => tool("Slow", "slow", run: "(Process.sleep(:infinity); {:ok, 1})")
    }
  end

  # Runs a tool call the way the loop does; `:kill` kills it once it runs,
  # as the loop's timeout does.
  defp call_tool(name, how \\ :wait) do
    sup = start_supervised!(Task.Supervisor, id: make_ref())
    {:ok, mod} = Dyn.lookup({:tool, name})
    task = ToolRunner.start(sup, self(), mod, %{"arguments" => %{}}, &ToolRunner.allow_all/2, %{})
    assert_receive {:tool_running, pid}
    if how == :kill, do: Process.exit(pid, :kill)
    ref = task.ref
    assert_receive {:DOWN, ^ref, :process, _, reason}
    reason
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  # Activated, 60 s (here: probation_ms) without a crash, and a later launch
  # reached stable.
  defp prove!(dir, files, opts) do
    n = activate!(files)
    eventually(fn -> match?({:ok, %{quiet: true}}, Dyn.generation(n)) end)
    relaunch(dir, [stable: true] ++ opts)
    :ok = Dyn.subscribe()
    :ok = Keeper.mark_stable(Keeper)
    assert %{gen: ^n} = await_dyn(:proven)
    n
  end

  test "activation needs an approval for that very generation, used once", %{tmp_dir: dir} do
    start_keeper(dir)
    %{n: n} = propose!(%{"weather.ex" => tool("Weather", "weather")})

    assert Dyn.activate(n, nil) == {:error, :approval_required}
    assert Dyn.activate(n, :forged) == {:error, :invalid_approval}
    {:ok, other} = Dyn.request_approval({:activate, n + 1})
    assert Dyn.activate(n, other) == {:error, :invalid_approval}

    assert %{generation: 0, pending: ^n} = Dyn.status()
    assert Store.current(dir) == 0
    assert Dyn.tools() == []
    assert {:ok, %{status: :candidate}} = Dyn.generation(n)

    # A revert token pulls a generation back once, not whenever it's replayed.
    {:ok, token} = Dyn.request_approval({:activate, n})
    assert {:ok, _} = Dyn.activate(n, token)
    {:ok, back} = Dyn.request_approval({:revert_to, 0})
    assert {:ok, _} = Dyn.revert_to(0, back)
    {:ok, again} = Dyn.request_approval({:revert_to, n})
    assert {:ok, _} = Dyn.revert_to(n, again)
    assert Dyn.revert_to(0, back) == {:error, :approval_used}
    assert Store.current(dir) == n
  end

  test "the production approval: only a fresh confirmation of that subject",
       %{tmp_dir: dir} do
    alias Rho.Dyn.Approval.Biometric

    start_supervised!(Biometric)
    start_keeper(dir, approval: Biometric)
    %{n: n} = propose!(%{"weather.ex" => tool("Weather", "weather")})

    assert Dyn.request_approval({:activate, n}) == {:error, :approval_required}

    assert Dyn.activate(n, {:test_approval, {:activate, n}, make_ref()}) ==
             {:error, :invalid_approval}

    :ok = Biometric.confirm({:activate, n})
    assert {:ok, token} = Dyn.request_approval({:activate, n})
    assert {:ok, %{status: :probation}} = Dyn.activate(n, token)
    assert Store.current(dir) == n
  end

  test "activation flips pointer and registry together; a failed pointer write changes neither",
       %{tmp_dir: dir} do
    start_keeper(dir)
    n1 = activate!(%{"weather.ex" => tool("Weather", "weather")})
    {:ok, g1} = Dyn.lookup({:tool, "weather"})
    %{n: n2} = propose!(%{"weather.ex" => tool("Weather", "weather", run: ~s|{:ok, "v2"}|)})
    {:ok, token} = Dyn.request_approval({:activate, n2})

    # The temp file the pointer is written through can't be created: as if
    # the write died half way.
    File.mkdir_p!(Path.join(dir, "current.tmp"))
    assert {:error, {:pointer_not_written, _}} = Dyn.activate(n2, token)
    assert Store.current(dir) == n1
    assert Dyn.lookup({:tool, "weather"}) == {:ok, g1}
    assert %{generation: ^n1} = Dyn.status()
    assert {:ok, %{status: :candidate}} = Dyn.generation(n2)

    File.rm_rf!(Path.join(dir, "current.tmp"))
    assert Dyn.activate(n2, token) == {:error, :approval_used}
    {:ok, token} = Dyn.request_approval({:activate, n2})
    assert {:ok, %{status: :probation, parent: ^n1}} = Dyn.activate(n2, token)
    assert Store.current(dir) == n2
    {:ok, g2} = Dyn.lookup({:tool, "weather"})
    assert g2.run(%{}, %{}) == {:ok, "v2"}
  end

  test "only the latest proposal, built on the current generation, can be activated",
       %{tmp_dir: dir} do
    start_keeper(dir)
    n1 = activate!(%{"a.ex" => tool("A", "a")})

    # A newer proposal supersedes the pending one (and unloads it).
    %{n: old} = propose!(%{"b.ex" => tool("B", "b")})
    %{n: stale} = propose!(%{"c.ex" => tool("C", "c")})
    {:ok, token} = Dyn.request_approval({:activate, old})
    assert {:error, {:not_a_candidate, :superseded}} = Dyn.activate(old, token)
    assert Compiler.loaded(old) == []

    # The generation it was built on is no longer current.
    {:ok, back} = Dyn.request_approval({:revert_to, 0})
    assert {:ok, _} = Dyn.revert_to(0, back)
    {:ok, token} = Dyn.request_approval({:activate, stale})
    assert {:error, {:stale, %{parent: ^n1, current: 0}}} = Dyn.activate(stale, token)
    assert Store.current(dir) == 0
  end

  test "3 crashes in 60 s on probation revert to the parent and report them", %{tmp_dir: dir} do
    start_keeper(dir)
    n = activate!(tools())
    :ok = Dyn.subscribe()

    # The task formats its crash itself, with the stack the agent fixes
    # from; the Keeper gets the text.
    assert {:rho_crash, "** (RuntimeError) boom\n" <> stack} = call_tool("boom")
    assert stack =~ "TestHost.Dyn.G#{n}.Boom.run/2"

    assert %{
             gen: ^n,
             module: "TestHost.Dyn.Boom",
             kind: :crash,
             status: :probation,
             reason: reason
           } = await_dyn(:crash)

    assert reason == "** (RuntimeError) boom\n" <> stack

    call_tool("boom")
    await_dyn(:crash)
    assert %{generation: ^n, status: :probation} = Dyn.status()

    assert call_tool("slow", :kill) == :killed
    assert %{kind: :killed, module: "TestHost.Dyn.Slow"} = await_dyn(:crash)

    assert %{from: ^n, to: 0, reason: reason, crashes: crashes} = await_dyn(:reverted)
    assert reason =~ "3 crashes within 60 s"
    assert Enum.map(crashes, & &1.kind) == [:crash, :crash, :killed]

    assert %{generation: 0} = Dyn.status()
    assert Store.current(dir) == 0
    assert Dyn.tools() == []
    assert {:ok, %{status: :reverted}} = Dyn.generation(n)

    # The agent can read it all back later.
    assert ["crash", "crash", "crash", "reverted"] = Enum.map(Dyn.log(), & &1.type)
  end

  test "a proven generation is not reverted by crashes; they're reported", %{tmp_dir: dir} do
    start_keeper(dir, probation_ms: 30)
    n = prove!(dir, tools(), probation_ms: 30)

    for _ <- 1..3 do
      call_tool("boom")
      assert %{gen: ^n, status: :proven} = await_dyn(:crash)
    end

    refute_receive {:rho_dyn, %{type: :reverted}}, 100
    assert %{generation: ^n, status: :proven} = Dyn.status()
    assert Store.current(dir) == n
    assert {:ok, %{status: :proven}} = Dyn.generation(n)
  end

  test "boot probation reverts an unproven generation when the launch after it died",
       %{tmp_dir: dir} do
    start_keeper(dir)
    n1 = activate!(%{"weather.ex" => tool("Weather", "weather", run: ~s|{:ok, "v1"}|)})
    n2 = activate!(%{"weather.ex" => tool("Weather", "weather", run: ~s|{:ok, "v2"}|)})

    # This launch reached stable; the next one runs generation 2 ...
    assert %{generation: ^n2, reverted: nil} = relaunch(dir, stable: true)
    {:ok, mod} = Dyn.lookup({:tool, "weather"})
    assert mod.run(%{}, %{}) == {:ok, "v2"}

    # ... and dies before reaching stable: the one after reverts first.
    assert %{generation: ^n1, reverted: %{from: ^n2, to: ^n1}, mode: :normal} = relaunch(dir)
    assert Store.current(dir) == n1
    {:ok, mod} = Dyn.lookup({:tool, "weather"})
    assert mod.run(%{}, %{}) == {:ok, "v1"}
    assert Compiler.loaded(n2) == []

    assert {:ok, %{status: :reverted, reason: "the launch after it was activated" <> _}} =
             Dyn.generation(n2)

    assert [%{type: "reverted", from: ^n2, to: ^n1}] = Dyn.log()
  end

  test "two launches in a row that never reach stable start the next in safe mode",
       %{tmp_dir: dir} do
    start_keeper(dir, probation_ms: 20)
    n = prove!(dir, %{"weather.ex" => tool("Weather", "weather")}, probation_ms: 20)

    assert %{mode: :normal, generation: ^n} = relaunch(dir)
    assert %{mode: :normal, generation: ^n, reverted: nil} = relaunch(dir)
    refute Dyn.safe_mode?()

    assert %{mode: :safe, generation: ^n, failed_launches: 2} = relaunch(dir)
    assert Dyn.safe_mode?()
    assert Dyn.tools() == []
    assert Compiler.loaded(n) == []
    assert %{mode: :safe, generation: ^n} = Dyn.status()
    assert Enum.any?(Dyn.log(), &(&1.type == "safe_mode"))

    # The safe launch got going: the next one loads the Dyn layer again.
    assert %{mode: :normal, generation: ^n} = relaunch(dir, stable: true)
    assert [{"weather", _}] = Dyn.tools()
  end

  # A launch that runs Core update `core` (mob_deliver's manifest id) after
  # the previous one died.
  defp core_launch(dir, opts) do
    :ok = stop_supervised(Keeper)
    purge_all()
    start_supervised!({Keeper, approval: Rho.Test.Dyn.Approval, dir: dir}, id: Keeper)
    Keeper.boot(Keeper, opts)
  end

  test "a launch that failed on a Core update mob_deliver rolled back doesn't count against Dyn",
       %{tmp_dir: dir} do
    start_keeper(dir)
    n1 = activate!(%{"weather.ex" => tool("Weather", "weather", run: ~s|{:ok, "v1"}|)})
    n2 = activate!(%{"weather.ex" => tool("Weather", "weather", run: ~s|{:ok, "v2"}|)})
    :ok = Keeper.mark_stable(Keeper)

    # This launch runs update "x" and dies before stable; the next one runs
    # the rolled-back Core and keeps the unproven generation.
    assert %{generation: ^n2, status: :probation} = core_launch(dir, core: "x")

    assert %{generation: ^n2, reverted: nil, failed_launches: 0, mode: :normal} =
             core_launch(dir, core: nil, core_rolled_back: "x")

    assert Store.current(dir) == n2

    # Died again, nothing rolled back: that one is the generation's.
    assert %{generation: ^n1, reverted: %{from: ^n2, to: ^n1}, failed_launches: 1} =
             core_launch(dir, core: nil)
  end

  test "a rolled-back update doesn't excuse a launch that didn't run it", %{tmp_dir: dir} do
    start_keeper(dir)
    n1 = activate!(%{"weather.ex" => tool("Weather", "weather", run: ~s|{:ok, "v1"}|)})
    n2 = activate!(%{"weather.ex" => tool("Weather", "weather", run: ~s|{:ok, "v2"}|)})
    :ok = Keeper.mark_stable(Keeper)

    # The build's own code with generation 2 dies before stable (the
    # generation's failure). The next launch runs update "x" and dies before
    # the Keeper boots, so it records nothing; the one after rolls "x" back.
    assert %{generation: ^n2} = core_launch(dir, core: nil)

    assert %{generation: ^n1, reverted: %{from: ^n2, to: ^n1}, failed_launches: 1} =
             core_launch(dir, core: nil, core_rolled_back: "x")
  end

  test "a stable launch runs :on_stable once (a delivered update's probation ends)",
       %{tmp_dir: dir} do
    start_keeper(dir, on_stable: {Kernel, :send, [self(), :launch_stable]}, stable_delay_ms: 50)

    Keeper.first_render(Keeper, nil)
    refute_received :launch_stable
    assert_receive :launch_stable, 1_000

    :ok = Keeper.mark_stable(Keeper)
    send(Keeper, {:mob_device, :did_enter_background})
    _ = Dyn.status()
    refute_receive :launch_stable, 100
  end

  test "an old generation is unloaded only once nothing runs its code, anywhere on a stack",
       %{tmp_dir: dir} do
    start_keeper(dir)

    # wait/0 is in Process.sleep/1 (not Dyn code) but returns into the module.
    src = fn tag ->
      "defmodule TestHost.Dyn.Waiter do\n  def wait do\n    :ok = Process.sleep(400)\n    #{inspect(tag)}\n  end\nend\n"
    end

    n1 = activate!(%{"waiter.ex" => src.("one")})
    {:ok, g1} = Dyn.lookup({:module, "Waiter"})
    test = self()
    waiter = spawn(fn -> send(test, {:waited, g1.wait()}) end)

    eventually(fn ->
      Process.info(waiter, :current_function) == {:current_function, {Process, :sleep, 1}}
    end)

    n2 = activate!(%{"waiter.ex" => src.("two")})
    n3 = activate!(%{"waiter.ex" => src.("three")})
    Process.sleep(150)
    assert Compiler.loaded(n1) == [g1]

    assert_receive {:waited, "one"}, 1_000
    eventually(fn -> Compiler.loaded(n1) == [] end)

    # The current generation and its parent (instant revert) stay.
    assert Compiler.loaded(n2) != []
    assert Compiler.loaded(n3) != []
  end

  test "a pending candidate can be discarded without approval", %{tmp_dir: dir} do
    start_keeper(dir)
    :ok = Dyn.subscribe()
    %{n: n} = propose!(%{"weather.ex" => tool("Weather", "weather")})

    assert Dyn.discard(n + 1) == {:error, :not_pending}
    assert Dyn.discard(n) == :ok
    assert %{gen: ^n} = await_dyn(:discarded)
    assert %{pending: nil, generation: 0} = Dyn.status()
    assert Compiler.loaded(n) == []
    assert {:ok, %{status: :discarded}} = Dyn.generation(n)
    {:ok, token} = Dyn.request_approval({:activate, n})
    assert {:error, {:not_a_candidate, :discarded}} = Dyn.activate(n, token)
  end

  test "proposals per launch are capped (atoms are never freed)", %{tmp_dir: dir} do
    start_keeper(dir, max_proposals: 2)
    :ok = Dyn.stage_put("a.ex", "defmodule TestHost.Dyn.A do\n  def x, do: File.rm(\"/\")\nend\n")
    assert {:error, %{stage: :check}} = Dyn.propose("one")
    assert {:error, %{stage: :check}} = Dyn.propose("two")
    assert Dyn.propose("three") == {:error, :proposal_limit}

    # A new launch starts counting again.
    relaunch(dir, max_proposals: 2)
    assert {:error, %{stage: :check}} = Dyn.propose("four")
  end

  test "the auto-revert loads its target before moving the pointer", %{tmp_dir: dir} do
    start_keeper(dir)
    n1 = activate!(%{"weather.ex" => tool("Weather", "weather")})
    n2 = activate!(tools())
    # Only the current generation is loaded after a relaunch; its parent's
    # binaries no longer match their manifest.
    relaunch(dir, stable: true)

    File.write!(
      Path.join([dir, "gens", "#{n1}", "ebin", "Elixir.TestHost.Dyn.G#{n1}.Weather.beam"]),
      "junk"
    )

    :ok = Dyn.subscribe()

    # The pointer can't be written: the crashes stay counted and nothing moves.
    File.mkdir_p!(Path.join(dir, "current.tmp"))
    for _ <- 1..3, do: call_tool("boom")
    assert %{gen: ^n2, to: 0} = await_dyn(:revert_failed)
    assert %{generation: ^n2, status: :probation} = Dyn.status()
    assert Store.current(dir) == n2

    # The next crash tries again; the broken parent is skipped for generation 0.
    File.rm_rf!(Path.join(dir, "current.tmp"))
    call_tool("boom")
    assert %{from: ^n2, to: 0} = await_dyn(:reverted)
    assert Store.current(dir) == 0
    assert %{generation: 0} = Dyn.status()
    assert Enum.any?(Dyn.log(), &(&1.type == "load_failed" and &1.gen == n1))
  end

  test "a launch that drew its first frame and then went to the background got going",
       %{tmp_dir: dir} do
    start_keeper(dir, stable_delay_ms: 60_000)
    n = activate!(%{"weather.ex" => tool("Weather", "weather")})
    assert %{generation: ^n} = relaunch(dir, stable: true, stable_delay_ms: 60_000)

    # Leaving before the first frame counts as a failed launch ...
    send(Keeper, {:mob_device, :did_enter_background})
    assert %{generation: ^n} = Dyn.status()
    assert %{boot_attempts: 1, stable: false} = Store.boot_markers(dir)

    # ... leaving after it doesn't: the user closed a working app.
    Keeper.first_render(Keeper, nil)
    send(Keeper, {:mob_device, :did_enter_background})
    _ = Dyn.status()
    assert %{boot_attempts: 0, stable: true} = Store.boot_markers(dir)

    assert %{generation: ^n, reverted: nil, failed_launches: 0} =
             relaunch(dir, stable_delay_ms: 60_000)
  end

  test "the pointer never makes a generation current that wasn't approved", %{tmp_dir: dir} do
    start_keeper(dir)

    :ok =
      Dyn.stage_put(
        "a.ex",
        "defmodule TestHost.Dyn.A do\n  def x, do: %TestHost.Dyn.Nope{}\nend\n"
      )

    assert {:error, %{stage: :compile, n: bad}} = Dyn.propose("broken")
    :ok = Store.put_current(dir, bad)

    assert %{generation: 0, mode: :normal} = relaunch(dir, stable: true)
    assert Store.current(dir) == 0
    assert {:ok, %{status: :rejected}} = Dyn.generation(bad)
    assert [%{type: "load_failed", gen: ^bad}] = Dyn.log()
  end

  # A proven tool generation whose selftest reads two flags: sleep that
  # long, and fail. Dyn code may only name Dyn modules, so they're atoms.
  @slow :rho_dyn_keeper_test_slow_selftest
  @fail :rho_dyn_keeper_test_fail_selftest

  defp proven_for_rebuild!(dir, opts) do
    on_exit(fn -> Enum.each([@slow, @fail], &:persistent_term.erase/1) end)

    selftest =
      "(Process.sleep(:persistent_term.get(#{inspect(@slow)}, 0)); " <>
        "if :persistent_term.get(#{inspect(@fail)}, false), do: {:error, :broken}, else: :ok)"

    start_keeper(dir, opts)
    prove!(dir, %{"weather.ex" => tool("Weather", "weather", selftest: selftest)}, opts)
  end

  defp built_by_an_older_app(dir, n),
    do: {:ok, _} = Store.update_generation(dir, n, &%{&1 | runtime: "an older app"})

  test "a generation built for an older Core is rebuilt and selftested in the background",
       %{tmp_dir: dir} do
    n = proven_for_rebuild!(dir, probation_ms: 20)
    built_by_an_older_app(dir, n)
    :persistent_term.put(@slow, 300)

    # The launch doesn't wait: nothing of the generation runs yet, and
    # proposals are refused until it does.
    assert %{generation: ^n, rebuilding: true} = relaunch(dir, stable: true, probation_ms: 20)
    :ok = Dyn.subscribe()
    assert Dyn.rebuilding() == n
    assert Dyn.tools() == []
    :ok = Dyn.stage_put("other.ex", tool("Other", "other"))
    assert {:error, :rebuilding} = Dyn.propose("while it rebuilds")

    # Then it loads, back on probation (its code is new), for this runtime.
    assert %{gen: ^n} = await_dyn(:loaded)
    assert Dyn.rebuilding() == nil
    assert [{"weather", _}] = Dyn.tools()
    assert {:ok, %{status: :probation, runtime: runtime}} = Dyn.generation(n)
    assert runtime == Compiler.runtime()
    assert {:ok, %{n: _}} = Dyn.propose("after it rebuilt")
  end

  test "a rebuild that fails its selftests is reported and leaves the generation unloaded",
       %{tmp_dir: dir} do
    n = proven_for_rebuild!(dir, probation_ms: 20)
    built_by_an_older_app(dir, n)
    :persistent_term.put(@fail, true)

    assert %{generation: ^n, rebuilding: true} = relaunch(dir, stable: true, probation_ms: 20)
    :ok = Dyn.await_rebuild()
    assert %{generation: ^n, status: :probation} = Dyn.status()
    assert Dyn.tools() == []
    assert Compiler.loaded(n) == []
    assert %{type: "load_failed", gen: ^n, reason: reason} = List.last(Dyn.log())
    assert reason =~ "failed its selftests after a rebuild"
  end

  test "a launch isn't stable before its rebuild is over, so one that dies during it counts",
       %{tmp_dir: dir} do
    n = proven_for_rebuild!(dir, probation_ms: 20)
    built_by_an_older_app(dir, n)
    :persistent_term.put(@slow, 1_000)

    assert %{rebuilding: true} = relaunch(dir, stable: true, probation_ms: 20)
    Keeper.first_render(Keeper, nil)
    :ok = Keeper.mark_stable(Keeper)
    assert %{boot_attempts: 1, stable: false} = Store.boot_markers(dir)

    # It died mid-rebuild: the next launch counts it, and rebuilds again;
    # stable comes once that rebuild is over.
    :persistent_term.put(@slow, 0)
    assert %{failed_launches: 1, rebuilding: true} = relaunch(dir, probation_ms: 20)
    Keeper.first_render(Keeper, nil)
    :ok = Dyn.await_rebuild()
    _ = Dyn.status()
    assert %{boot_attempts: 0, stable: true} = Store.boot_markers(dir)
    assert [{"weather", _}] = Dyn.tools()
  end
end
