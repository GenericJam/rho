defmodule Rho.Tool do
  @moduledoc """
  A tool the agent can call. Implementations are plain modules, so a host
  can register one at runtime by module, or serve changing sets of them
  from a source (see `Rho.ToolRegistry`).

  `run/2` gets the decoded JSON arguments (string keys) and a context map
  (`:session_id`, `:call_id`, `:data_dir`; from a loop also `:loop`, its
  pid, and `:withheld`, the tool names that loop doesn't offer, so read it
  with `Map.get(ctx, :withheld, [])`). It returns `{:ok, output}` or
  `{:error, reason}`; non-binary values are JSON-encoded (or inspected) for
  the model. Pictures, and data for the host's screens beside the text
  (`{:ok, {:details, output, details}}`), are `Rho.ToolRunner`'s. A raise,
  exit or timeout becomes an error result; it never takes the loop down.

  **Untrusted tools.** The loop reads a tool's declaration (`name/0`,
  `description/0`, `parameter_schema/0`, `timeout_ms/0`,
  `concurrency/0`) in its own process. A Dyn tool's
  (`Rho.Untrusted.untrusted?/1`) is read instead once per module, in a
  throwaway process with a time and heap bound (`Rho.Untrusted.call/2`),
  checked to be plain data and kept (`info/1`): one whose name,
  description or schema raises, runs over or isn't a string / JSON
  Schema map is left out of what the loop offers (logged once), and a
  bad `timeout_ms/0` or `concurrency/0` means the default.
  """

  require Logger

  alias Rho.Untrusted

  @callback name() :: String.t()
  @callback description() :: String.t()
  @doc "JSON Schema (string keys) of the arguments object."
  @callback parameter_schema() :: map()
  @callback run(args :: map(), ctx :: map()) :: {:ok, term()} | {:error, term()}
  @doc "Checks the tool works, without side effects outside a temp dir."
  @callback selftest() :: :ok | {:error, term()}
  @doc "Per-call timeout; default `default_timeout_ms/0`."
  @callback timeout_ms() :: pos_integer()
  @doc """
  How a call shares its turn with the reply's other calls (omp's tool
  `concurrency`). `:parallel` (the default) runs alongside them;
  `:exclusive` is for a tool that acts on or reads something only one
  call may touch at a time (the front's one screen): a turn with any
  exclusive call runs all its calls one at a time, in the model's order.
  """
  @callback concurrency() :: :parallel | :exclusive

  @optional_callbacks selftest: 0, timeout_ms: 0, concurrency: 0

  @default_timeout_ms 30_000

  @typedoc "A tool's declaration, as `info/1` reads it."
  @type info :: %{
          name: String.t(),
          description: String.t(),
          parameter_schema: map(),
          timeout_ms: pos_integer(),
          concurrency: :parallel | :exclusive
        }

  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @spec timeout_ms(module()) :: pos_integer()
  def timeout_ms(module) do
    if Untrusted.untrusted?(module) do
      case info(module) do
        {:ok, info} -> info.timeout_ms
        :error -> @default_timeout_ms
      end
    else
      if function_exported?(module, :timeout_ms, 0),
        do: module.timeout_ms(),
        else: @default_timeout_ms
    end
  end

  @doc """
  `module`'s `concurrency/0`, or `:parallel`. The loop asks it in its own
  process, so anything but `:exclusive`, a raise included, is `:parallel`.
  """
  @spec concurrency(module()) :: :parallel | :exclusive
  def concurrency(module) do
    if Untrusted.untrusted?(module) do
      case info(module) do
        {:ok, info} -> info.concurrency
        :error -> :parallel
      end
    else
      own_concurrency(module)
    end
  end

  defp own_concurrency(module) do
    if function_exported?(module, :concurrency, 0) and module.concurrency() == :exclusive,
      do: :exclusive,
      else: :parallel
  catch
    _, _ -> :parallel
  end

  @doc """
  The name the loop offers `module` under: its `name/0`, or for an
  untrusted tool `info/1`'s, nil when that failed (the tool is left out).
  """
  @spec offered_name(module()) :: String.t() | nil
  def offered_name(module) do
    if Untrusted.untrusted?(module) do
      case info(module) do
        {:ok, info} -> info.name
        :error -> nil
      end
    else
      module.name()
    end
  end

  @doc """
  `module`'s declaration. A trusted module's callbacks are called as they
  are; an untrusted one's are read once in a bounded throwaway process and
  kept (see the moduledoc): `:error` when its name, description or schema
  failed.
  """
  @spec info(module()) :: {:ok, info()} | :error
  def info(module) do
    if Untrusted.untrusted?(module) do
      key = {__MODULE__, module}

      case :persistent_term.get(key, nil) do
        nil ->
          info = read_untrusted(module)
          :persistent_term.put(key, info)
          info

        info ->
          info
      end
    else
      {:ok,
       %{
         name: module.name(),
         description: module.description(),
         parameter_schema: module.parameter_schema(),
         timeout_ms: timeout_ms(module),
         concurrency: concurrency(module)
       }}
    end
  end

  @doc """
  Drops what `info/1` kept of `modules` (the Dyn compiler calls it when it
  unloads them).
  """
  @spec forget([module()]) :: :ok
  def forget(modules) do
    for module <- modules, do: :persistent_term.erase({__MODULE__, module})
    :ok
  end

  defp read_untrusted(module) do
    declared =
      Untrusted.call(fn ->
        {name, description, schema} =
          {module.name(), module.description(), module.parameter_schema()}

        # What the loop will build from it must build.
        _ = req_llm_tool(name, description, schema)
        {name, description, schema}
      end)

    case declared do
      {:ok, {name, description, schema}}
      when is_binary(name) and is_binary(description) and is_map(schema) ->
        if String.valid?(name) and String.valid?(description) and json?(schema) do
          {:ok,
           %{
             name: name,
             description: description,
             parameter_schema: schema,
             timeout_ms: untrusted_timeout(module),
             concurrency: untrusted_concurrency(module)
           }}
        else
          left_out(module)
        end

      _ ->
        left_out(module)
    end
  end

  defp left_out(module) do
    Logger.warning(
      "[tool] #{inspect(module)} is left out: its name/0, description/0 or " <>
        "parameter_schema/0 raised, ran over, or didn't return a string / a JSON Schema map"
    )

    :error
  end

  defp untrusted_timeout(module) do
    with true <- function_exported?(module, :timeout_ms, 0),
         {:ok, ms} when is_integer(ms) and ms > 0 <- Untrusted.call(&module.timeout_ms/0) do
      ms
    else
      _ -> @default_timeout_ms
    end
  end

  defp untrusted_concurrency(module) do
    with true <- function_exported?(module, :concurrency, 0),
         {:ok, :exclusive} <- Untrusted.call(&module.concurrency/0) do
      :exclusive
    else
      _ -> :parallel
    end
  end

  # JSON-able plain data: no structs, tuples, funs, pids.
  defp json?(%{__struct__: _}), do: false
  defp json?(%{} = map), do: Enum.all?(map, fn {k, v} -> json_key?(k) and json?(v) end)
  defp json?(list) when is_list(list), do: Enum.all?(list, &json?/1)
  defp json?(text) when is_binary(text), do: String.valid?(text)
  defp json?(value), do: is_number(value) or is_atom(value)

  defp json_key?(key) when is_binary(key), do: String.valid?(key)
  defp json_key?(key), do: is_atom(key)

  @doc "Is `module` a loaded tool (exports the required callbacks)?"
  @spec tool?(module()) :: boolean()
  def tool?(module) do
    Code.ensure_loaded?(module) and
      Enum.all?([name: 0, description: 0, parameter_schema: 0, run: 2], fn {f, a} ->
        function_exported?(module, f, a)
      end)
  end

  @doc """
  The req_llm declaration sent to the model. Execution never goes through
  req_llm's callback: the loop runs tools itself (in parallel, gated,
  with timeouts). An untrusted tool's comes from `info/1` (call it only
  for a tool `offered_name/1` names).
  """
  @spec to_req_llm(module()) :: ReqLLM.Tool.t()
  def to_req_llm(module) do
    {:ok, info} = info(module)
    req_llm_tool(info.name, info.description, info.parameter_schema)
  end

  defp req_llm_tool(name, description, schema) do
    ReqLLM.Tool.new!(
      name: name,
      description: description,
      parameter_schema: schema,
      callback: fn _args -> {:error, :executed_by_rho_loop} end
    )
  end
end
