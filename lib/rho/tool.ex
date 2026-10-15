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
  """

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

  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @spec timeout_ms(module()) :: pos_integer()
  def timeout_ms(module) do
    if function_exported?(module, :timeout_ms, 0),
      do: module.timeout_ms(),
      else: @default_timeout_ms
  end

  @doc """
  `module`'s `concurrency/0`, or `:parallel`. The loop asks it in its own
  process, so anything but `:exclusive`, a raise included, is `:parallel`.
  """
  @spec concurrency(module()) :: :parallel | :exclusive
  def concurrency(module) do
    if function_exported?(module, :concurrency, 0) and module.concurrency() == :exclusive,
      do: :exclusive,
      else: :parallel
  catch
    _, _ -> :parallel
  end

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
  with timeouts).
  """
  @spec to_req_llm(module()) :: ReqLLM.Tool.t()
  def to_req_llm(module) do
    ReqLLM.Tool.new!(
      name: module.name(),
      description: module.description(),
      parameter_schema: module.parameter_schema(),
      callback: fn _args -> {:error, :executed_by_rho_loop} end
    )
  end
end
