defmodule Rho.Test.LoopHelpers do
  @moduledoc "Starting a loop on a scripted fake LLM, and collecting its events."

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Rho.Loop
  alias Rho.Session
  alias Rho.Test.FakeLLM

  @model "anthropic:claude-haiku-4-5"

  def model, do: @model

  @doc """
  Starts a subscribed loop in a fresh session under `dir`. Returns `%{loop,
  llm, session, dir}`. `:llm_opts` go to the fake with its script
  (`[fake: llm] ++ llm_opts`), as a loop's `:llm` options would.
  """
  def start_loop(dir, script, opts \\ []) do
    {:ok, llm} = FakeLLM.start(script)
    sup = start_supervised!(Task.Supervisor, id: make_ref())

    {session, entries} =
      Keyword.get_lazy(opts, :session, fn -> {Session.new(dir, @model, dir), []} end)

    loop_opts =
      [
        session: session,
        entries: entries,
        llm: llm_spec(llm, opts[:llm_opts]),
        tools: [
          Rho.Test.Tools.Echo,
          Rho.Test.Tools.Crash,
          Rho.Test.Tools.Slow,
          Rho.Test.Tools.Picture,
          Rho.Test.Tools.Notes
        ],
        task_supervisor: sup,
        data_dir: dir,
        system_prompt: "test",
        retry_base_ms: 1
      ] ++ Keyword.drop(opts, [:session, :llm_opts])

    loop = start_supervised!({Loop, loop_opts}, id: make_ref())
    :ok = Loop.subscribe(loop)
    %{loop: loop, llm: llm, session: session, dir: dir}
  end

  defp llm_spec(llm, nil), do: {FakeLLM, llm}
  defp llm_spec(llm, opts), do: {FakeLLM, [fake: llm] ++ opts}

  @doc "Events up to and including `agent_end`."
  def collect(timeout \\ 2_000), do: collect([], timeout)

  defp collect(acc, timeout) do
    receive do
      {:rho, _sid, %{type: :agent_end} = e} -> Enum.reverse([e | acc])
      {:rho, _sid, e} -> collect([e | acc], timeout)
    after
      timeout ->
        flunk("no agent_end; events so far: #{inspect(Enum.map(Enum.reverse(acc), & &1.type))}")
    end
  end

  @doc "Waits for the next event of `type` (discarding others)."
  def await_event(type, timeout \\ 2_000) do
    receive do
      {:rho, _sid, %{type: ^type} = e} -> e
      {:rho, _sid, _other} -> await_event(type, timeout)
    after
      timeout -> flunk("no #{type} event")
    end
  end

  @doc "Event types, with the message role for message_* events."
  def shape(events) do
    Enum.map(events, fn
      %{type: t, entry: %{"message" => %{"role" => role}}}
      when t in [:message_start, :message_end] ->
        {t, role}

      %{type: t, entry: %{"type" => "custom_message"}} when t in [:message_start, :message_end] ->
        {t, "custom"}

      %{type: t} ->
        t
    end)
  end

  def message(entry), do: entry["message"]
end
