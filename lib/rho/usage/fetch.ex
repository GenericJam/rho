defmodule Rho.Usage.Fetch do
  @moduledoc """
  Asks a provider's OAuth usage endpoint what its subscription has left,
  with the sign-in's access token (`Rho.Auth.credential/1`), as omp
  does (subscriptions only: an API key has no such endpoint):

    * Claude: `GET https://api.anthropic.com/api/oauth/usage` with the
      `oauth-2025-04-20` beta and Claude Code's user agent
    * ChatGPT: `GET https://chatgpt.com/backend-api/wham/usage` with the
      `chatgpt-account-id`

  `refresh/3` stores the result (`Rho.Usage.put_endpoint/5`). The
  token goes only into the request's `authorization` header; errors never
  include it.
  """

  alias Rho.Auth
  alias Rho.Usage

  @anthropic_url "https://api.anthropic.com/api/oauth/usage"
  @codex_url "https://chatgpt.com/backend-api/wham/usage"
  # req_llm's Claude subscription identity, so the endpoint sees what the
  # model calls send.
  @claude_user_agent "claude-cli/2.1.282 (external, cli)"

  @doc """
  Fetches and stores `provider`'s windows. `opts`: `:credential` (default
  `Rho.Auth.credential/1`), `:respond` (a test's fake response for
  the `Req.Request`), `:now`.
  """
  @spec refresh(Path.t(), Auth.provider(), keyword()) :: :ok | {:error, String.t()}
  def refresh(dir, provider, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with {:ok, body} <- fetch(provider, opts) do
      {windows, plan} = Usage.from_endpoint(provider, body, now)

      if windows == %{} do
        {:error, "the usage endpoint returned no windows"}
      else
        Usage.put_endpoint(dir, provider, windows, plan, now)
      end
    end
  end

  @doc """
  `provider`'s usage JSON, or why there is none: signed out, an API key
  (no subscription), an expired sign-in, or the endpoint's HTTP status and
  message (it answers 429 when asked too often).
  """
  @spec fetch(Auth.provider(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def fetch(provider, opts \\ []) do
    credential = Keyword.get(opts, :credential, &Auth.credential/1)

    case credential.(provider) do
      {:ok, %{type: :oauth} = auth} when provider in [:anthropic, :openai_codex] ->
        get(provider, auth, opts)

      {:ok, _api_key} ->
        {:error, "no subscription usage: #{Auth.label(provider)} is used with an API key"}

      {:error, :signed_out} ->
        {:error, "not signed in"}

      {:error, {:refresh_failed, message}} ->
        {:error, "sign-in expired: #{message}"}

      {:error, reason} ->
        {:error, "no sign-in (#{Auth.describe_error(reason)})"}
    end
  end

  defp get(provider, auth, opts) do
    req =
      Req.new(
        url: url(provider),
        headers: [{"accept", "application/json"} | headers(provider, auth)],
        retry: false,
        decode_body: false,
        receive_timeout: 15_000,
        connect_options: [timeout: 10_000]
      )

    req =
      case opts[:respond] do
        nil -> req
        respond -> Req.Request.append_request_steps(req, respond: &{&1, respond.(&1)})
      end

    case Req.request(req) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{} = json} -> {:ok, json}
          _ -> {:error, "the usage endpoint didn't return JSON"}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}#{error_text(body)}"}

      {:error, e} ->
        {:error, "no connection (#{Exception.message(e)})"}
    end
  end

  defp url(:anthropic), do: @anthropic_url
  defp url(:openai_codex), do: @codex_url

  defp headers(:anthropic, auth) do
    [
      {"authorization", "Bearer #{auth.token}"},
      {"anthropic-beta", "oauth-2025-04-20"},
      {"content-type", "application/json"},
      {"user-agent", @claude_user_agent}
    ]
  end

  defp headers(:openai_codex, auth) do
    [{"authorization", "Bearer #{auth.token}"}, {"user-agent", "rho"}] ++
      if(auth[:account_id], do: [{"chatgpt-account-id", auth.account_id}], else: [])
  end

  # The provider's own error message, bounded.
  defp error_text(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => m}}} when is_binary(m) -> ": " <> String.slice(m, 0, 200)
      {:ok, %{"error" => m}} when is_binary(m) -> ": " <> String.slice(m, 0, 200)
      {:ok, %{"detail" => m}} when is_binary(m) -> ": " <> String.slice(m, 0, 200)
      _ -> ""
    end
  end

  defp error_text(_body), do: ""
end
