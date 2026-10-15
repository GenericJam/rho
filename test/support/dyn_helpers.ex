defmodule Rho.Test.Dyn.Approval do
  @moduledoc "Approval for tests: `request/1` approves, with a fresh token; only its own tokens verify, for their subject."
  @behaviour Rho.Dyn.Approval

  @impl true
  def request(subject), do: {:ok, {:test_approval, subject, make_ref()}}

  @impl true
  def verify({:test_approval, subject, ref}, subject) when is_reference(ref), do: :ok
  def verify(_token, _subject), do: {:error, :invalid_approval}
end

defmodule Rho.Test.Dyn do
  @moduledoc """
  Starting a Keeper on a tmp dir, simulated launches, and Dyn sources.

  Dyn tests compile into the one VM-wide code server, so they run
  `async: false` and purge every module of the namespace around each test.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Rho.Dyn
  alias Rho.Dyn.Compiler
  alias Rho.Dyn.Config
  alias Rho.Dyn.Keeper

  @keeper Rho.Dyn.Keeper

  @fast [
    approval: Rho.Test.Dyn.Approval,
    selftest_timeout_ms: 2_000,
    stable_delay_ms: 0,
    gc_retry_ms: 50
  ]

  @doc """
  Purges every loaded module of the namespace (`Rho.Dyn.Config`) and every protocol
  implementation for a generation's module (a fresh VM, as far as Dyn goes).
  """
  def purge_all do
    prefix = "Elixir.#{Config.namespace_name()}."

    for {mod, _} <- :code.all_loaded(),
        String.starts_with?(Atom.to_string(mod), prefix) or
          Compiler.generation_of(mod) != nil do
      :code.purge(mod)
      :code.delete(mod)
      :code.purge(mod)
    end

    :ok
  end

  @doc "Starts the app-named Keeper on `dir` (supervised by the test) and boots it."
  def start_keeper(dir, opts \\ []) do
    start_supervised!({Keeper, Keyword.merge(@fast ++ [dir: dir], opts)}, id: @keeper)
    Keeper.boot(@keeper)
  end

  @doc """
  A new launch: the previous one dies (Keeper stopped, Dyn modules gone)
  and the next one boots. `stable: true` lets the previous launch reach
  stable first.
  """
  def relaunch(dir, opts \\ []) do
    if Keyword.get(opts, :stable, false), do: :ok = Keeper.mark_stable(@keeper)
    :ok = stop_supervised(@keeper)
    purge_all()
    start_keeper(dir, Keyword.delete(opts, :stable))
  end

  @doc "Stages `files` (`%{path => source}`) over the current generation and proposes them."
  def propose!(files, rationale \\ "test change") do
    :ok = Dyn.stage_reset()
    Enum.each(files, fn {path, source} -> :ok = Dyn.stage_put(path, source) end)
    assert {:ok, proposal} = Dyn.propose(rationale)
    proposal
  end

  @doc "Proposes and activates; returns the generation number."
  def activate!(files, rationale \\ "test change") do
    %{n: n} = propose!(files, rationale)
    {:ok, token} = Dyn.request_approval({:activate, n})
    assert {:ok, %{status: :probation}} = Dyn.activate(n, token)
    n
  end

  @doc "Waits for `{:rho_dyn, %{type: type}}` (discarding others)."
  def await_dyn(type, timeout \\ 2_000) do
    receive do
      {:rho_dyn, %{type: ^type} = event} -> event
      {:rho_dyn, _other} -> await_dyn(type, timeout)
    after
      timeout -> flunk("no #{type} event")
    end
  end

  @doc "A Dyn tool module `<ns>.<mod>` named `name`; `run_body` / `selftest_body` are source."
  def tool(mod, name, opts \\ []) do
    """
    defmodule #{Config.namespace_name()}.#{mod} do
      @behaviour Rho.Tool

      def name, do: #{inspect(name)}
      def description, do: "A test tool."
      def parameter_schema, do: %{"type" => "object", "properties" => %{}}
      def run(_args, _ctx), do: #{Keyword.get(opts, :run, "{:ok, #{inspect("ran " <> name)}}")}
      def selftest, do: #{Keyword.get(opts, :selftest, ":ok")}
    end
    """
  end

  @doc "A Dyn screen module `<ns>.<mod>` showing `text`."
  def screen(mod, text, opts \\ []) do
    """
    defmodule #{Config.namespace_name()}.#{mod} do
      use Mob.Screen

      def mount(_params, _session, socket) do
        #{Keyword.get(opts, :mount, "{:ok, Mob.Socket.assign(socket, :text, #{inspect(text)})}")}
      end

      def render(assigns) do
        ~MOB\"\"\"
        <Column padding={:space_lg}>
          <Text text={assigns.text} text_color={:on_surface} />
        </Column>
        \"\"\"
      end
    end
    """
  end
end
