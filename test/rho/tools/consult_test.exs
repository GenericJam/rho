defmodule Rho.Tools.ConsultTest do
  # async: false: the sign-ins (Rho.Auth) and `config :rho` are app-wide.
  use ExUnit.Case, async: false

  import Rho.Test.LoopHelpers

  alias Rho.Auth
  alias Rho.Consult
  alias Rho.Loop
  alias Rho.Models
  alias Rho.Session
  alias Rho.Test.FakeLLM
  alias Rho.Tools.Consult, as: AskModel

  @moduletag :tmp_dir
  @moduletag :capture_log

  @gemini "google:gemini-3.1-pro-preview"

  setup do
    start_supervised!(Auth)

    on_exit(fn ->
      for p <- Auth.providers(), do: Rho.CredentialStore.delete("auth:#{p}")
      Application.delete_env(:rho, :consult_models)
      Application.delete_env(:rho, :consult_system)
    end)
  end

  defp text_of(%ReqLLM.Message{content: parts}), do: Enum.map_join(parts, "", & &1.text)

  defp ask(args), do: [{:tool_call, "c1", "ask_model", args}]

  test "the lead asks Gemini for a critique with the conversation, and answers it",
       %{tmp_dir: dir} do
    :ok = Auth.put_api_key(:google, "AIza-test")
    Application.put_env(:rho, :consult_models, [@gemini])

    args = %{
      "model" => @gemini,
      "purpose" => "critique",
      "prompt" => "Check my answer: 2+2=5.",
      "include_conversation" => true
    }

    script = [
      [{:text, "2+2=5. Let me get a check."} | ask(args)],
      [{:text, "1. (high) 2+2 is 4."}],
      [{:text, "You're right: it's 4."}]
    ]

    %{loop: loop, llm: llm, session: session} =
      start_loop(dir, script, tools: [AskModel, Rho.Test.Tools.Echo])

    :ok = Loop.prompt(loop, "What is 2+2?")
    events = collect()
    assert List.last(events).reason == :done

    [lead, consult, answer] = FakeLLM.requests(llm)
    ask_model = Enum.find(lead.tools, &(&1.name == "ask_model"))
    assert ask_model.parameter_schema["properties"]["model"]["enum"] == [@gemini]

    # the consult: Gemini, the critique brief, the conversation without the call in flight
    assert consult.model == @gemini
    assert consult.system_prompt == Consult.default_system("critique")
    assert consult.tools == []
    sent = text_of(hd(consult.messages))
    assert sent =~ "[User]: What is 2+2?"
    assert sent =~ "[Assistant]: 2+2=5. Let me get a check."
    refute sent =~ "ask_model"
    refute sent =~ Session.aborted_tool_text()
    assert String.ends_with?(sent, "Check my answer: 2+2=5.")

    # the lead reads it as the tool's result
    assert [_user, _assistant, %{role: :tool} = result] = answer.messages
    assert text_of(result) == "#{@gemini} (critique):\n\n1. (high) 2+2 is 4."

    assert %{details: %{model: @gemini, purpose: "critique", usage: %{"output" => 20}}} =
             Enum.find(events, &(&1.type == :tool_execution_end))

    assert %{call_id: "c1", model: @gemini} = Enum.find(events, &(&1.type == :consult_start))
    assert %{call_id: "c1", status: :ok} = Enum.find(events, &(&1.type == :consult_end))

    # recorded in the session, between the call and its result; three calls in the totals
    {:ok, _, entries} = Session.open(session.path, model())

    order =
      for %{"type" => t} = e <- entries,
          t in ["message", "custom"],
          do: if(t == "custom", do: "consult", else: e["message"]["role"])

    assert order == ["user", "assistant", "consult", "toolResult", "assistant"]

    assert [%{"data" => %{"callId" => "c1", "purpose" => "critique"}}] =
             Enum.filter(entries, &(&1["type"] == "custom"))

    assert_in_delta Loop.snapshot(loop).totals.cost, 0.003, 1.0e-9
    assert Loop.snapshot(loop).totals.output == 60
  end

  test "stopping the lead's run stops its consult", %{tmp_dir: dir} do
    :ok = Auth.put_api_key(:google, "AIza-test")
    script = [ask(%{"model" => @gemini, "prompt" => "Check."}), [:block]]
    %{loop: loop} = start_loop(dir, script, tools: [AskModel])
    :ok = Loop.prompt(loop, "go")
    assert_receive {:llm_request, _lead, _}, 2_000
    assert_receive {:llm_request, %{model: @gemini}, worker}, 2_000
    ref = Process.monitor(worker)

    :ok = Loop.stop(loop)
    events = collect()

    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 2_000
    assert List.last(events).reason == :stopped

    assert [{"ask_model", "The consult was stopped.", true}] =
             for(
               %{type: :tool_execution_end, name: n, text: t, is_error: e} <- events,
               do: {n, t, e}
             )
  end

  test "a model the host doesn't allow, or whose provider isn't signed in, is refused" do
    :ok = Auth.put_api_key(:google, "AIza-test")
    Application.put_env(:rho, :consult_models, [@gemini, "openai:gpt-5"])

    assert Consult.models() == [@gemini]
    assert Consult.allowed(@gemini) == :ok
    assert {:error, why} = Consult.allowed("anthropic:claude-opus-4-1")
    assert why =~ "isn't one of the models you may consult (available: #{@gemini})"
    assert {:error, why} = Consult.allowed("openai:gpt-5")
    assert why =~ "OpenAI isn't signed in"
    assert {:error, why} = Consult.allowed("mistral:large")
    assert why =~ "isn't a model rho can call"

    assert {:error, refused} =
             AskModel.run(%{"model" => "openai:gpt-5", "prompt" => "q"}, %{call_id: "c"})

    assert refused =~ "isn't signed in"
    assert {:error, _} = AskModel.run(%{"model" => @gemini, "prompt" => ""}, %{call_id: "c"})
  end

  test "by default every catalog model of a signed-in provider may be consulted" do
    :ok = Auth.put_api_key(:google, "AIza-test")
    models = Consult.models()
    assert models != [] and Enum.all?(models, &String.starts_with?(&1, "google:"))
    assert models == for(m <- Models.catalog(:google), do: m.spec)
    assert Consult.allowed(hd(models)) == :ok
    assert {:error, _} = Consult.allowed("google:not-a-model")
    refute Map.has_key?(AskModel.parameter_schema()["properties"]["model"], "enum")
  end

  test "the host's system prompt per purpose: a map or a function; nil falls back" do
    {:ok, llm} = FakeLLM.start(List.duplicate([{:text, "ok"}], 3))
    run = fn purpose -> Consult.run(@gemini, "q", llm: {FakeLLM, llm}, purpose: purpose) end

    Application.put_env(:rho, :consult_system, %{"critique" => "Study critic brief."})
    {:ok, _} = run.("critique")
    assert_received {:llm_request, %{system_prompt: "Study critic brief."}, _}

    Application.put_env(:rho, :consult_system, fn
      "critique" -> "From a function."
      _ -> nil
    end)

    {:ok, _} = run.("critique")
    assert_received {:llm_request, %{system_prompt: "From a function."}, _}
    {:ok, _} = run.("translation")
    assert_received {:llm_request, %{system_prompt: system}, _}
    assert system == Consult.default_system("translation")
  end

  test "Gemini without a key: the real client fails with signed_out before any request" do
    assert {:error, {:signed_out, :google}} = error = Consult.run(@gemini, "q")
    assert Consult.describe(elem(error, 1)) =~ "Not signed in to Gemini (Google)"
  end
end
