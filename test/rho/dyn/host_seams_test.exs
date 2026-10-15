defmodule Rho.Dyn.HostSeamsTest do
  # Changes app-wide config and loads Dyn generations into the VM-wide code server.
  use ExUnit.Case, async: false

  import Rho.Test.Dyn, only: [purge_all: 0, await_dyn: 1]

  alias Rho.Dyn
  alias Rho.Dyn.Approval.Biometric
  alias Rho.Dyn.Check
  alias Rho.Dyn.Config
  alias Rho.Dyn.Keeper
  alias Rho.Dyn.Source
  alias Rho.Dyn.Store
  alias Rho.Loop
  alias Rho.Test.FakeLLM

  @moduletag :tmp_dir
  @moduletag :capture_log

  # A host that isn't Operator: its own namespace, its own Core modules and
  # its own UI (`Notebook.Screens`: cards, not mob screens).
  @host [
    namespace: Notebook.Gen,
    screens: Notebook.Screens,
    core: [Notebook],
    allowed: [Notebook.Api, Notebook.Card],
    guide: "Notes are the user's: never delete one."
  ]

  @fast [approval: Rho.Test.Dyn.Approval, stable_delay_ms: 0, gc_retry_ms: 50]

  defp put_env(key, value) do
    old = Application.fetch_env(:rho, key)
    Application.put_env(:rho, key, value)

    on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(:rho, key, v)
        :error -> Application.delete_env(:rho, key)
      end
    end)
  end

  # The host's config, with this test's Dyn modules purged before it's undone.
  defp host!(extra \\ []) do
    put_env(:dyn, Keyword.merge(@host, extra))
    purge_all()

    on_exit(fn ->
      purge_all()
      Enum.each([:first_render, :keeper], &:persistent_term.erase({Notebook.Screens, &1}))
    end)
  end

  defp start_rho(dir, dyn) do
    put_env(:data_dir, dir)

    start_supervised!({Rho.Supervisor, auth: [], login: [open_url: fn _ -> :ok end], dyn: dyn})
  end

  @weather """
  defmodule Notebook.Gen.Weather do
    @behaviour Rho.Tool

    def name, do: "weather"
    def description, do: "Today's weather."
    def parameter_schema, do: %{"type" => "object", "properties" => %{}}
    def run(_args, _ctx), do: {:ok, "sunny"}
    def selftest, do: :ok
  end
  """

  @card """
  defmodule Notebook.Gen.Hello do
    use Notebook.Card
    alias Notebook.Gen.Greeting

    def show(%{crash: true}), do: raise("card crashed")
    def show(_params), do: {:ok, Greeting.text() <> " " <> Atom.to_string(Notebook.Api.ping())}
  end

  defmodule Notebook.Gen.Greeting do
    def text, do: "hello"
  end
  """

  defp offered(request), do: Enum.map(request.tools, & &1.name)

  # The model calls a turn made, once it ended.
  defp flush_requests do
    receive do
      {:llm_request, _, _} -> flush_requests()
    after
      0 -> :ok
    end
  end

  test "a host with its own namespace and screens: the next turn's tools follow the generation",
       %{tmp_dir: dir} do
    host!()
    dyn_dir = Path.join(dir, "dyn")
    start_rho(dir, Keyword.put(@fast, :dir, dyn_dir))
    assert %{generation: 0, mode: :normal} = Dyn.boot()
    :ok = Dyn.subscribe()

    {:ok, llm} =
      FakeLLM.start([
        # The agent writes a tool and a card and proposes them ...
        [
          {:tool_call, "c1", "dyn_write", %{"path" => "weather.ex", "content" => @weather}},
          {:tool_call, "c2", "dyn_write", %{"path" => "hello.ex", "content" => @card}}
        ],
        [{:tool_call, "c3", "dyn_propose", %{"rationale" => "weather and a card"}}],
        [{:text, "proposed"}],
        # ... the human approves; the next turn calls the new tool ...
        [{:tool_call, "c4", "weather", %{}}],
        [{:text, "it's sunny"}],
        # ... and after a revert it's gone.
        [{:tool_call, "c5", "weather", %{}}],
        [{:text, "no weather"}]
      ])

    {:ok, loop} = Rho.start_loop(llm: {FakeLLM, llm}, system_prompt: "t")
    :ok = Loop.subscribe(loop)

    :ok = Loop.prompt(loop, "build it")
    assert_receive {:llm_request, first, _}, 2_000
    assert "dyn_propose" in offered(first)
    refute "weather" in offered(first)

    assert_receive {:rho, _, %{type: :tool_execution_end, name: "dyn_propose", text: text}},
                   30_000

    assert text =~ "Proposed generation G1"
    assert_receive {:rho, _, %{type: :agent_end, reason: :done}}, 5_000
    flush_requests()

    # Compiled into the host's namespace, the card selftested by the host's hook.
    assert {:ok, gen} = Dyn.generation(1)

    assert Enum.sort(Enum.map(gen.modules, &{&1.module, &1.versioned, &1.kind})) == [
             {"Notebook.Gen.Greeting", "Notebook.Gen.G1.Greeting", :module},
             {"Notebook.Gen.Hello", "Notebook.Gen.G1.Hello", :screen},
             {"Notebook.Gen.Weather", "Notebook.Gen.G1.Weather", :tool}
           ]

    assert %{detail: "card: showed \"hello pong\""} =
             Enum.find(gen.selftests, &(&1.module == "Notebook.Gen.Hello"))

    {:ok, token} = Dyn.request_approval({:activate, 1})
    assert {:ok, %{status: :probation}} = Dyn.activate(1, token)

    :ok = Loop.prompt(loop, "weather?")
    assert_receive {:llm_request, second, _}, 2_000
    assert "weather" in offered(second)
    assert_receive {:rho, _, %{type: :tool_execution_end, name: "weather", text: "sunny"}}, 5_000
    assert_receive {:rho, _, %{type: :agent_end, reason: :done}}, 5_000
    flush_requests()

    # A card process enters through the host's entry function, wrapped: its
    # crash counts against the generation.
    assert [{"Hello", card}] = Dyn.screens()
    assert card == Notebook.Gen.G1.Hello
    spawn(fn -> card.show(%{crash: true}) end)
    assert %{gen: 1, module: "Notebook.Gen.Hello", kind: :crash} = await_dyn(:crash)

    {:ok, back} = Dyn.request_approval({:revert_to, 0})
    assert {:ok, %{n: 0}} = Dyn.revert_to(0, back)

    :ok = Loop.prompt(loop, "weather again?")
    assert_receive {:llm_request, third, _}, 2_000
    refute "weather" in offered(third)

    assert_receive {:rho, _,
                    %{
                      type: :message_end,
                      entry: %{
                        "message" => %{"role" => "toolResult", "toolCallId" => "c5"} = result
                      }
                    }},
                   5_000

    assert [%{"text" => "Tool not found: weather" <> _}] = result["content"]
  end

  test "the host's UI says when a launch got going", %{tmp_dir: dir} do
    host!()
    dyn_dir = Path.join(dir, "dyn")
    start_rho(dir, Keyword.merge(@fast, dir: dyn_dir, stable_delay_ms: 60_000))

    _ = Dyn.boot()
    assert %{boot_attempts: 1, stable: false} = Store.boot_markers(dyn_dir)

    # Its first frame starts the clock; the user closing it then is no failed launch.
    Notebook.Screens.first_frame()
    Notebook.Screens.close()
    _ = Dyn.status()
    assert %{boot_attempts: 0, stable: true} = Store.boot_markers(dyn_dir)
  end

  test "the static check follows the host's namespace and Core" do
    host!()
    run = fn body -> Check.run(%{"p.ex" => "defmodule Notebook.Gen.P do\n  #{body}\nend\n"}) end

    assert {:ok, _} = run.("def ok, do: Notebook.Api.ping()")
    assert {:error, [%{message: m}]} = run.("def x, do: Notebook.Secret.token()")
    assert m =~ "is the Core's own code (Dyn code may only use Rho.Tool, Notebook.Api and"
    assert {:error, [%{message: m}]} = run.("def x, do: Rho.Auth.status()")
    assert m =~ "the Core's own code"
    assert {:error, [%{message: m}]} = run.("def x, do: Notebook.Gen.G2.P.x()")
    assert m =~ "reserved for compiled generations"

    assert {:error, [%{message: m}]} = Check.run(%{"d.ex" => "defmodule Dyn.D do\nend\n"})
    assert m =~ "Dyn modules must be Notebook.Gen.*"

    guide = Dyn.agent_guide()
    assert guide =~ "`defmodule Notebook.Gen.<Name>`"
    assert guide =~ "`use Notebook.Card` with `show/1`"
    assert guide =~ "except `Rho.Tool`, `Notebook.Api`, `Notebook.Card`."
    assert guide =~ "Notes are the user's: never delete one."
  end

  test "a host that doesn't use Dyn: no Dyn process, tool or source", %{tmp_dir: dir} do
    put_env(:dyn, [])
    start_rho(dir, Config.enabled?())

    refute Process.whereis(Keeper)
    refute Process.whereis(Biometric)
    assert Rho.ToolRegistry.sources() == []
    assert Rho.ToolRegistry.core_tools() == Rho.ToolRegistry.builtin_tools()
    assert Dyn.status().mode == :off
  end

  test "defaults: namespace Dyn, no screens (the boot is the first frame)", %{tmp_dir: dir} do
    put_env(:dyn, enabled: true)
    purge_all()
    on_exit(&purge_all/0)
    assert Config.namespace() == Elixir.Dyn
    dyn_dir = Path.join(dir, "dyn")
    start_rho(dir, Keyword.put(@fast, :dir, dyn_dir))
    assert Source in Rho.ToolRegistry.sources()

    _ = Dyn.boot()
    # Rho.Dyn.Screens.None: stable `:stable_delay_ms` (0 here) after the boot.
    Process.sleep(20)
    _ = Dyn.status()
    assert %{boot_attempts: 0, stable: true} = Store.boot_markers(dyn_dir)

    :ok = Dyn.stage_put("hi.ex", "defmodule Dyn.Hi do\n  def hi, do: :hi\nend\n")
    assert {:ok, %{n: n}} = Dyn.propose("hi")
    {:ok, token} = Dyn.request_approval({:activate, n})
    assert {:ok, _} = Dyn.activate(n, token)
    assert {:ok, mod} = Dyn.lookup({:module, "Hi"})
    assert mod.hi() == :hi
    assert inspect(mod) == "Dyn.G#{n}.Hi"
  end

  test "a namespace below Rho is refused (rho's own modules live there)", %{tmp_dir: dir} do
    put_env(:dyn, namespace: Rho.Agent)

    assert {:error, {{%ArgumentError{message: m}, _stack}, _child}} =
             start_supervised({Keeper, Keyword.put(@fast, :dir, dir)})

    assert m =~ "must not be below Rho"
  end
end
