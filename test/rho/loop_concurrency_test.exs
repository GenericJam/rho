defmodule Rho.LoopConcurrencyTest.Gate do
  @moduledoc """
  Test tools' body: tells the process registered as `args["to"]`
  `{:started, call_id, pid}`, waits for `:go`, answers with the call id.
  """
  def run(args, ctx) do
    send(String.to_existing_atom(args["to"]), {:started, ctx.call_id, self()})

    receive do
      :go -> {:ok, ctx.call_id}
    end
  end
end

defmodule Rho.LoopConcurrencyTest.Shared do
  @moduledoc "Test tool: an ordinary (parallel) gated tool."
  @behaviour Rho.Tool
  alias Rho.LoopConcurrencyTest.Gate

  @impl true
  def name, do: "shared"
  @impl true
  def description, do: "Gated."
  @impl true
  def parameter_schema, do: %{"type" => "object"}
  @impl true
  def run(args, ctx), do: Gate.run(args, ctx)
end

defmodule Rho.LoopConcurrencyTest.Alone do
  @moduledoc "Test tool: an exclusive gated tool."
  @behaviour Rho.Tool
  alias Rho.LoopConcurrencyTest.Gate

  @impl true
  def name, do: "alone"
  @impl true
  def description, do: "Gated, one at a time."
  @impl true
  def parameter_schema, do: %{"type" => "object"}
  @impl true
  def concurrency, do: :exclusive
  @impl true
  def run(args, ctx), do: Gate.run(args, ctx)
end

defmodule Rho.LoopConcurrencyTest.Confused do
  @moduledoc "Test tool: its `concurrency/0` raises."
  @behaviour Rho.Tool
  alias Rho.LoopConcurrencyTest.Gate

  @impl true
  def name, do: "confused"
  @impl true
  def description, do: "Raises when asked how it runs."
  @impl true
  def parameter_schema, do: %{"type" => "object"}
  @impl true
  def concurrency, do: raise("no idea")
  @impl true
  def run(args, ctx), do: Gate.run(args, ctx)
end

defmodule Rho.LoopConcurrencyTest do
  use ExUnit.Case, async: true

  import Rho.Test.LoopHelpers

  alias Rho.Loop
  alias Rho.LoopConcurrencyTest.Alone
  alias Rho.LoopConcurrencyTest.Confused
  alias Rho.LoopConcurrencyTest.Shared
  alias Rho.Session

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup do
    name = :"loop_concurrency_#{System.unique_integer([:positive])}"
    Process.register(self(), name)
    %{to: Atom.to_string(name)}
  end

  defp start(dir, calls, to) do
    reply = for {id, tool} <- calls, do: {:tool_call, id, tool, %{"to" => to}}

    %{loop: loop} =
      start_loop(dir, [reply, [{:text, "done"}]],
        tools: [Shared, Alone, Confused],
        inputs: [:text]
      )

    :ok = Loop.prompt(loop, "go")
  end

  defp result_ids(events) do
    for %{type: :message_end, entry: %{"message" => %{"role" => "toolResult"} = m}} <- events,
        do: {m["toolCallId"], Session.text(m["content"])}
  end

  test "a turn with an exclusive call runs its calls one at a time, in order",
       %{tmp_dir: dir, to: to} do
    start(dir, [{"a", "alone"}, {"x", "shared"}, {"b", "alone"}], to)

    for id <- ["a", "x", "b"] do
      assert_receive {:started, ^id, pid}, 2_000
      # Nothing else starts while it runs.
      refute_receive {:started, _, _}, 100
      send(pid, :go)
    end

    assert result_ids(collect()) == [{"a", "a"}, {"x", "x"}, {"b", "b"}]
  end

  test "a turn of parallel calls still runs them together", %{tmp_dir: dir, to: to} do
    start(dir, [{"p", "shared"}, {"q", "shared"}, {"r", "confused"}], to)

    # All three are running before any is let go.
    pids =
      for _ <- 1..3 do
        assert_receive {:started, id, pid}, 2_000
        {id, pid}
      end

    assert pids |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["p", "q", "r"]
    Enum.each(pids, fn {_, pid} -> send(pid, :go) end)

    assert result_ids(collect()) == [{"p", "p"}, {"q", "q"}, {"r", "r"}]
  end
end
