defmodule Rho.LoopTodoTest.Ctx do
  @moduledoc "Test tool: answers with what the loop put in its ctx."
  @behaviour Rho.Tool

  @impl true
  def name, do: "ctx"
  @impl true
  def description, do: "Shows the tool ctx."
  @impl true
  def parameter_schema, do: %{"type" => "object"}
  @impl true
  def run(_args, ctx), do: {:ok, inspect({ctx.loop, Map.get(ctx, :withheld, [])})}
end

defmodule Rho.LoopTodoTest do
  use ExUnit.Case, async: true

  import Rho.Test.LoopHelpers

  alias Rho.Loop
  alias Rho.LoopTodoTest.Ctx
  alias Rho.Session
  alias Rho.Test.FakeLLM
  alias Rho.Tools.Todo

  @moduletag :tmp_dir
  @moduletag :capture_log

  @set {:tool_call, "t1", "todo", %{"action" => "set", "items" => ["write it", "test it"]}}

  defp notices(events) do
    for %{type: :message_end, entry: %{"type" => "custom_message"} = e} <- events,
        do: e["content"]
  end

  defp last_user_text(request) do
    request.messages
    |> Enum.filter(&(&1.role == :user))
    |> List.last()
    |> Map.fetch!(:content)
    |> Enum.map_join("", & &1.text)
  end

  test "a run that stops with open todo items gets one reminder turn, then ends",
       %{tmp_dir: dir} do
    script = [[@set], [{:text, "all done"}], [{:text, "blocked: need the user"}]]
    %{loop: loop, llm: llm} = start_loop(dir, script, tools: [Todo], inputs: [:text])
    :ok = Loop.prompt(loop, "go")
    events = collect()

    reminder =
      ~s(You stopped with open todo items: "write it"; "test it". Continue with them, ) <>
        "or if you're blocked or need the user, say so and stop."

    assert notices(events) == [reminder]
    assert List.last(events) == %{type: :agent_end, reason: :done}

    # The reminder is the last thing the model read, and it had one more call.
    assert [_, _, third] = FakeLLM.requests(llm)
    assert last_user_text(third) == reminder

    # Persisted as a notice entry.
    {:ok, _session, entries} = Session.open(Loop.snapshot(loop).path, model())

    assert Enum.any?(
             entries,
             &(&1["customType"] == "rho.notice" and &1["content"] == reminder)
           )
  end

  test "a run whose todo items are all done ends without a reminder", %{tmp_dir: dir} do
    set = {:tool_call, "t1", "todo", %{"action" => "set", "items" => ["write it"]}}
    done = {:tool_call, "t2", "todo", %{"action" => "done", "index" => 1}}
    script = [[set], [done], [{:text, "all done"}]]
    %{loop: loop, llm: llm} = start_loop(dir, script, tools: [Todo], inputs: [:text])
    :ok = Loop.prompt(loop, "go")
    events = collect()

    assert notices(events) == []
    assert List.last(events) == %{type: :agent_end, reason: :done}
    assert [_, _, _] = FakeLLM.requests(llm)
  end

  test "a loop without the todo tool never reminds", %{tmp_dir: dir} do
    %{loop: loop, session: session} = start_loop(dir, [[{:text, "hi"}]], inputs: [:text])

    {:ok, _} =
      Todo.run(%{"action" => "set", "items" => ["left over"]}, %{
        session_id: session.id,
        data_dir: dir
      })

    :ok = Loop.prompt(loop, "go")
    assert notices(collect()) == []
  end

  test "a subagent (a loop that withholds task) ends with its answer, not a reminder",
       %{tmp_dir: dir} do
    script = [[@set], [{:text, "the research answer"}]]

    %{loop: loop, llm: llm} =
      start_loop(dir, script, tools: [Todo], withhold_tools: ["task"], inputs: [:text])

    :ok = Loop.prompt(loop, "go")
    events = collect()

    assert notices(events) == []
    assert List.last(events) == %{type: :agent_end, reason: :done}
    assert [_, _] = FakeLLM.requests(llm)
  end

  test "a tool's ctx carries its loop and the names the loop withholds", %{tmp_dir: dir} do
    script = [[{:tool_call, "c1", "ctx", %{}}], [{:text, "ok"}]]

    %{loop: loop} =
      start_loop(dir, script, tools: [Ctx], withhold_tools: ["notes"], inputs: [:text])

    :ok = Loop.prompt(loop, "go")
    events = collect()

    assert [text] = for(%{type: :tool_execution_end, name: "ctx", text: t} <- events, do: t)
    assert text == inspect({loop, ["notes"]})
  end
end
