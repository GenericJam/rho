defmodule Rho.Auth.OAuthFlowTest do
  use ExUnit.Case, async: true

  alias Rho.Auth.OAuthFlow

  @anthropic_client "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @codex_client "app_EMoamEEZ73f0CkXaXp7hrann"

  # Answers the token endpoint with `status`/`body`, telling the test what was sent.
  defp responding(status, body) do
    me = self()

    fn req ->
      send(me, {:token_request, req})
      Req.Response.new(status: status, body: Jason.encode!(body))
    end
  end

  defp sent do
    assert_received {:token_request, req}
    [type] = Req.Request.get_header(req, "content-type")
    body = IO.iodata_to_binary(req.body)

    decoded =
      if type == "application/json", do: Jason.decode!(body), else: URI.decode_query(body)

    %{url: URI.to_string(req.url), type: type, body: decoded, headers: req.headers}
  end

  defp jwt(claims) do
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    "eyJhbGciOiJub25lIn0." <> payload <> ".sig"
  end

  describe "start/2" do
    test "Anthropic: claude.ai's authorize URL with omp's parameters, in omp's order" do
      redirect = OAuthFlow.default_redirect(:anthropic)
      assert redirect == "http://localhost:54545/callback"

      %{url: url, verifier: verifier, state: state} = OAuthFlow.start(:anthropic, redirect)

      %URI{scheme: "https", host: "claude.ai", path: "/oauth/authorize", query: query} =
        URI.parse(url)

      assert URI.query_decoder(query) |> Enum.to_list() == [
               {"client_id", @anthropic_client},
               {"response_type", "code"},
               {"redirect_uri", redirect},
               {"scope",
                "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"},
               {"code_challenge", OAuthFlow.challenge(verifier)},
               {"code_challenge_method", "S256"},
               {"state", state},
               {"code", "true"}
             ]

      # form-encoded like URLSearchParams: spaces as +, : and / escaped
      assert query =~ "scope=org%3Acreate_api_key+user%3Aprofile+"
      assert query =~ "redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback"

      # PKCE: 96 random bytes base64url; state: 16 bytes hex
      assert byte_size(verifier) == 128 and verifier =~ ~r/^[A-Za-z0-9_-]+$/
      assert state =~ ~r/^[0-9a-f]{32}$/
      assert OAuthFlow.start(:anthropic, redirect).state != state
    end

    test "OpenAI Codex: auth.openai.com with the Codex CLI's extra parameters" do
      redirect = OAuthFlow.default_redirect(:openai_codex)
      assert redirect == "http://localhost:1455/auth/callback"

      %{url: url, verifier: verifier, state: state} = OAuthFlow.start(:openai_codex, redirect)
      %URI{host: "auth.openai.com", path: "/oauth/authorize", query: query} = URI.parse(url)

      assert URI.query_decoder(query) |> Enum.to_list() == [
               {"client_id", @codex_client},
               {"response_type", "code"},
               {"redirect_uri", redirect},
               {"scope",
                "openid profile email offline_access api.connectors.read api.connectors.invoke"},
               {"code_challenge", OAuthFlow.challenge(verifier)},
               {"code_challenge_method", "S256"},
               {"state", state},
               {"id_token_add_organizations", "true"},
               {"codex_cli_simplified_flow", "true"},
               {"originator", "omp"}
             ]
    end

    test "the S256 challenge is RFC 7636's" do
      # RFC 7636 appendix B
      assert OAuthFlow.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
               "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    end
  end

  describe "exchange/5" do
    test "Anthropic: JSON with the PKCE verifier and state; identity from the account" do
      flow = %{verifier: "v-1", state: "s-1"}
      redirect = OAuthFlow.default_redirect(:anthropic)

      respond =
        responding(200, %{
          "access_token" => "at",
          "refresh_token" => "rt",
          "expires_in" => 28_800,
          "account" => %{"uuid" => "acc-1", "email_address" => "k@example.com"}
        })

      before = System.os_time(:millisecond)

      assert {:ok, creds} =
               OAuthFlow.exchange(:anthropic, "code-1", flow, redirect, respond: respond)

      assert %{
               url: "https://api.anthropic.com/v1/oauth/token",
               type: "application/json",
               body: body
             } =
               sent()

      assert body == %{
               "grant_type" => "authorization_code",
               "client_id" => @anthropic_client,
               "code" => "code-1",
               "redirect_uri" => redirect,
               "code_verifier" => "v-1",
               "state" => "s-1"
             }

      assert %{
               "type" => "oauth",
               "access" => "at",
               "refresh" => "rt",
               "accountId" => "acc-1",
               "email" => "k@example.com"
             } = creds

      # stored 5 minutes short of the 8 h, as omp does
      assert_in_delta creds["expires"], before + 28_800_000 - 300_000, 1_000
    end

    test "Anthropic's pasted code#state: the pasted state is sent" do
      respond =
        responding(200, %{"access_token" => "at", "refresh_token" => "rt", "expires_in" => 60})

      flow = %{verifier: "v", state: "flow-state"}

      assert {:ok, creds} =
               OAuthFlow.exchange(:anthropic, "the-code#pasted-state", flow, "r",
                 respond: respond
               )

      assert %{"code" => "the-code", "state" => "pasted-state"} = sent().body
      refute Map.has_key?(creds, "email")
    end

    test "OpenAI: a form body without state; the account id from the token's auth claim" do
      access =
        jwt(%{
          "https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct-42"},
          "https://api.openai.com/profile" => %{"email" => " K@Example.com "}
        })

      respond =
        responding(200, %{"access_token" => access, "refresh_token" => "rt", "expires_in" => 3600})

      redirect = OAuthFlow.default_redirect(:openai_codex)
      flow = %{verifier: "v-2", state: "s-2"}
      before = System.os_time(:millisecond)

      assert {:ok, creds} =
               OAuthFlow.exchange(:openai_codex, "code-2", flow, redirect, respond: respond)

      assert %{
               url: "https://auth.openai.com/oauth/token",
               type: "application/x-www-form-urlencoded",
               body: body
             } = sent()

      assert body == %{
               "grant_type" => "authorization_code",
               "client_id" => @codex_client,
               "code" => "code-2",
               "redirect_uri" => redirect,
               "code_verifier" => "v-2"
             }

      assert %{"accountId" => "acct-42", "email" => "k@example.com", "access" => ^access} = creds
      assert_in_delta creds["expires"], before + 3_600_000, 1_000
    end

    test "OpenAI: the id token's claim counts too; no identity at all fails the sign-in" do
      id_token = jwt(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "from-id"}})

      respond =
        responding(200, %{
          "access_token" => "opaque",
          "id_token" => id_token,
          "refresh_token" => "rt",
          "expires_in" => 3600
        })

      flow = %{verifier: "v", state: "s"}

      assert {:ok, %{"accountId" => "from-id"}} =
               OAuthFlow.exchange(:openai_codex, "c", flow, "r", respond: respond)

      respond =
        responding(200, %{"access_token" => "opaque", "refresh_token" => "rt", "expires_in" => 1})

      assert {:error, "OpenAI sign-in: no account identity in the token"} =
               OAuthFlow.exchange(:openai_codex, "c", flow, "r", respond: respond)
    end

    test "the token endpoint's error comes back readable" do
      flow = %{verifier: "v", state: "s"}

      respond =
        responding(400, %{"error" => "invalid_grant", "error_description" => "Code expired"})

      assert {:error, "Anthropic token exchange failed: 400 invalid_grant: Code expired"} =
               OAuthFlow.exchange(:anthropic, "c", flow, "r", respond: respond)

      respond = responding(401, %{"error" => %{"type" => "unauthorized", "message" => "nope"}})

      assert {:error, "OpenAI token exchange failed: 401 unauthorized: nope"} =
               OAuthFlow.exchange(:openai_codex, "c", flow, "r", respond: respond)

      respond = responding(200, %{"refresh_token" => "rt"})

      assert {:error, "Anthropic token response has no access_token"} =
               OAuthFlow.exchange(:anthropic, "c", flow, "r", respond: respond)
    end

    test "transport errors are retried until the deadline" do
      me = self()

      respond = fn _req ->
        n = Process.get(:attempts, 0) + 1
        Process.put(:attempts, n)
        send(me, {:attempt, n})

        if n == 1,
          do: Req.TransportError.exception(reason: :econnrefused),
          else:
            Req.Response.new(
              status: 200,
              body: ~s({"access_token":"a","refresh_token":"r","expires_in":5})
            )
      end

      deadline = System.monotonic_time(:millisecond) + 10_000

      assert {:ok, %{"access" => "a"}} =
               OAuthFlow.exchange(:anthropic, "c", %{verifier: "v", state: "s"}, "r",
                 respond: respond,
                 retry_until: deadline
               )

      assert_received {:attempt, 2}

      # without a deadline, one try
      Process.delete(:attempts)

      assert {:error, "Anthropic token exchange failed: no connection" <> _} =
               OAuthFlow.exchange(:anthropic, "c", %{verifier: "v", state: "s"}, "r",
                 respond: respond
               )
    end
  end

  describe "refresh/3" do
    test "Anthropic: JSON refresh grant with Claude Code's headers; the refresh token rotates" do
      stored = %{
        "type" => "oauth",
        "access" => "old",
        "refresh" => "rt-1",
        "expires" => 0,
        "accountId" => "acc-1",
        "email" => "k@example.com"
      }

      respond =
        responding(200, %{
          "access_token" => "new",
          "refresh_token" => "rt-2",
          "expires_in" => 28_800
        })

      assert {:ok, creds} = OAuthFlow.refresh(:anthropic, stored, respond: respond)
      %{body: body, headers: headers} = sent()

      assert body == %{
               "grant_type" => "refresh_token",
               "client_id" => @anthropic_client,
               "refresh_token" => "rt-1"
             }

      assert headers["anthropic-beta"] == ["oauth-2025-04-20"]
      assert headers["user-agent"] == ["anthropic-sdk-typescript/0.112.1 userOAuthProvider"]

      # identity the response lacks is kept
      assert %{
               "access" => "new",
               "refresh" => "rt-2",
               "accountId" => "acc-1",
               "email" => "k@example.com"
             } =
               creds

      assert creds["expires"] > System.os_time(:millisecond)
    end

    test "OpenAI: a form refresh grant; an unrotated refresh token is kept" do
      stored = %{
        "type" => "oauth",
        "access" => "",
        "refresh" => "rt-1",
        "expires" => 0,
        "accountId" => "a"
      }

      respond = responding(200, %{"access_token" => "new", "expires_in" => 3600})

      assert {:ok, %{"access" => "new", "refresh" => "rt-1", "accountId" => "a"}} =
               OAuthFlow.refresh(:openai_codex, stored, respond: respond)

      assert %{type: "application/x-www-form-urlencoded", body: body, headers: headers} = sent()

      assert body == %{
               "grant_type" => "refresh_token",
               "client_id" => @codex_client,
               "refresh_token" => "rt-1"
             }

      refute Map.has_key?(headers, "anthropic-beta")
    end
  end
end
