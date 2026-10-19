defmodule Rho.Images do
  @moduledoc """
  Pictures drawn on the user's ChatGPT sign-in (`:openai_codex`, ChatGPT
  Plus/Pro), as Codex draws them: the Responses API at
  `https://chatgpt.com/backend-api/codex/responses` with OpenAI's hosted
  `image_generation` tool (gpt-image), forced with `tool_choice`, the
  picture coming back base64 in the stream's `image_generation_call` item.
  The drawing counts against the subscription's Codex limits; there is no
  API key and no per-picture bill.

  This is a focused Req call, not req_llm: req_llm's `openai_codex`
  provider (1.26 to 1.28) drops a finished `image_generation_call` item,
  so the picture never reaches the response, and for the gpt-5.6 models it
  sends Codex's "responses lite" contract, which strips hosted tools such
  as `image_generation` from the request. An API-key image model
  (gpt-image on `:openai`, Gemini on `:google`) is req_llm's
  `ReqLLM.generate_image/3`.

  A text model drives the tool (it reads the prompt and the reference
  pictures and writes the tool's prompt, returned as `revised_prompt`):
  `:model` (default #{inspect("gpt-5.6-luna")}, the fastest of Codex's
  models that drew in testing, 2026-10-18; gpt-5.6-sol, gpt-6-luna,
  gpt-6-astra and gpt-6.1-sol drew too). The ChatGPT account accepts only
  the models Codex lists for it (`models/1`, Codex's own
  `GET /backend-api/codex/models`); gpt-5.5 and gpt-image-2 are refused
  with a 400 ("not supported when using Codex with a ChatGPT account").
  When the account refuses the model, `generate/2` asks that list once and
  draws with the first model it lists: Codex's own default, the one Codex
  draws with.

  Every call that reached (or may have reached) the provider is recorded
  with `Rho.Usage` as a call to `"openai_codex:<model>"`: its tokens, the
  subscription windows its headers report, a 429's reset, and a dropped
  connection or a timeout as an error. Errors are `t:Rho.LLM.error/0`,
  so `Rho.LLM.describe/1` says them: `{:signed_out, :openai_codex}`, a
  dead sign-in (`{:auth, …}`), `{:rate_limited, limit}` with the window
  and when it resets, `{:http, status, message}`, `{:transport, reason}`,
  `{:other, message}` (no picture: a refusal, the model's own words).
  The access token goes only into the request's `authorization` header.

  The stream is read as it arrives, keeping only the picture, the usage
  and the first error; one event is held whole (a picture's base64, a few
  MB) up to 48 MB. The whole drawing is bounded by `:timeout` (4 minutes);
  it takes 20–60 s, in a task of the caller's: call it from a tool's task,
  never from a loop's process.
  """

  alias Rho.Auth
  alias Rho.LLM.ReqLLM, as: Adapter
  alias Rho.Usage

  @base_url "https://chatgpt.com/backend-api/codex"
  @default_model "gpt-5.6-luna"
  # The Codex CLI version whose model list `models/1` asks for (the
  # current release on 2026-10-18): the endpoint lists the models a client
  # of that version may use, so it needs one (an old one gets fewer models,
  # a very old one none). `:client_version` overrides it.
  @client_version "0.160.1"
  @originator "codex_cli_rs"
  @formats %{"png" => "image/png", "jpeg" => "image/jpeg", "webp" => "image/webp"}
  @instructions """
  Draw the picture the user describes with the image_generation tool. When \
  the user gives a picture, draw from it: change it as asked, or keep its look.\
  """
  # The whole drawing, stream included (a picture renders silently for
  # 20–60 s).
  @timeout 240_000
  # One server-sent event held whole: a picture's base64 is a few MB.
  @max_event 48 * 1024 * 1024
  @max_error_body 64 * 1024
  @max_text 2_000

  @type picture :: %{
          mime: String.t(),
          bytes: binary(),
          revised_prompt: String.t() | nil,
          size: String.t() | nil,
          action: String.t() | nil,
          model: String.t(),
          usage: map() | nil
        }

  @doc """
  Draws `prompt` on the ChatGPT sign-in: `{:ok, picture}` with the image's
  `mime` and `bytes`, the tool's `revised_prompt`, the `size` it drew at
  (`"1536x1024"`), its `action` (`"generate"`, or `"edit"` when it drew
  from a reference) and the driving `model`, or `{:error, t:Rho.LLM.error/0}`.

  Options:

    * `:references`: pictures to draw from, `[{mime, bytes}]`
    * `:size`: `"1024x1024"`, `"1536x1024"`, `"1024x1536"` or `"auto"`
      (the tool's default); an edit may keep its reference's shape instead
    * `:quality`: `"low"`, `"medium"`, `"high"` or `"auto"` (the default)
    * `:format`: `"png"` (the default), `"jpeg"` or `"webp"`
    * `:model`: the Codex model that drives the tool (see the moduledoc)
    * `:timeout`: the whole drawing, in ms (default #{@timeout})
    * tests: `:credential` (as `Rho.Auth.credential/1`), `:respond` (the
      fake `Req.Response` for each `Req.Request`), `:base_url`, `:data_dir`
      (where usage is recorded, default `Rho.Config.data_dir/0`), `:now`,
      `:client_version` (`models/1`'s)
  """
  @spec generate(String.t(), keyword()) :: {:ok, picture()} | {:error, Rho.LLM.error()}
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    credential = Keyword.get(opts, :credential, &Auth.credential/1)

    with {:ok, auth} <- Adapter.credential(:openai_codex, credential) do
      model = Keyword.get(opts, :model, @default_model)

      case draw(model, prompt, auth, opts) do
        {:error, {:refused_model, message}} -> fallback(model, message, prompt, auth, opts)
        result -> result
      end
    end
  end

  @doc """
  The model ids the ChatGPT account may use with Codex, in Codex's order
  (its picker's, by priority: the first is Codex's default), hidden ones
  left out: Codex's `GET /backend-api/codex/models`, asked as Codex CLI
  #{@client_version} (`:client_version`). Takes `generate/2`'s
  `:credential`, `:respond` and `:base_url`.
  """
  @spec models(keyword()) :: {:ok, [String.t()]} | {:error, Rho.LLM.error()}
  def models(opts \\ []) do
    credential = Keyword.get(opts, :credential, &Auth.credential/1)

    with {:ok, auth} <- Adapter.credential(:openai_codex, credential) do
      req =
        request(opts,
          method: :get,
          url: "/models",
          params: [client_version: Keyword.get(opts, :client_version, @client_version)],
          headers: headers(auth, "application/json"),
          receive_timeout: 15_000
        )

      case Req.request(req) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          listed(body)

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http, status, error_text(body)}}

        {:error, e} ->
          {:error, Adapter.normalize(e)}
      end
    end
  end

  defp listed(body) do
    case Jason.decode(body) do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok,
         for(
           %{"slug" => slug} = m <- Enum.sort_by(models, &(&1["priority"] || 1_000)),
           is_binary(slug) and m["visibility"] != "hide",
           do: slug
         )}

      _ ->
        {:error, {:other, "Codex's model list wasn't JSON with models"}}
    end
  end

  # The account refused `model`: draw once with the model Codex itself
  # uses by default (the first it lists), which is what draws in Codex.
  defp fallback(model, message, prompt, auth, opts) do
    case models(opts) do
      {:ok, [^model | _]} -> {:error, {:http, 400, message}}
      {:ok, [first | _]} -> first |> draw(prompt, auth, opts) |> refused_as_http()
      _ -> {:error, {:http, 400, message}}
    end
  end

  defp refused_as_http({:error, {:refused_model, message}}), do: {:error, {:http, 400, message}}
  defp refused_as_http(result), do: result

  defp draw(model, prompt, auth, opts) do
    format = opts |> Keyword.get(:format, "png") |> to_string()
    spec = "openai_codex:" <> model
    timeout = Keyword.get(opts, :timeout, @timeout)

    req =
      request(opts,
        method: :post,
        url: "/responses",
        headers: headers(auth, "text/event-stream"),
        json: body(model, prompt, format, opts),
        receive_timeout: timeout,
        into: &collect/2
      )

    case within(timeout, fn -> Req.request(req) end) do
      {:ok, %Req.Response{status: 200} = resp} ->
        stream_result(model, resp, opts)

      {:ok, %Req.Response{status: status, headers: headers} = resp} ->
        failed(spec, status, headers, raw_body(resp), opts)

      {:error, e} ->
        error = Adapter.normalize(e)
        record(spec, %{status: nil, headers: [], error: Rho.LLM.describe(error)}, opts)
        {:error, error}
    end
  end

  # The whole drawing within `timeout` (a stream that keeps sending can't
  # hold it longer): a timeout is the connection's, `{:transport, :timeout}`.
  defp within(timeout, fun) do
    task =
      Task.async(fn ->
        try do
          fun.()
        catch
          kind, reason -> {:error, {:other, Exception.format_banner(kind, reason)}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timeout -> {:error, :timeout}
    end
  end

  defp body(model, prompt, format, opts) do
    tool =
      %{
        "type" => "image_generation",
        "size" => opts[:size],
        "quality" => opts[:quality],
        "output_format" => format
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    pictures =
      for {mime, bytes} <- Keyword.get(opts, :references, []) do
        %{"type" => "input_image", "image_url" => "data:#{mime};base64,#{Base.encode64(bytes)}"}
      end

    %{
      "model" => model,
      "instructions" => @instructions,
      "input" => [
        %{
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => prompt} | pictures]
        }
      ],
      "tools" => [tool],
      "tool_choice" => %{"type" => "image_generation"},
      "store" => false,
      "stream" => true
    }
  end

  defp request(opts, req_opts) do
    req =
      Req.new(
        [
          base_url: Keyword.get(opts, :base_url, @base_url),
          retry: false,
          decode_body: false,
          connect_options: [timeout: 15_000]
        ] ++ req_opts
      )

    case opts[:respond] do
      nil -> req
      respond -> Req.Request.append_request_steps(req, respond: &{&1, respond.(&1)})
    end
  end

  defp headers(auth, accept) do
    [
      {"authorization", "Bearer #{auth.token}"},
      {"originator", @originator},
      {"accept", accept}
    ] ++ if(auth[:account_id], do: [{"chatgpt-account-id", auth.account_id}], else: [])
  end

  # ── the stream ──
  #
  # Read as it arrives (`collect/2`, Req's `into:`), keeping only what the
  # result needs: the picture, the usage, the first error, the model's
  # words (bounded). One event is held whole until its blank line (a
  # picture's base64, a few MB), and no more than @max_event.

  defp new_state,
    do: %{
      pending: [],
      pending_size: 0,
      last: "",
      picture: nil,
      usage: nil,
      error: nil,
      text: "",
      raw: "",
      halt: false
    }

  defp collect({:data, data}, {req, resp}) do
    state = Req.Response.get_private(resp, :codex_sse) || new_state()
    state = if resp.status == 200, do: feed(state, data), else: keep_raw(state, data)
    resp = Req.Response.put_private(resp, :codex_sse, state)
    {if(state.halt, do: :halt, else: :cont), {req, resp}}
  end

  # A failure's body, for its message: the start of it.
  defp keep_raw(state, data) do
    room = @max_error_body - byte_size(state.raw)

    if room > 0,
      do: %{state | raw: state.raw <> binary_part(data, 0, min(room, byte_size(data)))},
      else: state
  end

  defp raw_body(resp) do
    case Req.Response.get_private(resp, :codex_sse) do
      %{raw: raw} -> raw
      nil -> resp.body
    end
  end

  # Events end at a blank line, which may straddle two chunks (`last` is
  # the previous chunk's last byte).
  defp feed(%{halt: true} = state, _data), do: state
  defp feed(state, ""), do: state

  defp feed(state, data) do
    lead = byte_size(state.last)

    case :binary.match(state.last <> data, "\n\n") do
      {at, 2} ->
        cut = at - lead
        head = if cut > 0, do: binary_part(data, 0, cut), else: ""
        rest = binary_part(data, cut + 2, byte_size(data) - cut - 2)
        block = IO.iodata_to_binary([state.pending, head])
        state = event(%{state | pending: [], pending_size: 0, last: ""}, block)
        feed(state, rest)

      :nomatch ->
        size = state.pending_size + byte_size(data)

        if size > @max_event do
          %{state | pending: [], pending_size: 0, halt: true, error: too_large()}
        else
          %{
            state
            | pending: [state.pending, data],
              pending_size: size,
              last: binary_part(data, byte_size(data) - 1, 1)
          }
        end
    end
  end

  defp too_large,
    do: "the drawing's stream sent an event over #{div(@max_event, 1024 * 1024)} MB"

  defp event(state, block) do
    data =
      for line <- String.split(block, "\n"),
          "data:" <> data <- [String.trim_trailing(line, "\r")],
          do: String.trim(data)

    case Jason.decode(Enum.join(data, "\n")) do
      {:ok, %{} = event} -> apply_event(state, event)
      _ -> state
    end
  end

  defp apply_event(state, %{"type" => "response.output_item.done", "item" => item}) do
    case {state.picture, picture(item)} do
      {nil, %{} = picture} -> %{state | picture: picture}
      _ -> state
    end
  end

  defp apply_event(state, %{"type" => "response.output_text.delta", "delta" => delta})
       when is_binary(delta) do
    if byte_size(state.text) < @max_text, do: %{state | text: state.text <> delta}, else: state
  end

  defp apply_event(state, %{"type" => "response.completed", "response" => %{"usage" => %{} = u}}),
    do: %{state | usage: u}

  defp apply_event(state, event) do
    case {state.error, stream_error(event)} do
      {nil, error} when is_binary(error) -> %{state | error: error}
      _ -> state
    end
  end

  defp stream_result(model, resp, opts) do
    spec = "openai_codex:" <> model

    state =
      case Req.Response.get_private(resp, :codex_sse) do
        nil -> feed(new_state(), to_string(resp.body))
        state -> state
      end

    # What's left without a closing blank line is the last event.
    state = event(state, IO.iodata_to_binary(state.pending))

    # A picture is a call that worked, even if the stream ended before
    # `response.completed` (no usage then).
    usage = usage(state.usage) || (state.picture && usage(%{}))
    error = if state.picture, do: nil, else: state.error
    record(spec, %{status: 200, headers: resp.headers, usage: usage, error: error}, opts)

    case state do
      %{picture: %{} = picture} -> {:ok, Map.merge(picture, %{model: model, usage: state.usage})}
      %{error: error} when is_binary(error) -> {:error, {:other, error}}
      %{text: text} -> {:error, {:other, no_picture(text)}}
    end
  end

  defp picture(%{"type" => "image_generation_call", "result" => result} = item)
       when is_binary(result) and result != "" do
    case Base.decode64(result) do
      {:ok, bytes} ->
        %{
          mime: Map.get(@formats, item["output_format"], "image/png"),
          bytes: bytes,
          revised_prompt: item["revised_prompt"],
          size: item["size"],
          action: item["action"]
        }

      :error ->
        nil
    end
  end

  defp picture(_item), do: nil

  defp stream_error(%{"type" => "error"} = event), do: message(event) || "the drawing failed"

  defp stream_error(%{"type" => type, "response" => response})
       when type in ["response.failed", "response.incomplete"] do
    message(response["error"]) || reason(response["incomplete_details"]) ||
      "the drawing failed (#{type})"
  end

  defp stream_error(_event), do: nil

  defp message(%{"message" => m}) when is_binary(m), do: String.slice(m, 0, 300)
  defp message(%{"error" => %{} = e}), do: message(e)
  defp message(_), do: nil

  defp reason(%{"reason" => r}) when is_binary(r), do: "the drawing stopped: #{r}"
  defp reason(_), do: nil

  # No picture and no error: what the model said instead (a refusal).
  defp no_picture(text) do
    case String.trim(text) do
      "" -> "the model answered without a picture"
      text -> "the model answered without a picture: " <> String.slice(text, 0, 300)
    end
  end

  # Req LLM's usage keys, as `Rho.Session.usage/1` reads them.
  defp usage(%{} = u) do
    %{
      input_tokens: u["input_tokens"] || 0,
      output_tokens: u["output_tokens"] || 0,
      cached_tokens: get_in(u, ["input_tokens_details", "cached_tokens"]) || 0
    }
  end

  defp usage(nil), do: nil

  # ── failures ──

  defp failed(spec, status, headers, body, opts) do
    json =
      case Jason.decode(to_string(body)) do
        {:ok, %{} = json} -> json
        _ -> nil
      end

    message = error_text(body)
    record(spec, %{status: status, headers: headers, body: json, error: message}, opts)

    cond do
      status == 400 and refused_model?(message) ->
        {:error, {:refused_model, message}}

      status == 429 ->
        dir = Keyword.get_lazy(opts, :data_dir, &Rho.Config.data_dir/0)
        now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)
        {:error, Adapter.limit({:http, 429, message}, spec, headers, json, Usage.load(dir), now)}

      true ->
        {:error, {:http, status, message}}
    end
  end

  defp refused_model?(message),
    do: String.contains?(message, "not supported when using Codex with a ChatGPT account")

  # The provider's own message, bounded; the status alone when it has none.
  defp error_text(body) do
    case Jason.decode(to_string(body)) do
      {:ok, %{"error" => %{"message" => m}}} when is_binary(m) -> String.slice(m, 0, 300)
      {:ok, %{"error" => m}} when is_binary(m) -> String.slice(m, 0, 300)
      {:ok, %{"detail" => m}} when is_binary(m) -> String.slice(m, 0, 300)
      _ -> "no message"
    end
  end

  defp record(spec, call, opts) do
    case opts[:data_dir] do
      nil -> Adapter.record(spec, call)
      dir -> Usage.record(dir, spec, call)
    end
  end
end
