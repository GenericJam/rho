defmodule Rho.LoopRateLimitTest do
  use ExUnit.Case, async: true

  import Rho.Test.LoopHelpers

  alias Rho.LLM
  alias Rho.Loop
  alias Rho.Test.FakeLLM

  @moduletag :tmp_dir
  @moduletag :capture_log

  @fallback "openai_codex:gpt-5"

  defp limited(extra \\ %{}) do
    {:error,
     {:rate_limited,
      Map.merge(
        %{
          status: 429,
          message: "This request would exceed your account's rate limit.",
          provider: :anthropic,
          retry_after_ms: nil,
          resets_at: nil,
          window: nil
        },
        extra
      )}}
  end

  defp used_up(at), do: limited(%{resets_at: at, window: "5 hours"})

  defp retries(events), do: for(%{type: :retry} = e <- events, do: e)
  defp turn_error(events), do: Enum.find(events, &(&1.type == :turn_end)).error

  defp requested_models do
    receive do
      {:llm_request, request, _pid} -> [request.model | requested_models()]
    after
      0 -> []
    end
  end

  test "a throttle waits as long as retry-after says, then the reply goes through", %{
    tmp_dir: dir
  } do
    %{loop: loop} = start_loop(dir, [[limited(%{retry_after_ms: 60})], [{:text, "ok"}]])

    :ok = Loop.prompt(loop, "hi")
    assert_receive {:llm_request, _, _}
    t0 = System.monotonic_time(:millisecond)
    assert_receive {:llm_request, _, _}, 1_000
    assert System.monotonic_time(:millisecond) - t0 >= 50

    events = collect()
    assert [%{attempt: 1, delay_ms: 60, error: error}] = retries(events)
    assert error =~ "429 (rate limited)"
    assert List.last(events).reason == :done
  end

  test "throttles back off exponentially up to the cap, more often than other errors", %{
    tmp_dir: dir
  } do
    script = List.duplicate([limited()], 5) ++ [[{:text, "ok"}]]
    %{loop: loop} = start_loop(dir, script, rate_limit_cap_ms: 4)

    :ok = Loop.prompt(loop, "hi")
    events = collect()
    assert Enum.map(retries(events), & &1.delay_ms) == [1, 2, 4, 4, 4]
    assert List.last(events).reason == :done
  end

  test "a used-up window ends the run at once, saying until when", %{tmp_dir: dir} do
    at = System.os_time(:second) + 3 * 3600
    %{loop: loop, llm: llm} = start_loop(dir, [[used_up(at)], [{:text, "never"}]])

    :ok = Loop.prompt(loop, "hi")
    events = collect()
    assert retries(events) == []
    assert [_] = FakeLLM.requests(llm)

    error = turn_error(events)
    assert error =~ "Claude (Anthropic)'s 5 hours limit is used up until #{LLM.clock(at)}"
    assert error =~ "switch model in the app's settings, or prompt again then"
    assert List.last(events).reason == :error
  end

  test "a used-up window continues the run on the fallback model, then hands the model back",
       %{tmp_dir: dir} do
    at = System.os_time(:second) + 3 * 3600

    %{loop: loop} =
      start_loop(dir, [[used_up(at)], [{:text, "from the fallback"}]],
        fallback_model: @fallback,
        fallback_check: fn @fallback -> :ok end
      )

    :ok = Loop.prompt(loop, "hi")
    events = collect()
    assert retries(events) == []
    assert List.last(events).reason == :done
    assert [model(), @fallback] == requested_models()

    entries = Loop.snapshot(loop).entries
    changes = for %{"type" => "model_change", "model" => m} <- entries, do: m
    assert [_, _] = changes

    notice =
      Enum.find_value(entries, fn
        %{"type" => "custom_message", "content" => text} -> text
        _ -> nil
      end)

    assert notice =~ "5 hours limit is used up"
    assert notice =~ "Continuing this run on #{@fallback}"

    reply = Enum.find(entries, &match?(%{"message" => %{"role" => "assistant"}}, &1))
    assert reply["message"]["content"] == [%{"type" => "text", "text" => "from the fallback"}]
    # The session's own model is back for the next run.
    assert Loop.snapshot(loop).model == model()
  end

  test "throttles past the retries: the fallback, if it can take over, else prompt again", %{
    tmp_dir: dir
  } do
    script = List.duplicate([limited()], 3) ++ [[{:text, "ok"}]]

    %{loop: loop} =
      start_loop(dir, script,
        rate_limit_retries: 2,
        fallback_model: @fallback,
        fallback_check: fn _ -> :ok end
      )

    :ok = Loop.prompt(loop, "hi")
    events = collect()
    assert [_, _] = retries(events)
    assert List.last(events).reason == :done
    assert List.last(requested_models()) == @fallback

    # The fallback can't take over: the run ends, saying why and what to do.
    %{loop: loop} =
      start_loop(dir, List.duplicate([limited()], 3),
        rate_limit_retries: 2,
        fallback_model: @fallback,
        fallback_check: fn _ -> {:error, "ChatGPT (OpenAI Codex) isn't signed in"} end
      )

    :ok = Loop.prompt(loop, "hi")
    events = collect()
    error = turn_error(events)
    assert error =~ "Still limited after 2 retries"
    assert error =~ "prompt again to continue this run"
    assert error =~ "(Fallback model: ChatGPT (OpenAI Codex) isn't signed in.)"
    assert List.last(events).reason == :error
  end

  test "no fallback configured: a throttle past the budget ends the run with what to do", %{
    tmp_dir: dir
  } do
    %{loop: loop, llm: llm} =
      start_loop(dir, [[limited(%{retry_after_ms: 10_000})]], rate_limit_budget_ms: 5_000)

    :ok = Loop.prompt(loop, "hi")
    events = collect()
    assert retries(events) == []
    assert [_] = FakeLLM.requests(llm)
    assert turn_error(events) =~ "Prompt again to continue this run."
  end

  test "stop during a rate-limit wait ends the run at once", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [[limited(%{retry_after_ms: 60_000})]])

    :ok = Loop.prompt(loop, "hi")
    assert %{delay_ms: 60_000} = await_event(:retry)
    :ok = Loop.stop(loop)
    assert List.last(collect()).reason == :stopped
  end
end
