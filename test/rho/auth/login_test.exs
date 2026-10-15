defmodule Rho.Auth.LoginTest do
  # async: false: Rho.Auth and Rho.Auth.Login are app-wide singletons.
  use ExUnit.Case, async: false

  alias Rho.Auth
  alias Rho.Auth.Login

  @moduletag :capture_log

  setup do
    {:ok, sock} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)

    test = self()

    token_endpoint = fn req ->
      %{"code" => code} = params = Jason.decode!(IO.iodata_to_binary(req.body))
      send(test, {:token_request, params})
      if code == "slow", do: Process.sleep(300)

      body = %{
        "access_token" => "at",
        "refresh_token" => "rt",
        "expires_in" => 28_800,
        "account" => %{"email_address" => "k@example.com"}
      }

      Req.Response.new(status: 200, body: Jason.encode!(body))
    end

    start_supervised!(Auth)

    login_opts = [
      open_url: fn url ->
        send(test, {:opened, url})
        :ok
      end,
      redirect: fn
        :anthropic -> "http://localhost:#{port}/callback"
        :openai_codex -> "http://localhost:#{port}/auth/callback"
      end,
      respond: token_endpoint
    ]

    start_supervised!({Login, login_opts})

    on_exit(fn -> for p <- Auth.providers(), do: Rho.CredentialStore.delete("auth:#{p}") end)
    %{port: port, login_opts: login_opts}
  end

  defp opened_state do
    assert_received {:opened, url}
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
  end

  defp browse(port, path_and_query) do
    Req.get!("http://127.0.0.1:#{port}#{path_and_query}", retry: false, redirect: false)
  end

  test "the browser's redirect lands on the phone's listener, which signs in", %{port: port} do
    assert {:ok, "https://claude.ai/oauth/authorize?" <> _ = url} = Login.begin(:anthropic)
    assert url =~ URI.encode_www_form("http://localhost:#{port}/callback")
    state = opened_state()

    # browsers also ask for the favicon
    assert %{status: 404} = browse(port, "/favicon.ico")

    page = browse(port, "/callback?code=the-code&state=#{state}")
    assert page.status == 200
    assert page.body =~ "Switch back to the app"

    assert_receive {:rho_login, :anthropic, :ok}, 2_000
    assert_received {:token_request, %{"code" => "the-code", "state" => ^state}}
    assert {:ok, %{"access" => "at", "email" => "k@example.com"}} = Auth.get(:anthropic)

    # the flow is over: the listener is closed and a paste has nothing to finish
    assert {:error, _} = Req.get("http://127.0.0.1:#{port}/callback", retry: false)
    assert Login.paste(:anthropic, "x#y") == {:error, :no_login_started}
  end

  test "an older tab's redirect gets an error page and leaves the sign-in in progress alone",
       %{port: port} do
    {:ok, _url} = Login.begin(:anthropic)
    state = opened_state()

    for stale <- ["/callback?code=c&state=forged", "/callback?code=c", "/callback"] do
      page = browse(port, stale)
      assert page.body =~ "out of date"
    end

    refute_received {:rho_login, _, _}
    refute_received {:token_request, _}

    browse(port, "/callback?code=good&state=#{state}")
    assert_receive {:rho_login, :anthropic, :ok}, 2_000
    assert_received {:token_request, %{"code" => "good"}}
  end

  test "a new sign-in cancels an exchange still running for the old one" do
    {:ok, _url} = Login.begin(:anthropic)
    state = opened_state()
    :ok = Login.paste(:anthropic, "slow##{state}")
    assert_receive {:token_request, %{"code" => "slow"}}

    {:ok, _url} = Login.begin(:anthropic)

    refute_receive {:rho_login, :anthropic, _}, 500
    refute Auth.signed_in?(:anthropic)
  end

  test "a sign-in nobody finishes times out and frees the port", %{
    port: port,
    login_opts: opts
  } do
    stop_supervised!(Login)
    start_supervised!({Login, Keyword.put(opts, :flow_timeout_ms, 50)})

    {:ok, _url} = Login.begin(:anthropic)
    assert_receive {:rho_login, :anthropic, {:error, message}}, 1_000
    assert message =~ "sign in again from the app's settings"
    assert {:error, _} = Req.get("http://127.0.0.1:#{port}/callback", retry: false)
  end

  test "with the device's secure store unavailable, the sign-in fails and says why", %{port: port} do
    Application.put_env(:rho, :credential_store, Rho.Test.UnavailableStore)
    on_exit(fn -> Application.delete_env(:rho, :credential_store) end)

    {:ok, _url} = Login.begin(:anthropic)
    browse(port, "/callback?code=c&state=#{opened_state()}")

    assert_receive {:rho_login, :anthropic, {:error, message}}, 2_000
    assert message == "couldn't save it: the device's secure store isn't available in this build"
  end

  test "providers that take only an API key have no sign-in flow" do
    assert Login.begin(:google) == {:error, :not_oauth}
    assert Login.begin(:openai) == {:error, :not_oauth}
    refute_received {:opened, _}
  end

  test "the provider saying no is reported", %{port: port} do
    {:ok, _url} = Login.begin(:anthropic)
    state = opened_state()

    browse(port, "/callback?error=access_denied&error_description=User+declined&state=#{state}")

    assert_receive {:rho_login, :anthropic, {:error, message}}
    assert message =~ "access_denied: User declined"
  end

  test "Anthropic's code page: the pasted code#state finishes the sign-in" do
    assert Login.paste(:anthropic, "c#s") == {:error, :no_login_started}

    {:ok, _url} = Login.begin(:anthropic)
    state = opened_state()

    assert Login.paste(:openai_codex, "c##{state}") == {:error, {:started_for, :anthropic}}
    assert Login.paste(:anthropic, "c#another-state") == {:error, :state_mismatch}
    assert Login.paste(:anthropic, "   ") == {:error, :no_code}

    assert Login.paste(:anthropic, " pasted-code##{state} ") == :ok
    assert_receive {:rho_login, :anthropic, :ok}, 2_000
    assert_received {:token_request, %{"code" => "pasted-code", "state" => ^state}}
    assert Auth.signed_in?(:anthropic)
  end

  test "pasted input: code#state, a bare code, a redirect URL or its query" do
    assert Login.parse_input("abc#def") == {"abc", "def"}
    assert Login.parse_input("abc") == {"abc", nil}

    assert Login.parse_input("http://localhost:1455/auth/callback?code=c1&state=s1") ==
             {"c1", "s1"}

    assert Login.parse_input("?code=c2&state=s2") == {"c2", "s2"}
    assert Login.parse_input("code=c3") == {"c3", nil}
    assert Login.parse_input("") == {nil, nil}
  end
end
