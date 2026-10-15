defmodule Rho.ToolRunner do
  @moduledoc """
  Runs one tool call in its own task (under a `Task.Supervisor`, not linked
  to the loop). The `before_tool_call` gate runs first, inside the task, so
  a gate that waits (a biometric approval) never blocks the loop;
  once the gate allows, the task tells the loop (`{:tool_running, pid}`),
  which starts the tool's timeout clock from then.

  The task's result is `{:ok, text}` or `{:error, text}`. A raise, exit or
  kill of the task is turned into an error result by the loop. Before a
  tool runs, the registry's sources are told its task
  (`Rho.ToolRegistry.watch/2`), so a source of agent-written tools can
  count a crash or timeout (the loop kills it) against them.

  A tool may answer with pictures for the model as well as text:
  `{:ok, {:images, [{mime_type, bytes}], text}}` (photos), or
  `{:ok, {:image, mime_type, bytes, text}}` for one (a screenshot).

  And with data for the host's screens beside what the model reads (pi's
  tool result `details`): `{:ok, {:details, output, details}}`, where
  `output` is any of the above. The model and the session get `output`;
  `details` goes to the loop's subscribers, with `tool_execution_end`
  (`Rho.Events`), so a screen can draw the answer (a passage, a table)
  without parsing the text, and into the session only as far as the
  host's `:keep_details` (`Rho.Loop`) keeps it.
  """

  alias Rho.Tool
  alias Rho.ToolRegistry

  @type gate :: (call :: map(), ctx :: map() -> :allow | {:block, String.t()})

  @doc "The default gate: everything is allowed."
  @spec allow_all(map(), map()) :: :allow
  def allow_all(_call, _ctx), do: :allow

  @spec start(Supervisor.supervisor(), pid(), module(), map(), gate(), map()) :: Task.t()
  def start(task_sup, loop, module, call, gate, ctx) do
    Task.Supervisor.async_nolink(task_sup, fn ->
      case gate.(call, ctx) do
        :allow ->
          :ok = ToolRegistry.watch(self(), module)
          send(loop, {:tool_running, self()})
          call["arguments"] |> module.run(ctx) |> to_result()

        {:block, reason} ->
          {:error, "Blocked before running: #{reason}"}
      end
    end)
  end

  @type images :: {:images, [{String.t(), binary()}], String.t()}
  @type result :: {:ok, String.t() | images()} | {:error, String.t()}

  @doc """
  A tool's return as the loop takes it: `{:ok, text | images}` or
  `{:error, text}`, or `{:details, result, details}` for a tool that
  answered with details (see the moduledoc).
  """
  @spec to_result(term()) :: result() | {:details, result(), term()}
  def to_result({:ok, {:details, output, details}}) do
    case to_result({:ok, output}) do
      {:details, result, _nested} -> {:details, result, details}
      result -> {:details, result, details}
    end
  end

  def to_result({:ok, {:image, mime, data, text}}),
    do: to_result({:ok, {:images, [{mime, data}], text}})

  def to_result({:ok, {:images, images, text} = result})
      when is_list(images) and is_binary(text) do
    if Enum.all?(images, &match?({mime, data} when is_binary(mime) and is_binary(data), &1)),
      do: {:ok, result},
      else: {:error, "tool returned malformed images"}
  end

  def to_result({:ok, value}), do: {:ok, to_text(value)}
  def to_result({:error, value}), do: {:error, to_text(value)}

  def to_result(other),
    do: {:error, "tool returned an unexpected value: #{inspect(other, limit: 20)}"}

  @spec crash_text(term()) :: String.t()
  def crash_text({%{__exception__: true} = e, stack}) when is_list(stack),
    do: "Tool crashed: " <> Exception.format_banner(:error, e, stack)

  def crash_text(reason), do: "Tool crashed: " <> Exception.format_exit(reason)

  @spec timeout_text(module()) :: String.t()
  def timeout_text(module),
    do: "Tool timed out after #{Tool.timeout_ms(module)} ms and was killed."

  @spec skipped_text() :: String.t()
  def skipped_text, do: "Tool was not executed because the run was stopped by the user."

  defp to_text(value) when is_binary(value), do: value

  defp to_text(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value, limit: 50, printable_limit: 4000)
    end
  end
end
