defmodule Rho.ConsultTest do
  use ExUnit.Case, async: true

  import Rho.Test.LoopHelpers

  alias Rho.Budget
  alias Rho.Consult
  alias Rho.LLM.ReqLLM, as: Adapter
  alias Rho.Loop
  alias Rho.Session
  alias Rho.Settings.File, as: Settings
  alias Rho.Test.FakeLLM

  @moduletag :tmp_dir
  @moduletag :capture_log

  @gemini "google:gemini-3.1-pro-preview"

  defp text_of(%ReqLLM.Message{content: parts}), do: Enum.map_join(parts, "", & &1.text)

  defp consult_events do
    receive do
      {:rho, _sid, %{type: :consult_end} = e} ->
        [e]

      {:rho, _sid, %{type: t} = e} when t in [:consult_start, :consult_delta] ->
        [e | consult_events()]

      {:rho, _sid, _other} ->
        consult_events()
    after
      2_000 -> flunk("no consult_end")
    end
  end

  defp entries(session) do
    {:ok, _session, entries} = Session.open(session.path, model())
    entries
  end

  test "a consult on the session: streamed to subscribers, usage in the session, no turn",
       %{tmp_dir: dir} do
    usage = %{input_tokens: 50, output_tokens: 10, total_cost: 0.002}
    script = [[{:text, "1. (high) "}, {:text, "Wrong."}, {:usage, usage}]]
    %{loop: loop, session: session} = start_loop(dir, script)

    assert {:ok, %{text: "1. (high) Wrong.", model: @gemini, purpose: "critique", usage: u}} =
             Consult.run(@gemini, "Review: 2+2=5", loop: loop, purpose: "critique")

    assert u["output"] == 10 and u["cost"]["total"] == 0.002

    assert_received {:llm_request, request, _worker}
    assert request.model == @gemini
    assert request.system_prompt == Consult.default_system("critique")
    assert request.tools == []
    assert [user] = request.messages
    assert text_of(user) == "Review: 2+2=5"

    events = consult_events()

    assert [
             %{type: :consult_start, id: id, model: @gemini, purpose: "critique", call_id: nil},
             %{type: :consult_delta, id: id, kind: :text, delta: "1. (high) "},
             %{type: :consult_delta, id: id, kind: :text, delta: "Wrong."},
             %{type: :consult_end, id: id, status: :ok, text: "1. (high) Wrong.", error: nil} = e
           ] = events

    assert %{"type" => "custom", "data" => %{"id" => ^id, "status" => "ok"}} = e.entry

    # the session's own record; it counts in the totals, and no run started
    assert [%{"type" => "custom", "customType" => "rho.consult", "data" => data}] =
             Enum.filter(entries(session), &(&1["type"] == "custom"))

    assert %{"model" => @gemini, "purpose" => "critique", "callId" => nil} = data
    snapshot = Loop.snapshot(loop)
    assert snapshot.totals.cost == 0.002 and snapshot.totals.output == 10
    assert snapshot.status == :idle and snapshot.consults == []
    refute_received {:rho, _, %{type: :agent_start}}
    # it isn't sent to the lead
    assert Loop.context(loop) == []
  end

  test "with the conversation: the transcript before the prompt, the newest part when too long",
       %{tmp_dir: dir} do
    script = [[{:text, "Four."}], [{:text, "Fine."}], [{:text, "Five."}], [{:text, "Ok."}]]
    %{loop: loop, llm: llm} = start_loop(dir, script)
    :ok = Loop.prompt(loop, "What is 2+2?")
    collect()

    assert {:ok, _} =
             Consult.run(@gemini, "Is the answer right?", loop: loop, include_conversation: true)

    text = llm |> FakeLLM.requests() |> List.last() |> Map.fetch!(:messages) |> hd() |> text_of()

    assert text =~
             ~r/<conversation>\n\[User\]: What is 2\+2\?\n\n\[Assistant\]: Four\.\n<\/conversation>/

    assert String.ends_with?(text, "Is the answer right?")

    # over half the consulted model's window: the oldest part is cut
    :ok = Loop.prompt(loop, "FIRST " <> String.duplicate("long text ", 40_000))
    collect()
    assert {:ok, _} = Consult.run(@gemini, "Again?", loop: loop, include_conversation: true)
    text = llm |> FakeLLM.requests() |> List.last() |> Map.fetch!(:messages) |> hd() |> text_of()
    assert text =~ "earlier characters cut"
    refute text =~ "What is 2+2?"
    refute text =~ "FIRST"
    assert text =~ "[Assistant]: Five.\n</conversation>"
  end

  test "an attributed turn: the other model's own entry, sent marked, read back",
       %{tmp_dir: dir} do
    %{loop: loop, session: session} = start_loop(dir, [[{:text, "Fixed: 4."}]])

    :ok =
      Loop.prompt(loop, "1. (high) 2+2 is 4.",
        attribution: {:model, @gemini, "critique"},
        instruction: "Respond to each point."
      )

    events = collect()

    assert [entry] =
             for(
               %{type: :message_end, entry: %{"type" => "custom_message"} = e} <- events,
               do: e
             )

    assert entry["content"] == "1. (high) 2+2 is 4."
    assert entry["customType"] == "rho.model_message"
    assert Session.attribution(entry) == %{model: @gemini, purpose: "critique"}
    assert Session.notice_kind(entry) == nil

    assert_received {:llm_request, request, _}
    [sent] = request.messages
    assert sent.role == :user

    assert text_of(sent) ==
             ~s|<model_message model="#{@gemini}" purpose="critique">\n| <>
               "This is from another model (#{@gemini}), not from the user.\n\n" <>
               "1. (high) 2+2 is 4.\n</model_message>\n\nRespond to each point."

    # read back from disk, it builds the same request; a user's message has no attribution
    stored = entries(session)
    assert [^sent, %{role: :assistant}] = Session.context(stored)
    assert [%{} = from_disk] = Enum.filter(stored, &Session.attribution/1)
    assert from_disk["details"]["instruction"] == "Respond to each point."
    assert Session.attribution(Session.user("hi")) == nil
    assert Session.attribution(Session.custom(:notice, "x")) == nil
  end

  test "attribution through steer and follow_up; bad attributions raise", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[{:sleep, 100}, {:text, "a"}], [{:text, "b"}]])
    :ok = Loop.prompt(loop, "go")
    :ok = Loop.follow_up(loop, "Second look.", attribution: {:model, @gemini, "second_opinion"})
    events = collect()

    assert [{_, "Second look."}] =
             for(
               %{type: :message_end, entry: %{"type" => "custom_message"} = e} <- events,
               do: {Session.attribution(e), e["content"]}
             )

    assert_raise ArgumentError, fn ->
      Loop.steer(loop, "x", attribution: {:model, @gemini, "critique"}, attachments: [att()])
    end

    assert_raise ArgumentError, fn ->
      Loop.steer(loop, "", attribution: {:model, @gemini, "c"})
    end

    assert_raise ArgumentError, fn -> Loop.steer(loop, "x", instruction: "no attribution") end
    assert_raise ArgumentError, fn -> Loop.steer(loop, "x", attribution: {:user, "x"}) end
  end

  defp att, do: %{kind: :text, name: "a.txt", mime: "text/plain", about: "a", path: "/tmp/a.txt"}

  test "Rho.Loop.stop stops a consult while the loop is idle; its call is killed",
       %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[:block]])
    task = Task.async(fn -> Consult.run(@gemini, "Review", loop: loop, purpose: "critique") end)
    assert_receive {:llm_request, _request, worker}, 2_000
    ref = Process.monitor(worker)
    assert [%{id: id, model: @gemini}] = Loop.snapshot(loop).consults

    :ok = Loop.stop(loop)

    assert Task.await(task) == {:error, :stopped}
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 2_000

    assert [_start, %{type: :consult_end, id: ^id, status: :stopped, entry: nil}] =
             consult_events()

    assert Loop.snapshot(loop).consults == []
    assert Consult.describe(:stopped) =~ "stopped"
  end

  test "a stopped consult leaves nothing in its caller's mailbox; the next one runs",
       %{tmp_dir: dir} do
    # the call streams a delta only after the stops are in the caller's mailbox
    script = [[{:sleep, 150}, {:text, "late"}, :block], [{:text, "Second."}]]
    %{loop: loop} = start_loop(dir, script)

    task =
      Task.async(fn ->
        first = Consult.run(@gemini, "Review", loop: loop)
        left = Process.info(self(), :messages)
        {first, left, Consult.run(@gemini, "Again", loop: loop)}
      end)

    assert_receive {:llm_request, _request, _worker}, 2_000
    :erlang.suspend_process(task.pid)
    for _ <- 1..3, do: :ok = Loop.stop(loop)
    Process.sleep(300)
    :erlang.resume_process(task.pid)

    assert {{:error, :stopped}, {:messages, []}, {:ok, %{text: "Second."}}} = Task.await(task)
  end

  test "a tool answer that raced the stop doesn't stay in the caller's mailbox",
       %{tmp_dir: dir} do
    call = [{:tool_call, "t", "echo", %{"text" => "x", "sleep_ms" => 300}}]
    %{loop: loop} = start_loop(dir, [call])

    task =
      Task.async(fn ->
        result = Consult.run(@gemini, "q", loop: loop, tools: [Rho.Test.Tools.Echo])
        {result, Process.info(self(), :messages)}
      end)

    assert_receive {:llm_request, _request, _worker}, 2_000
    Process.sleep(100)
    :erlang.suspend_process(task.pid)
    :ok = Loop.stop(loop)
    Process.sleep(400)
    :erlang.resume_process(task.pid)

    assert {{:error, :stopped}, {:messages, []}} = Task.await(task)
  end

  test "a tool the consulted model runs dies with the consult's caller", %{tmp_dir: dir} do
    sup = start_supervised!(Task.Supervisor, id: :consult_tools)
    call = [{:tool_call, "t", "echo", %{"text" => "x", "sleep_ms" => 5_000}}]
    {:ok, llm} = FakeLLM.start([call])

    caller =
      spawn(fn ->
        Consult.run(@gemini, "q",
          llm: {FakeLLM, llm},
          tools: [Rho.Test.Tools.Echo],
          task_supervisor: sup,
          data_dir: dir
        )
      end)

    assert [tool] = wait_until(fn -> Task.Supervisor.children(sup) end, &(&1 != []))
    ref = Process.monitor(tool)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^tool, :killed}, 2_000
  end

  defp wait_until(fun, ok?, tries \\ 100) do
    value = fun.()

    cond do
      ok?.(value) -> value
      tries == 0 -> flunk("timed out; last: #{inspect(value)}")
      true -> Process.sleep(20) && wait_until(fun, ok?, tries - 1)
    end
  end

  test "a model message dropped at the iteration limit is named as not sent", %{tmp_dir: dir} do
    script = [[{:tool_call, "c1", "echo", %{"text" => "x", "sleep_ms" => 200}}], [{:text, "S"}]]
    %{loop: loop} = start_loop(dir, script, max_iterations: 1)
    :ok = Loop.prompt(loop, "go")
    assert_receive {:rho, _, %{type: :tool_execution_start}}, 2_000
    :ok = Loop.steer(loop, "Point 1 is wrong.", attribution: {:model, @gemini, "critique"})
    events = collect()

    notices = for %{type: :message_end, entry: %{"type" => "custom_message"} = e} <- events, do: e
    assert Enum.any?(notices, &(&1["content"] =~ "Not sent: Point 1 is wrong."))
    refute Enum.any?(notices, &Session.attribution/1)
  end

  test "the loop exiting stops a consult", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[:block]])
    task = Task.async(fn -> Consult.run(@gemini, "Review", loop: loop) end)
    assert_receive {:llm_request, _request, worker}, 2_000
    ref = Process.monitor(worker)

    GenServer.stop(loop)

    assert Task.await(task) == {:error, :stopped}
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 2_000
    assert Consult.run(@gemini, "again", loop: loop) == {:error, :stopped}
  end

  test "a caller that dies takes its model call with it; the loop ends the consult",
       %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[:block]])
    caller = spawn(fn -> Consult.run(@gemini, "Review", loop: loop) end)
    assert_receive {:llm_request, _request, worker}, 2_000
    ref = Process.monitor(worker)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 2_000
    assert [_start, %{type: :consult_end, status: :error, error: error}] = consult_events()
    assert error =~ "exited"
  end

  test "tools: the consulted model calls one, reads its result, answers; usage summed",
       %{tmp_dir: dir} do
    script = [
      [{:text, "Checking."}, {:tool_call, "t1", "echo", %{"text" => "John 3:16 says ..."}}],
      [{:text, "The citation holds."}]
    ]

    %{loop: loop} = start_loop(dir, script)

    assert {:ok, %{text: "The citation holds.", usage: usage}} =
             Consult.run(@gemini, "Check the citation", loop: loop, tools: [Rho.Test.Tools.Echo])

    assert usage["output"] == 40
    assert_in_delta usage["cost"]["total"], 0.002, 1.0e-9
    assert_received {:llm_request, first, _}
    assert_received {:llm_request, second, _}
    assert Enum.map(first.tools, & &1.name) == ["echo"]

    assert [_user, %{role: :assistant, tool_calls: [_]}, %{role: :tool} = result] =
             second.messages

    assert text_of(result) == "John 3:16 says ..."
  end

  test "tools: the last allowed call is told to answer", %{tmp_dir: dir} do
    call = [{:tool_call, "t", "echo", %{"text" => "x"}}]
    %{loop: loop} = start_loop(dir, [call, call ++ [{:text, "Answer."}]])

    assert {:ok, %{text: "Answer."}} =
             Consult.run(@gemini, "q",
               loop: loop,
               tools: [Rho.Test.Tools.Echo],
               max_iterations: 2
             )

    assert_received {:llm_request, _, _}
    assert_received {:llm_request, last, _}
    assert text_of(List.last(last.messages)) =~ "last model call"
  end

  test "the loop's daily cost cap: refused before the call", %{tmp_dir: dir} do
    :ok = Settings.put_daily_cap(0.01, dir)
    :ok = Budget.record(dir, 0.02)
    %{loop: loop} = start_loop(dir, [[{:text, "never"}]], budget: dir)

    assert {:error, {:cost_cap, spent, cap}} = Consult.run(@gemini, "q", loop: loop)
    assert spent == 0.02 and cap == 0.01
    refute_received {:llm_request, _, _}
    assert Consult.describe({:cost_cap, spent, cap}) =~ "$0.02 of $0.01"
    # nothing reached the model, so nothing is recorded
    assert [_start, %{type: :consult_end, status: :error, entry: nil}] = consult_events()
  end

  test "a consult's cost goes against the loop's budget", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[{:text, "ok"}]], budget: dir)
    assert {:ok, _} = Consult.run(@gemini, "q", loop: loop)
    assert Budget.spent(dir) == 0.001
  end

  test "without a loop: the given model client, no session", %{tmp_dir: _dir} do
    {:ok, llm} = FakeLLM.start([[{:text, "Hi."}]])

    assert {:ok, %{text: "Hi.", purpose: "second_opinion"}} =
             Consult.run(@gemini, "hello", llm: {FakeLLM, llm}, system: "Be terse.")

    assert_received {:llm_request, %{system_prompt: "Be terse."} = request, _}
    refute Map.has_key?(request, :session_id)
    assert_raise ArgumentError, fn -> Consult.run(@gemini, "x", include_conversation: true) end
  end

  test "an empty answer or a model error comes back as an error", %{tmp_dir: _dir} do
    {:ok, llm} = FakeLLM.start([[{:text, "  "}], [{:error, {:http, 500, "boom"}}]])
    assert {:error, {:other, msg}} = Consult.run(@gemini, "q", llm: {FakeLLM, llm})
    assert msg =~ "no text"
    assert {:error, {:http, 500, "boom"}} = Consult.run(@gemini, "q", llm: {FakeLLM, llm})
  end

  test "Gemini: the consult's request, as req_llm's Google provider sends it", %{tmp_dir: dir} do
    {:ok, llm} = FakeLLM.start([[{:text, "ok"}]])

    {:ok, _} =
      Consult.run(@gemini, "Review this answer.",
        llm: {FakeLLM, llm},
        purpose: "critique",
        data_dir: dir
      )

    assert_received {:llm_request, request, _}
    key = %{type: :api_key, key: "AIza-TEST"}
    {:ok, opts} = Adapter.options(request, fn :google -> {:ok, key} end)
    refute Keyword.has_key?(opts, :tools)

    context =
      ReqLLM.Context.new([ReqLLM.Context.system(request.system_prompt) | request.messages])

    {:ok, model} = ReqLLM.model(request.model)
    {:ok, provider} = ReqLLM.provider(model.provider)
    {:ok, finch} = provider.attach_stream(model, context, opts, nil)

    assert model.provider == :google
    assert finch.path =~ "gemini-3.1-pro-preview:streamGenerateContent"

    assert for({k, v} <- finch.headers, String.downcase(k) == "x-goog-api-key", do: v) == [
             "AIza-TEST"
           ]

    body = Jason.decode!(finch.body)

    assert [%{"role" => "user", "parts" => [%{"text" => "Review this answer."}]}] =
             body["contents"]

    assert Jason.encode!(body["systemInstruction"]) =~ "Push back"
    refute Map.has_key?(body, "tools")
  end
end
