defmodule Rho.Models.CodexTest do
  # async: false: the kept list is node-wide (`:persistent_term`, the data
  # dir's file).
  use ExUnit.Case, async: false

  import Rho.Test.LoopHelpers

  alias Rho.Loop
  alias Rho.Models
  alias Rho.Models.Codex
  alias Rho.Session
  alias Rho.Test.FakeLLM

  @moduletag :tmp_dir
  @moduletag :capture_log

  @refused "The 'gpt-5.5' model is not supported when using Codex with a ChatGPT account."

  defp signed_in(:openai_codex), do: {:ok, %{type: :oauth, token: "tok", account_id: "acc-1"}}

  defp listing(models), do: Jason.encode!(%{"models" => models})

  defp entry(slug, priority, extra \\ %{}),
    do: Map.merge(%{"slug" => slug, "visibility" => "list", "priority" => priority}, extra)

  # Answers each request with the next response, telling the test what was asked.
  defp respond(responses) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn req ->
      send(test, {:asked, req.method, URI.to_string(req.url), req.headers})
      Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
    end
  end

  defp ok(body), do: Req.Response.new(status: 200, body: body)

  defp fetched!(slugs) do
    body = listing(for {slug, i} <- Enum.with_index(slugs), do: entry(slug, i))
    {:ok, _} = Codex.refresh(credential: &signed_in/1, respond: respond([ok(body)]))
  end

  setup do
    file = Path.join(Rho.Config.data_dir(), "codex_models.json")
    File.rm(file)
    Codex.reset()

    on_exit(fn ->
      File.rm(file)
      Codex.reset()
    end)

    %{kept_file: file}
  end

  describe "fetch/1" do
    test "the picker's models in Codex's order, named as the catalog writes them; hidden, unlisted and malformed entries left out" do
      body =
        listing([
          entry("b", 5, %{"display_name" => "GPT-6-Astra", "context_window" => 272_000}),
          %{"slug" => "hidden", "visibility" => "hide", "priority" => 4},
          %{"slug" => "unlisted", "visibility" => "none", "priority" => 0},
          %{"slug" => "no-visibility", "priority" => 0},
          1,
          %{"slug" => "c", "visibility" => "list"},
          entry("a", 1, %{"display_name" => "GPT-6.1-Sol", "context_window" => 500_000})
        ])

      assert {:ok, models} = Codex.fetch(credential: &signed_in/1, respond: respond([ok(body)]))

      assert models == [
               %{id: "a", name: "GPT-6.1 Sol", context: 500_000},
               %{id: "b", name: "GPT-6 Astra", context: 272_000},
               %{id: "c", name: "c", context: nil}
             ]

      assert_received {:asked, :get, url, headers}
      assert url =~ "/models?client_version="
      assert headers["chatgpt-account-id"] == ["acc-1"]
    end

    test "signed out, or an error status, is an error and nothing is kept" do
      assert {:error, {:signed_out, :openai_codex}} =
               Codex.refresh(credential: fn _ -> {:error, :signed_out} end)

      respond = respond([Req.Response.new(status: 403, body: ~s({"detail":"Forbidden"}))])

      assert {:error, {:http, 403, "Forbidden"}} =
               Codex.refresh(credential: &signed_in/1, respond: respond)

      assert Codex.replacement("openai_codex:gpt-5.5") == nil
    end
  end

  describe "the kept list" do
    test "before any fetch: the shipped list, and no saved model is replaced" do
      assert [%{id: "gpt-6.1-sol"} | _] = Codex.models()
      refute Enum.any?(Codex.models(), &(&1.id == "gpt-5.5"))
      assert Codex.replacement("openai_codex:gpt-5.5") == nil
      assert Models.resolve("openai_codex:gpt-5.5") == "openai_codex:gpt-5.5"
    end

    test "a fetched list is the catalog, and a saved model it lacks resolves to its first" do
      fetched!(["gpt-7-sol", "gpt-6-luna"])

      assert Enum.map(Models.catalog(:openai_codex), & &1.spec) ==
               ["openai_codex:gpt-7-sol", "openai_codex:gpt-6-luna"]

      assert Codex.default() == "gpt-7-sol"
      assert Codex.replacement("openai_codex:gpt-5.5") == "openai_codex:gpt-7-sol"
      assert Codex.replacement("openai_codex:gpt-6-luna") == nil
      assert Codex.replacement("anthropic:claude-sonnet-4-5") == nil
      assert Models.resolve("openai_codex:gpt-5.5") == "openai_codex:gpt-7-sol"
      assert Models.resolve("anthropic:claude-sonnet-4-5") == "anthropic:claude-sonnet-4-5"
    end

    test "it survives a restart through the data dir's file", %{kept_file: file} do
      fetched!(["gpt-7-sol"])
      assert File.exists?(file)

      Codex.reset()
      assert Codex.replacement("openai_codex:gpt-5.5") == "openai_codex:gpt-7-sol"

      File.write!(file, "not json")
      Codex.reset()
      assert Codex.replacement("openai_codex:gpt-5.5") == nil
      assert [%{id: "gpt-6.1-sol"} | _] = Codex.models()
    end

    test "a refused model leaves the list and the default takes over" do
      fetched!(["gpt-5.5", "gpt-6-luna"])

      assert Codex.refused("openai_codex:gpt-5.5") == "openai_codex:gpt-6-luna"
      assert Enum.map(Codex.models(), & &1.id) == ["gpt-6-luna"]
      assert Codex.replacement("openai_codex:gpt-5.5") == "openai_codex:gpt-6-luna"
    end

    test "a model refused before any fetch: the shipped list without it" do
      assert Codex.refused("openai_codex:gpt-6.1-sol") == "openai_codex:gpt-6-astra"
      assert Codex.replacement("openai_codex:gpt-6.1-sol") == "openai_codex:gpt-6-astra"
    end

    test "refresh_async fetches a stale list once, then not again while it is fresh" do
      Application.put_env(:rho, :codex_models_refresh, true)
      on_exit(fn -> Application.put_env(:rho, :codex_models_refresh, false) end)

      body = listing([entry("gpt-7-sol", 1)])
      opts = [credential: &signed_in/1, respond: respond([ok(body)])]

      :ok = Codex.refresh_async(opts)
      assert_receive {:asked, :get, _, _}, 1_000
      wait_until(fn -> Codex.default() == "gpt-7-sol" end)

      :ok = Codex.refresh_async(opts)
      refute_receive {:asked, :get, _, _}, 100
    end

    test "the notice names both models" do
      fetched!(["gpt-7-sol"])

      assert Codex.replaced_notice("openai_codex:gpt-5.5", "openai_codex:gpt-7-sol") ==
               "gpt-5.5 isn't offered on the ChatGPT sign-in any more; using gpt-7-sol instead."

      Codex.reset()

      assert Codex.replaced_notice("openai_codex:gpt-6-luna", "openai_codex:gpt-6.1-sol") ==
               "GPT-6 Luna isn't offered on the ChatGPT sign-in any more; using GPT-6.1 Sol instead."
    end
  end

  describe "a loop on a model the sign-in no longer accepts" do
    defp codex_loop(dir, script) do
      session = Session.new(dir, "openai_codex:gpt-5.5", dir)
      start_loop(dir, script, session: {session, []})
    end

    defp notices(events) do
      for %{type: :message_end, entry: %{"type" => "custom_message", "content" => text}} <-
            events,
          do: text
    end

    test "a run starting on it moves the session to the default, with a notice", %{
      tmp_dir: dir
    } do
      fetched!(["gpt-7-sol"])
      %{loop: loop, llm: llm} = codex_loop(dir, [[{:text, "ok"}]])

      :ok = Loop.prompt(loop, "hi")
      events = collect()

      assert [%{model: "openai_codex:gpt-7-sol"}] =
               for(%{type: :model_change} = e <- events, do: e)

      assert notices(events) == [
               "gpt-5.5 isn't offered on the ChatGPT sign-in any more; using gpt-7-sol instead."
             ]

      assert [%{model: "openai_codex:gpt-7-sol"}] = FakeLLM.requests(llm)
      assert List.last(events).reason == :done
      assert :sys.get_state(loop).session.model == "openai_codex:gpt-7-sol"
    end

    test "the backend refusing it: the call is made again on the default, with a notice", %{
      tmp_dir: dir
    } do
      %{loop: loop, llm: llm} =
        codex_loop(dir, [[{:error, {:http, 400, @refused}}], [{:text, "ok"}]])

      :ok = Loop.prompt(loop, "hi")
      events = collect()

      assert Enum.map(FakeLLM.requests(llm), & &1.model) ==
               ["openai_codex:gpt-5.5", "openai_codex:gpt-6.1-sol"]

      assert notices(events) == [
               "gpt-5.5 isn't offered on the ChatGPT sign-in any more; using GPT-6.1 Sol instead."
             ]

      assert List.last(events).reason == :done
    end

    test "a second refusal in the run ends it with the error", %{tmp_dir: dir} do
      refused = {:error, {:http, 400, @refused}}
      %{loop: loop, llm: llm} = codex_loop(dir, [[refused], [refused], [{:text, "never"}]])

      :ok = Loop.prompt(loop, "hi")
      events = collect()

      assert length(FakeLLM.requests(llm)) == 2
      assert List.last(events).reason == :error
    end
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
