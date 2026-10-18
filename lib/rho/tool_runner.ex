defmodule Rho.ToolRunner do
  @moduledoc """
  Runs one tool call in its own task (under a `Task.Supervisor`, not linked
  to the loop). The `before_tool_call` gate runs first, inside the task, so
  a gate that waits (a biometric approval) never blocks the loop;
  once the gate allows, the task tells the loop (`{:tool_running, pid}`),
  which starts the tool's timeout clock from then.

  The task's result is `{:ok, text}` or `{:error, text}`. A raise, exit or
  throw in the task (the gate's or the tool's) is formatted there
  (`Rho.Untrusted.format/4`) and ends the task with that text as its exit
  reason; the loop turns it, or any other abnormal end of the task (a kill,
  a linked process's exit), into an error result without running anything
  of the reason (`Rho.Untrusted.exit_text/2`). Before a
  tool runs, the registry's sources are told its task
  (`Rho.ToolRegistry.watch/2`), so a source of agent-written tools can
  count a crash or timeout (the loop kills it) against them.

  A Dyn tool's answer (`Rho.Untrusted.untrusted?/1`) is made plain data in
  the task (`Rho.Untrusted.plain/1`: structs become maps, funs text)
  before it is encoded or leaves the task, so neither the loop nor its
  subscribers ever hold a value whose protocols run Dyn code.

  A tool may answer with pictures for the model as well as text:
  `{:ok, {:images, [{mime_type, bytes}], text}}` (photos), or
  `{:ok, {:image, mime_type, bytes, text}}` for one (a screenshot). A
  picture the host already keeps (a tool that saved what it drew) may go
  by reference instead, `%{ref: ref, mime: mime_type}` (optional `:name`)
  in the `:images` list: the session stores the ref, not the bytes, and
  the host's `:resolve_attachment` hook (`Rho.Config`) gives them back
  when a request is built (`Rho.Session.tool_result/5`). One answer's
  pictures are all of one form (the two are stored apart, so a mix would
  lose their order); a mix is an error.

  And with data for the host's screens beside what the model reads (pi's
  tool result `details`): `{:ok, {:details, output, details}}`, where
  `output` is any of the above, or `{:error, {:details, reason, details}}`
  for a failure. The model and the session get `output` (or `reason`);
  `details` goes to the loop's subscribers, with `tool_execution_end`
  (`Rho.Events`), so a screen can draw the answer (a passage, a table)
  without parsing the text, and into the session only as far as the
  host's `:keep_details` (`Rho.Loop`) keeps it.
  """

  alias Rho.Tool
  alias Rho.ToolRegistry
  alias Rho.Untrusted

  @type gate :: (call :: map(), ctx :: map() -> :allow | {:block, String.t()})

  @doc "The default gate: everything is allowed."
  @spec allow_all(map(), map()) :: :allow
  def allow_all(_call, _ctx), do: :allow

  @doc """
  Starts `call` (`%{"arguments" => ...}`) of `module` as a task under
  `task_sup`, not linked: `gate` first, then the tool, with `ctx` as the
  context `c:Rho.Tool.run/2` gets. Once the gate allows, the task sends
  `loop` `{:tool_running, pid}`; it returns `to_result/1` of the tool's
  answer. This is how `Rho.Loop` runs every call.
  """
  @spec start(Supervisor.supervisor(), pid(), module(), map(), gate(), map()) :: Task.t()
  def start(task_sup, loop, module, call, gate, ctx) do
    Task.Supervisor.async_nolink(task_sup, fn ->
      try do
        case gate.(call, ctx) do
          :allow ->
            :ok = ToolRegistry.watch(self(), module)
            send(loop, {:tool_running, self()})
            call["arguments"] |> module.run(ctx) |> answer(module) |> to_result()

          {:block, reason} ->
            {:error, "Blocked before running: #{reason}"}
        end
      catch
        kind, reason -> Untrusted.crash(kind, reason, __STACKTRACE__)
      end
    end)
  end

  defp answer(value, module),
    do: if(Untrusted.untrusted?(module), do: Untrusted.plain(value), else: value)

  @type image ::
          {String.t(), binary()}
          | %{
              required(:ref) => String.t(),
              required(:mime) => String.t(),
              optional(:name) => String.t()
            }
  @type images :: {:images, [image()], String.t()}
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
    cond do
      not Enum.all?(images, &image?/1) ->
        {:error, "tool returned malformed images"}

      Enum.any?(images, &is_map/1) and Enum.any?(images, &is_tuple/1) ->
        {:error, "tool returned pictures both inline and by reference; use one form"}

      true ->
        {:ok, result}
    end
  end

  def to_result({:ok, value}), do: {:ok, to_text(value)}

  def to_result({:error, {:details, reason, details}}),
    do: {:details, {:error, to_text(reason)}, details}

  def to_result({:error, value}), do: {:error, to_text(value)}

  def to_result(other),
    do: {:error, "tool returned an unexpected value: #{inspect(other, limit: 20)}"}

  defp image?({mime, data}), do: is_binary(mime) and is_binary(data)

  defp image?(%{ref: ref, mime: mime} = image),
    do: is_binary(ref) and is_binary(mime) and is_binary(Map.get(image, :name, ""))

  defp image?(_image), do: false

  @doc """
  The error text for a tool task that ended abnormally (its `:DOWN`
  reason), in the loop's process: nothing of the reason runs
  (`Rho.Untrusted.exit_text/2`); a crash the task formatted itself reads
  as that text.
  """
  @spec crash_text(term()) :: String.t()
  def crash_text(reason), do: "Tool crashed: " <> Untrusted.exit_text(reason)

  @doc "The error text for a call killed at `module`'s timeout (`Rho.Tool.timeout_ms/1`)."
  @spec timeout_text(module()) :: String.t()
  def timeout_text(module),
    do: "Tool timed out after #{Tool.timeout_ms(module)} ms and was killed."

  @doc false
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
