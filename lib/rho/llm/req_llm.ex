defmodule Rho.LLM.ReqLLM do
  @moduledoc """
  The model calls through req_llm's providers, streamed, with the
  provider's credential from `Rho.Auth` (fetched, and for a subscription
  refreshed when due, per call):

    * `anthropic:` signed in to a subscription (Claude Pro/Max) →
      `auth_mode: :oauth`, `access_token`, `with_claude_subscription: true`
      (Claude Code's betas and identity); with an API key → `api_key`.
      Either way prompt caching (`anthropic_prompt_cache: true`,
      `anthropic_cache_messages: -1`): req_llm puts a `cache_control`
      breakpoint on the last tool, the system prompt and the last message,
      so each call reads the previous one's prefix from the cache instead
      of paying (and spending rate limit on) the whole prompt again
    * `openai_codex:` (ChatGPT Plus/Pro) → `auth_mode: :oauth`,
      `access_token`, `chatgpt_account_id`, and the session id as
      `session_id` (the prompt cache key)
    * `openai:` (an API key) → `api_key`, and the session id as
      `prompt_cache_key`
    * `google:` (a Gemini API key) → `api_key`, sent in the
      `x-goog-api-key` header (`google_auth_header: true`) rather than the
      URL, so it stays out of logged URLs

  A provider without a credential fails with `{:signed_out, provider}`;
  any other model prefix with `{:other, _}`. `max_tokens` is always
  explicit (req_llm's default is the model's whole output limit).

  Pictures the model makes come back as the reply's `:images`: the
  `:image` content parts (bytes and `media_type`) of the response's
  message. That message already holds the streamed `:content_part`
  chunks (req_llm's response builder materializes them; preview frames,
  `stream_only?`, it leaves out), so each picture counts once. An
  `:image_url` part (a link, not bytes) is skipped: rho doesn't fetch it.

  Every call that reached the provider is recorded with
  `Rho.Usage.record/3`: its tokens and cost, the subscription
  windows its response headers report, and a 429's reset, under the
  request's `:data_dir` (the loop's or consult's), else
  `Rho.Config.data_dir/0`.

  Options (the loop's `llm: {Rho.LLM.ReqLLM, opts}`):

    * `:credential`: `fn provider -> … end` answering as
      `Rho.Auth.credential/1` does (the default); a host serving several
      accounts passes its account's (`Rho.Auth.Vault.credential/2`)
    * `:status`: `fn -> status end` answering as `Rho.Auth.status/0` does
      (the default), for what reads who is signed in on the loop's behalf
      (`Rho.LLM.status/1`: the fallback check, `ask_model`)

  The cost is req_llm's, from the reply's usage and llm_db's prices.
  req_llm prices a reply only when every conditional tariff of the model
  is settled by the caller's `:pricing_context` (else `usage.pricing` is
  `%{status: :unknown}`, no cost, and rho counts $0: llm_db's Claude
  prices carry such conditions), so each call passes what rho's
  requests are: never batched, never fast mode or a priority / flex
  tier, no US-only inference or regional processing, Anthropic's default
  5-minute cache, Gemini's implicit cache. A subscription call is priced
  the same, at what it would cost on an API key: notional, for the usage
  screens and the daily cap (`Rho.Budget`).

  A 429 (or a 529 overloaded) comes back as `{:rate_limited, limit}`
  (`t:Rho.LLM.limit/0`): its `retry-after`, and when
  a usage window is used up, which one and until when: from the response's
  headers, a Codex usage-limit body, else the windows
  `Rho.Usage` recorded from earlier calls (an Anthropic 5-hour
  window at 100 % answers with the same message as a short throttle).
  """
  @behaviour Rho.LLM

  require Logger

  alias ReqLLM.StreamResponse
  alias Rho.Auth
  alias Rho.Usage

  @impl true
  def stream(request, opts, sink) do
    case options(request, credential_fun(opts)) do
      {:ok, call_opts} -> run(request, call_opts, sink)
      {:error, _normalized} = error -> error
    end
  end

  defp credential_fun(opts) when is_list(opts),
    do: Keyword.get(opts, :credential, &Auth.credential/1)

  defp credential_fun(_opts), do: &Auth.credential/1

  defp run(request, opts, sink) do
    context =
      ReqLLM.Context.new([ReqLLM.Context.system(request.system_prompt) | request.messages])

    case ReqLLM.stream_text(request.model, context, opts) do
      {:ok, stream} ->
        # Asked before the stream is read, answered with the rest of its
        # metadata: the response's status and headers (the usage windows).
        meta = :gen_server.send_request(stream.metadata_handle, :await)

        result =
          StreamResponse.process_stream(stream,
            on_result: &sink.({:text, &1}),
            on_thinking: &sink.({:thinking, &1})
          )

        finish(request, result, metadata(meta))

      {:error, _reason} = error ->
        finish(request, error, %{})
    end
  end

  defp finish(request, {:ok, response}, meta) do
    record(
      request.model,
      %{
        status: meta[:status],
        headers: meta[:headers] || [],
        usage: response.usage
      },
      dir(request)
    )

    {:ok, reply(response)}
  end

  defp finish(request, {:error, reason}, meta) do
    model = request.model
    error = normalize(reason)
    {status, headers, body} = http_failure(reason, meta)
    message = with {:http, _status, message} <- error, do: message
    message = if is_binary(message), do: message, else: nil
    call = %{status: status, headers: headers, body: body, error: message || "failed"}
    record(model, call, dir(request))
    # Read before this call's record lands: the earlier calls' windows.
    state = if match?({:http, 429, _}, error), do: Usage.load(dir(request)), else: %{}

    {:error, limit(error, model, headers, body, state, System.os_time(:second))}
  end

  defp dir(request), do: request[:data_dir] || Rho.Config.data_dir()

  @doc false
  # A 429 / 529 as `{:rate_limited, limit}` (see the moduledoc); `state` is
  # Rho.Usage's, `now` unix seconds. Other errors are returned as
  # they are.
  @spec limit(Rho.LLM.error(), String.t(), term(), term(), map(), integer()) ::
          Rho.LLM.error()
  def limit({:http, status, message}, model, headers, body, state, now)
      when status in [429, 529] do
    h = header_map(headers)

    provider =
      case Auth.provider_for_model(model) do
        {:ok, provider} -> provider
        :error -> nil
      end

    used_up = if status == 429 and provider, do: used_up(provider, h, body, state, now)

    {:rate_limited,
     %{
       status: status,
       message: message,
       provider: provider,
       retry_after_ms: retry_after_ms(h, now),
       resets_at: used_up && used_up.resets_at,
       window: used_up && used_up.window
     }}
  end

  def limit(error, _model, _headers, _body, _state, _now), do: error

  # A window this response reports at 100 %, else a Codex usage-limit body,
  # else a window the earlier calls left at 100 % (or a recorded 429 more
  # than a minute from lifting: a shorter one is a throttle).
  defp used_up(provider, h, body, state, now) do
    full =
      for {_id, %{"used" => used, "resets_at" => at} = w} <- Usage.from_headers(provider, h),
          used >= 100 and is_integer(at) and at > now,
          do: %{window: w["label"], resets_at: at}

    cond do
      full != [] ->
        Enum.max_by(full, & &1.resets_at)

      at = codex_reset(body, now) ->
        %{window: nil, resets_at: at}

      true ->
        case Usage.exhausted(state, provider, now) do
          %{window: nil, resets_at: at} when at <= now + 60 -> nil
          other -> other
        end
    end
  end

  defp codex_reset(%{"error" => %{} = error}, now), do: codex_reset(error, now)

  defp codex_reset(%{} = error, now) do
    cond do
      is_integer(error["resets_at"]) and error["resets_at"] > now -> error["resets_at"]
      is_integer(error["resets_in_seconds"]) -> now + error["resets_in_seconds"]
      true -> nil
    end
  end

  defp codex_reset(_body, _now), do: nil

  # `retry-after-ms`, else `retry-after` in seconds or as an HTTP date.
  defp retry_after_ms(h, now) do
    case number(h["retry-after-ms"]) || retry_after(h["retry-after"], now) do
      nil -> nil
      ms -> max(round(ms), 0)
    end
  end

  defp retry_after(nil, _now), do: nil

  defp retry_after(value, now) do
    case number(value) do
      nil -> http_date_ms(value, now)
      seconds -> seconds * 1000
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # "Fri, 09 Oct 2026 06:26:09 GMT"
  defp http_date_ms(text, now) do
    with [_, d, mon, y, hh, mm, ss] <-
           Regex.run(~r/(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})/, text),
         month when month != nil <- Enum.find_index(@months, &(&1 == mon)),
         [d, y, hh, mm, ss] = Enum.map([d, y, hh, mm, ss], &String.to_integer/1),
         {:ok, at} <- NaiveDateTime.new(y, month + 1, d, hh, mm, ss) do
      (at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()) * 1000 - now * 1000
    else
      _ -> nil
    end
  end

  defp number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp number(_value), do: nil

  defp header_map(%{} = headers), do: header_map(Map.to_list(headers))

  defp header_map(headers) when is_list(headers) do
    Map.new(headers, fn
      {k, [v | _]} -> {String.downcase(to_string(k)), to_string(v)}
      {k, v} -> {String.downcase(to_string(k)), to_string(v)}
    end)
  end

  defp header_map(_headers), do: %{}

  # The metadata the stream's handle sent; `%{}` if it stopped without.
  defp metadata(request_id) do
    case :gen_server.receive_response(request_id, 1_000) do
      {:reply, {:ok, %{} = meta}} -> meta
      _ -> %{}
    end
  end

  # A failed response's status, headers and decoded body (a 429's reset).
  defp http_failure(%ReqLLM.Error.API.Stream{cause: cause}, meta) when cause != nil,
    do: http_failure(cause, meta)

  defp http_failure(%ReqLLM.Error.API.Request{status: status} = e, meta) when is_integer(status),
    do: {status, e.headers || meta[:headers] || [], e.response_body}

  defp http_failure(_reason, meta), do: {meta[:status], meta[:headers] || [], nil}

  @doc false
  # Records `call` to `model` in `dir` beside the caller (it may wait on the
  # store's lock) and never fails it; the screens hear of it from
  # `Usage.subscribe/0`. `Rho.Images` records its calls through here too.
  @spec record(String.t(), Usage.call(), Path.t()) :: :ok
  def record(model, call, dir \\ Rho.Config.data_dir()) do
    {:ok, _} = Task.start(fn -> record_in(dir, model, call) end)
    :ok
  end

  defp record_in(dir, model, call) do
    Usage.record(dir, model, call)
  rescue
    e -> Logger.warning("[usage] couldn't record a model call: #{Exception.message(e)}")
  end

  @doc false
  # req_llm's options for `request`: max_tokens, tools and the provider's
  # credential from `credential` (`Rho.Auth.credential/1`).
  @spec options(Rho.LLM.request(), (Auth.provider() -> term())) ::
          {:ok, keyword()} | {:error, Rho.LLM.error()}
  def options(request, credential) do
    # max_retries: 0: the loop retries (with its own bounded backoff). req_llm's
    # stream retry sleeps for a 429's retry-after, which on a subscription
    # limit is days: the call then died as a bare `:timeout` instead of the 429.
    base =
      [max_tokens: request.max_tokens, max_retries: 0] ++
        if(request.tools == [], do: [], else: [tools: request.tools])

    with {:ok, provider} <- provider(request.model),
         {:ok, auth} <- credential(provider, credential) do
      {:ok,
       base ++
         auth_options(provider, auth, request) ++
         [pricing_context: pricing_context(provider)]}
    end
  end

  # The billing facts of rho's requests (see the moduledoc), for llm_db's
  # conditional components: Claude's `pricing.batch` (api "batch"),
  # `pricing.fast` (request_body speed "fast"), `pricing.data_residency`
  # (inference_geo "us") and the cache write's TTL ("5m" / "1h"; a reply
  # that reports its writes per TTL is priced by those); OpenAI's and
  # Gemini's batch, `service_tier` (flex, priority, fast) and regional
  # processing, Gemini's explicit-cache storage. Settling them is what
  # makes req_llm price a reply at all. Since 1.28 req_llm takes an
  # `openai:` call's api, region and returned tier from the call itself
  # (over these); Anthropic's it doesn't:
  # https://github.com/agentjido/req_llm/issues/1121. A ChatGPT
  # subscription (`openai_codex:`) call has OpenAI's facts.
  defp pricing_context(:anthropic),
    do: %{
      api: "messages",
      inference_geo: "global",
      request_body: %{"speed" => "standard"},
      cache_ttl: "5m"
    }

  defp pricing_context(provider) when provider in [:openai, :openai_codex],
    do: %{api: "responses", service_tier: "default", regional_processing: false}

  defp pricing_context(:google),
    do: %{api: "generate_content", service_tier: "standard", cache_type: "implicit"}

  defp provider(model) do
    case Auth.provider_for_model(model) do
      {:ok, provider} ->
        {:ok, provider}

      :error ->
        {:error,
         {:other,
          "can't call #{model}: use an anthropic:…, openai_codex:…, openai:… or " <>
            "google:… model."}}
    end
  end

  @doc false
  # `credential`'s answer for `provider` (`Rho.Auth.credential/1`) as the
  # options need it, or the call's error.
  @spec credential(Auth.provider(), (Auth.provider() -> term())) ::
          {:ok, Auth.credential()} | {:error, Rho.LLM.error()}
  def credential(provider, credential) do
    case credential.(provider) do
      {:ok, %{type: type} = auth} when type in [:oauth, :api_key] ->
        {:ok, auth}

      {:error, :signed_out} ->
        {:error, {:signed_out, provider}}

      {:error, {:refresh_failed, message}} ->
        {:error, {:auth, provider, message}}

      {:error, {:store_failed, reason}} ->
        {:error,
         {:other,
          "the refreshed #{Auth.label(provider)} sign-in couldn't be saved " <>
            "(#{Auth.describe_error(reason)}); it is retried, try again in a moment."}}
    end
  end

  @anthropic_cache [anthropic_prompt_cache: true, anthropic_cache_messages: -1]

  defp auth_options(:anthropic, %{type: :oauth} = auth, _request) do
    [
      provider_options:
        [auth_mode: :oauth, access_token: auth.token, with_claude_subscription: true] ++
          @anthropic_cache
    ]
  end

  defp auth_options(:anthropic, %{type: :api_key, key: key}, _request),
    do: [api_key: key, provider_options: @anthropic_cache]

  defp auth_options(:openai_codex, %{type: :oauth} = auth, request) do
    [
      provider_options:
        [
          auth_mode: :oauth,
          access_token: auth.token,
          chatgpt_account_id: auth.account_id,
          session_id: request[:session_id]
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    ]
  end

  defp auth_options(:openai, %{type: :api_key, key: key}, request) do
    cache = if request[:session_id], do: [prompt_cache_key: request.session_id], else: []
    [api_key: key, provider_options: cache]
  end

  defp auth_options(:google, %{type: :api_key, key: key}, _request),
    do: [api_key: key, provider_options: [google_auth_header: true]]

  @doc false
  # The `Rho.LLM` reply for a finished response.
  @spec reply(ReqLLM.Response.t()) :: Rho.LLM.reply()
  def reply(response) do
    message = response.message

    %{
      text: ReqLLM.Response.text(response) || "",
      thinking: ReqLLM.Response.thinking(response) || "",
      tool_calls:
        for call <- ReqLLM.Response.tool_calls(response) do
          %{
            "id" => call.id,
            "name" => call.function.name,
            "arguments" => decode_args(call.function.arguments)
          }
        end,
      images: images(message),
      usage: response.usage,
      finish_reason: response.finish_reason || (message && :stop)
    }
  end

  defp images(%ReqLLM.Message{content: parts}) when is_list(parts) do
    for %ReqLLM.Message.ContentPart{type: :image, data: data, media_type: mime} <- parts,
        is_binary(data) and is_binary(mime),
        do: {mime, data}
  end

  defp images(_message), do: []

  defp decode_args(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = args} -> args
      _ -> %{"_raw" => json}
    end
  end

  defp decode_args(%{} = args), do: args
  defp decode_args(_), do: %{}

  @doc false
  @spec normalize(term()) :: Rho.LLM.error()
  def normalize(%ReqLLM.Error.API.Request{status: status} = e) when is_integer(status),
    do: {:http, status, to_string(e.reason)}

  def normalize(%ReqLLM.Error.API.Response{status: status} = e) when is_integer(status),
    do: {:http, status, to_string(e.reason)}

  # A failure mid-stream is raised as a Stream error wrapping the real one
  # (its message inspects the whole cause, response headers included).
  def normalize(%ReqLLM.Error.API.Stream{cause: cause}) when cause != nil, do: normalize(cause)

  def normalize(%{__struct__: mod, reason: reason})
      when mod in [Mint.TransportError, Req.TransportError, Finch.TransportError, Finch.Error],
      do: {:transport, reason}

  def normalize(%{__exception__: true} = e), do: {:other, Exception.message(e)}
  def normalize({:http_task_failed, reason}), do: normalize(reason)
  # A stream that stalls past req_llm's receive timeout ends as a bare
  # `:timeout`: the connection, not the request, so the loop retries it.
  def normalize(:timeout), do: {:transport, :timeout}
  def normalize({:timeout, _} = reason), do: {:transport, reason}
  def normalize(other), do: {:other, inspect(other, limit: 20, printable_limit: 500)}
end
