defmodule Rho.LLM do
  @moduledoc """
  The model client the loop talks to. `Rho.LLM.ReqLLM` is the real
  one (Anthropic, OpenAI, OpenAI Codex and Google through req_llm, with
  the credential from `Rho.Auth`); tests inject a scripted fake.

  `stream/3` runs in a process the loop owns (and kills on Stop). It calls
  `sink` for every streamed delta and returns the whole reply:

    * events: `{:text, delta}`, `{:thinking, delta}`
    * `{:ok, %{text:, thinking:, tool_calls: [%{"id", "name", "arguments"}],
       usage: map | nil, finish_reason: atom}}`, and optionally `images:
       [{mime_type, bytes}]`, pictures the model made (`Rho.Session.assistant/2`
       keeps them in the session; they aren't sent back to the model)
    * `{:error, error}` where `error` is normalized: `{:http, status, message}`,
      `{:rate_limited, limit}` (a 429, or a 529 overloaded, with what the
      response and `Rho.Usage` say about when it lifts: see
      `t:limit/0`), `{:transport, reason}`, `{:signed_out, provider}` (no
      credential for the model's provider), `{:auth, provider, message}` (its
      token couldn't be refreshed) or `{:other, message}`

  `describe/1`'s remedies say where the user signs in or switches model
  as the host words it (`Rho.Config.hint/1`).

  Two kinds of 429 need telling apart (`Rho.Loop` does): a
  short throttle ("would exceed your account's rate limit"), worth waiting
  out, and a subscription window used up for hours (a window at 100 %, a
  Codex "usage limit has been reached"), where waiting is pointless: the
  limit's `resets_at` says which.
  """

  alias Rho.Auth
  alias Rho.Usage

  @type request :: %{
          required(:model) => String.t(),
          required(:system_prompt) => String.t(),
          required(:messages) => [ReqLLM.Message.t()],
          required(:tools) => [ReqLLM.Tool.t()],
          required(:max_tokens) => pos_integer(),
          optional(:session_id) => String.t()
        }
  @typedoc """
  A rate limit: `retry_after_ms` from the response's `retry-after(-ms)`,
  and `resets_at` (unix s) / `window` (its label, e.g. `"5 hours"`, or nil)
  when a usage window is used up; `provider` is nil when unknown.
  """
  @type limit :: %{
          status: integer(),
          message: String.t(),
          provider: Auth.provider() | nil,
          retry_after_ms: non_neg_integer() | nil,
          resets_at: integer() | nil,
          window: String.t() | nil
        }
  @type error ::
          {:http, integer(), String.t()}
          | {:rate_limited, limit()}
          | {:transport, term()}
          | {:signed_out, Rho.Auth.provider()}
          | {:auth, Rho.Auth.provider(), String.t()}
          | {:other, String.t()}
  @type reply :: %{
          required(:text) => String.t(),
          required(:thinking) => String.t(),
          required(:tool_calls) => [map()],
          required(:usage) => map() | nil,
          required(:finish_reason) => atom() | nil,
          optional(:images) => [{String.t(), binary()}]
        }

  @callback stream(request(), opts :: term(), sink :: (term() -> any())) ::
              {:ok, reply()} | {:error, error()}

  @doc "Worth retrying: rate limits, provider 5xx, dropped connections."
  @spec retryable?(error()) :: boolean()
  def retryable?({:rate_limited, _}), do: true
  def retryable?({:http, 429, _}), do: true
  def retryable?({:http, status, _}) when status >= 500, do: true
  def retryable?({:transport, _}), do: true
  def retryable?(_), do: false

  @doc """
  The rate limit an error is (a 429 or a 529 overloaded, with what is
  known about it), or nil for any other error.
  """
  @spec rate_limit(error()) :: limit() | nil
  def rate_limit({:rate_limited, limit}), do: limit

  def rate_limit({:http, status, message}) when status in [429, 529],
    do: %{
      status: status,
      message: message,
      provider: nil,
      retry_after_ms: nil,
      resets_at: nil,
      window: nil
    }

  def rate_limit(_error), do: nil

  @doc """
  Can `model` take over a run another model's limit stopped: its provider
  signed in, and none of its usage windows used up for more than a minute
  (`Rho.Usage`)? `:ok` or `{:error, why}`.
  """
  @spec usable(String.t(), Path.t(), integer()) :: :ok | {:error, String.t()}
  def usable(model, dir \\ Rho.Config.data_dir(), now \\ System.os_time(:second)) do
    with {:ok, provider} <- known(model),
         {:ok, _creds} <- signed_in(provider) do
      case Usage.exhausted(Usage.load(dir), provider, now) do
        %{resets_at: at} = limit when at > now + 60 -> {:error, used_up(provider, limit)}
        _ -> :ok
      end
    end
  end

  defp known(model) do
    case Auth.provider_for_model(model) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, "not an anthropic:…, openai_codex:…, openai:… or google:… model"}
    end
  end

  defp signed_in(provider) do
    case Auth.get(provider) do
      {:ok, creds} -> {:ok, creds}
      _ -> {:error, "#{Auth.label(provider)} isn't signed in"}
    end
  end

  @doc "What the user sees for a failed call, with the remedy where there is one."
  @spec describe(error()) :: String.t()
  def describe({:rate_limited, %{resets_at: at} = limit}) when is_integer(at) do
    if at > System.os_time(:second),
      do:
        used_up(limit.provider, limit) <>
          "; switch model #{hint(:switch_model)}, or prompt again then.",
      else: describe({:http, limit.status, limit.message})
  end

  def describe({:rate_limited, limit}), do: describe({:http, limit.status, limit.message})

  def describe({:http, 402, message}) do
    "402 (payment required): #{message}\n" <>
      "Check your plan's usage limits, or lower max_tokens for this model."
  end

  def describe({:http, 401, message}),
    do: "401 (sign-in rejected): #{message}\nSign in again #{hint(:sign_in)}."

  def describe({:http, 429, message}), do: "429 (rate limited): #{message}"
  def describe({:http, 529, message}), do: "529 (overloaded): #{message}"
  def describe({:http, status, message}), do: "Model call failed (HTTP #{status}): #{message}"

  def describe({:transport, reason}),
    do: "Network error talking to the model provider: #{inspect(reason)}"

  def describe({:signed_out, provider}),
    do: "Not signed in to #{Auth.label(provider)}: sign in #{hint(:sign_in)}."

  def describe({:auth, provider, message}) do
    "#{Auth.label(provider)} sign-in expired (#{message}): " <>
      "sign in again #{hint(:sign_in)}."
  end

  def describe({:other, message}), do: "Model call failed: #{message}"

  defp hint(key), do: Rho.Config.hint(key)

  # "Claude (Anthropic)'s 5 hours limit is used up until 05:10"
  defp used_up(provider, %{resets_at: at} = limit) do
    who = if provider, do: Auth.label(provider), else: "The model provider"
    what = if limit[:window], do: "#{limit.window} limit", else: "usage limit"
    "#{who}'s #{what} is used up until #{clock(at)}"
  end

  @doc """
  Unix time `at` on the device's clock: `HH:MM` today, `Mon D HH:MM` on
  another day. `now` (unix s) is for tests.
  """
  @spec clock(integer(), integer()) :: String.t()
  def clock(at, now \\ System.os_time(:second)) do
    {date, {h, mi, _s}} = :calendar.system_time_to_local_time(at, :second)
    {today, _} = :calendar.system_time_to_local_time(now, :second)
    time = :io_lib.format(~c"~2..0B:~2..0B", [h, mi]) |> to_string()

    if date == today do
      time
    else
      {_y, month, day} = date

      Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), month - 1) <>
        " #{day} " <> time
    end
  end
end
