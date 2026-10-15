defmodule Rho.LoopTest do
  use ExUnit.Case, async: true

  import Rho.Test.LoopHelpers

  alias Rho.Loop
  alias Rho.Session
  alias Rho.Settings.File, as: Settings
  alias Rho.Test.FakeLLM
  alias Rho.ToolRunner

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp result_texts(events) do
    for %{type: :message_end, entry: %{"message" => %{"role" => "toolResult"} = m}} <- events,
        do: {m["toolName"], Session.text(m["content"]), m["isError"]}
  end

  defp text_of(%ReqLLM.Message{content: parts}), do: Enum.map_join(parts, "", & &1.text)

  defp notices(events) do
    for %{type: :message_end, entry: %{"type" => "custom_message"} = e} <- events,
        do: e["content"]
  end

  test "a plain reply: pi's event order, streamed deltas, persisted", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[{:text, "Hel"}, {:text, "lo"}]])
    :ok = Loop.prompt(loop, "hi")
    events = collect()

    assert shape(events) == [
             :agent_start,
             :turn_start,
             {:message_start, "user"},
             {:message_end, "user"},
             {:message_start, "assistant"},
             :message_update,
             :message_update,
             {:message_end, "assistant"},
             :turn_end,
             :agent_end
           ]

    assert for(%{type: :message_update, delta: d} <- events, do: d) == ["Hel", "lo"]

    %{entry: assistant} =
      Enum.find(
        events,
        &match?(%{type: :message_end, entry: %{"message" => %{"role" => "assistant"}}}, &1)
      )

    assert message(assistant)["stopReason"] == "stop"
    assert Session.text(message(assistant)["content"]) == "Hello"
    assert List.last(events) == %{type: :agent_end, reason: :done}
    assert Loop.snapshot(loop).status == :idle
  end

  test "a tool turn: tools run, results feed the next model call", %{tmp_dir: dir} do
    script = [[{:tool_call, "c1", "echo", %{"text" => "pong"}}], [{:text, "done"}]]
    %{loop: loop, llm: llm} = start_loop(dir, script)
    :ok = Loop.prompt(loop, "ping")
    events = collect()

    assert shape(events) == [
             :agent_start,
             :turn_start,
             {:message_start, "user"},
             {:message_end, "user"},
             {:message_start, "assistant"},
             {:message_end, "assistant"},
             :tool_execution_start,
             :tool_execution_end,
             {:message_start, "toolResult"},
             {:message_end, "toolResult"},
             :turn_end,
             :turn_start,
             {:message_start, "assistant"},
             :message_update,
             {:message_end, "assistant"},
             :turn_end,
             :agent_end
           ]

    [_, second] = FakeLLM.requests(llm)

    assert [
             %{role: :user},
             %{role: :assistant, tool_calls: [_]},
             %{role: :tool, tool_call_id: "c1"} = tool
           ] = second.messages

    assert text_of(tool) == "pong"

    assert Enum.map(second.tools, & &1.name) |> Enum.sort() ==
             ["crash", "echo", "notes", "picture", "slow"]

    assert second.max_tokens == 4096
  end

  test "a tool's image goes to the model and into the session, after its text",
       %{tmp_dir: dir} do
    script = [[{:tool_call, "c1", "picture", %{}}], [{:text, "I see it"}]]
    %{loop: loop, llm: llm, session: session} = start_loop(dir, script)
    :ok = Loop.prompt(loop, "look")
    events = collect()

    assert result_texts(events) == [{"picture", "a picture", false}]

    [_, second] = FakeLLM.requests(llm)
    %{role: :tool, content: [text, image]} = List.last(second.messages)
    assert {text.type, text.text} == {:text, "a picture"}

    assert {image.type, image.data, image.media_type} ==
             {:image, <<137, 80, 78, 71>>, "image/png"}

    # Persisted pi-style, and read back the same way (a resumed session).
    {:ok, _session, entries} = Session.open(session.path, model())

    assert [%{"message" => %{"content" => [_, part]}}] =
             for(%{"message" => %{"role" => "toolResult"}} = e <- entries, do: e)

    assert part == %{
             "type" => "image",
             "data" => Base.encode64(<<137, 80, 78, 71>>),
             "mimeType" => "image/png"
           }

    assert [_, _, %{role: :tool, content: [_, %{type: :image}]}, _] = Session.messages(entries)
  end

  test "a tool's details go to the subscribers with its end, its text to the model and session",
       %{tmp_dir: dir} do
    script = [
      [{:tool_call, "c1", "details", %{}}, {:tool_call, "c2", "echo", %{}}],
      [{:text, "ok"}]
    ]

    tools = [Rho.Test.Tools.Details, Rho.Test.Tools.Echo]
    %{loop: loop, llm: llm, session: session} = start_loop(dir, script, tools: tools)
    :ok = Loop.prompt(loop, "look")
    events = collect()

    # In completion order: the two run side by side.
    ends = for %{type: :tool_execution_end} = e <- events, do: {e.name, e.text, e.details}
    assert Enum.sort(ends) == [{"details", "two verses", %{verses: [1, 2]}}, {"echo", "", nil}]

    [_, second] = FakeLLM.requests(llm)
    assert [%{role: :tool} = tool, _echo] = Enum.drop(second.messages, 2)
    assert text_of(tool) == "two verses"

    {:ok, _session, entries} = Session.open(session.path, model())

    assert [%{"message" => result}, _echo] =
             for(%{"message" => %{"role" => "toolResult"}} = e <- entries, do: e)

    assert Session.text(result["content"]) == "two verses"
    refute Map.has_key?(result, "details")
  end

  defp tool_result_messages(path) do
    {:ok, _session, entries} = Session.open(path, model())
    for %{"message" => %{"role" => "toolResult"} = m} <- entries, do: m
  end

  test "keep_details stores the host's part of a tool's details in its result entry",
       %{tmp_dir: dir} do
    script = [
      [{:tool_call, "c1", "details", %{}}, {:tool_call, "c2", "echo", %{}}],
      [{:text, "ok"}]
    ]

    tools = [Rho.Test.Tools.Details, Rho.Test.Tools.Echo]
    test = self()

    keep = fn name, details ->
      send(test, {:kept, name})
      %{first: hd(details.verses)}
    end

    %{loop: loop, llm: llm, session: session} =
      start_loop(dir, script, tools: tools, keep_details: keep)

    :ok = Loop.prompt(loop, "look")
    events = collect()

    # Called for the tool that answered with details only; the event still has them whole.
    assert_received {:kept, "details"}
    refute_received {:kept, "echo"}

    assert [%{verses: [1, 2]}] =
             for(%{type: :tool_execution_end, name: "details"} = e <- events, do: e.details)

    assert [%{"details" => %{"first" => 1}} = kept, echo] = tool_result_messages(session.path)
    assert kept["toolName"] == "details"
    refute Map.has_key?(echo, "details")

    # The entry the subscribers got is the one on disk.
    assert [%{"details" => %{"first" => 1}}] =
             for(
               %{type: :message_end, entry: %{"message" => %{"role" => "toolResult"} = m}} <-
                 events,
               m["toolName"] == "details",
               do: m
             )

    [_, second] = FakeLLM.requests(llm)
    refute inspect(second.messages) =~ "first"
  end

  test "a keep_details that raises, or keeps what JSON can't hold, stores nothing",
       %{tmp_dir: dir} do
    for keep <- [fn _name, _details -> raise "boom" end, fn _name, _details -> {:a, self()} end] do
      sub = Path.join(dir, inspect(make_ref()))
      script = [[{:tool_call, "c1", "details", %{}}], [{:text, "ok"}]]

      %{loop: loop, session: session} =
        start_loop(sub, script, tools: [Rho.Test.Tools.Details], keep_details: keep)

      :ok = Loop.prompt(loop, "look")
      assert List.last(collect()) == %{type: :agent_end, reason: :done}
      assert [result] = tool_result_messages(session.path)
      assert Session.text(result["content"]) == "two verses"
      refute Map.has_key?(result, "details")
    end
  end

  test "pictures in the model's reply land in its assistant entry, after the text",
       %{tmp_dir: dir} do
    png = <<137, 80, 78, 71, 13, 10>>
    script = [[{:text, "A fox:"}, {:image, "image/png", png}], [{:text, "again"}]]
    %{loop: loop, llm: llm, session: session} = start_loop(dir, script)
    :ok = Loop.prompt(loop, "draw a fox")
    events = collect()

    assert [%{"content" => content}] =
             for(
               %{type: :message_end, entry: %{"message" => %{"role" => "assistant"} = m}} <-
                 events,
               do: m
             )

    assert [%{"type" => "text", "text" => "A fox:"}, %{"type" => "image"} = image] = content
    assert image["mimeType"] == "image/png"
    assert Base.decode64!(image["data"]) == png

    {:ok, _session, entries} = Session.open(session.path, model())
    assert List.last(entries)["message"]["content"] == content

    # The next call sends the turn back as text only.
    :ok = Loop.prompt(loop, "another")
    collect()
    [_, second] = FakeLLM.requests(llm)
    assert [_user, %{role: :assistant} = sent, _again] = second.messages
    assert text_of(sent) == "A fox:"
    assert Enum.all?(sent.content, &(&1.type == :text))
  end

  describe "attachments" do
    defp photo do
      %{
        kind: :image,
        name: "IMG_0412.jpg",
        path: "/ws/inbox/IMG_0412.jpg",
        mime: "image/jpeg",
        about: "1.2 MB · 3024×4032 · GPS 49.28, -123.12",
        image: {"image/jpeg", <<0xFF, 0xD8, 0xFF, 0xD9>>}
      }
    end

    defp pdf(dir) do
      path = Path.join(dir, "report.pdf")
      File.write!(path, "%PDF-1.7 tiny")
      %{kind: :pdf, name: "report.pdf", path: path, mime: "application/pdf", about: "13 B"}
    end

    test "go to the model as blocks: typed text, each file's envelope, the picture, the PDF",
         %{tmp_dir: dir} do
      %{loop: loop, llm: llm} = start_loop(dir, [[{:text, "a cat"}]])
      notes = %{kind: :text, name: "notes.txt", path: "/ws/inbox/notes.txt", mime: "text/plain"}
      notes = Map.merge(notes, %{about: "8 B", text: "buy milk"})

      :ok = Loop.prompt(loop, "what's in this?", [photo(), notes, pdf(dir)])
      collect()

      [request] = FakeLLM.requests(llm)
      [%{role: :user, content: parts}] = request.messages

      assert [
               %{type: :text, text: "what's in this?"},
               %{type: :text, text: photo_envelope},
               %{type: :image, data: <<0xFF, 0xD8, 0xFF, 0xD9>>, media_type: "image/jpeg"},
               %{type: :text, text: notes_envelope},
               %{type: :text, text: "<attachment name=\"report.pdf\"" <> _},
               %{type: :file, data: "%PDF-1.7 tiny", media_type: "application/pdf"}
             ] = parts

      assert photo_envelope ==
               ~s|<attachment name="IMG_0412.jpg" type="image/jpeg" | <>
                 ~s|path="/ws/inbox/IMG_0412.jpg">\n| <>
                 "1.2 MB · 3024×4032 · GPS 49.28, -123.12\n</attachment>"

      assert notes_envelope =~ "8 B\nbuy milk\n</attachment>"
    end

    test "a model without pictures gets the path and metadata only", %{tmp_dir: dir} do
      %{loop: loop, llm: llm} = start_loop(dir, [[{:text, "ok"}]], inputs: [:text])
      :ok = Loop.prompt(loop, "", [photo(), pdf(dir)])
      collect()

      [request] = FakeLLM.requests(llm)
      [%{role: :user, content: parts}] = request.messages
      assert Enum.map(parts, & &1.type) == [:text, :text, :text]
      [envelope, note, pdf_envelope] = Enum.map(parts, & &1.text)
      assert envelope =~ ~s|path="/ws/inbox/IMG_0412.jpg"|
      assert envelope =~ "GPS 49.28, -123.12"
      assert note =~ "doesn't take pictures"
      assert pdf_envelope =~ "report.pdf"
    end

    test "persist, title an attachment-only session and come back on resume",
         %{tmp_dir: dir} do
      %{loop: loop, session: session} = start_loop(dir, [[{:text, "a cat"}]])
      :ok = Loop.prompt(loop, "", [photo()])
      collect()
      live = Loop.context(loop)

      {:ok, reopened, entries} = Session.open(session.path, "x")
      assert reopened.title == "IMG_0412.jpg"
      assert Session.context(entries, inputs: [:text, :image, :pdf]) == live

      [user] = for %{"message" => %{"role" => "user"}} = e <- entries, do: e
      assert Session.typed(message(user)) == ""

      assert [%{"name" => "IMG_0412.jpg", "path" => "/ws/inbox/IMG_0412.jpg", "kind" => "image"}] =
               Session.attachments(message(user))
    end

    test "steered and queued with the message", %{tmp_dir: dir} do
      script = [
        [{:tool_call, "c1", "echo", %{"text" => "x", "sleep_ms" => 150}}],
        [{:text, "ok"}]
      ]

      %{loop: loop, llm: llm} = start_loop(dir, script)
      :ok = Loop.prompt(loop, "start")
      await_event(:tool_execution_start)
      :ok = Loop.steer(loop, "", [photo()])
      assert Loop.snapshot(loop).queue.steering == ["IMG_0412.jpg"]
      collect()

      [_, second] = FakeLLM.requests(llm)
      assert [:text, :image] = Enum.map(List.last(second.messages).content, & &1.type)
    end
  end

  test "parallel tool calls: run together, results kept in call order", %{tmp_dir: dir} do
    calls = [
      {:tool_call, "a", "echo", %{"text" => "first", "sleep_ms" => 150}},
      {:tool_call, "b", "echo", %{"text" => "second"}}
    ]

    %{loop: loop} = start_loop(dir, [calls, [{:text, "ok"}]])
    :ok = Loop.prompt(loop, "go")
    events = collect()

    tool_events =
      for %{type: t, id: id} <- events,
          t in [:tool_execution_start, :tool_execution_end],
          do: {t, id}

    assert tool_events == [
             {:tool_execution_start, "a"},
             {:tool_execution_start, "b"},
             {:tool_execution_end, "b"},
             {:tool_execution_end, "a"}
           ]

    assert result_texts(events) == [{"echo", "first", false}, {"echo", "second", false}]
  end

  test "a crashing tool and a timed-out tool become error results; the run continues", %{
    tmp_dir: dir
  } do
    calls = [
      {:tool_call, "c", "crash", %{}},
      {:tool_call, "s", "slow", %{}},
      {:tool_call, "x", "nope", %{}}
    ]

    %{loop: loop, llm: llm} = start_loop(dir, [calls, [{:text, "recovered"}]])

    :ok = Loop.prompt(loop, "go")
    events = collect()

    assert [{"crash", crash, true}, {"slow", slow, true}, {"nope", nope, true}] =
             result_texts(events)

    assert crash =~ "Tool crashed" and crash =~ "boom"
    assert slow =~ "timed out after 50 ms"
    assert nope =~ "Tool not found: nope"
    assert [_, _] = FakeLLM.requests(llm)
    assert List.last(events).reason == :done
  end

  test "steer is injected at the next step boundary, not as a new run", %{tmp_dir: dir} do
    script = [[{:tool_call, "c1", "echo", %{"text" => "x", "sleep_ms" => 150}}], [{:text, "ok"}]]
    %{loop: loop, llm: llm} = start_loop(dir, script)
    :ok = Loop.prompt(loop, "start")
    await_event(:tool_execution_start)
    :ok = Loop.steer(loop, "also do y")
    events = collect()

    refute Enum.any?(events, &(&1.type == :agent_start))
    assert Enum.count(events, &(&1.type == :turn_start)) == 1

    # turn 2 opens with the steering message, after the tool batch
    after_results = Enum.drop_while(events, &(&1.type != :turn_end))

    assert [:turn_end, :queue, :turn_start, {:message_start, "user"}, {:message_end, "user"} | _] =
             shape(after_results)

    %{entry: steer} = Enum.find(after_results, &(&1.type == :message_end))
    assert message(steer)["steering"] == true

    [_, second] = FakeLLM.requests(llm)
    assert [_, _, %{role: :tool}, %{role: :user} = last] = second.messages
    assert text_of(last) == "also do y"
  end

  test "a note during a run lands after it, never between a tool call and its result", %{
    tmp_dir: dir
  } do
    script = [
      [{:tool_call, "c1", "echo", %{"text" => "x", "sleep_ms" => 150}}],
      [{:text, "ok"}],
      [{:text, "again ok"}]
    ]

    %{loop: loop, llm: llm} = start_loop(dir, script)
    :ok = Loop.prompt(loop, "start")
    await_event(:tool_execution_start)
    :ok = Loop.note(loop, :aside, "phone b says: hi")
    events = collect()
    assert {:message_end, "custom"} not in shape(events)

    # Right after agent_end; the next model call sees it, after the reply.
    assert %{entry: %{"customType" => "rho.aside"}} = await_event(:message_end)
    :ok = Loop.prompt(loop, "again")
    _ = collect()

    kinds =
      Enum.map(Loop.snapshot(loop).entries, &(&1["customType"] || &1["message"]["role"]))

    assert Enum.take(kinds, -5) == [
             "toolResult",
             "assistant",
             "rho.aside",
             "user",
             "assistant"
           ]

    third = List.last(FakeLLM.requests(llm))
    assert Enum.any?(third.messages, &(text_of(&1) == "phone b says: hi"))
  end

  test "follow_up runs once the agent would stop", %{tmp_dir: dir} do
    script = [[{:sleep, 100}, {:text, "first"}], [{:text, "second"}]]
    %{loop: loop, llm: llm} = start_loop(dir, script)
    :ok = Loop.prompt(loop, "one")
    await_event(:message_start)
    :ok = Loop.follow_up(loop, "two")
    events = collect()

    # (the first turn_start was consumed above)
    assert Enum.count(events, &(&1.type == :turn_end)) == 2
    assert Enum.count(events, &(&1.type == :agent_end)) == 1
    [first_end | _] = for %{type: :turn_end} = e <- events, do: e
    assert Session.text(message(first_end.entry)["content"]) == "first"
    [_, second] = FakeLLM.requests(llm)
    assert text_of(List.last(second.messages)) == "two"
  end

  test "stop aborts the stream, keeps the partial text and ends the run cleanly", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[{:text, "partial"}, :block]])
    :ok = Loop.prompt(loop, "go")
    assert_receive {:llm_request, _request, worker}
    await_event(:message_update)
    :ok = Loop.stop(loop)
    events = collect()

    assert [
             {:message_end, "assistant"},
             :turn_end,
             {:message_start, "custom"},
             {:message_end, "custom"},
             :agent_end
           ] =
             shape(events)

    %{entry: aborted} = hd(events)
    assert message(aborted)["stopReason"] == "aborted"
    assert Session.text(message(aborted)["content"]) == "partial"
    assert List.last(events).reason == :stopped
    refute Process.alive?(worker)

    # the loop is usable again
    assert Loop.snapshot(loop).status == :idle
  end

  test "stop during tools lets started tools finish and skips the rest", %{tmp_dir: dir} do
    calls = [
      {:tool_call, "a", "echo", %{"text" => "ran", "sleep_ms" => 150}},
      {:tool_call, "b", "echo", %{"text" => "never"}},
      {:tool_call, "c", "echo", %{"text" => "never"}}
    ]

    %{loop: loop, llm: llm} =
      start_loop(dir, [calls, [{:text, "unreachable"}]], max_tool_concurrency: 1)

    :ok = Loop.prompt(loop, "go")
    await_event(:tool_execution_start)
    :ok = Loop.stop(loop)
    events = collect()

    skipped = ToolRunner.skipped_text()

    assert result_texts(events) == [
             {"echo", "ran", false},
             {"echo", skipped, true},
             {"echo", skipped, true}
           ]

    assert for(%{type: :tool_execution_start, id: id} <- events, do: id) == []
    assert List.last(events).reason == :stopped
    assert [_] = FakeLLM.requests(llm)
  end

  describe "at max_iterations" do
    setup do
      %{call: [{:tool_call, "c", "echo", %{"text" => "again"}}]}
    end

    test "the run gets one last call for a status, its tool calls dropped; then it ends",
         %{tmp_dir: dir, call: call} do
      # The wrap-up reply tries a tool anyway; a fourth reply is never asked for.
      status = [{:text, "Done: A. Broken: B. Next: C."}, {:tool_call, "x", "echo", %{}}]
      script = [call, call, status, [{:text, "never sent"}]]
      %{loop: loop, llm: llm} = start_loop(dir, script, max_iterations: 2)
      :ok = Loop.prompt(loop, "loop forever")
      events = collect()

      assert List.last(events).reason == :max_iterations
      assert [first, _, last] = FakeLLM.requests(llm)
      # The tools stay declared (the conversation holds tool calls, and they
      # head the cached prompt); the notice and the loop keep them unused.
      assert first.tools != []
      assert Enum.map(last.tools, & &1.name) == Enum.map(first.tools, & &1.name)

      assert [notice] = notices(events)
      assert notice =~ "You've reached the limit of 2 model calls for this run"
      assert notice =~ "Don't call tools."
      assert last.messages |> List.last() |> text_of() == notice

      # The status is the run's last word, and the tool it asked for never ran.
      assert for(%{type: :tool_execution_start} = e <- events, do: e.id) == ["c", "c"]
      %{entries: entries} = Loop.snapshot(loop)
      assert %{"message" => %{"role" => "assistant"} = m} = List.last(entries)
      assert Session.text(m["content"]) == "Done: A. Broken: B. Next: C."
      assert Session.tool_calls(m) == []
    end

    test "stop during the wrap-up call ends the run as any stop does",
         %{tmp_dir: dir, call: call} do
      %{loop: loop, llm: llm} = start_loop(dir, [call, [:block]], max_iterations: 1)
      :ok = Loop.prompt(loop, "loop forever")
      # The wrap-up request comes after the tool batch; a loaded runner can take
      # longer than assert_receive's default 100 ms (flaked once on OTP 28 CI).
      assert_receive {:llm_request, _first, _worker}, 2_000
      assert_receive {:llm_request, _wrap_up, _worker}, 2_000

      :ok = Loop.stop(loop)
      events = collect()
      assert List.last(events).reason == :stopped
      assert [_, _] = FakeLLM.requests(llm)
    end

    test "a failed wrap-up call still ends the run at the limit", %{tmp_dir: dir, call: call} do
      script = [call, [{:error, {:other, "boom"}}]]
      %{loop: loop, llm: llm} = start_loop(dir, script, max_iterations: 1)
      :ok = Loop.prompt(loop, "loop forever")

      assert List.last(collect()).reason == :max_iterations
      assert [_, _] = FakeLLM.requests(llm)
    end

    test "the cost cap still holds for the wrap-up call", %{tmp_dir: dir, call: call} do
      :ok = Settings.put_daily_cap(0.01, dir)
      costly = [{:usage, %{input_tokens: 10, output_tokens: 5, total_cost: 0.02}} | call]
      script = [costly, [{:text, "x"}]]
      %{loop: loop, llm: llm} = start_loop(dir, script, max_iterations: 1, budget: dir)
      :ok = Loop.prompt(loop, "loop forever")
      events = collect()

      assert List.last(events).reason == :cost_cap
      assert [_] = FakeLLM.requests(llm)
      assert [_wrap_up, cap] = notices(events)
      assert cap =~ "Daily cost cap reached"
    end
  end

  test "a 429 is retried with backoff, then the reply goes through", %{tmp_dir: dir} do
    script = [
      [{:error, {:http, 429, "slow down"}}],
      [{:error, {:transport, :closed}}],
      [{:text, "ok"}]
    ]

    %{loop: loop} = start_loop(dir, script)

    :ok = Loop.prompt(loop, "hi")
    events = collect()

    assert [%{attempt: 1, delay_ms: 1}, %{attempt: 2, delay_ms: 2}] =
             for(%{type: :retry} = e <- events, do: e)

    assert Enum.count(events, &(&1.type == :turn_start)) == 1
    assert List.last(events).reason == :done
  end

  test "retries stop after two; a 402 is terminal and tells the user what to do", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[{:error, {:http, 402, "can only afford 8000"}}]])

    :ok = Loop.prompt(loop, "hi")
    events = collect()
    assert for(%{type: :retry} <- events, do: :retry) == []
    %{error: error, entry: entry} = Enum.find(events, &(&1.type == :turn_end))
    assert error =~ "can only afford 8000"
    assert error =~ "lower max_tokens"
    assert message(entry)["stopReason"] == "error"
    assert message(entry)["errorMessage"] == error
    assert List.last(events).reason == :error

    %{loop: loop2} = start_loop(dir, List.duplicate([{:error, {:http, 503, "busy"}}], 3))

    :ok = Loop.prompt(loop2, "hi")
    events = collect()
    assert [_, _] = for(%{type: :retry} <- events, do: :retry)
    assert List.last(events).reason == :error
  end

  test "before_tool_call can block a call", %{tmp_dir: dir} do
    gate = fn %{"name" => name}, %{session_id: sid} when is_binary(sid) ->
      if name == "echo", do: {:block, "needs approval"}, else: :allow
    end

    script = [[{:tool_call, "c", "echo", %{"text" => "x"}}], [{:text, "ok"}]]
    %{loop: loop} = start_loop(dir, script, before_tool_call: gate)
    :ok = Loop.prompt(loop, "go")
    assert [{"echo", "Blocked before running: needs approval", true}] = result_texts(collect())
  end

  test "prompt while running is refused; steer while idle starts a run", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[{:sleep, 100}, {:text, "a"}], [{:text, "b"}]])
    :ok = Loop.prompt(loop, "one")
    assert {:error, :running} = Loop.prompt(loop, "two")
    collect()
    :ok = Loop.steer(loop, "three")
    assert [:agent_start | _] = shape(collect())
  end

  test "the session file replays to the exact context the live loop sends", %{tmp_dir: dir} do
    script = [
      [
        {:thinking, "hmm"},
        {:text, "Let me note that."},
        {:tool_call, "n1", "notes", %{"action" => "append", "text" => "milk"}}
      ],
      [{:text, "Noted."}],
      [{:text, "Still here."}]
    ]

    %{loop: loop, session: session} = start_loop(dir, script)
    :ok = Loop.prompt(loop, "remember milk")
    collect()
    assert File.read!(Path.join(dir, "notes.md")) == "milk\n"

    live = Loop.context(loop)
    {:ok, reopened, entries} = Session.open(session.path, "anthropic:unused")
    assert Session.context(entries) == live
    assert reopened.model == model()
    assert [_, _, _, _] = live

    # resume: a new loop on the reopened session continues the same file and chain
    GenServer.stop(loop)

    %{loop: resumed, llm: llm} =
      start_loop(dir, Enum.drop(script, 2), session: {reopened, entries})

    assert Loop.context(resumed) == live
    :ok = Loop.prompt(resumed, "still there?")
    collect()
    [request] = FakeLLM.requests(llm)
    assert Enum.take(request.messages, 4) == live

    {:ok, _, all} = Session.open(session.path, "x")
    ids = Enum.map(all, & &1["id"])
    assert Enum.map(all, & &1["parentId"]) == [nil | Enum.drop(ids, -1)]
  end
end
