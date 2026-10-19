defmodule Rho.AuthTest do
  # async: false: the sign-ins live in the app-wide credential store.
  use ExUnit.Case, async: false

  alias Rho.Auth
  alias Rho.Test.FlakyCredentialStore

  @moduletag :capture_log

  setup do
    on_exit(fn -> for p <- Auth.providers(), do: Rho.CredentialStore.delete("auth:#{p}") end)
  end

  defp now, do: System.os_time(:millisecond)

  defp creds(extra \\ %{}) do
    Map.merge(
      %{
        "type" => "oauth",
        "access" => "at-1",
        "refresh" => "rt-1",
        "expires" => now() + 3_600_000
      },
      extra
    )
  end

  # A token endpoint that counts its calls, answers after `delay_ms`, and
  # rotates the refresh token.
  defp endpoint(status \\ 200, delay_ms \\ 0) do
    test = self()

    fn req ->
      body = IO.iodata_to_binary(req.body)

      params =
        if Req.Request.get_header(req, "content-type") == ["application/json"],
          do: Jason.decode!(body),
          else: URI.decode_query(body)

      send(test, {:refresh_request, params})
      Process.sleep(delay_ms)

      body =
        if status == 200,
          do: %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 3600},
          else: %{"error" => "invalid_grant", "error_description" => "Refresh token expired"}

      Req.Response.new(status: status, body: Jason.encode!(body))
    end
  end

  test "put/get/status/delete; subscribers hear every change" do
    start_supervised!(Auth)
    :ok = Auth.subscribe()

    signed_out = %{signed_in: false, type: nil, email: nil, expires: nil}

    assert Auth.status() == %{
             anthropic: signed_out,
             openai_codex: signed_out,
             openai: signed_out,
             google: signed_out
           }

    c = creds(%{"email" => "k@example.com", "accountId" => "acct"})
    assert :ok = Auth.put(:openai_codex, c)
    assert_received {:rho_auth, :changed}
    assert Auth.get(:openai_codex) == {:ok, c}

    assert Auth.status().openai_codex == %{
             signed_in: true,
             type: :oauth,
             email: "k@example.com",
             expires: c["expires"]
           }

    refute Auth.signed_in?(:anthropic)

    assert {:ok, %{type: :oauth, token: "at-1", account_id: "acct"}} =
             Auth.credential(:openai_codex)

    assert :ok = Auth.delete(:openai_codex)
    assert_received {:rho_auth, :changed}
    assert Auth.get(:openai_codex) == :error
    assert Auth.credential(:openai_codex) == {:error, :signed_out}
  end

  test "put refuses what isn't pi's OAuth or API-key credential for that provider" do
    start_supervised!(Auth)

    assert {:error, :invalid_credentials} = Auth.put(:anthropic, Map.delete(creds(), "refresh"))
    assert {:error, :invalid_credentials} = Auth.put(:anthropic, creds(%{"refresh" => ""}))
    assert {:error, :invalid_credentials} = Auth.put(:anthropic, creds(%{"type" => "api_key"}))
    assert {:error, :unknown_provider} = Auth.put(:mistral, creds())
    # no subscription sign-in for OpenAI's API or Gemini; no API key for Codex
    assert {:error, :invalid_credentials} = Auth.put(:openai, creds())
    assert {:error, :invalid_credentials} = Auth.put(:google, creds())
    assert {:error, :invalid_credentials} = Auth.put_api_key(:openai_codex, "sk-x")
    assert {:error, :invalid_credentials} = Auth.put_api_key(:openai, "  ")
    assert Auth.get(:anthropic) == :error
    assert Auth.get(:openai) == :error
  end

  test "API keys: stored as pi's api_key entry, handed out as they are, never refreshed" do
    start_supervised!({Auth, respond: endpoint()})
    :ok = Auth.subscribe()

    for {provider, key} <- [anthropic: "sk-ant-1", openai: "sk-proj-1", google: "AIza-1"] do
      assert :ok = Auth.put_api_key(provider, " #{key}\n")
      assert_received {:rho_auth, :changed}
      assert Auth.get(provider) == {:ok, %{"type" => "api_key", "key" => key}}
      assert Auth.credential(provider) == {:ok, %{type: :api_key, key: key}}

      assert %{signed_in: true, type: :api_key, email: nil, expires: nil} =
               Auth.status()[provider]
    end

    refute_received {:refresh_request, _}
    assert Auth.kinds(:anthropic) == [:oauth, :api_key]
    assert Auth.kinds(:openai_codex) == [:oauth]
    assert Auth.kinds(:google) == [:api_key]
  end

  test "a provider holds one credential: a key replaces a sign-in and back" do
    start_supervised!(Auth)
    :ok = Auth.put(:anthropic, creds())
    assert {:ok, %{type: :oauth}} = Auth.credential(:anthropic)

    :ok = Auth.put_api_key(:anthropic, "sk-ant-2")
    assert Auth.credential(:anthropic) == {:ok, %{type: :api_key, key: "sk-ant-2"}}

    :ok = Auth.put(:anthropic, creds())
    assert {:ok, %{type: :oauth, token: "at-1"}} = Auth.credential(:anthropic)
  end

  test "a model spec's provider" do
    assert Auth.provider_for_model("anthropic:claude-haiku-4-5") == {:ok, :anthropic}
    assert Auth.provider_for_model("openai_codex:gpt-5") == {:ok, :openai_codex}
    assert Auth.provider_for_model("openai:gpt-5") == {:ok, :openai}
    assert Auth.provider_for_model("google:gemini-2.5-flash") == {:ok, :google}
    assert Auth.provider_for_model("mistral:large") == :error
  end

  test "on the host the store is a 0600 file" do
    start_supervised!(Auth)
    :ok = Auth.put(:anthropic, creds())

    path = Path.join([Rho.Config.data_dir(), "secure", "auth_anthropic"])
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
  end

  test "a token near expiry is refreshed first, the rotated refresh token stored, and announced" do
    start_supervised!({Auth, respond: endpoint()})
    :ok = Auth.put(:anthropic, creds(%{"expires" => now() + 60_000, "email" => "k@example.com"}))
    :ok = Auth.subscribe()

    assert {:ok, %{token: "at-2"}} = Auth.credential(:anthropic)
    assert_received {:refresh_request, %{"refresh_token" => "rt-1"}}
    # a phone tells its linked computers of the rotated sign-in from this
    assert_received {:rho_auth, :changed}

    assert {:ok, %{"access" => "at-2", "refresh" => "rt-2", "email" => "k@example.com"} = stored} =
             Auth.get(:anthropic)

    assert stored["expires"] > now() + 50 * 60_000

    # fresh now: no second refresh
    assert {:ok, %{token: "at-2"}} = Auth.credential(:anthropic)
    refute_received {:refresh_request, _}
  end

  test "a login moved over without its access token refreshes on first use" do
    start_supervised!({Auth, respond: endpoint()})
    :ok = Auth.put(:openai_codex, creds(%{"access" => "", "expires" => 0}))

    assert {:ok, %{token: "at-2"}} = Auth.credential(:openai_codex)

    assert_received {:refresh_request,
                     %{"grant_type" => "refresh_token", "refresh_token" => "rt-1"}}
  end

  test "concurrent callers share one refresh" do
    start_supervised!({Auth, respond: endpoint(200, 150)})
    :ok = Auth.put(:anthropic, creds(%{"expires" => now()}))

    results =
      1..5
      |> Enum.map(fn _ -> Task.async(fn -> Auth.credential(:anthropic) end) end)
      |> Task.await_many()

    assert Enum.uniq(results) == [{:ok, %{type: :oauth, token: "at-2", account_id: nil}}]
    assert_received {:refresh_request, _}
    refute_received {:refresh_request, _}
  end

  test "not started (a host with per-account vaults): nobody is signed in" do
    refute Process.whereis(Auth)
    assert Auth.credential(:anthropic) == {:error, :signed_out}
  end

  test "a failed refresh is an error that keeps the sign-in, and is announced" do
    start_supervised!({Auth, respond: endpoint(400)})
    old = creds(%{"expires" => now()})
    :ok = Auth.put(:anthropic, old)
    :ok = Auth.subscribe()

    assert {:error, {:refresh_failed, message}} = Auth.credential(:anthropic)
    assert message =~ "400 invalid_grant: Refresh token expired"
    assert_receive {:rho_auth, :changed}
    assert Auth.get(:anthropic) == {:ok, old}
  end

  test "a new sign-in during a refresh wins over the refresh's result" do
    start_supervised!({Auth, respond: endpoint(200, 200)})
    :ok = Auth.put(:anthropic, creds(%{"expires" => now()}))

    waiting = Task.async(fn -> Auth.credential(:anthropic) end)
    assert_receive {:refresh_request, _}

    fresh = creds(%{"access" => "at-new", "refresh" => "rt-new"})
    :ok = Auth.put(:anthropic, fresh)

    assert Task.await(waiting) == {:ok, %{type: :oauth, token: "at-new", account_id: nil}}
    assert Auth.get(:anthropic) == {:ok, fresh}
  end

  test "an API key stored during a refresh wins: the waiter gets the key, the store keeps it" do
    start_supervised!({Auth, respond: endpoint(200, 200)})
    :ok = Auth.put(:anthropic, creds(%{"expires" => now()}))

    waiting = Task.async(fn -> Auth.credential(:anthropic) end)
    assert_receive {:refresh_request, _}

    :ok = Auth.put_api_key(:anthropic, "sk-ant-new")

    # the waiter is answered only once the refresh's result is in: it was
    # dropped, not saved over the key
    assert Task.await(waiting) == {:ok, %{type: :api_key, key: "sk-ant-new"}}
    assert Auth.get(:anthropic) == {:ok, %{"type" => "api_key", "key" => "sk-ant-new"}}
  end

  describe "when the store fails" do
    setup do
      on_exit(&FlakyCredentialStore.restore/0)
    end

    test "a refreshed sign-in that can't be saved is never handed out nor refreshed again from the spent token" do
      start_supervised!({Auth, respond: endpoint(), save_retry_ms: 60_000})
      :ok = Auth.put(:anthropic, creds(%{"expires" => now()}))
      :ok = Auth.subscribe()
      FlakyCredentialStore.install([:put])

      assert Auth.credential(:anthropic) == {:error, {:store_failed, :disk_full}}
      assert_received {:refresh_request, %{"refresh_token" => "rt-1"}}
      assert_received {:rho_auth, :changed}

      # the store still holds the spent rt-1: no second refresh with it
      assert Auth.credential(:anthropic) == {:error, {:store_failed, :disk_full}}
      refute_received {:refresh_request, _}
      assert {:ok, %{"refresh" => "rt-1"}} = Auth.get(:anthropic)

      # saving works again: the next call saves the rotated sign-in, then hands it out
      FlakyCredentialStore.fail([])
      assert {:ok, %{token: "at-2"}} = Auth.credential(:anthropic)
      refute_received {:refresh_request, _}
      assert {:ok, %{"access" => "at-2", "refresh" => "rt-2"}} = Auth.get(:anthropic)
    end

    test "an unsaved refreshed sign-in is saved by a background retry" do
      start_supervised!({Auth, respond: endpoint(), save_retry_ms: 20})
      :ok = Auth.put(:anthropic, creds(%{"expires" => now()}))
      FlakyCredentialStore.install([:put])

      assert {:error, {:store_failed, _}} = Auth.credential(:anthropic)
      FlakyCredentialStore.fail([])

      # no call needed: the retry timer saves it (polled, not slept on: CI is slow)
      assert Enum.any?(1..200, fn _ ->
               match?({:ok, %{"refresh" => "rt-2"}}, Auth.get(:anthropic)) or
                 (Process.sleep(10) && false)
             end)
    end

    test "a replacement that doesn't save leaves the refresh in flight in charge" do
      start_supervised!({Auth, respond: endpoint(200, 200)})
      :ok = Auth.put(:anthropic, creds(%{"expires" => now()}))

      waiting = Task.async(fn -> Auth.credential(:anthropic) end)
      assert_receive {:refresh_request, %{"refresh_token" => "rt-1"}}

      FlakyCredentialStore.install([:put])
      assert {:error, :disk_full} = Auth.put(:anthropic, creds(%{"refresh" => "rt-other"}))
      FlakyCredentialStore.fail([])

      # the refresh's rotated result is kept, not dropped and redone with the spent rt-1
      assert Task.await(waiting) == {:ok, %{type: :oauth, token: "at-2", account_id: nil}}
      assert {:ok, %{"refresh" => "rt-2"}} = Auth.get(:anthropic)
      refute_received {:refresh_request, _}
    end

    test "a sign-out that doesn't delete is an error, and nothing changes" do
      start_supervised!(Auth)
      :ok = Auth.put(:anthropic, creds())
      :ok = Auth.subscribe()
      FlakyCredentialStore.install([:delete])

      assert Auth.delete(:anthropic) == {:error, :disk_full}
      refute_received {:rho_auth, :changed}
      assert Auth.signed_in?(:anthropic)
    end
  end
end
