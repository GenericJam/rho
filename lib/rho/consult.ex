defmodule Rho.Consult do
  @moduledoc """
  One model consulting another: `run/3` sends another model (a Gemini
  model, say, while Claude leads the session) a prompt, optionally with the
  session's conversation and attachments, lets it call a given set of
  tools, and returns its answer, `{:ok, %{text, model, purpose, usage}}`.
  The lead model gets one through the `ask_model` tool
  (`Rho.Tools.Consult`); a host runs one itself (a critique after every
  reply) and hands the answer to the lead as that model's message
  (`Rho.Loop.prompt/3` with `attribution: {:model, model, purpose}`).

  It runs in the caller's process (any process: a tool's task, a host's
  task) and blocks it; the model call itself runs in a worker the caller
  owns, which dies with the caller. The credential comes from `Rho.Auth`
  as for the loop's calls, so a provider without one fails with
  `{:error, {:signed_out, provider}}` (`describe/1` words it for the user).

  With `:loop` (the session's `Rho.Loop`) a consult is the session's:

    * its events go to the loop's subscribers (`consult_start`,
      `consult_delta`, `consult_end`, `Rho.Events`), so a screen can show
      it live;
    * its usage is recorded in the session (`Rho.Session.consult/1`,
      counted by `Rho.Session.totals/1`) and its cost against the loop's
      `:budget`, the daily cost cap checked before each of its calls;
    * `Rho.Loop.stop/1` (or the loop exiting) stops it: the model call and
      any tool it's running are killed and `run/3` returns
      `{:error, :stopped}`, whether or not the loop was running a turn;
    * `:include_conversation` sends the conversation so far (as a
      transcript, the tool calls still in flight left out; the newest part
      when it's too long for the consulted model);
    * the loop's `:llm`, `:budget`, `:data_dir`, `:task_supervisor` and
      `:before_tool_call` are the defaults of the options of those names.

  Which models may be consulted is the host's (`Rho.Config`'s
  `:consult_models`, checked by `allowed/1`; `run/3` itself doesn't
  check it, the host's own calls choose their model), and so is the
  system prompt per purpose (`:consult_system`).
  """

  alias ReqLLM.Context
  alias ReqLLM.ToolCall
  alias Rho.Artifacts
  alias Rho.Auth
  alias Rho.Budget
  alias Rho.Compaction
  alias Rho.LLM
  alias Rho.Models
  alias Rho.Session
  alias Rho.Tool
  alias Rho.ToolRunner

  @type result :: %{
          text: String.t(),
          model: String.t(),
          purpose: String.t(),
          usage: map()
        }
  @typedoc """
  Why a consult failed: the model call's error (`t:Rho.LLM.error/0`,
  `{:signed_out, provider}` when its provider has no credential),
  `:stopped` (the loop stopped or exited) or `{:cost_cap, spent, cap}`
  (today's spend reached the loop's daily cap).
  """
  @type error :: LLM.error() | :stopped | {:cost_cap, float(), float()}

  @options [
    purpose: "second_opinion",
    system: nil,
    loop: nil,
    include_conversation: false,
    attachments: [],
    tools: [],
    max_iterations: 4,
    max_tokens: 4096,
    llm: nil,
    budget: nil,
    data_dir: nil,
    task_supervisor: nil,
    before_tool_call: nil,
    call_id: nil
  ]

  # A tool result in the conversation sent along, cut to this.
  @transcript_tool_bytes 8_000

  @last_call "This is your last model call for this consult: don't call tools; " <>
               "answer with what you have."

  @doc """
  Consults `model` (a req_llm spec) with `prompt`. Options:

    * `:purpose`: `"critique"`, `"second_opinion"` (the default) or any
      text; it picks the default system prompt and labels the consult in
      events and the session
    * `:system`: the system prompt; default the host's for the purpose
      (`Rho.Config.consult_system/1`), else rho's
    * `:loop`: the session's `Rho.Loop` (see the moduledoc)
    * `:include_conversation`: send the loop's conversation too (default
      false; needs `:loop`)
    * `:attachments`: `t:Rho.Session.attachment/0`s sent with the prompt
      (by `:ref`, fetched through `:resolve_attachment`, or by `:path`);
      pictures and PDFs go as the consulted model takes them
    * `:tools`: tool modules the consulted model may call (default none),
      run one at a time through the `:before_tool_call` gate with each
      tool's timeout; `:max_iterations` model calls at most (default 4)
    * `:max_tokens`: per model call (default 4096)
    * `:llm` (`{module, opts}`), `:budget` (a data dir, or nil for no
      cap), `:data_dir`, `:task_supervisor`, `:before_tool_call`: default
      the loop's, else `{Rho.LLM.ReqLLM, []}`, no cap,
      `Rho.Config.data_dir/0`, `Rho.TaskSup`, allow all
    * `:call_id`: the tool call the consult answers (`ask_model` sets it),
      carried in its events and record

  `usage` is pi's usage map (`Rho.Session.usage/1`), summed over the
  consult's model calls. Raises `ArgumentError` for an unknown option, an
  attachment with neither `:path` nor `:ref`, or `:include_conversation`
  without `:loop`.
  """
  @spec run(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, error()}
  def run(model, prompt, opts \\ []) when is_binary(model) and is_binary(prompt) do
    opts = Keyword.validate!(opts, @options)
    :ok = Session.check_attachments!(opts[:attachments])

    if opts[:include_conversation] and opts[:loop] == nil,
      do: raise(ArgumentError, "include_conversation needs a :loop")

    info = %{
      id: id(),
      model: model,
      purpose: to_string(opts[:purpose]),
      call_id: opts[:call_id]
    }

    case join(opts[:loop], info, opts[:include_conversation]) do
      {:ok, joined} ->
        c = settle(info, opts, joined)
        {result, usage, calls} = consult(c, messages(c, prompt, opts, joined))
        result = with {:ok, answer} <- result, do: {:ok, %{answer | usage: usage}}
        leave(c, result, usage, calls)
        result

      {:error, _} = error ->
        error
    end
  end

  @doc "What the user sees for a failed consult."
  @spec describe(error()) :: String.t()
  def describe(:stopped), do: "The consult was stopped."

  def describe({:cost_cap, spent, cap}),
    do: "Daily cost cap reached: $#{dollars(spent)} of $#{dollars(cap)} spent today."

  def describe(error), do: LLM.describe(error)

  @doc """
  The models that may be consulted now: the host's `:consult_models`
  (`Rho.Config`), else every catalog model (`Rho.Models`), whose provider
  is signed in.
  """
  @spec models() :: [String.t()]
  def models do
    status = Auth.status()

    case Rho.Config.consult_models() do
      nil -> for {_provider, true, models} <- Models.by_provider(status), m <- models, do: m.spec
      allowed -> Enum.filter(allowed, &signed_in?(&1, status))
    end
  end

  @doc """
  Whether `model` may be consulted: on the host's `:consult_models` list
  (by default, in the catalog) and its provider signed in. `:ok`, or
  `{:error, why}` naming the models that may be.
  """
  @spec allowed(String.t()) :: :ok | {:error, String.t()}
  def allowed(model) when is_binary(model) do
    case Auth.provider_for_model(model) do
      {:ok, provider} ->
        cond do
          not listed?(model, provider) ->
            {:error, "#{model} isn't one of the models you may consult#{choices()}"}

          not Auth.signed_in?(provider) ->
            {:error,
             "#{Auth.label(provider)} isn't signed in, so #{model} can't be consulted#{choices()}"}

          true ->
            :ok
        end

      :error ->
        {:error, "#{model} isn't a model rho can call#{choices()}"}
    end
  end

  defp listed?(model, provider) do
    case Rho.Config.consult_models() do
      nil -> Enum.any?(Models.catalog(provider), &Models.same?(&1.spec, model))
      allowed -> Enum.any?(allowed, &Models.same?(&1, model))
    end
  end

  defp signed_in?(model, status) do
    case Auth.provider_for_model(model) do
      {:ok, provider} -> match?(%{signed_in: true}, status[provider])
      :error -> false
    end
  end

  defp choices do
    case models() do
      [] -> " (none is available: sign in to a provider #{Rho.Config.hint(:sign_in)})"
      models -> " (available: #{Enum.join(models, ", ")})"
    end
  end

  @doc "rho's system prompt for a consult with `purpose` (when the host sets none)."
  @spec default_system(String.t()) :: String.t()
  def default_system("critique") do
    "Another AI model asked you to review its work. Push back: find what is wrong, " <>
      "unsupported, missing, one-sided or overstated, most important first, as a concise " <>
      "numbered list, each point with its severity (high, medium or low) and why. Don't " <>
      "rewrite the work. If it holds up, say so briefly."
  end

  def default_system(purpose) do
    "Another AI model is consulting you (purpose: #{purpose}). Answer its request directly " <>
      "and concisely, with your own view where it differs; say where you are unsure."
  end

  # ── the session's loop ──

  defp join(nil, _info, _include), do: {:ok, nil}

  defp join(loop, info, include) do
    {:ok, joined} = GenServer.call(loop, {:consult_start, info, include})
    {:ok, Map.put(joined, :ref, Process.monitor(joined.loop))}
  catch
    :exit, _ -> {:error, :stopped}
  end

  defp settle(info, opts, joined) do
    loop_opts = if joined, do: joined.opts, else: %{}
    pick = fn key, default -> opts[key] || loop_opts[key] || default end

    Map.merge(info, %{
      loop: joined && joined.loop,
      loop_ref: joined && joined.ref,
      session_id: joined && joined.session.id,
      llm: pick.(:llm, {LLM.ReqLLM, []}),
      budget: pick.(:budget, nil),
      data_dir: pick.(:data_dir, nil) || Rho.Config.data_dir(),
      task_supervisor: pick.(:task_supervisor, Rho.TaskSup),
      gate: pick.(:before_tool_call, &ToolRunner.allow_all/2),
      system: system(opts[:system], info.purpose),
      tools: Map.new(opts[:tools], &{Tool.offered_name(&1), &1}) |> Map.delete(nil),
      max_iterations: max(opts[:max_iterations], 1),
      max_tokens: opts[:max_tokens]
    })
  end

  defp system(nil, purpose),
    do: Rho.Config.consult_system(purpose) || default_system(purpose)

  defp system(given, _purpose), do: given

  # Tells the loop how it ended, so it records the usage and tells its
  # subscribers; a stop that raced the end is dropped from the mailbox.
  defp leave(%{loop: nil}, _result, _usage, _calls), do: :ok

  defp leave(c, result, usage, calls) do
    {status, text, error} =
      case result do
        {:ok, %{text: text}} -> {:ok, text, nil}
        {:error, :stopped} -> {:stopped, "", nil}
        {:error, error} -> {:error, "", describe(error)}
      end

    ending = %{
      status: status,
      text: text,
      error: error,
      usage: usage,
      record: calls > 0
    }

    try do
      GenServer.call(c.loop, {:consult_end, c.id, ending})
    catch
      :exit, _ -> :ok
    end

    Process.demonitor(c.loop_ref, [:flush])
    loop = c.loop

    receive do
      {:rho_stop, ^loop} -> :ok
    after
      0 -> :ok
    end
  end

  # ── the request ──

  defp messages(c, prompt, opts, joined) do
    conversation =
      if opts[:include_conversation], do: conversation(joined.entries, c), else: ""

    text =
      if conversation == "",
        do: prompt,
        else:
          "The conversation so far, between the user and the assistant consulting you:\n\n" <>
            "<conversation>\n#{conversation}\n</conversation>\n\n" <> prompt

    Session.messages([Session.user(text, attachments: opts[:attachments])],
      inputs: Models.inputs(c.model),
      fetch: false
    )
  end

  # The newest part that fits half the consulted model's window.
  defp conversation(entries, c) do
    budget = max(div(Compaction.context_window(c.model), 2) - c.max_tokens, 1_024)

    entries
    |> without_calls_in_flight()
    |> Session.context(inputs: [:text], fetch: false)
    |> Compaction.transcript(budget, @transcript_tool_bytes)
  end

  # The lead's last reply, when its tool calls haven't been answered yet
  # (the consult is one of them), goes without them: none has a result.
  defp without_calls_in_flight(entries) do
    {later, earlier} =
      entries |> Enum.reverse() |> Enum.split_while(&(not match?(%{"type" => "message"}, &1)))

    case earlier do
      [%{"message" => %{"role" => "assistant", "content" => content} = m} = last | rest]
      when is_list(content) ->
        if Session.tool_calls(m) == [] do
          entries
        else
          parts = Enum.reject(content, &match?(%{"type" => "toolCall"}, &1))
          last = put_in(last, ["message", "content"], parts)
          Enum.reverse(rest, [last | Enum.reverse(later)])
        end

      _ ->
        entries
    end
  end

  # ── the calls ──

  # `{result, usage, model calls that came back}`.
  defp consult(c, messages), do: step(c, messages, 1, Session.usage(nil), 0)

  defp step(c, messages, n, usage, calls) do
    messages =
      if n == c.max_iterations and n > 1 and c.tools != %{},
        do: messages ++ [Context.user(@last_call)],
        else: messages

    with :ok <- check_budget(c),
         {:ok, reply} <- call(c, request(c, messages)) do
      reply_usage = Session.usage(reply[:usage])
      record_cost(c, reply_usage["cost"]["total"])
      usage = add_usage(usage, reply_usage)
      tool_calls = reply[:tool_calls] || []

      if tool_calls != [] and c.tools != %{} and n < c.max_iterations,
        do: tools_step(c, messages, reply, tool_calls, {n, usage, calls + 1}),
        else: {answer(c, reply), usage, calls + 1}
    else
      {:error, error} -> {{:error, error}, usage, calls}
    end
  end

  # The reply's tool calls run, then the next call with their results.
  defp tools_step(c, messages, reply, tool_calls, {n, usage, calls}) do
    case run_tools(c, tool_calls) do
      {:ok, results} ->
        calls_msg = Context.assistant(reply.text || "", tool_calls: to_calls(tool_calls))
        step(c, messages ++ [calls_msg | results], n + 1, usage, calls)

      {:error, :stopped} ->
        {{:error, :stopped}, usage, calls}
    end
  end

  defp answer(c, reply) do
    case String.trim(reply[:text] || "") do
      "" -> {:error, {:other, "#{c.model} answered with no text"}}
      text -> {:ok, %{text: text, model: c.model, purpose: c.purpose, usage: nil}}
    end
  end

  defp request(c, messages) do
    request = %{
      model: c.model,
      system_prompt: c.system,
      messages: messages,
      tools: for(m <- Map.values(c.tools), t <- [Tool.to_req_llm(m)], t != nil, do: t),
      max_tokens: c.max_tokens
    }

    if c.session_id, do: Map.put(request, :session_id, c.session_id), else: request
  end

  defp to_calls(calls),
    do:
      for(t <- calls, do: ToolCall.new(t["id"], t["name"], Jason.encode!(t["arguments"] || %{})))

  defp check_budget(%{budget: dir}) when is_binary(dir) do
    case Budget.check(dir) do
      :ok -> :ok
      {:over, spent, cap} -> {:error, {:cost_cap, spent, cap}}
    end
  end

  defp check_budget(_c), do: :ok

  defp record_cost(%{budget: dir}, cost) when is_binary(dir), do: Budget.record(dir, cost)
  defp record_cost(_c, _cost), do: :ok

  @usage_keys ~w(input output cacheRead cacheWrite totalTokens)
  @cost_keys ~w(input output cacheRead cacheWrite total)

  defp add_usage(a, b) do
    a = Enum.reduce(@usage_keys, a, fn k, acc -> Map.update!(acc, k, &(&1 + (b[k] || 0))) end)

    cost =
      Enum.reduce(@cost_keys, a["cost"], fn k, acc ->
        Map.update(acc, k, b["cost"][k] || 0, &(&1 + (b["cost"][k] || 0)))
      end)

    %{a | "cost" => cost}
  end

  # The model call in a worker the caller owns: its deltas go to the loop,
  # a stop (or the loop's exit) kills it. The worker watches the caller and
  # kills the call if the caller goes first (a tool's task killed at its
  # timeout), so no call outlives its consult.
  defp call(c, request) do
    {mod, llm_opts} = c.llm
    caller = self()

    {pid, ref} =
      spawn_monitor(fn ->
        worker = self()
        caller_ref = Process.monitor(caller)
        Process.flag(:trap_exit, true)

        inner =
          spawn_link(fn ->
            request = %{
              request
              | messages: Session.fetch(request.messages, %{session_id: c.session_id})
            }

            result = mod.stream(request, llm_opts, &send(caller, {:consult_llm, worker, &1}))
            send(caller, {:consult_done, worker, result})
          end)

        receive do
          {:EXIT, ^inner, :normal} -> :ok
          {:EXIT, ^inner, reason} -> exit(reason)
          {:DOWN, ^caller_ref, :process, _, _} -> Process.exit(inner, :kill)
        end
      end)

    await_call(c, pid, ref)
  end

  defp await_call(c, pid, ref) do
    loop = c.loop
    loop_ref = c.loop_ref

    receive do
      {:consult_llm, ^pid, {kind, delta}} when kind in [:text, :thinking] and is_binary(delta) ->
        if loop, do: send(loop, {:rho_consult_delta, self(), c.id, kind, delta})
        await_call(c, pid, ref)

      {:consult_done, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, _, reason} ->
        {:error, {:other, "the consult's model call crashed: #{Exception.format_exit(reason)}"}}

      {:rho_stop, ^loop} ->
        kill(pid, ref)
        {:error, :stopped}

      {:DOWN, ^loop_ref, :process, _, _} ->
        kill(pid, ref)
        {:error, :stopped}
    end
  end

  defp kill(pid, ref) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
  end

  # ── tools ──

  # One at a time, in the model's order: `{:ok, [tool result message]}`.
  defp run_tools(c, calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      case run_tool(c, call) do
        :stopped ->
          {:halt, {:error, :stopped}}

        text ->
          {:cont, {:ok, acc ++ [Context.tool_result(call["id"], call["name"], text)]}}
      end
    end)
  end

  defp run_tool(c, call) do
    case c.tools[call["name"]] do
      nil ->
        known = c.tools |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        "Tool not found: #{call["name"]}. Available tools: #{known}"

      module ->
        ctx = %{
          session_id: c.session_id,
          call_id: call["id"],
          data_dir: c.data_dir,
          loop: c.loop,
          withheld: []
        }

        task = ToolRunner.start(c.task_supervisor, self(), module, call, c.gate, ctx)
        await_tool(c, call, task, module, nil)
    end
  end

  defp await_tool(c, call, %Task{pid: tpid, ref: tref} = task, module, timer) do
    loop = c.loop
    loop_ref = c.loop_ref

    receive do
      {:tool_running, ^tpid} ->
        timer = Process.send_after(self(), {:consult_tool_timeout, tref}, Tool.timeout_ms(module))
        await_tool(c, call, task, module, timer)

      {^tref, result} ->
        Process.demonitor(tref, [:flush])
        cancel(timer)
        tool_text(c, call, result)

      {:DOWN, ^tref, :process, _, reason} ->
        cancel(timer)
        ToolRunner.crash_text(reason)

      {:consult_tool_timeout, ^tref} ->
        kill(tpid, tref)
        ToolRunner.timeout_text(module)

      {:rho_stop, ^loop} ->
        cancel(timer)
        kill(tpid, tref)
        :stopped

      {:DOWN, ^loop_ref, :process, _, _} ->
        cancel(timer)
        kill(tpid, tref)
        :stopped
    end
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer, async: false, info: false)

  # The text the consulted model reads (pictures aren't passed on), over
  # the output budget cut as the loop cuts it.
  defp tool_text(c, call, result) do
    result =
      case result do
        {:details, result, _details} -> result
        result -> result
      end

    text =
      case result do
        {:ok, {:images, images, text}} -> "#{text}\n(#{length(images)} picture(s) not shown)"
        {:ok, text} -> text
        {:error, text} -> "Error: #{text}"
      end

    Artifacts.limit(text, c.data_dir, c.session_id || "consult-#{c.id}", call["id"])
  end

  # ── helpers ──

  defp id, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp dollars(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
end
