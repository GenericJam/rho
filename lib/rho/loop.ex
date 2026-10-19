defmodule Rho.Loop do
  @moduledoc """
  The agent loop for one session: a GenServer with pi's lifecycle
  (`pi-agent-core/src/agent-loop.ts`; events in `Rho.Events`).

  A run starts with `prompt/2` (or `steer/2` / `follow_up/2` while idle) and
  repeats turns: one model call (streamed), then the reply's tool calls in
  parallel (up to `:max_tool_concurrency`, 4; one at a time, in the
  model's order, when any of them is an `:exclusive` tool,
  `Rho.Tool.concurrency/1`), until the model stops calling tools
  and nothing is queued.

    * `steer/3` while running queues a user message injected at the next
      step boundary: after the current tool batch, before the next model
      call (or, if the model just stopped, as one more turn).
    * `follow_up/3` while running runs after the agent would stop.
    * `stop/1` kills the in-flight model call and skips tools not yet
      started; started tools finish, each sent `{:rho_stop, loop}`
      first, so one that waits on others (`task`'s subagents) can wrap up
      early. The run ends with a notice entry. Consults on the session
      (`Rho.Consult`) are sent `{:rho_stop, loop}` too, even when idle.

  Another model's answer goes in as that model's message, not the
  user's: `prompt/3`, `steer/3` or `follow_up/3` with `attribution:
  {:model, model, purpose}` (`Rho.Session.model_message/4`).

  The slow parts never run in this process: the model call runs in a
  monitored worker, each tool in a task under `:task_supervisor`, so the
  loop always answers steer / stop. Guards: `:max_iterations` model calls
  per run (12), explicit `:max_tokens` (4096), up to `:max_retries` (2)
  retries with exponential backoff on 5xx / transport errors, and
  with `:budget` (a data dir) the per-day cost cap (`Rho.Budget`):
  checked before each model call, each reply's cost recorded. A run at
  `:max_iterations` doesn't just stop: a notice asks the model for a short
  status (what's done, what's in progress or broken, the next steps) and
  it gets exactly one more call, with no tools offered, before the run
  ends (`:max_iterations`), so the user and the next run know where
  things stand.

  Rate limits (a 429 or a 529 overloaded, `Rho.LLM.rate_limit/1`)
  are waited out more patiently, as omp does: up to `:rate_limit_retries`
  (8) retries, each after the response's `retry-after`, or until the used
  up window resets, else the exponential backoff capped at
  `:rate_limit_cap_ms` (60 s), as long as the waits add up to no more
  than `:rate_limit_budget_ms` (5 min). A wait that would go past it (a
  subscription window used up for hours) isn't started. Then the run
  continues on the fallback model (omp's fallback chain, one link):
  `:fallback_model` (default the host's `Rho.Settings.fallback_model/1`),
  if `:fallback_check` (`fn model -> :ok | {:error, why} end`; default
  `Rho.LLM.usable/2` over the loop's `:data_dir` and the `:llm`'s
  `Rho.LLM.status/1`: signed in, not used up itself) passes, with a
  `model_change` entry and a notice
  saying why; the session's own model comes back (another `model_change`)
  when the run ends. Without one, the run ends with the error and what to
  do: when the limit lifts, or to prompt again to continue.

  Compaction (pi's; `Rho.Compaction`): before each model call, a
  context over the window (`:context_window`, default the model's) minus
  the reserve (`:reserve_tokens`, default pi's) has its older part
  summarized by the model into a `compaction` entry, keeping about
  `:keep_recent_tokens` (pi's 20,000) of recent messages. The summary call
  uses `:compaction_model` (default the session's) with an explicit
  `:compaction_max_tokens` (4096), runs in a worker like a model call and
  counts toward the cost cap; if it fails, the run ends with an error
  notice and nothing else is persisted. A call the provider rejects as
  over the context window is compacted and retried once.

  A run about to end (the model stopped calling tools, nothing queued)
  with items still open on the session's todo list
  (`Rho.Tools.Todo.open_items/2`, when `todo` is offered) gets
  one more turn, once per run: a notice naming them, as omp's reminder
  does, so the agent finishes them or says why it can't.

  A tool's ctx is `%{session_id, call_id, data_dir, loop, withheld}`: the
  loop's pid and the names in `:withhold_tools`, besides
  `Rho.Tool`'s three.

  A tool that answers with details (`{:ok, {:details, output, details}}`,
  `Rho.ToolRunner`) has them sent to the subscribers with
  `tool_execution_end` as it gave them (a Dyn tool's as plain data,
  `Rho.Untrusted.plain/1`); what goes in the session is the host's choice,
  `:keep_details` (`fn tool_name, details -> kept | nil end`, called in
  this process, so keep it quick): its non-nil answer is stored as the
  toolResult entry's `details` (pi's), for a screen drawing the session
  later. The default keeps nothing. A keep function that raises or keeps
  something JSON can't encode is logged and nothing is stored. Pictures
  the model makes (the reply's `:images`, `Rho.LLM`) go in the
  assistant entry, as pi's image parts.

  Everything is persisted to the session as it happens
  (`Rho.Session`, omp/pi's JSONL).
  """
  use GenServer, restart: :temporary

  alias Rho.Artifacts
  alias Rho.Budget
  alias Rho.Compaction
  alias Rho.Events
  alias Rho.LLM
  alias Rho.Models
  alias Rho.Session
  alias Rho.Settings
  alias Rho.Tool
  alias Rho.ToolRegistry
  alias Rho.ToolRunner
  alias Rho.Tools.Todo

  require Logger

  @defaults [
    max_iterations: 12,
    max_tokens: 4096,
    max_retries: 2,
    retry_base_ms: 1_000,
    max_tool_concurrency: 4,
    task_supervisor: Rho.TaskSup,
    tools: :registry,
    withhold_tools: [],
    before_tool_call: &ToolRunner.allow_all/2,
    llm: {LLM.ReqLLM, []},
    context_window: nil,
    reserve_tokens: nil,
    keep_recent_tokens: 20_000,
    compaction_model: nil,
    compaction_max_tokens: 4096,
    rate_limit_retries: 8,
    rate_limit_cap_ms: 60_000,
    rate_limit_budget_ms: 300_000,
    fallback_model: :settings,
    fallback_check: :usable,
    keep_details: nil
  ]

  # Open todo items the reminder names; the rest it counts.
  @reminder_items 10

  # ── API ──

  @doc """
  Options: `:session` and `:entries` (from `Rho.Session.new/3` or
  `Rho.Session.open/2`), `:system_prompt`, `:data_dir` (given to tools,
  and to the model client with each request: where its usage is
  recorded), `:llm` (`{module, opts}`), `:tools` (`:registry` or a list of tool
  modules), `:withhold_tools` (tool names never offered nor run: `task`
  withholds itself from its subagents), `:before_tool_call` (`fn call,
  ctx -> :allow | {:block, reason} end`), `:keep_details` (`fn tool_name,
  details -> term() | nil end`: the part of a tool's details stored in its
  result entry; nil, the default, stores none), `:task_supervisor`, `:budget`
  (the data dir holding the cost ledger and cap; nil means no cap),
  `:inputs` (what the model takes, for attachments and tool pictures;
  default `Rho.Models.inputs/1` of the session's model), and the
  compaction, rate-limit and fallback options and guards above.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc """
  Starts a run. `{:error, :running}` if one is in progress (use `steer/3`).

  The third argument is the message's attachments
  (`t:Rho.Session.attachment/0`), or a keyword list of options:

    * `:attachments`: as above; `text` may then be empty. One attached by
      reference (`:ref`) is stored without its bytes and fetched through
      the `:resolve_attachment` hook (`Rho.Config`) for each request.
    * `:attribution`: `{:model, model, purpose}` makes `text` another
      model's message (a consult's answer, `Rho.Consult`), not the
      user's: stored as its own entry (`Rho.Session.model_message/4`,
      read back with `Rho.Session.attribution/1`) and sent to the model
      marked as that model's. No attachments with it.
    * `:instruction`: with `:attribution`, what the model is asked to do
      with that message ("Respond to each point: ..."), sent after it.

  Raises `ArgumentError` for an attachment with neither `:path` nor
  `:ref`, or an attribution with attachments or empty text.
  """
  @spec prompt(GenServer.server(), String.t(), [Session.attachment()] | keyword()) ::
          :ok | {:error, :running}
  def prompt(loop, text, attachments_or_opts \\ []),
    do: GenServer.call(loop, {:prompt, input!(text, attachments_or_opts)})

  @doc """
  Injects `text` at the next step boundary; starts a run if idle. The
  third argument is `prompt/3`'s.
  """
  @spec steer(GenServer.server(), String.t(), [Session.attachment()] | keyword()) :: :ok
  def steer(loop, text, attachments_or_opts \\ []),
    do: GenServer.call(loop, {:steer, input!(text, attachments_or_opts)})

  @doc """
  Runs `text` once the agent would otherwise stop; starts a run if idle.
  The third argument is `prompt/3`'s.
  """
  @spec follow_up(GenServer.server(), String.t(), [Session.attachment()] | keyword()) :: :ok
  def follow_up(loop, text, attachments_or_opts \\ []),
    do: GenServer.call(loop, {:follow_up, input!(text, attachments_or_opts)})

  # `{text, attachments}`, or with options for the entry
  # `{text, attachments, opts}` (`user/2`).
  defp input!(text, list) do
    {attachments, opts} =
      if list != [] and Keyword.keyword?(list) do
        opts = Keyword.validate!(list, attachments: [], attribution: nil, instruction: nil)
        {opts[:attachments], opts}
      else
        {list, []}
      end

    :ok = Session.check_attachments!(attachments)
    attributed!(text, attachments, opts[:attribution], opts[:instruction])
  end

  defp attributed!(text, attachments, nil, nil), do: {text, attachments}

  defp attributed!(_text, _attachments, nil, _instruction),
    do: raise(ArgumentError, ":instruction goes with an :attribution")

  defp attributed!(text, [], {:model, model, purpose} = by, instruction)
       when is_binary(model) and is_binary(purpose) and text != "",
       do: {text, [], [attribution: by, instruction: instruction]}

  defp attributed!(_text, _attachments, attribution, _instruction) do
    raise ArgumentError,
          "an :attribution is {:model, model, purpose} (strings), with text and no " <>
            "attachments; got #{inspect(attribution)}"
  end

  @doc """
  A question from another agent (another node's, through the host's
  clustering): queued like `follow_up/3` (a run starts if idle), as a user
  entry marked `"ask" => id` and attributed to node `from`, so the asker
  can find the answer after it.
  """
  @spec ask(GenServer.server(), String.t(), String.t(), node()) :: :ok
  def ask(loop, text, id, from),
    do: GenServer.call(loop, {:follow_up, {text, [], [ask: id, from: from]}})

  @doc """
  Aborts the model call and unstarted tools (no-op when idle), and stops
  every consult made on this loop (`Rho.Consult`), running or idle.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(loop), do: GenServer.call(loop, :stop)

  @doc """
  Adds a notice entry (`kind` `:notice` / `:aside`) to the session, as the
  loop's own are: the user sees it, and the model with the next call. A
  run in progress gets it when the run ends, so it never lands between a
  tool call and its result.
  """
  @spec note(GenServer.server(), :notice | :aside, String.t()) :: :ok
  def note(loop, kind, text) when kind in [:notice, :aside] and is_binary(text),
    do: GenServer.call(loop, {:note, kind, text})

  @doc """
  Sends `pid` (the caller by default) `{:rho, session_id, event}`
  for every event, until it exits or unsubscribes.
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(loop, pid \\ self()), do: GenServer.call(loop, {:subscribe, pid})

  @doc "Stops sending the caller this loop's events (`subscribe/2`)."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(loop), do: GenServer.call(loop, {:unsubscribe, self()})

  @doc "Switches the model (a req_llm spec) for later calls; idle only."
  @spec set_model(GenServer.server(), String.t()) :: :ok | {:error, :running}
  def set_model(loop, model), do: GenServer.call(loop, {:set_model, model})

  @doc """
  `%{session_id, path, title, model, status, entries, totals, streaming,
  queue, consults}`: what a screen needs to draw the session from scratch.
  `consults` are the ones running (`Rho.Consult`), `%{id, model, purpose,
  call_id}` each.
  """
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(loop), do: GenServer.call(loop, :snapshot)

  @doc """
  The req_llm messages the next model call would send (no system prompt),
  its files fetched (`Rho.Session.fetch/2`) in the caller's process.
  """
  @spec context(GenServer.server()) :: [ReqLLM.Message.t()]
  def context(loop) do
    {messages, session_id} = GenServer.call(loop, :context)
    Session.fetch(messages, %{session_id: session_id})
  end

  @doc """
  `%{session, opts}`: this loop's session and the options it was started
  with (no `:session` / `:entries`), so a tool can start a loop configured
  like its caller's (`task`'s subagents: same model, LLM, gate, budget).
  """
  @spec config(GenServer.server()) :: %{session: Session.t(), opts: keyword()}
  def config(loop), do: GenServer.call(loop, :config)

  # ── GenServer ──

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)

    state = %{
      session: Keyword.fetch!(opts, :session),
      entries_rev: opts |> Keyword.get(:entries, []) |> Enum.reverse(),
      opts: Map.new(Keyword.drop(opts, [:session, :entries, :name])),
      subscribers: %{},
      status: :idle,
      steering: [],
      follow_up: [],
      notes: [],
      run: nil,
      consults: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, input}, _from, %{status: :idle} = s),
    do: {:reply, :ok, start_run(s, [user(input)])}

  def handle_call({:prompt, _input}, _from, s), do: {:reply, {:error, :running}, s}

  def handle_call({:steer, input}, _from, %{status: :idle} = s),
    do: {:reply, :ok, start_run(s, [user(input)])}

  def handle_call({:steer, input}, _from, s),
    do: {:reply, :ok, queued(%{s | steering: s.steering ++ [input]})}

  def handle_call({:follow_up, input}, _from, %{status: :idle} = s),
    do: {:reply, :ok, start_run(s, [user(input)])}

  def handle_call({:follow_up, input}, _from, s),
    do: {:reply, :ok, queued(%{s | follow_up: s.follow_up ++ [input]})}

  def handle_call(:stop, _from, s), do: {:reply, :ok, s |> stop_consults() |> do_stop()}

  def handle_call({:note, kind, text}, _from, %{status: :idle} = s),
    do: {:reply, :ok, notice(s, kind, text)}

  def handle_call({:note, kind, text}, _from, s),
    do: {:reply, :ok, %{s | notes: s.notes ++ [{kind, text}]}}

  def handle_call({:subscribe, pid}, _from, s) do
    subs =
      if Map.has_key?(s.subscribers, pid),
        do: s.subscribers,
        else: Map.put(s.subscribers, pid, Process.monitor(pid))

    {:reply, :ok, %{s | subscribers: subs}}
  end

  def handle_call({:unsubscribe, pid}, _from, s) do
    {ref, subs} = Map.pop(s.subscribers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{s | subscribers: subs}}
  end

  def handle_call({:set_model, model}, _from, %{status: :idle} = s) do
    {s, _} = persist(s, Session.model_change(model))
    emit(s, %{type: :model_change, model: model})
    {:reply, :ok, s}
  end

  def handle_call({:set_model, _model}, _from, s), do: {:reply, {:error, :running}, s}

  def handle_call(:snapshot, _from, s) do
    entries = Enum.reverse(s.entries_rev)

    snapshot = %{
      session_id: s.session.id,
      path: s.session.path,
      title: s.session.title,
      model: s.session.model,
      status: s.status,
      entries: entries,
      totals: Session.totals(entries),
      streaming: s.run && s.run.stream && IO.iodata_to_binary(s.run.stream.text),
      queue: %{steering: labels(s.steering), follow_up: labels(s.follow_up)},
      consults: for({_id, c} <- s.consults, do: Map.take(c, [:id, :model, :purpose, :call_id]))
    }

    {:reply, snapshot, s}
  end

  def handle_call(:context, _from, s),
    do: {:reply, {Session.context(Enum.reverse(s.entries_rev), inputs(s)), s.session.id}, s}

  def handle_call(:config, _from, s),
    do: {:reply, %{session: s.session, opts: Map.to_list(s.opts)}, s}

  # A consult (`Rho.Consult`) on this session: the caller is watched (and
  # sent `{:rho_stop, loop}` on stop) until it ends.
  def handle_call({:consult_start, info, include}, {pid, _tag}, s) do
    c = Map.merge(info, %{pid: pid, ref: Process.monitor(pid)})
    s = %{s | consults: Map.put(s.consults, info.id, c)}
    emit(s, Map.merge(%{type: :consult_start}, Map.take(info, [:id, :model, :purpose, :call_id])))

    joined = %{
      loop: self(),
      session: s.session,
      opts: s.opts,
      entries: if(include, do: Enum.reverse(s.entries_rev))
    }

    {:reply, {:ok, joined}, s}
  end

  def handle_call({:consult_end, id, ending}, _from, s) do
    case Map.pop(s.consults, id) do
      {nil, _} ->
        {:reply, :ok, s}

      {c, consults} ->
        Process.demonitor(c.ref, [:flush])
        {:reply, :ok, consult_ended(%{s | consults: consults}, c, ending)}
    end
  end

  # model stream worker
  @impl true
  def handle_info({:llm_event, pid, {kind, delta}}, %{run: %{stream: %{pid: pid} = st}} = s)
      when kind in [:text, :thinking] and is_binary(delta) do
    st = Map.update!(st, kind, &[&1, delta])
    emit(s, %{type: :message_update, kind: kind, delta: delta})
    {:noreply, put_run(s, stream: st)}
  end

  def handle_info({:llm_done, pid, result}, %{run: %{stream: %{pid: pid, ref: ref}}} = s) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, reply} -> {:noreply, handle_reply(s, reply)}
      {:error, error} -> {:noreply, handle_error(s, error)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run: %{stream: %{ref: ref}}} = s),
    do:
      {:noreply,
       handle_error(s, {:other, "model call crashed: #{Exception.format_exit(reason)}"})}

  def handle_info(:retry_attempt, %{run: %{phase: :backoff}} = s),
    do: {:noreply, start_attempt(put_run(s, retry_timer: nil))}

  # compaction summary worker
  def handle_info({:compaction_done, pid, result}, %{run: %{compaction: %{pid: pid} = c}} = s) do
    Process.demonitor(c.ref, [:flush])
    {:noreply, compaction_done(s, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run: %{compaction: %{ref: ref}}} = s),
    do:
      {:noreply,
       compaction_failed(s, "the summary call crashed: #{Exception.format_exit(reason)}")}

  # tool tasks
  def handle_info({:tool_running, pid}, %{run: %{batch: %{running: running}}} = s) do
    case Enum.find(running, fn {_ref, r} -> r.pid == pid end) do
      {ref, r} ->
        timer = Process.send_after(self(), {:tool_timeout, ref}, Tool.timeout_ms(r.module))
        {:noreply, update_batch(s, &put_in(&1, [:running, ref, :timer], timer))}

      nil ->
        {:noreply, s}
    end
  end

  def handle_info({ref, result}, %{run: %{batch: %{running: running}}} = s)
      when is_map_key(running, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, tool_done(s, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run: %{batch: %{running: running}}} = s)
      when is_map_key(running, ref),
      do: {:noreply, tool_done(s, ref, {:error, ToolRunner.crash_text(reason)})}

  def handle_info({:tool_timeout, ref}, %{run: %{batch: %{running: running}}} = s)
      when is_map_key(running, ref) do
    %{pid: pid, module: module} = running[ref]
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    {:noreply, tool_done(s, ref, {:error, ToolRunner.timeout_text(module)})}
  end

  # consults
  def handle_info({:rho_consult_delta, pid, id, kind, delta}, s) do
    case s.consults do
      %{^id => %{pid: ^pid} = c} ->
        emit(s, %{
          type: :consult_delta,
          id: id,
          model: c.model,
          purpose: c.purpose,
          call_id: c.call_id,
          kind: kind,
          delta: delta
        })

      _ ->
        :ok
    end

    {:noreply, s}
  end

  # a consult's caller that went without ending it, else a subscriber
  def handle_info({:DOWN, ref, :process, pid, _reason}, s) do
    case Enum.find(s.consults, fn {_id, c} -> c.ref == ref end) do
      {id, c} ->
        ending = %{
          status: :error,
          text: "",
          error: "the consult's process exited",
          usage: nil,
          record: false
        }

        {:noreply, consult_ended(%{s | consults: Map.delete(s.consults, id)}, c, ending)}

      nil ->
        case s.subscribers do
          %{^pid => ^ref} -> {:noreply, %{s | subscribers: Map.delete(s.subscribers, pid)}}
          _ -> {:noreply, s}
        end
    end
  end

  # late messages from a killed stream worker or a finished batch
  def handle_info(_message, s), do: {:noreply, s}

  # ── run lifecycle ──

  defp start_run(s, inputs) do
    s = %{
      s
      | status: :running,
        run: %{
          iteration: 0,
          turn: 0,
          phase: nil,
          stopping: false,
          attempt: 1,
          waited_ms: 0,
          fallback_from: nil,
          todo_reminded: false,
          wrap_up: false,
          stream: nil,
          compaction: nil
        }
    }

    emit(s, %{type: :agent_start})
    begin_turn(s, inputs)
  end

  # At the limit: one last call, with no tools, for a status; then the run
  # ends. Messages queued for this turn aren't sent (the notice says so).
  defp begin_turn(%{run: %{iteration: n}} = s, inputs) when n >= s.opts.max_iterations do
    if s.run.wrap_up,
      do: finish_wrap_up(s, dropped(inputs)),
      else:
        s |> put_run(wrap_up: true) |> notice(:notice, wrap_up(n, dropped(inputs))) |> turn([])
  end

  defp begin_turn(s, inputs), do: turn(s, inputs)

  # The messages a turn at the limit doesn't send: the user's, and another
  # model's (`Rho.Session.model_message/4`).
  defp dropped(inputs), do: Enum.map(inputs, &dropped_text/1)

  defp dropped_text(%{"message" => m}) do
    case Session.typed(m) do
      "" -> Enum.map_join(Session.attachments(m), ", ", & &1["name"])
      text -> text
    end
  end

  defp dropped_text(%{"type" => "custom_message", "content" => content}),
    do: Session.text(content)

  defp wrap_up(n, dropped) do
    "You've reached the limit of #{n} model calls for this run (max_iterations). Don't " <>
      "call tools. Reply with a short status for the user: what's done and verified, " <>
      "what's in progress or broken, and the " <>
      "next steps to continue." <> not_sent(dropped)
  end

  defp finish_wrap_up(s, []), do: finish(s, :max_iterations)

  defp finish_wrap_up(s, dropped),
    do: s |> notice(:notice, String.trim_leading(not_sent(dropped))) |> finish(:max_iterations)

  defp not_sent([]), do: ""
  defp not_sent(dropped), do: " Not sent: " <> Enum.join(dropped, " / ")

  defp turn(s, inputs) do
    run = s.run

    s =
      put_run(s,
        turn: run.turn + 1,
        iteration: run.iteration + 1,
        attempt: 1,
        waited_ms: 0,
        batch: nil,
        assistant: nil,
        overflow_retried: false
      )

    emit(s, %{type: :turn_start, turn: s.run.turn})

    s =
      Enum.reduce(inputs, s, fn input, acc ->
        {acc, entry} = persist(acc, input)
        emit(acc, %{type: :message_start, entry: entry})
        emit(acc, %{type: :message_end, entry: entry})
        acc
      end)

    with_budget(s, &maybe_compact/1)
  end

  # Every model call, the summary call included, goes through the cap.
  defp with_budget(s, next) do
    case budget(s) do
      :ok ->
        next.(s)

      {:over, spent, cap} ->
        text =
          "Daily cost cap reached: $#{dollars(spent)} of $#{dollars(cap)} spent today. " <>
            "No more model calls until tomorrow, or until the cap is raised."

        s |> notice(:notice, text) |> finish(:cost_cap)
    end
  end

  # pi's pre-prompt compaction: a context over the threshold has its older
  # part summarized first; the call then goes out on the compacted context.
  defp maybe_compact(s) do
    entries = Enum.reverse(s.entries_rev)
    request = request(s, entries)
    tokens = Compaction.context_tokens(entries, request)
    window = window(s, s.session.model)

    with true <- Compaction.should_compact?(tokens, window, s.opts.reserve_tokens),
         %{} = plan <- Compaction.prepare(entries, s.opts.keep_recent_tokens) do
      start_compaction(s, plan, tokens, nil)
    else
      _ -> start_attempt(s, request)
    end
  end

  defp budget(%{opts: %{budget: dir}}) when is_binary(dir), do: Budget.check(dir)
  defp budget(_s), do: :ok

  defp record_cost(%{opts: %{budget: dir}}, cost) when is_binary(dir),
    do: Budget.record(dir, cost)

  defp record_cost(_s, _cost), do: :ok

  defp dollars(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  defp start_attempt(s), do: start_attempt(s, request(s))

  defp start_attempt(s, request) do
    {mod, llm_opts} = s.opts.llm
    loop = self()

    {pid, ref} =
      spawn_monitor(fn ->
        me = self()
        # the files the session holds no bytes of (the host's hook may be slow)
        request = %{
          request
          | messages: Session.fetch(request.messages, %{session_id: request.session_id})
        }

        result = mod.stream(request, llm_opts, &send(loop, {:llm_event, me, &1}))
        send(loop, {:llm_done, me, result})
      end)

    emit(s, %{
      type: :message_start,
      entry: %{"type" => "message", "message" => %{"role" => "assistant", "content" => []}}
    })

    put_run(s, phase: :streaming, stream: %{pid: pid, ref: ref, text: [], thinking: []})
  end

  defp request(s), do: request(s, Enum.reverse(s.entries_rev))

  defp request(s, entries) do
    %{
      model: s.session.model,
      session_id: s.session.id,
      data_dir: data_dir(s),
      system_prompt: s.opts[:system_prompt] || Rho.Config.system_prompt(),
      messages: Session.context(entries, inputs(s)),
      tools: for(m <- Map.values(offered(s)), t <- [Tool.to_req_llm(m)], t != nil, do: t),
      max_tokens: s.opts.max_tokens
    }
  end

  # What the model takes (pictures, PDFs); the `:inputs` option overrides
  # it. The files the session holds no bytes of stay placeholders, fetched
  # by the model call's process (`start_attempt/2`), never this one.
  defp inputs(s),
    do: [inputs: s.opts[:inputs] || Models.inputs(s.session.model), fetch: false]

  # The tools the next call offers. The wrap-up at the limit keeps them: a
  # conversation holding tool calls must declare its tools (Anthropic rejects
  # it otherwise), and they head the cached prompt. Its notice says not to
  # call them, and handle_reply drops any it calls anyway.
  defp offered(s), do: tools(s)

  defp tools(%{opts: %{tools: :registry}} = s), do: named(ToolRegistry.list(), s)
  defp tools(%{opts: %{tools: modules}} = s), do: named(modules, s)

  # By the name each offers itself under; a Dyn tool whose declaration
  # failed (`Rho.Tool.offered_name/1`) is left out.
  defp named(modules, s) do
    for(m <- modules, name <- [Tool.offered_name(m)], name != nil, into: %{}, do: {name, m})
    |> Map.drop(s.opts.withhold_tools)
  end

  # A wrap-up reply's tool calls (none were offered) are dropped, not run.
  defp handle_reply(s, reply) do
    calls = if s.run.wrap_up, do: [], else: reply.tool_calls || []

    stop_reason =
      cond do
        calls != [] -> "toolUse"
        reply[:finish_reason] == :length -> "length"
        true -> "stop"
      end

    reply = Map.merge(reply, %{tool_calls: calls, stop_reason: stop_reason})
    {s, entry} = persist(put_run(s, stream: nil), Session.assistant(reply, s.session.model))
    record_cost(s, get_in(entry, ["message", "usage", "cost", "total"]) || 0)
    emit(s, %{type: :message_end, entry: entry})

    if calls == [], do: end_turn(s, entry, []), else: start_batch(s, entry, calls)
  end

  defp handle_error(s, error) do
    case overflow_plan(s, error) do
      {plan, tokens} ->
        s
        |> put_run(stream: nil)
        |> with_budget(&start_compaction(&1, plan, tokens, LLM.describe(error)))

      nil ->
        retry_or_fail(s, error)
    end
  end

  # A call rejected as over the context window: compact and retry, once
  # per model call; a second overflow ends the run like any other error.
  defp overflow_plan(%{run: %{overflow_retried: false}} = s, error) do
    entries = Enum.reverse(s.entries_rev)

    with true <- Compaction.overflow?(error),
         %{} = plan <- Compaction.prepare(entries, s.opts.keep_recent_tokens) do
      {plan, Compaction.context_tokens(entries, request(s, entries))}
    else
      _ -> nil
    end
  end

  defp overflow_plan(_s, _error), do: nil

  defp retry_or_fail(s, error) do
    %{attempt: attempt} = s.run

    case LLM.rate_limit(error) do
      nil ->
        if LLM.retryable?(error) and attempt <= s.opts.max_retries,
          do: retry(s, error, s.opts.retry_base_ms * Integer.pow(2, attempt - 1)),
          else: fail(s, LLM.describe(error))

      limit ->
        rate_limited(s, error, limit)
    end
  end

  # A rate limit: wait as the response says (or until the used-up window
  # resets) within the budget; past it, the fallback model, else the end.
  defp rate_limited(s, error, limit) do
    %{attempt: attempt, waited_ms: waited} = s.run
    now = System.os_time(:second)

    delay =
      cond do
        is_integer(limit.resets_at) and limit.resets_at > now ->
          max((limit.resets_at - now) * 1000, limit.retry_after_ms || 0)

        is_integer(limit.retry_after_ms) ->
          limit.retry_after_ms

        true ->
          min(s.opts.retry_base_ms * Integer.pow(2, attempt - 1), s.opts.rate_limit_cap_ms)
      end

    if attempt <= s.opts.rate_limit_retries and waited + delay <= s.opts.rate_limit_budget_ms do
      s |> put_run(waited_ms: waited + delay) |> retry(error, delay)
    else
      give_up(s, error, attempt - 1, waited)
    end
  end

  defp retry(s, error, delay) do
    attempt = s.run.attempt
    emit(s, %{type: :retry, attempt: attempt, delay_ms: delay, error: LLM.describe(error)})
    timer = Process.send_after(self(), :retry_attempt, delay)
    put_run(s, phase: :backoff, attempt: attempt + 1, stream: nil, retry_timer: timer)
  end

  defp give_up(s, error, retries, waited) do
    described = LLM.describe(error)

    case fallback(s) do
      {:ok, model} ->
        from = s.session.model
        Logger.warning("[loop] #{described}; falling back to #{model}")
        {s, _} = persist(put_run(s, stream: nil), Session.model_change(model))
        emit(s, %{type: :model_change, model: model})

        text =
          "#{described}\nContinuing this run on #{model} (the fallback model); " <>
            "the next run goes back to #{from}."

        s
        |> notice(:notice, text)
        |> put_run(fallback_from: from, attempt: 1, waited_ms: 0)
        |> with_budget(&start_attempt/1)

      {:error, why} ->
        text =
          cond do
            described =~ "is used up until" ->
              described

            retries > 0 ->
              "#{described}\nStill limited after #{retries} retries over #{div(waited, 1000)} s: prompt again to continue this run."

            true ->
              "#{described}\nPrompt again to continue this run."
          end

        fail(s, if(why, do: text <> "\n(Fallback model: #{why}.)", else: text))
    end
  end

  # The fallback model for this run: once per run, not the model that ran
  # out, and only if it can take over now. `{:error, nil}` if none is set.
  defp fallback(%{run: %{fallback_from: from}}) when from != nil, do: {:error, nil}

  defp fallback(s) do
    model =
      case s.opts.fallback_model do
        :settings -> Settings.fallback_model(data_dir(s))
        model -> model
      end

    cond do
      model in [nil, ""] -> {:error, nil}
      Models.same?(model, s.session.model) -> {:error, nil}
      true -> with :ok <- fallback_check(s, model), do: {:ok, model}
    end
  end

  defp fallback_check(%{opts: %{fallback_check: :usable}} = s, model),
    do: LLM.usable(model, data_dir: data_dir(s), status: LLM.status(s.opts.llm))

  defp fallback_check(s, model), do: s.opts.fallback_check.(model)

  defp fail(s, message) do
    stream = s.run.stream
    Logger.warning("[loop] model call failed: #{message}")

    reply = %{
      text: IO.iodata_to_binary(stream.text),
      thinking: IO.iodata_to_binary(stream.thinking),
      stop_reason: "error",
      error: message
    }

    {s, entry} = persist(put_run(s, stream: nil), Session.assistant(reply, s.session.model))
    emit(s, %{type: :message_end, entry: entry})

    emit(s, %{type: :turn_end, turn: s.run.turn, entry: entry, tool_results: [], error: message})

    # A failed wrap-up still ends a run that hit the limit.
    finish(s, if(s.run.wrap_up, do: :max_iterations, else: :error))
  end

  defp end_turn(s, entry, results) do
    emit(s, %{type: :turn_end, turn: s.run.turn, entry: entry, tool_results: results, error: nil})
    has_calls = Session.tool_calls(entry["message"]) != []

    cond do
      s.run.stopping -> stopped(s)
      s.run.wrap_up -> finish_wrap_up(s, labels(s.steering) ++ labels(s.follow_up))
      has_calls or s.steering != [] -> drain(s, :steering)
      s.follow_up != [] -> drain(s, :follow_up)
      true -> remind_or_finish(s)
    end
  end

  # omp's todo reminder: a run about to end with items left on the
  # session's todo list gets one more turn, once, to finish them or to say
  # why it can't. Only when the model has `todo` to tick them off with, and
  # not in a subagent (a loop that withholds `task`): its last reply is the
  # answer its caller gets, which a reminder turn would replace.
  defp remind_or_finish(%{run: %{todo_reminded: false}} = s) do
    open =
      if Map.has_key?(tools(s), Todo.name()) and "task" not in s.opts.withhold_tools,
        do: Todo.open_items(data_dir(s), s.session.id)

    if open in [nil, []] do
      finish(s, :done)
    else
      s |> put_run(todo_reminded: true) |> notice(:notice, todo_reminder(open)) |> begin_turn([])
    end
  end

  defp remind_or_finish(s), do: finish(s, :done)

  defp todo_reminder(open) do
    shown = open |> Enum.take(@reminder_items) |> Enum.map_join("; ", &"\"#{&1}\"")
    more = length(open) - @reminder_items
    more = if more > 0, do: " (and #{more} more)", else: ""

    "You stopped with open todo items: #{shown}#{more}. Continue with them, or if you're " <>
      "blocked or need the user, say so and stop."
  end

  defp drain(s, :steering) do
    inputs = for input <- s.steering, do: user(input, steering: true)
    s = %{s | steering: []}
    if inputs != [], do: queued(s)
    begin_turn(s, inputs)
  end

  defp drain(s, :follow_up) do
    inputs = for input <- s.follow_up, do: user(input)
    s |> Map.put(:follow_up, []) |> queued() |> begin_turn(inputs)
  end

  defp user(input, opts \\ [])

  defp user({text, attachments}, opts),
    do: Session.user(text, [attachments: attachments] ++ opts)

  defp user({text, attachments, input_opts}, opts) do
    case Keyword.pop(input_opts, :attribution) do
      {{:model, model, purpose}, rest} ->
        Session.model_message(text, model, purpose, instruction: rest[:instruction])

      {nil, rest} ->
        Session.user(text, [attachments: attachments] ++ rest ++ opts)
    end
  end

  # A queued message as the screen shows it: its text, else its files.
  defp labels(queue) do
    for input <- queue do
      {text, attachments} = {elem(input, 0), elem(input, 1)}
      if text == "", do: Enum.map_join(attachments, ", ", & &1.name), else: text
    end
  end

  defp finish(s, reason) do
    s = restore_model(s)
    had_queue = s.steering != [] or s.follow_up != []
    s = %{s | status: :idle, run: nil, steering: [], follow_up: []}
    if had_queue, do: emit(s, %{type: :queue, steering: [], follow_up: []})
    emit(s, %{type: :agent_end, reason: reason})
    Enum.reduce(s.notes, %{s | notes: []}, fn {kind, text}, acc -> notice(acc, kind, text) end)
  end

  # A run that fell back hands the session its own model back.
  defp restore_model(%{run: %{fallback_from: from}} = s) when is_binary(from) do
    {s, _} = persist(s, Session.model_change(from))
    emit(s, %{type: :model_change, model: from})
    s
  end

  defp restore_model(s), do: s

  # ── compaction ──

  # The summary call runs in a monitored worker like a model call, so the
  # loop still answers steer / stop; its deltas go nowhere. `overflow` is
  # the rejected call's error, or nil for a threshold compaction.
  defp start_compaction(s, plan, tokens, overflow) do
    {mod, llm_opts} = s.opts.llm
    model = s.opts.compaction_model || s.session.model
    max_tokens = s.opts.compaction_max_tokens

    request =
      plan
      |> Compaction.summary_request(model, max_tokens, window(s, model))
      |> Map.put(:data_dir, data_dir(s))

    loop = self()

    {pid, ref} =
      spawn_monitor(fn ->
        me = self()
        send(loop, {:compaction_done, me, mod.stream(request, llm_opts, fn _delta -> :ok end)})
      end)

    reason = if overflow, do: :overflow, else: :threshold
    emit(s, %{type: :compaction_start, reason: reason, tokens: tokens})

    put_run(s,
      phase: :compacting,
      overflow_retried: s.run.overflow_retried or reason == :overflow,
      compaction: %{pid: pid, ref: ref, plan: plan, tokens: tokens, overflow: overflow}
    )
  end

  defp compaction_done(s, {:ok, reply}) do
    %{plan: plan, tokens: before} = s.run.compaction
    record_cost(s, Session.usage(reply[:usage])["cost"]["total"])

    case String.trim(reply[:text] || "") do
      "" ->
        compaction_failed(s, "the model returned an empty summary")

      summary ->
        pending = Session.compaction(summary, plan.first_kept_id, before, 0)
        request = request(s, Enum.reverse([pending | s.entries_rev]))
        after_tokens = Compaction.request_tokens(request)
        s = put_run(s, compaction: nil)
        {s, entry} = persist(s, %{pending | "tokensAfter" => after_tokens})
        Logger.info("[loop] compacted the context: ~#{before} -> ~#{after_tokens} tokens")
        emit(s, %{type: :compaction, entry: entry})
        with_budget(s, &start_attempt(&1, request))
    end
  end

  defp compaction_done(s, {:error, error}), do: compaction_failed(s, LLM.describe(error))

  # Only the notice is persisted, and the run ends: no retry loop.
  defp compaction_failed(s, reason) do
    Logger.warning("[loop] compaction failed: #{reason}")

    text =
      "Compacting the context failed: #{reason}" <>
        case s.run.compaction.overflow do
          nil -> ""
          overflow -> "\nIt was needed because the model call failed: #{overflow}"
        end

    s = s |> put_run(compaction: nil) |> notice(:error, text)
    emit(s, %{type: :turn_end, turn: s.run.turn, entry: nil, tool_results: [], error: text})
    finish(s, :error)
  end

  defp window(s, model), do: s.opts.context_window || Compaction.context_window(model)

  # ── stop ──

  defp do_stop(%{status: :idle} = s), do: s
  defp do_stop(%{run: %{stopping: true}} = s), do: s

  defp do_stop(%{run: %{phase: :streaming, stream: st}} = s) do
    Process.demonitor(st.ref, [:flush])
    Process.exit(st.pid, :kill)
    aborted_turn(s, IO.iodata_to_binary(st.text), IO.iodata_to_binary(st.thinking))
  end

  defp do_stop(%{run: %{phase: :backoff, retry_timer: timer}} = s) do
    if timer, do: Process.cancel_timer(timer)
    aborted_turn(s, "", "")
  end

  defp do_stop(%{run: %{phase: :compacting, compaction: c}} = s) do
    Process.demonitor(c.ref, [:flush])
    Process.exit(c.pid, :kill)
    s = put_run(s, compaction: nil)
    emit(s, %{type: :turn_end, turn: s.run.turn, entry: nil, tool_results: [], error: nil})
    stopped(s)
  end

  defp do_stop(%{run: %{phase: :tools, batch: batch}} = s) do
    for {_ref, %{pid: pid}} <- batch.running, do: send(pid, {:rho_stop, self()})
    skipped = Map.new(batch.queue, &{&1, {ToolRunner.skipped_text(), true}})

    s =
      update_batch(
        put_run(s, stopping: true),
        &%{&1 | queue: [], results: Map.merge(&1.results, skipped)}
      )

    maybe_complete(s)
  end

  defp aborted_turn(s, text, thinking) do
    reply = %{text: text, thinking: thinking, stop_reason: "aborted"}
    {s, entry} = persist(put_run(s, stream: nil), Session.assistant(reply, s.session.model))
    emit(s, %{type: :message_end, entry: entry})
    emit(s, %{type: :turn_end, turn: s.run.turn, entry: entry, tool_results: [], error: nil})
    stopped(s)
  end

  defp stopped(s) do
    dropped = labels(s.steering) ++ labels(s.follow_up)

    text =
      "Stopped by the user." <>
        if(dropped == [], do: "", else: " Not sent: " <> Enum.join(dropped, " / "))

    s |> notice(:notice, text) |> finish(:stopped)
  end

  # ── tool batch ──

  defp start_batch(s, entry, calls) do
    available = tools(s)
    indexed = calls |> Enum.with_index() |> Map.new(fn {c, i} -> {i, c} end)

    {queue, results} =
      Enum.reduce(0..(length(calls) - 1), {[], %{}}, fn i, {queue, results} ->
        name = indexed[i]["name"]

        if Map.has_key?(available, name) do
          {[i | queue], results}
        else
          known = available |> Map.keys() |> Enum.sort() |> Enum.join(", ")

          {queue,
           Map.put(results, i, {"Tool not found: #{name}. Available tools: #{known}", true})}
        end
      end)

    queue = Enum.reverse(queue)

    batch = %{
      calls: indexed,
      tools: available,
      queue: queue,
      limit: concurrency_limit(s, queue, indexed, available),
      running: %{},
      results: results
    }

    s
    |> put_run(phase: :tools, assistant: entry, batch: batch)
    |> pump()
    |> maybe_complete()
  end

  # A batch with an exclusive tool (`Rho.Tool.concurrency/1`)
  # runs one call at a time, in the model's order; else up to the limit.
  defp concurrency_limit(s, queue, calls, tools) do
    exclusive? = Enum.any?(queue, &(Tool.concurrency(tools[calls[&1]["name"]]) == :exclusive))
    if exclusive?, do: 1, else: s.opts.max_tool_concurrency
  end

  defp pump(%{run: %{batch: %{queue: [i | rest], running: running} = batch}} = s)
       when map_size(running) < batch.limit do
    call = batch.calls[i]
    module = batch.tools[call["name"]]

    ctx = %{
      session_id: s.session.id,
      call_id: call["id"],
      data_dir: data_dir(s),
      loop: self(),
      withheld: s.opts.withhold_tools
    }

    task =
      ToolRunner.start(s.opts.task_supervisor, self(), module, call, s.opts.before_tool_call, ctx)

    emit(s, %{
      type: :tool_execution_start,
      id: call["id"],
      name: call["name"],
      arguments: call["arguments"]
    })

    run = %{idx: i, pid: task.pid, module: module, timer: nil}
    s |> update_batch(&%{&1 | queue: rest, running: Map.put(&1.running, task.ref, run)}) |> pump()
  end

  defp pump(s), do: s

  defp data_dir(s), do: s.opts[:data_dir] || Rho.Config.data_dir()

  defp tool_done(s, ref, result) do
    %{idx: i, timer: timer} = s.run.batch.running[ref]
    if timer, do: Process.cancel_timer(timer)
    call = s.run.batch.calls[i]

    {result, details} =
      case result do
        {:details, result, details} -> {result, details}
        result -> {result, nil}
      end

    {text, is_error, images} =
      case result do
        {:ok, {:images, images, text}} -> {text, false, images}
        {:ok, text} -> {text, false, []}
        {:error, text} -> {text, true, []}
      end

    # Over the output budget: head + tail for the model, the rest an artifact.
    text = Artifacts.limit(text, data_dir(s), s.session.id, call["id"])

    emit(s, %{
      type: :tool_execution_end,
      id: call["id"],
      name: call["name"],
      text: text,
      is_error: is_error,
      details: details
    })

    kept = keep_details(s.opts.keep_details, call["name"], details)

    s
    |> update_batch(
      &%{
        &1
        | running: Map.delete(&1.running, ref),
          results: Map.put(&1.results, i, {text, is_error, images, kept})
      }
    )
    |> then(&if(&1.run.stopping, do: &1, else: pump(&1)))
    |> maybe_complete()
  end

  # The host's part of a tool's details for the session; nil on any failure.
  defp keep_details(nil, _name, _details), do: nil
  defp keep_details(_keep, _name, nil), do: nil

  defp keep_details(keep, name, details) when is_function(keep, 2) do
    kept = keep.(name, details)

    case kept != nil and Jason.encode(kept) do
      {:error, error} ->
        Logger.warning(
          "[loop] keep_details for #{name} kept non-JSON: #{Exception.message(error)}"
        )

        nil

      _ ->
        kept
    end
  rescue
    e ->
      Logger.warning("[loop] keep_details for #{name} raised: #{Exception.message(e)}")
      nil
  catch
    kind, reason ->
      Logger.warning("[loop] keep_details for #{name} failed: #{inspect({kind, reason})}")
      nil
  end

  defp keep_details(keep, name, _details) do
    Logger.warning("[loop] keep_details for #{name} isn't a 2-arity function: #{inspect(keep)}")
    nil
  end

  defp maybe_complete(%{run: %{batch: %{queue: [], running: running} = batch}} = s)
       when map_size(running) == 0 do
    {s, entries} =
      Enum.reduce(0..(map_size(batch.calls) - 1), {s, []}, fn i, {acc, entries} ->
        call = batch.calls[i]

        {text, is_error, images, details} =
          case batch.results[i] do
            {text, is_error} -> {text, is_error, [], nil}
            {_text, _is_error, _images, _details} = result -> result
          end

        tool_result =
          Session.tool_result(call["id"], call["name"], text, is_error,
            images: images,
            details: details
          )

        {acc, entry} = persist(acc, tool_result)
        emit(acc, %{type: :message_start, entry: entry})
        emit(acc, %{type: :message_end, entry: entry})
        {acc, [entry | entries]}
      end)

    end_turn(put_run(s, batch: nil), s.run.assistant, Enum.reverse(entries))
  end

  defp maybe_complete(s), do: s

  # ── consults ──

  # `Rho.Consult`s watch for this, as tools do (`{:rho_stop, loop}`).
  defp stop_consults(s) do
    for {_id, %{pid: pid}} <- s.consults, do: send(pid, {:rho_stop, self()})
    s
  end

  # Its usage recorded in the session when a model call came back (a
  # `custom` entry, never sent to the model, so it may land mid-turn).
  defp consult_ended(s, c, ending) do
    {s, entry} =
      if ending.record do
        record =
          Session.consult(%{
            id: c.id,
            model: c.model,
            purpose: c.purpose,
            status: ending.status,
            call_id: c.call_id,
            usage: ending.usage
          })

        persist(s, record)
      else
        {s, nil}
      end

    emit(s, %{
      type: :consult_end,
      id: c.id,
      model: c.model,
      purpose: c.purpose,
      call_id: c.call_id,
      status: ending.status,
      text: ending.text,
      usage: ending.usage,
      error: ending.error,
      entry: entry
    })

    s
  end

  # ── helpers ──

  defp notice(s, kind, text) do
    {s, entry} = persist(s, Session.custom(kind, text))
    emit(s, %{type: :message_start, entry: entry})
    emit(s, %{type: :message_end, entry: entry})
    s
  end

  defp queued(s) do
    emit(s, %{type: :queue, steering: labels(s.steering), follow_up: labels(s.follow_up)})
    s
  end

  defp persist(s, entry) do
    {session, written} = Session.append(s.session, entry)
    {%{s | session: session, entries_rev: [written | s.entries_rev]}, written}
  end

  defp put_run(s, kv), do: %{s | run: Enum.into(kv, s.run)}

  defp update_batch(s, fun), do: put_run(s, batch: fun.(s.run.batch))

  defp emit(s, event), do: Events.broadcast(Map.keys(s.subscribers), s.session.id, event)
end
