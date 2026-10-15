defmodule Rho.CompactionTest do
  use ExUnit.Case, async: true

  import Rho.Test.LoopHelpers

  alias Rho.Budget
  alias Rho.Compaction
  alias Rho.Loop
  alias Rho.Session
  alias Rho.Settings.File, as: Settings
  alias Rho.Test.FakeLLM
  alias Rho.Test.Tools.Echo

  @moduletag :tmp_dir
  @moduletag :capture_log

  @overflow "This endpoint's maximum context length is 200000 tokens. However, you requested about 250000 tokens (249000 of text input, 1000 in the output)."

  # Compaction starts above 10,000 estimated tokens (a 40k window less a
  # 30k reserve); the summarizer, sized by the same window, takes ~11.5k.
  @window 40_000
  @reserve 30_000

  # `tokens` estimated tokens of `char` (the estimate is bytes / 4).
  defp long(char, tokens), do: String.duplicate(char, tokens * 4)

  defp text_of(%ReqLLM.Message{content: parts}), do: Enum.map_join(parts, "", & &1.text)

  defp id(entry, id), do: Map.put(entry, "id", id)

  defp lines(path),
    do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp start(dir, script, opts \\ []) do
    start_loop(
      dir,
      script,
      [
        tools: [Echo],
        context_window: @window,
        reserve_tokens: @reserve,
        keep_recent_tokens: 1500
      ] ++ opts
    )
  end

  defp prompt!(loop, text) do
    :ok = Loop.prompt(loop, text)
    collect()
  end

  defp entry(events, type), do: Enum.find_value(events, &(&1.type == type && &1[:entry]))

  describe "the cut point" do
    setup do
      call = %{"id" => "c1", "name" => "echo", "arguments" => %{}}

      reply =
        &Session.assistant(%{text: long("x", 100), tool_calls: &1, stop_reason: "stop"}, model())

      entries = [
        id(Session.user(long("p", 100)), "u1"),
        id(reply.([call]), "a1"),
        id(Session.tool_result("c1", "echo", long("r", 400), false), "r1"),
        id(reply.([]), "a2"),
        id(Session.user(long("q", 100)), "u2"),
        id(reply.([]), "a3")
      ]

      %{entries: entries}
    end

    test "keeps the newest whole messages that fit, never cutting a call from its result",
         %{entries: entries} do
      first_kept = fn keep ->
        case Compaction.prepare(entries, keep) do
          nil -> nil
          plan -> {plan.first_kept_id, Enum.map(plan.entries, & &1["id"])}
        end
      end

      # u2 + a3 fit 250; adding a2 would not
      assert first_kept.(250) == {"u2", ~w(u1 a1 r1 a2)}
      # the 400-token result fits after a2, but its call would not: both go
      assert first_kept.(600) == {"a2", ~w(u1 a1 r1)}
      # the call and its result are kept together
      assert first_kept.(850) == {"a1", ~w(u1)}
      # the newest message is kept even when it alone is over the budget
      assert first_kept.(50) == {"a3", ~w(u1 a1 r1 a2 u2)}
      # everything fits: nothing to summarize
      assert first_kept.(10_000) == nil

      for keep <- 1..1_200//7 do
        case Compaction.prepare(entries, keep) do
          nil ->
            :ok

          plan ->
            summarized = Enum.map(plan.entries, & &1["id"])
            refute plan.first_kept_id == "r1"
            assert "a1" in summarized == "r1" in summarized
        end
      end
    end

    test "after a compaction: only what follows its first kept entry, with its summary",
         %{entries: entries} do
      compaction = id(Session.compaction("S1", "a2", 900, 300), "c1")
      later = [id(Session.user(long("v", 100)), "u3"), id(Session.user(long("w", 100)), "u4")]

      plan = Compaction.prepare(entries ++ [compaction | later], 250)

      assert plan.first_kept_id == "u3"
      assert Enum.map(plan.entries, & &1["id"]) == ~w(a2 u2 a3)
      assert plan.previous_summary == "S1"

      [prompt] = Compaction.summary_request(plan, model(), 2048, 200_000).messages
      prompt = text_of(prompt)
      assert prompt =~ "[User]: qqqq"
      assert prompt =~ "<previous-summary>\nS1\n</previous-summary>"
      assert prompt =~ "Update existing handoff summary"
      refute prompt =~ "pppp"
      refute prompt =~ "rrrr"
      refute prompt =~ "vvvv"
    end
  end

  test "a reply before the latest compaction no longer sizes the context" do
    big = %{input_tokens: 150_000, output_tokens: 1_000}

    entries = [
      id(Session.user("hi"), "u1"),
      id(Session.assistant(%{text: "ok", usage: big, stop_reason: "stop"}, model()), "a1"),
      id(Session.user("more"), "u2")
    ]

    request = %{system_prompt: "", tools: [], messages: Session.context(entries)}
    assert Compaction.context_tokens(entries, request) > 150_000

    compacted = entries ++ [id(Session.compaction("S", "u2", 151_000, 10), "c1")]
    request = %{request | messages: Session.context(compacted)}
    assert Compaction.context_tokens(compacted, request) < 100
  end

  test "pi's thresholds: window minus the larger of 15% and the reserve" do
    assert Compaction.threshold(200_000, nil) == 170_000
    assert Compaction.threshold(128_000, nil) == 108_800
    assert Compaction.threshold(200_000, 50_000) == 150_000
    # the default 16k reserve leaves a small window no room: 15% instead
    assert Compaction.threshold(16_000, nil) == 13_600

    refute Compaction.should_compact?(170_000, 200_000, nil)
    assert Compaction.should_compact?(170_001, 200_000, nil)
  end

  test "context overflow errors are told apart from other failures" do
    assert Compaction.overflow?({:http, 400, @overflow})

    assert Compaction.overflow?(
             {:http, 400, "prompt is too long: 210000 tokens > 200000 maximum"}
           )

    assert Compaction.overflow?({:other, "context_length_exceeded"})

    refute Compaction.overflow?({:http, 402, "can only afford 8000"})
    refute Compaction.overflow?({:http, 429, "rate limited"})
    refute Compaction.overflow?({:transport, :timeout})
  end

  test "a conversation too big for the summarizer is cut to fit, head first" do
    entries = [id(Session.user(long("h", 10_000)), "u1"), id(Session.user("tail"), "u2")]
    plan = Compaction.prepare(entries, 10)

    [prompt] = Compaction.summary_request(plan, model(), 4096, 16_000).messages
    prompt = text_of(prompt)
    assert prompt =~ "<conversation>\n[User]: hhhh"
    assert prompt =~ "more characters truncated]\n</conversation>"
    assert Compaction.estimate(prompt) < 3_000
  end

  describe "in the loop" do
    test "over the threshold: summarize the older part, then call with summary + tail",
         %{tmp_dir: dir} do
      script = [[{:text, "r1"}], [{:text, "r2"}], [{:text, "SUMMARY ONE"}], [{:text, "r3"}]]
      %{loop: loop, llm: llm} = start(dir, script)

      prompt!(loop, long("a", 3000))
      prompt!(loop, long("b", 3000))
      events = prompt!(loop, long("c", 5000))

      assert shape(events) == [
               :agent_start,
               :turn_start,
               {:message_start, "user"},
               {:message_end, "user"},
               :compaction_start,
               :compaction,
               {:message_start, "assistant"},
               :message_update,
               {:message_end, "assistant"},
               :turn_end,
               :agent_end
             ]

      assert %{reason: :threshold} = Enum.find(events, &(&1.type == :compaction_start))

      [_, _, summary_call, call] = FakeLLM.requests(llm)

      # one summary call: explicit max_tokens, no tools, pi's prompts
      assert %{max_tokens: 4096, tools: []} = summary_call
      assert summary_call.system_prompt =~ "Summarize user–AI coding-assistant conversations"
      [prompt] = summary_call.messages
      prompt = text_of(prompt)
      assert prompt =~ "<conversation>\n[User]: aaaa"
      assert prompt =~ "[Assistant]: r1\n\n[User]: bbbb"
      assert prompt =~ "[Assistant]: r2\n</conversation>"
      assert prompt =~ "You MUST summarize the conversation above"
      refute prompt =~ "cccc"
      refute prompt =~ "previous-summary"

      # the call itself: the summary as pi renders it, then the kept tail
      assert [summary, tail] = call.messages
      assert text_of(summary) =~ "<summary>\nSUMMARY ONE\n</summary>"
      assert text_of(tail) == long("c", 5000)

      compaction = entry(events, :compaction)
      user = entry(events, :message_end)
      assert compaction["firstKeptEntryId"] == user["id"]
      assert compaction["tokensBefore"] > 10_000
      assert compaction["tokensAfter"] < 10_000
    end

    test "a second compaction carries the first summary forward; only the latest is sent",
         %{tmp_dir: dir} do
      script = [
        [{:text, "r1"}],
        [{:text, "r2"}],
        [{:text, "SUMMARY ONE"}],
        [{:text, "r3"}],
        [{:text, "SUMMARY TWO"}],
        [{:text, "r4"}]
      ]

      %{loop: loop, llm: llm, session: session} = start(dir, script)

      for text <- [long("a", 3000), long("b", 3000), long("c", 5000)], do: prompt!(loop, text)
      events = prompt!(loop, long("d", 6000))
      assert entry(events, :compaction)

      [_, _, _, _, summary_call, call] = FakeLLM.requests(llm)
      [prompt] = summary_call.messages
      prompt = text_of(prompt)
      assert prompt =~ "<conversation>\n[User]: cccc"
      assert prompt =~ "[Assistant]: r3\n</conversation>"
      assert prompt =~ "<previous-summary>\nSUMMARY ONE\n</previous-summary>"
      assert prompt =~ "Update existing handoff summary"
      refute prompt =~ "aaaa"

      assert [summary, tail] = call.messages
      assert text_of(summary) =~ "<summary>\nSUMMARY TWO\n</summary>"
      assert text_of(tail) == long("d", 6000)

      # on disk: pi's CompactionEntry, and the file reopens to the same context
      compactions = for %{"type" => "compaction"} = e <- lines(session.path), do: e
      assert [_, _] = compactions

      for c <- compactions do
        assert Map.keys(c) |> Enum.sort() ==
                 ~w(firstKeptEntryId fromExtension id method parentId summary timestamp tokensAfter tokensBefore type)

        assert %{"method" => "soft", "fromExtension" => false} = c
      end

      {:ok, _session, entries} = Session.open(session.path, "unused")
      assert Session.context(entries) == Loop.context(loop)
      assert [%{content: [%{text: "Prior model work" <> _}]} | _] = Loop.context(loop)
    end

    test "the summary call's cost counts toward the daily cap", %{tmp_dir: dir} do
      :ok = Settings.put_daily_cap(0.1, dir)

      summary = [
        {:usage, %{input_tokens: 2000, output_tokens: 50, total_cost: 0.2}},
        {:text, "S"}
      ]

      script = [[{:text, "r1"}], summary, [{:text, "never sent"}]]
      %{loop: loop, llm: llm} = start(dir, script, budget: dir)

      prompt!(loop, long("a", 3000))
      events = prompt!(loop, long("b", 8000))

      assert entry(events, :compaction)
      assert %{reason: :cost_cap} = List.last(events)
      assert_in_delta Budget.spent(dir), 0.201, 1.0e-9
      assert [_, _] = FakeLLM.requests(llm)
    end

    test "a failed summary: an error notice, no compaction, the run ends", %{tmp_dir: dir} do
      script = [[{:text, "r1"}], [{:error, {:http, 402, "can only afford 100"}}]]
      %{loop: loop, llm: llm, session: session} = start(dir, script)

      prompt!(loop, long("a", 3000))
      events = prompt!(loop, long("b", 8000))

      assert %{reason: :error} = List.last(events)
      refute entry(events, :compaction)

      assert [notice] =
               for(
                 %{type: :message_end, entry: %{"type" => "custom_message"} = e} <- events,
                 do: e
               )

      assert notice["customType"] == "rho.error"
      assert notice["content"] =~ "Compacting the context failed: 402"
      assert %{type: :turn_end, error: "Compacting" <> _} = Enum.at(events, -2)

      refute Enum.any?(lines(session.path), &(&1["type"] == "compaction"))
      assert [_, _] = FakeLLM.requests(llm)
    end

    test "stop during the summary call: nothing compacted", %{tmp_dir: dir} do
      %{loop: loop, session: session} = start(dir, [[{:text, "r1"}], [:block]])
      prompt!(loop, long("a", 3000))

      :ok = Loop.prompt(loop, long("b", 8000))
      await_event(:compaction_start)
      :ok = Loop.stop(loop)

      assert %{reason: :stopped} = List.last(collect())
      refute Enum.any?(lines(session.path), &(&1["type"] == "compaction"))
    end
  end

  describe "a call rejected as over the context window" do
    test "is compacted and retried once", %{tmp_dir: dir} do
      script = [
        [{:text, "r1"}],
        [{:error, {:http, 400, @overflow}}],
        [{:text, "S"}],
        [{:text, "r2"}]
      ]

      # the model's own window (200k): only the provider's rejection compacts
      %{loop: loop, llm: llm, session: session} =
        start_loop(dir, script, tools: [Echo], keep_recent_tokens: 1500)

      prompt!(loop, long("a", 1000))
      events = prompt!(loop, long("b", 2000))

      assert shape(events) == [
               :agent_start,
               :turn_start,
               {:message_start, "user"},
               {:message_end, "user"},
               {:message_start, "assistant"},
               :compaction_start,
               :compaction,
               {:message_start, "assistant"},
               :message_update,
               {:message_end, "assistant"},
               :turn_end,
               :agent_end
             ]

      assert %{reason: :overflow} = Enum.find(events, &(&1.type == :compaction_start))
      assert %{reason: :done} = List.last(events)

      [_, _, _, retry] = FakeLLM.requests(llm)
      assert [summary, tail] = retry.messages
      assert text_of(summary) =~ "<summary>\nS\n</summary>"
      assert text_of(tail) == long("b", 2000)

      # the rejected attempt is not persisted
      refute Enum.any?(lines(session.path), &(get_in(&1, ["message", "stopReason"]) == "error"))
    end

    test "a second overflow ends the run with the error", %{tmp_dir: dir} do
      overflow = [{:error, {:http, 400, @overflow}}]
      script = [[{:text, "r1"}], overflow, [{:text, "S"}], overflow, [{:text, "never"}]]
      %{loop: loop, llm: llm} = start_loop(dir, script, tools: [Echo], keep_recent_tokens: 1500)

      prompt!(loop, long("a", 1000))
      events = prompt!(loop, long("b", 2000))

      assert %{reason: :error} = List.last(events)
      assert [_] = for(%{type: :compaction} = e <- events, do: e)
      assert [_, _, _, _] = FakeLLM.requests(llm)

      %{entry: failed} = List.last(for %{type: :message_end} = e <- events, do: e)
      assert failed["message"]["stopReason"] == "error"
      assert failed["message"]["errorMessage"] =~ "maximum context length is 200000 tokens"
    end
  end
end
