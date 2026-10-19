defmodule Rho.Test.FakeLLM do
  @moduledoc """
  A scripted `Rho.LLM`: each model call takes the next reply from
  the script and plays its steps, streaming through the loop's sink.

  Steps: `{:text, s}`, `{:thinking, s}`, `{:tool_call, id, name, args}`,
  `{:image, mime_type, bytes}` (a picture in the reply's `:images`),
  `{:sleep, ms}`, `:block` (never returns; the loop must kill it),
  `{:error, error}` (returns it), `{:usage, map}`, `{:finish, reason}`.

  Every call sends the test `{:llm_request, request, worker_pid}`. Its
  opts are the script's agent, or `[fake: agent]` plus other options a
  loop reads from its `:llm` (`:status`, `Rho.LLM.status/1`).
  """
  @behaviour Rho.LLM

  @spec start([[term()]], pid()) :: {:ok, pid()}
  def start(script, test \\ self()),
    do: Agent.start_link(fn -> %{script: script, requests: [], test: test} end)

  @spec requests(pid()) :: [map()]
  def requests(agent), do: Agent.get(agent, & &1.requests)

  @impl true
  def stream(request, opts, sink) when is_list(opts),
    do: stream(request, Keyword.fetch!(opts, :fake), sink)

  def stream(request, agent, sink) do
    {reply, test} =
      Agent.get_and_update(agent, fn
        %{script: [reply | rest]} = st ->
          {{reply, st.test}, %{st | script: rest, requests: st.requests ++ [request]}}

        %{script: []} = st ->
          {{:exhausted, st.test}, %{st | requests: st.requests ++ [request]}}
      end)

    send(test, {:llm_request, request, self()})

    case reply do
      :exhausted ->
        {:error, {:other, "fake script exhausted"}}

      steps ->
        play(steps, sink, %{
          text: "",
          thinking: "",
          tool_calls: [],
          usage: default_usage(),
          finish_reason: :stop
        })
    end
  end

  defp play([], _sink, acc), do: {:ok, acc}

  defp play([step | rest], sink, acc) do
    case step do
      {:text, s} ->
        sink.({:text, s})
        play(rest, sink, %{acc | text: acc.text <> s})

      {:thinking, s} ->
        sink.({:thinking, s})
        play(rest, sink, %{acc | thinking: acc.thinking <> s})

      {:sleep, ms} ->
        Process.sleep(ms)
        play(rest, sink, acc)

      :block ->
        Process.sleep(:infinity)

      {:error, error} ->
        {:error, error}

      step ->
        play(rest, sink, add(step, acc))
    end
  end

  # The steps that only add to the reply.
  defp add({:tool_call, id, name, args}, acc),
    do: %{
      acc
      | tool_calls: acc.tool_calls ++ [%{"id" => id, "name" => name, "arguments" => args}]
    }

  defp add({:image, mime, bytes}, acc),
    do: Map.update(acc, :images, [{mime, bytes}], &(&1 ++ [{mime, bytes}]))

  defp add({:usage, usage}, acc), do: %{acc | usage: usage}
  defp add({:finish, reason}, acc), do: %{acc | finish_reason: reason}

  defp default_usage, do: %{input_tokens: 100, output_tokens: 20, total_cost: 0.001}
end

defmodule Rho.Test.Tools.Echo do
  @moduledoc "Test tool: returns `text` after `sleep_ms`."
  @behaviour Rho.Tool

  @impl true
  def name, do: "echo"
  @impl true
  def description, do: "Echo text back."
  @impl true
  def parameter_schema,
    do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}

  @impl true
  def run(args, _ctx) do
    Process.sleep(args["sleep_ms"] || 0)
    {:ok, args["text"] || ""}
  end
end

defmodule Rho.Test.Tools.Crash do
  @moduledoc "Test tool: raises."
  @behaviour Rho.Tool

  @impl true
  def name, do: "crash"
  @impl true
  def description, do: "Always raises."
  @impl true
  def parameter_schema, do: %{"type" => "object"}
  @impl true
  def run(_args, _ctx), do: raise("boom")
end

defmodule Rho.Test.Tools.Slow do
  @moduledoc "Test tool: outlives its 50 ms timeout."
  @behaviour Rho.Tool

  @impl true
  def name, do: "slow"
  @impl true
  def description, do: "Never finishes in time."
  @impl true
  def parameter_schema, do: %{"type" => "object"}
  @impl true
  def timeout_ms, do: 50
  @impl true
  def run(_args, _ctx) do
    Process.sleep(5_000)
    {:ok, "too late"}
  end
end

defmodule Rho.Test.Tools.Picture do
  @moduledoc "Test tool: answers with an image and a caption."
  @behaviour Rho.Tool

  @impl true
  def name, do: "picture"
  @impl true
  def description, do: "Returns a tiny image."
  @impl true
  def parameter_schema, do: %{"type" => "object"}
  @impl true
  def run(_args, _ctx), do: {:ok, {:image, "image/png", <<137, 80, 78, 71>>, "a picture"}}
end

defmodule Rho.Test.Tools.Notes do
  @moduledoc "Test tool: appends `text` to `notes.md` in the data dir."
  @behaviour Rho.Tool

  @impl true
  def name, do: "notes"
  @impl true
  def description, do: "Append a note."
  @impl true
  def parameter_schema,
    do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}

  @impl true
  def run(%{"text" => text}, ctx) do
    File.write!(Path.join(ctx.data_dir, "notes.md"), [text, ?\n], [:append])
    {:ok, "Appended."}
  end
end

defmodule Rho.Test.Tools.Details do
  @moduledoc "Test tool: answers with text for the model and data for the screens."
  @behaviour Rho.Tool

  @impl true
  def name, do: "details"
  @impl true
  def description, do: "Returns text and details."
  @impl true
  def parameter_schema, do: %{"type" => "object"}
  @impl true
  def run(%{"fail" => true}, _ctx), do: {:error, {:details, "no such verse", %{ref: "X 1:1"}}}
  def run(_args, _ctx), do: {:ok, {:details, "two verses", %{verses: [1, 2]}}}
end
