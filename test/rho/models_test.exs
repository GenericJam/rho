defmodule Rho.ModelsTest do
  # async: false: the sign-ins (Rho.Auth) are app-wide.
  use ExUnit.Case, async: false

  alias Rho.Auth
  alias Rho.Models

  @creds %{"type" => "oauth", "access" => "a", "refresh" => "r", "expires" => 0}

  setup do
    start_supervised!(Auth)
    on_exit(fn -> for p <- Auth.providers(), do: Rho.CredentialStore.delete("auth:#{p}") end)
  end

  test "ChatGPT signed in: omp's Codex models are listed" do
    :ok = Auth.put(:anthropic, @creds)
    :ok = Auth.put(:openai_codex, @creds)

    assert [
             {:anthropic, true, [_ | _]},
             {:openai_codex, true, codex},
             {:openai, false, []},
             {:google, false, []}
           ] = Models.by_provider()

    assert Enum.any?(codex, &(&1.spec == "openai_codex:gpt-5.5"))
    refute Enum.any?(codex, &String.contains?(&1.spec, "image"))
    assert Models.same?("anthropic:claude-haiku-4-5", "anthropic:claude-haiku-4-5-20251001")
  end

  test "API keys: OpenAI's and Gemini's tool-calling chat models are listed" do
    :ok = Auth.put_api_key(:openai, "sk-proj")
    :ok = Auth.put_api_key(:google, "AIza")

    by = Map.new(Models.by_provider(), fn {p, signed_in, models} -> {p, {signed_in, models}} end)
    assert {false, []} = by.anthropic
    assert {true, [_ | _] = openai} = by.openai
    assert {true, [_ | _] = google} = by.google

    assert Enum.all?(openai, &String.starts_with?(&1.spec, "openai:"))
    assert Enum.all?(google, &String.starts_with?(&1.spec, "google:"))
    assert Enum.any?(google, &String.starts_with?(&1.spec, "google:gemini"))
    assert Enum.any?(openai, &(&1.spec == "openai:gpt-5"))
    # embeddings, speech, image-only and realtime / live models can't run the loop
    refute Enum.any?(openai, &(&1.spec =~ ~r/embedding|tts|whisper|dall-e|realtime/))
    refute Enum.any?(google, &(&1.spec =~ ~r/embedding|-live/))
  end
end
