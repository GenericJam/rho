defmodule Rho.Dyn.CheckTest do
  use ExUnit.Case, async: true

  alias Rho.Dyn.Check
  alias Rho.Dyn.Compiler
  alias Rho.Test.Dyn

  defp check(body) do
    """
    defmodule TestHost.Dyn.Probe do
      def go(pid, mod, fun) do
        _ = {pid, mod, fun}
        #{body}
      end
    end
    """
  end

  # The violations `body` causes, as "line: message" lines.
  defp violation(body) do
    assert {:error, violations} = Check.run(%{"probe.ex" => check(body)})
    Enum.map_join(violations, "\n", &"#{&1.line}: #{&1.message}")
  end

  test "accepts a valid tool and a valid screen" do
    sources = %{
      "weather.ex" => Dyn.tool("Weather", "weather"),
      "notes.ex" => Dyn.screen("Notes", "hi"),
      "helpers/format.ex" => """
      defmodule TestHost.Dyn.Helpers.Format do
        alias TestHost.Dyn.Notes

        def now, do: System.monotonic_time() |> Integer.to_string()
        def bye(pid), do: Process.exit(self(), {:done, pid})
        def screen, do: Notes
        def up(list), do: Enum.map(list, &String.upcase/1)
        def call, do: apply(String, :upcase, ["a"])
        def setting, do: :persistent_term.get(:rho_dyn_setting, :default)
      end
      """
    }

    assert {:ok, parsed} = Check.run(sources)
    assert Enum.map(parsed, &elem(&1, 0)) == ["helpers/format.ex", "notes.ex", "weather.ex"]
  end

  test "rejects each banned construct, with the line" do
    banned = [
      {":code.purge(mod)", ":code"},
      {":erlang.halt()", ":erlang.halt"},
      {"System.halt()", "System.halt"},
      {"System.stop()", "System.stop"},
      {~s|System.cmd("rm", ["-rf", "/"])|, "System.cmd"},
      {~s|Port.open({:spawn, "sh"}, [])|, "Port"},
      {~s|:os.cmd(~c"ls")|, ":os.cmd"},
      {~s|Code.eval_string("1")|, "Code"},
      {~s|Code.compile_string("x")|, "Code"},
      {":erlang.binary_to_term(mod)", ":erlang.binary_to_term"},
      {"Protocol.derive(Inspect, Range)", "Protocol.derive"},
      {"Protocol.consolidate(Inspect, [])", "Protocol.consolidate"},
      {"Mob.Dist.ensure_started([])", "Mob.Dist"},
      {"Node.connect(:x@y)", "Node"},
      {":init.stop()", ":init"},
      {~s|File.read("/data")|, "touches the file system directly"},
      {~s|Path.wildcard("/data/*")|, "Path.wildcard"},
      {"Process.exit(pid, :kill)", "exit/2 may only exit self()"},
      {"pid |> Process.exit(:kill)", "exit/2 may only exit self()"},
      {"apply(mod, :halt, [])", "module held in a variable"},
      {"Kernel.apply(mod, :halt, [])", "module held in a variable"},
      {"apply(System, fun, [])", "computed function"},
      {"mod.halt()", "dynamic dispatch"},
      {"TestHost.Loop.stop(pid)", "the Core's own code"},
      {"TestHost.Boot.timings()", "the Core's own code"},
      {"Rho.ToolRegistry", "the Core's own code"},
      {":\"Elixir.System\".halt()", "write module names as aliases"},
      {~s|String.to_atom("Elixir.System")|, "String.to_atom"},
      {"&System.halt/0", "System.halt"},
      {"Mob.Test.tap(:x, :y)", "Mob.Test"},
      {"MobDeliver.mark_stable()", "MobDeliver"},
      {":erlang.suspend_process(pid)", ":erlang.suspend_process"},
      {":erlang.resume_process(pid)", ":erlang.resume_process"},
      {":erlang.trace(pid, true, [:call])", ":erlang.trace"},
      {":erlang.trace_pattern({:m, :f, :_}, true)", ":erlang.trace_pattern"},
      {":logger.add_primary_filter(:x, {&String.upcase/2, nil})", ":logger"},
      {"Logger.add_translator({String, :upcase})", "Logger.add_translator"},
      {~s|:telemetry.attach("x", [:a], &String.upcase/4, nil)|, ":telemetry"},
      {":gen_event.add_handler(pid, String, [])", ":gen_event"},
      {":erlang.trace_delivered(pid)", ":erlang.trace_delivered"},
      {":erlang.system_monitor(pid, [:busy_port])", ":erlang.system_monitor"},
      {":erlang.system_profile(pid, [:runnable_procs])", ":erlang.system_profile"},
      {":seq_trace.set_token(:label, 1)", ":seq_trace"},
      {"send(:mob_screen, {:files, :picked, []})", ":mob_screen is the router"},
      {"Process.send(:mob_screen, {:files, :picked, []}, [])", ":mob_screen is the router"},
      {"Process.send_after(:mob_screen, {:camera, :photo, %{}}, 1)", ":mob_screen is the router"},
      {~s|send(self(), {:mob_file_result, "audio", "recorded", "[]"})|,
       ":mob_file_result is native's own reply"},
      {~s|x = {:mob_file_result, "files", "picked", "[]"}|,
       ":mob_file_result is native's own reply"},
      {":dbg.tracer()", ":dbg"},
      {":erts_debug.df(:m)", ":erts_debug"},
      {":erts_internal.purge_module(:m, :prepare)", ":erts_internal"},
      {":observer_backend.sys_info()", ":observer_backend"},
      {":persistent_term.put(:k, 1)", ":persistent_term.put"},
      {":persistent_term.erase(:k)", ":persistent_term.erase"},
      {"Process.list()", "Process.list"},
      {":erlang.processes()", ":erlang.processes"},
      # The front's limits: nothing that drives screens outside it, files, sign-ins.
      {"Mob.Screen.start_root(TestHost.Dyn.Probe)", "Mob.Screen.start_root"},
      {"Mob.Router.get_nav_history(pid)", "app-facing"},
      {"Mob.Renderer.render(%{}, :android)", "app-facing"},
      {"Mob.Composite.register(:column, {TestHost.Dyn.Probe, :go})", "app-facing"},
      {"Mob.Storage.write(:documents, \"x\", \"y\")", "Mob.Storage"},
      # Mob's native layer: Dyn code goes through Mob's modules, which the host gates.
      {":mob_nif.clipboard_put(\"x\")", ":mob_nif.clipboard_put/1, which is Mob's native layer"},
      {"f = &:mob_nif.screenshot/3", "Mob's native layer"},
      # Held in a variable, a native layer could be called without parentheses.
      {"nif = :mob_nif\n    nif.exit_app", ":mob_nif is Mob's native layer"},
      {"store = :mob_secure_store_nif", ":mob_secure_store_nif holds the sign-ins"},
      {":mob_secure_store_nif.store_get(\"anthropic\")", "sign-ins"},
      {"MobSecureStore.get(\"anthropic\")", "sign-ins"},
      {"Rho.CredentialStore.get(\"anthropic\")", "the Core's own code"},
      {"Rho.Dyn.Keeper.status(Rho.Dyn.Keeper)", "the Core's own code"},
      {"TestHost.Settings.put_daily_cap(100)", "the Core's own code"},
      {"Rho.Auth.status()", "the Core's own code"},
      # Files' file-tool side takes a caller's roots: a forged ctx escapes them.
      {~s|TestHost.Files.workspace(%{data_dir: "/data"})|,
       "TestHost.Files.workspace/1, which Dyn code may not"},
      {~s|TestHost.Files.resolve("x", :write, ctx)|,
       "TestHost.Files.resolve/3, which Dyn code may not"},
      {"TestHost.Files.roots(ctx)", "TestHost.Files.roots/1, which Dyn code may not"},
      {~s|TestHost.Files.real_path("/data")|, "TestHost.Files.real_path/1"},
      {"&TestHost.Files.resolve/3", "TestHost.Files.resolve/3"},
      {"f = TestHost.Files", "as a value"},
      {"TestHost.Files.grant_capability({:files, :picked, []})",
       "TestHost.Files.grant_capability/1"},
      # app:// links are the terminal's (sign-ins, handoffs, updates).
      {"Mob.Link.register(self())", "app-facing"},
      # A wake handler runs later, unchecked: it's checked as a call now.
      {~s|Mob.Wake.register(:w, :refresh, {:file, :delete, ["/data"]})|, ":file.delete"},
      {"Mob.Wake.register(:w, :refresh, {System, :halt, []})", "System.halt"},
      {"Mob.Wake.register(:w, :refresh, handler)", "literal {Module, :function}"},
      {"apply(Mob.Wake, :register, [:w, :refresh, h])", "may only be called directly"},
      {"&Mob.Wake.register/3", "may only be called directly"}
    ]

    for {body, expected} <- banned do
      assert violation(body) =~ ~r/^4: .*#{Regex.escape(expected)}/, "#{body} was not rejected"
    end
  end

  test "front screens may use mob's app-facing modules, Mishka, themes and the plugins" do
    source = """
    defmodule TestHost.Dyn.Probe do
      use Mob.Screen

      alias MobMishka.Components.MishkaSlider

      def mount(_params, _session, socket), do: {:ok, Mob.Socket.assign(socket, :v, 1)}

      def render(assigns) do
        ~MOB\"\"\"
        <Column>
          <MishkaSlider value={@v} on_change={:v} color={0xFF7C3AED} />
          <Text text={Mob.State.get(:theme, :dark) |> inspect()} />
        </Column>
        \"\"\"
      end

      def handle_info({:change, :v, v}, socket),
        do: {:noreply, Mob.Socket.assign(socket, :v, MishkaSlider.snap(v, step: 5))}

      def handle_info({:tap, :theme}, socket) do
        Mob.Theme.set(Mob.Theme.Light)
        Mob.Theme.set(MobThemes.Material3)
        {:noreply, socket}
      end

      def handle_info({:tap, :where}, socket) do
        socket = Mob.Permissions.request(socket, :location)
        {:noreply, MobLocation.get_once(socket)}
      end

      def handle_info({:tap, :snap}, socket), do: {:noreply, MobCamera.capture_photo(socket)}

      def handle_info({:tap, :wake}, socket) do
        :ok = Mob.Wake.register(:probe_refresh, :refresh, {TestHost.Dyn.Probe, :refresh, [1]})
        {:noreply, socket}
      end

      def handle_info({:tap, :next}, socket),
        do: {:noreply, Mob.Socket.push_screen(socket, TestHost.Dyn.Other)}

      def handle_info(_message, socket), do: {:noreply, socket}
    end
    """

    assert {:ok, _} = Check.run(%{"probe.ex" => source})
  end

  test "front screens and tools get the sensors, files in the roots, Nx, TFLite and the GPU" do
    source = """
    defmodule TestHost.Dyn.Probe do
      use Mob.Screen

      @glsl "#version 300 es\\nprecision highp float;\\nin vec2 v_uv;\\nout vec4 frag_color;\\nvoid main() { frag_color = vec4(v_uv, 0.5, 1.0); }"

      def mount(_params, _session, socket) do
        socket = Mob.Motion.start(socket, sensors: [:accelerometer, :magnetometer])
        :ok = MobSensors.read(:pressure)
        {:ok, Mob.Socket.assign(socket, :sum, Nx.tensor([1.0, 2.0]) |> Nx.sum() |> Nx.to_number())}
      end

      def render(assigns) do
        ~MOB\"\"\"
        <Column>
          <GpuView id={:waves} width={200} height={200} shader={%{android: @glsl}} uniforms={[1.0]} />
          <Text text={inspect(@sum)} />
        </Column>
        \"\"\"
      end

      def handle_info({:tap, :save}, socket) do
        :ok = TestHost.Files.write(Path.join("notes", "today.txt"), "hi")
        {:ok, model} = TestHost.Files.read("models/tiny.tflite")
        {:ok, handle, _delegate} = TestHost.Tflite.load(model)
        _ = NxTfliteMob.call(handle, [<<0::32>>])
        {:noreply, Mob.Permissions.request(socket, :all_files)}
      end

      def handle_info(_message, socket), do: {:noreply, socket}
    end
    """

    assert {:ok, _} = Check.run(%{"probe.ex" => source})

    # the rest of the Core (rho's and the host's) stays out of reach
    assert violation(~s|Rho.Session.open("x", nil)|) =~ "the Core's own code"
  end

  test "sees through aliases, imports, delegation and ~MOB templates" do
    for {source, line, expected} <- [
          {"alias System, as: S\n  def go, do: S.halt()", 3, "System.halt"},
          {"alias :code, as: C\n  def go(m), do: C.purge(m)", 2, ":code"},
          {"import System\n  def go, do: :ok", 2, "imports System"},
          {"defdelegate go(), to: System, as: :halt", 2, "System.halt"},
          {"defmacro go, do: :ok", 2, "macro"},
          {"@on_load :go\n  def go, do: :ok", 2, "@on_load"},
          {"def go, do: ~MOB|<Text text={System.halt()} />|", 2, "System.halt"},
          {"defimpl String.Chars, for: Atom do\n    def to_string(_), do: \"\"\n  end", 2,
           "protocol"}
        ] do
      src = "defmodule TestHost.Dyn.Probe do\n  #{source}\nend\n"
      assert {:error, violations} = Check.run(%{"p.ex" => src})

      assert Enum.any?(violations, &(&1.line == line and &1.message =~ expected)),
             "#{inspect(source)}: #{inspect(violations)}"
    end
  end

  test "defimpl only for a Dyn module" do
    ok = """
    defmodule TestHost.Dyn.Card do
      defstruct [:title]
      defimpl String.Chars do
        def to_string(card), do: card.title
      end
      defimpl Inspect, for: TestHost.Dyn.Deck do
        def inspect(_, _), do: "deck"
      end
      defimpl Inspect, for: __MODULE__ do
        def inspect(_, _), do: "card"
      end
    end
    """

    assert {:ok, _} = Check.run(%{"card.ex" => ok})

    for target <- ["Atom", "Deck", "Rho.Session", "TestHost.Dyn.G3.Card"] do
      src = "defmodule TestHost.Dyn.P do\n  defimpl Inspect, for: #{target} do\n  end\nend\n"
      assert {:error, violations} = Check.run(%{"p.ex" => src})
      assert Enum.any?(violations, &(&1.line == 2 and &1.message =~ "protocol")), target
    end

    # A short name that is a Dyn module's in one module and Atom's in
    # another (it would compile to Inspect.Atom, replacing the stdlib's).
    shadowed = """
    defmodule TestHost.Dyn.A do
      defmodule Atom do end
    end
    defmodule TestHost.Dyn.B do
      defimpl Inspect, for: Atom do
        def inspect(_a, _o), do: Inspect.Algebra.string("pwned")
      end
    end
    """

    assert {:error, [%{line: 5, message: shadow}]} = Check.run(%{"s.ex" => shadowed})
    assert shadow =~ "protocol implementation"

    # `TestHost` aliased to something else would move `TestHost.Dyn.X` out.
    moved = """
    defmodule TestHost.Dyn.C do
      alias Kernel, as: TestHost
      defimpl Inspect, for: TestHost.Dyn.X do
      end
    end
    """

    assert {:error, violations} = Check.run(%{"m.ex" => moved})
    assert Enum.any?(violations, &(&1.line == 3))

    assert {:error, [%{message: m}]} =
             Check.run(%{"q.ex" => "defimpl Inspect, for: TestHost.Dyn.Q do\nend\n"})

    assert m =~ "top level"
  end

  test "Protocol.derive at a module's top, which would redefine the stdlib's Inspect.Range" do
    source = """
    defmodule TestHost.Dyn.D do
      require Protocol
      Protocol.derive(Inspect, Range)
    end
    """

    assert {:error, [%{line: 3, message: m}]} = Check.run(%{"d.ex" => source})
    assert m =~ "Protocol.derive"
  end

  test "compiled modules are the generation's, or protocol implementations for them" do
    compile = fn src -> src |> Code.compile_string() |> hd() end
    own = compile.("defmodule TestHost.Dyn.G901.Own do\n  defstruct [:a]\nend\n")

    impl =
      compile.(
        "defimpl String.Chars, for: TestHost.Dyn.G901.Own do\n  def to_string(_), do: \"\"\nend\n"
      )

    # For another generation's module; named like an implementation, but not one.
    other =
      compile.(
        "defimpl String.Chars, for: TestHost.Dyn.G902.Own do\n  def to_string(_), do: \"\"\nend\n"
      )

    fake = compile.("defmodule Elsewhere.TestHost.Dyn.G901.Own do\nend\n")
    on_exit(fn -> Compiler.purge(Enum.map([own, impl, other, fake], &elem(&1, 0))) end)

    assert Check.beam([own, impl], 901) == :ok

    for outside <- [other, fake] do
      assert {:error, violations} = Check.beam([own, outside], 901)
      assert Enum.any?(violations, &(&1.message =~ "is outside TestHost.Dyn: only a protocol"))
    end
  end

  test "modules must live under TestHost.Dyn, and only modules at the top level" do
    assert {:error, [%{line: 1, message: m1}]} =
             Check.run(%{"a.ex" => "defmodule TestHost.Evil do\nend\n"})

    assert m1 =~ "TestHost.Dyn.*"

    assert {:error, [%{message: m2}]} =
             Check.run(%{"b.ex" => "defmodule TestHost.Dyn.G7.Foo do\nend\n"})

    assert m2 =~ "reserved"

    assert {:error, [%{line: 1, message: m3}]} = Check.run(%{"c.ex" => "IO.puts(:hi)\n"})
    assert m3 =~ "top level"
  end

  test "reports every violation of every file, and syntax errors" do
    sources = %{
      "a.ex" =>
        "defmodule TestHost.Dyn.A do\n  def x, do: File.rm(\"/\")\n  def y, do: :init.stop()\nend\n",
      "b.ex" => "defmodule TestHost.Dyn.B do\n  def x(, do: 1\nend\n"
    }

    assert {:error, violations} = Check.run(sources)

    assert [{"a.ex", 2}, {"a.ex", 3}, {"b.ex", 2}] =
             Enum.map(violations, &{&1.file, &1.line})

    assert Check.format(violations) =~ "a.ex:2: calls File.rm/1"
  end
end
