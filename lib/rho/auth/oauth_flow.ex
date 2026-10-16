defmodule Rho.Auth.OAuthFlow do
  @moduledoc """
  The OAuth authorization-code flows omp signs in with (`/login anthropic`,
  `/login openai-codex`), built as omp's declarative engine builds them from
  `pi-catalog`'s `rules/auth/anthropic.kdl` and `openai-codex.kdl`:

    * **Anthropic** (Claude Pro/Max): `https://claude.ai/oauth/authorize`
      with `code=true`, PKCE S256, redirect `http://localhost:54545/callback`;
      the token endpoint `https://api.anthropic.com/v1/oauth/token` takes a
      JSON body (the exchange also sends `state`; a refresh sends Claude
      Code's `anthropic-beta` and `User-Agent` headers). Access tokens live
      ~8 h and are stored 5 min short; each refresh rotates the refresh
      token, and the grant dies ~30 days after the interactive login.
    * **OpenAI Codex** (ChatGPT Plus/Pro): `https://auth.openai.com/oauth/authorize`,
      PKCE S256, redirect exactly `http://localhost:1455/auth/callback` (the
      only one OpenAI allows); `https://auth.openai.com/oauth/token` takes a
      form body. The ChatGPT account id comes from the access/id token's
      `https://api.openai.com/auth` claim.

  Credentials are pi's `auth.json` entry: `%{"type" => "oauth", "access",
  "refresh", "expires" (ms since the epoch), "accountId", "email"}` (the
  last two only when known).

  HTTP: `opts[:respond]` (tests) answers a request instead of the network,
  `fn %Req.Request{} -> %Req.Response{} end`, seeing it fully encoded.
  """

  @type provider :: :anthropic | :openai_codex
  @type flow :: %{verifier: String.t(), state: String.t()}
  @type creds :: %{String.t() => term()}

  # Public OAuth client id, stored base64 as omp does so secret scanners stay quiet.
  @anthropic_client_id Base.decode64!("OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl")
  @codex_client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  # The Claude Code SDK version omp's refresh User-Agent names (claudeCodeSdkVersion).
  @claude_code_sdk_version "0.112.1"
  @openai_auth_claim "https://api.openai.com/auth"
  @openai_profile_claim "https://api.openai.com/profile"
  @retry_ms 2_000

  @doc "The provider's registered localhost redirect URI (the one `start/2` normally gets)."
  @spec default_redirect(provider()) :: String.t()
  def default_redirect(:anthropic), do: "http://localhost:54545/callback"
  def default_redirect(:openai_codex), do: "http://localhost:1455/auth/callback"

  @doc """
  A new PKCE verifier and state, and the authorize URL for them: the
  standard parameters in omp's order, then the provider's extras.
  """
  @spec start(provider(), String.t()) :: %{
          url: String.t(),
          verifier: String.t(),
          state: String.t()
        }
  def start(provider, redirect_uri) do
    verifier = :crypto.strong_rand_bytes(96) |> Base.url_encode64(padding: false)
    state = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    %{
      url: authorize_url(provider, redirect_uri, verifier, state),
      verifier: verifier,
      state: state
    }
  end

  @doc false
  @spec authorize_url(provider(), String.t(), String.t(), String.t()) :: String.t()
  def authorize_url(provider, redirect_uri, verifier, state) do
    p = config(provider)

    params =
      [
        {"client_id", p.client_id},
        {"response_type", "code"},
        {"redirect_uri", redirect_uri},
        {"scope", Enum.join(p.scopes, " ")},
        {"code_challenge", challenge(verifier)},
        {"code_challenge_method", "S256"},
        {"state", state}
      ] ++ p.authorize_params

    p.authorize_url <> "?" <> URI.encode_query(params)
  end

  @doc "PKCE S256: base64url(sha256(verifier)), unpadded."
  @spec challenge(String.t()) :: String.t()
  def challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  @doc """
  Exchanges an authorization code for credentials. A `code#state` (what
  Anthropic's code page shows) is split, the pasted state winning, as omp
  does. `opts`: `:respond`, and `:retry_until` (a monotonic ms deadline:
  transport errors are retried every 2 s until then, for a phone whose
  network Android cuts while the browser is in front).
  """
  @spec exchange(provider(), String.t(), flow(), String.t(), keyword()) ::
          {:ok, creds()} | {:error, String.t()}
  def exchange(provider, code, %{verifier: verifier, state: state}, redirect_uri, opts \\ []) do
    p = config(provider)

    {code, state} =
      case String.split(code, "#", parts: 2) do
        [code, pasted] when pasted != "" -> {code, pasted}
        [code | _] -> {code, state}
      end

    params =
      [
        grant_type: "authorization_code",
        client_id: p.client_id,
        code: code,
        redirect_uri: redirect_uri,
        code_verifier: verifier
      ] ++ if(provider == :anthropic, do: [state: state], else: [])

    with {:ok, body} <- token_request(p, params, [], "token exchange", opts) do
      login_creds(provider, body)
    end
  end

  @doc """
  Trades `creds`' refresh token for new credentials. The refresh token
  rotates when the response carries one; identity the response lacks is
  kept from `creds`.
  """
  @spec refresh(provider(), creds(), keyword()) :: {:ok, creds()} | {:error, String.t()}
  def refresh(provider, %{"refresh" => refresh} = creds, opts \\ []) when is_binary(refresh) do
    p = config(provider)
    params = [grant_type: "refresh_token", client_id: p.client_id, refresh_token: refresh]

    with {:ok, body} <- token_request(p, params, p.refresh_headers, "token refresh", opts),
         {:ok, fresh} <- base_creds(p, body, refresh) do
      {:ok, Map.merge(creds, Map.merge(fresh, identity(provider, body)))}
    end
  end

  # ── providers ──

  defp config(:anthropic) do
    %{
      name: "Anthropic",
      client_id: @anthropic_client_id,
      authorize_url: "https://claude.ai/oauth/authorize",
      scopes: ~w(org:create_api_key user:profile user:inference user:sessions:claude_code
                 user:mcp_servers user:file_upload),
      authorize_params: [{"code", "true"}],
      token_url: "https://api.anthropic.com/v1/oauth/token",
      body: :json,
      timeout_ms: 30_000,
      skew_ms: 300_000,
      refresh_headers: [
        {"anthropic-beta", "oauth-2025-04-20"},
        {"user-agent", "anthropic-sdk-typescript/#{@claude_code_sdk_version} userOAuthProvider"}
      ]
    }
  end

  defp config(:openai_codex) do
    %{
      name: "OpenAI",
      client_id: @codex_client_id,
      authorize_url: "https://auth.openai.com/oauth/authorize",
      scopes: ~w(openid profile email offline_access api.connectors.read api.connectors.invoke),
      authorize_params: [
        {"id_token_add_organizations", "true"},
        {"codex_cli_simplified_flow", "true"},
        {"originator", "omp"}
      ],
      token_url: "https://auth.openai.com/oauth/token",
      body: :form,
      timeout_ms: 15_000,
      skew_ms: 0,
      refresh_headers: []
    }
  end

  # ── token endpoint ──

  defp token_request(p, params, headers, what, opts) do
    case post(p, params, headers, opts) do
      {:ok, status, body} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, status, body} ->
        {:error, "#{p.name} #{what} failed: #{status} #{error_text(body)}"}

      {:transport, reason} ->
        deadline = opts[:retry_until]

        if deadline && System.monotonic_time(:millisecond) + @retry_ms < deadline do
          Process.sleep(@retry_ms)
          token_request(p, params, headers, what, opts)
        else
          {:error, "#{p.name} #{what} failed: no connection (#{reason})"}
        end
    end
  end

  defp post(p, params, headers, opts) do
    encoded = if p.body == :json, do: [json: Map.new(params)], else: [form: params]

    req =
      Req.new(
        [
          method: :post,
          url: p.token_url,
          headers: [{"accept", "application/json"} | headers],
          retry: false,
          decode_body: false,
          receive_timeout: p.timeout_ms,
          connect_options: [timeout: 10_000]
        ] ++ encoded
      )

    req =
      case opts[:respond] do
        nil -> req
        respond -> Req.Request.append_request_steps(req, respond: &{&1, respond.(&1)})
      end

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, decode(body)}
      {:error, e} -> {:transport, Exception.message(e)}
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode(body), do: body

  # `error: error_description` as OAuth servers send it, else a bounded body.
  defp error_text(%{"error" => %{} = e}), do: error_text(e)

  defp error_text(%{} = body) do
    code = body["error"] || body["type"] || body["code"]
    message = body["error_description"] || body["message"]

    case {code, message} do
      {nil, nil} -> body |> Jason.encode!() |> String.slice(0, 300)
      {code, nil} -> to_string(code)
      {nil, message} -> to_string(message)
      {code, message} -> "#{code}: #{message}"
    end
  end

  defp error_text(body), do: body |> to_string() |> String.slice(0, 300)

  # ── credentials ──

  defp login_creds(provider, body) do
    with {:ok, creds} <- base_creds(config(provider), body, nil) do
      creds = Map.merge(creds, identity(provider, body))

      if provider == :openai_codex and not Map.has_key?(creds, "accountId") and
           not Map.has_key?(creds, "email"),
         do: {:error, "OpenAI sign-in: no account identity in the token"},
         else: {:ok, creds}
    end
  end

  defp base_creds(p, %{"access_token" => access} = body, previous_refresh)
       when is_binary(access) and access != "" do
    case {body["expires_in"], body["refresh_token"] || previous_refresh} do
      {seconds, refresh} when is_number(seconds) and is_binary(refresh) and refresh != "" ->
        {:ok,
         %{
           "type" => "oauth",
           "access" => access,
           "refresh" => refresh,
           "expires" => System.os_time(:millisecond) + round(seconds * 1000) - p.skew_ms
         }}

      _ ->
        {:error, "#{p.name} token response is missing refresh_token or expires_in"}
    end
  end

  defp base_creds(p, _body, _previous),
    do: {:error, "#{p.name} token response has no access_token"}

  defp identity(:anthropic, body) do
    compact(%{
      "accountId" => get_in(body, ["account", "uuid"]),
      "email" => get_in(body, ["account", "email_address"])
    })
  end

  defp identity(:openai_codex, body) do
    claims = Enum.map([body["access_token"], body["id_token"]], &jwt_claims/1)
    email = Enum.find_value(claims, &get_in(&1, [@openai_profile_claim, "email"]))

    compact(%{
      "accountId" =>
        Enum.find_value(claims, &get_in(&1, [@openai_auth_claim, "chatgpt_account_id"])),
      "email" => email && email |> String.trim() |> String.downcase()
    })
  end

  defp compact(map), do: Map.reject(map, fn {_k, v} -> not is_binary(v) or v == "" end)

  @doc false
  @spec jwt_claims(term()) :: map()
  def jwt_claims(token) when is_binary(token) do
    with [_, payload, _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = claims} <- Jason.decode(json) do
      claims
    else
      _ -> %{}
    end
  end

  def jwt_claims(_), do: %{}
end
