defmodule Rho.Auth.VaultTest do
  # async: false: asserts that nothing reaches the app-wide credential store.
  use ExUnit.Case, async: false

  alias Rho.Auth.Vault

  @moduletag :capture_log

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

  defp due, do: creds(%{"expires" => now()})

  # A token endpoint that tells the test of each refresh, answers after
  # `delay_ms` and rotates the refresh token.
  defp endpoint(status \\ 200, delay_ms \\ 0) do
    test = self()

    fn req ->
      params = req.body |> IO.iodata_to_binary() |> Jason.decode!()
      send(test, {:refresh_request, params["refresh_token"]})
      Process.sleep(delay_ms)

      body =
        if status == 200,
          do: %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 3600},
          else: %{"error" => "invalid_grant", "error_description" => "Refresh token expired"}

      Req.Response.new(status: status, body: Jason.encode!(body))
    end
  end

  # An :on_refresh that tells the test, then answers `answer`.
  defp told(answer \\ :ok) do
    test = self()

    fn provider, creds ->
      send(test, {:on_refresh, provider, creds})
      answer
    end
  end

  defp vault(opts), do: start_supervised!({Vault, opts}, id: make_ref())

  test "put/get/status/delete in memory only; subscribers hear every change" do
    v = vault([])
    :ok = Vault.subscribe(v)
    c = creds(%{"email" => "k@example.com", "accountId" => "acct"})

    assert :ok = Vault.put(v, :openai_codex, c)
    assert_received {:rho_auth_vault, ^v, :changed}
    assert Vault.get(v, :openai_codex) == {:ok, c}

    assert Vault.status(v).openai_codex ==
             %{signed_in: true, type: :oauth, email: "k@example.com", expires: c["expires"]}

    assert {:ok, %{type: :oauth, token: "at-1", account_id: "acct"}} =
             Vault.credential(v, :openai_codex)

    assert :ok = Vault.put_api_key(v, :google, " AIza-1\n")
    assert Vault.credential(v, :google) == {:ok, %{type: :api_key, key: "AIza-1"}}

    # never written to the node's store
    for p <- Rho.Auth.providers(), do: assert(Rho.CredentialStore.get("auth:#{p}") == :error)

    assert :ok = Vault.delete(v, :openai_codex)
    assert_received {:rho_auth_vault, ^v, :changed}
    assert Vault.get(v, :openai_codex) == :error
    assert Vault.credential(v, :openai_codex) == {:error, :signed_out}
    refute Vault.signed_in?(v, :openai_codex)
  end

  test "put refuses what doesn't fit the provider" do
    v = vault([])

    assert Vault.put(v, :anthropic, Map.delete(creds(), "refresh")) ==
             {:error, :invalid_credentials}

    assert Vault.put(v, :openai, creds()) == {:error, :invalid_credentials}
    assert Vault.put(v, :mistral, creds()) == {:error, :unknown_provider}
    assert Vault.get(v, :anthropic) == :error
  end

  test "two vaults never see each other's credentials" do
    a = vault([])
    b = vault([])
    :ok = Vault.put_api_key(a, :anthropic, "sk-ant-a")

    assert Vault.credential(a, :anthropic) == {:ok, %{type: :api_key, key: "sk-ant-a"}}
    assert Vault.credential(b, :anthropic) == {:error, :signed_out}
    refute Vault.status(b).anthropic.signed_in
  end

  test "concurrent callers share one refresh; :on_refresh has the new sign-in before anyone gets it" do
    v = vault(respond: endpoint(200, 150), on_refresh: told())
    :ok = Vault.put(v, :anthropic, due())
    :ok = Vault.subscribe(v)

    results =
      1..5
      |> Enum.map(fn _ -> Task.async(fn -> Vault.credential(v, :anthropic) end) end)
      |> Task.await_many()

    assert Enum.uniq(results) == [{:ok, %{type: :oauth, token: "at-2", account_id: nil}}]
    assert_received {:refresh_request, "rt-1"}
    refute_received {:refresh_request, _}
    assert_received {:on_refresh, :anthropic, %{"access" => "at-2", "refresh" => "rt-2"}}
    # a refresh that worked is a change too
    assert_received {:rho_auth_vault, ^v, :changed}
    assert {:ok, %{"refresh" => "rt-2"}} = Vault.get(v, :anthropic)
  end

  test "an :on_refresh that fails holds the refreshed sign-in back, never refreshing the spent token again" do
    test = self()
    answer = :counters.new(1, [])

    on_refresh = fn _provider, creds ->
      send(test, {:on_refresh, creds["refresh"]})
      if :counters.get(answer, 1) == 0, do: {:error, :phone_unreachable}, else: :ok
    end

    v = vault(respond: endpoint(), on_refresh: on_refresh, save_retry_ms: 60_000)
    :ok = Vault.put(v, :anthropic, due())

    assert Vault.credential(v, :anthropic) == {:error, {:store_failed, :phone_unreachable}}
    assert_received {:refresh_request, "rt-1"}
    assert_received {:on_refresh, "rt-2"}

    # still held back: no second refresh with the spent rt-1
    assert Vault.credential(v, :anthropic) == {:error, {:store_failed, :phone_unreachable}}
    refute_received {:refresh_request, _}
    assert {:ok, %{"refresh" => "rt-1"}} = Vault.get(v, :anthropic)

    # :on_refresh works now: the next call keeps the rotated sign-in, then hands it out
    :counters.add(answer, 1, 1)
    assert {:ok, %{token: "at-2"}} = Vault.credential(v, :anthropic)
    refute_received {:refresh_request, _}
    assert {:ok, %{"refresh" => "rt-2"}} = Vault.get(v, :anthropic)
  end

  test "a put during a refresh wins over the refresh's result" do
    v = vault(respond: endpoint(200, 200), on_refresh: told())
    :ok = Vault.put(v, :anthropic, due())

    waiting = Task.async(fn -> Vault.credential(v, :anthropic) end)
    assert_receive {:refresh_request, "rt-1"}

    fresh = creds(%{"access" => "at-new", "refresh" => "rt-new"})
    :ok = Vault.put(v, :anthropic, fresh)

    assert Task.await(waiting) == {:ok, %{type: :oauth, token: "at-new", account_id: nil}}
    assert Vault.get(v, :anthropic) == {:ok, fresh}
    refute_received {:on_refresh, _, _}
  end

  test "a failed refresh keeps the sign-in and says so" do
    v = vault(respond: endpoint(400), on_refresh: told())
    old = due()
    :ok = Vault.put(v, :anthropic, old)
    :ok = Vault.subscribe(v)

    assert {:error, {:refresh_failed, message}} = Vault.credential(v, :anthropic)
    assert message =~ "invalid_grant"
    assert_receive {:rho_auth_vault, ^v, :changed}
    assert Vault.get(v, :anthropic) == {:ok, old}
    refute_received {:on_refresh, _, _}
  end

  describe ":refresher" do
    test "its fresh credentials are kept as they are: no refresh here, no :on_refresh" do
      test = self()
      from_phone = creds(%{"access" => "at-phone", "refresh" => "rt-phone"})

      refresher = fn provider ->
        send(test, {:asked, provider})
        {:ok, from_phone}
      end

      v = vault(respond: endpoint(), on_refresh: told(), refresher: refresher)
      :ok = Vault.put(v, :anthropic, due())

      assert {:ok, %{token: "at-phone"}} = Vault.credential(v, :anthropic)
      assert_received {:asked, :anthropic}
      refute_received {:refresh_request, _}
      refute_received {:on_refresh, _, _}
      assert Vault.get(v, :anthropic) == {:ok, from_phone}
    end

    test ":local, a crash or invalid credentials: the vault refreshes itself and tells :on_refresh" do
      for answer <- [fn _ -> :local end, fn _ -> raise "boom" end, fn _ -> {:ok, %{}} end] do
        v = vault(respond: endpoint(), on_refresh: told(), refresher: answer)
        :ok = Vault.put(v, :anthropic, due())

        assert {:ok, %{token: "at-2"}} = Vault.credential(v, :anthropic)
        assert_received {:refresh_request, "rt-1"}
        assert_received {:on_refresh, :anthropic, %{"refresh" => "rt-2"}}
      end
    end

    test "no answer within :refresher_timeout: the vault refreshes itself" do
      test = self()

      refresher = fn _provider ->
        send(test, {:asked, self()})
        Process.sleep(:infinity)
      end

      v =
        vault(
          respond: endpoint(),
          on_refresh: told(),
          refresher: refresher,
          refresher_timeout: 50
        )

      :ok = Vault.put(v, :anthropic, due())

      assert {:ok, %{token: "at-2"}} = Vault.credential(v, :anthropic)
      assert_received {:asked, asked}
      refute Process.alive?(asked)
      assert_received {:refresh_request, "rt-1"}
      assert_received {:on_refresh, :anthropic, _}
    end

    test "the refreshed sign-in arriving by put while it is asked wins" do
      test = self()

      refresher = fn _provider ->
        send(test, {:asked, self()})
        receive do: (:answer -> :local)
      end

      v = vault(respond: endpoint(), on_refresh: told(), refresher: refresher)
      :ok = Vault.put(v, :anthropic, due())

      waiting = Task.async(fn -> Vault.credential(v, :anthropic) end)
      assert_receive {:asked, asked}

      from_phone = creds(%{"access" => "at-phone", "refresh" => "rt-phone"})
      :ok = Vault.put(v, :anthropic, from_phone)

      # the delegation in flight is stopped: it never falls back to spending rt-1 here
      assert Task.await(waiting) == {:ok, %{type: :oauth, token: "at-phone", account_id: nil}}
      refute Process.alive?(asked)
      refute_received {:refresh_request, _}
      assert Vault.get(v, :anthropic) == {:ok, from_phone}
    end
  end

  test "a stopped vault holds nothing" do
    {:ok, v} = Vault.start_link([])
    :ok = Vault.put_api_key(v, :anthropic, "sk-ant-1")
    :ok = GenServer.stop(v)

    assert Vault.credential(v, :anthropic) == {:error, :signed_out}
    assert Vault.get(v, :anthropic) == :error
    refute Vault.status(v).anthropic.signed_in
  end
end
