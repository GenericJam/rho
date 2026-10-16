defmodule Rho.Tool do
  @moduledoc """
  A tool the agent can call. Implementations are plain modules, so a host
  can register one at runtime by module, or serve changing sets of them
  from a source (see `Rho.ToolRegistry`).

  `c:run/2` gets the decoded JSON arguments (string keys) and a context map
  (`:session_id`, `:call_id`, `:data_dir`; from a loop also `:loop`, its
  pid, and `:withheld`, the tool names that loop doesn't offer, so read it
  with `Map.get(ctx, :withheld, [])`). It returns `{:ok, output}` or
  `{:error, reason}`; non-binary values are JSON-encoded (or inspected) for
  the model. Pictures, and data for the host's screens beside the text
  (`{:ok, {:details, output, details}}`), are `Rho.ToolRunner`'s. A raise,
  exit or timeout becomes an error result; it never takes the loop down.

  **Untrusted tools.** The loop reads a tool's declaration (`c:name/0`,
  `c:description/0`, `c:parameter_schema/0`, `c:timeout_ms/0`,
  `c:concurrency/0`) in its own process. A Dyn tool's
  (`Rho.Untrusted.untrusted?/1`) is read instead in one throwaway process
  with a time and heap bound, checked to be plain data and kept for the
  module's life: one whose name, description or schema raises or isn't a
  string / JSON Schema map is left out of what the loop offers (logged
  once), and a bad `c:timeout_ms/0` or `c:concurrency/0` means the default. A
  read that runs over (a busy phone) leaves the tool out for now and is
  tried again after 1, 5 and 30 minutes; after that it stays out.
  """

  require Logger

  alias Rho.Untrusted

  # When a read that ran over is tried again: after each of these, then never.
  @retries_ms [60_000, 300_000, 1_800_000]
  @max_timeout_ms 86_400_000
  @int_bound Bitwise.bsl(1, 1024)

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

  @typedoc "A tool's declaration: its callbacks' answers, checked."
  @type info :: %{
          name: String.t(),
          description: String.t(),
          parameter_schema: map(),
          timeout_ms: pos_integer(),
          concurrency: :parallel | :exclusive
        }

  @doc "The per-call timeout of a tool without `c:timeout_ms/0` (30 000 ms)."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc """
  `module`'s per-call timeout: its `c:timeout_ms/0`, else
  `default_timeout_ms/0`. A Dyn tool's comes from its checked declaration.
  """
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
  `module`'s `c:concurrency/0`, or `:parallel`. The loop asks it in its own
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

  @doc false
  # The name the loop offers `module` under: its `name/0`, or for an
  # untrusted tool `info/1`'s, nil when that failed (the tool is left out).
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

  @doc false
  # `module`'s declaration. A trusted module's callbacks are called as they
  # are; an untrusted one's are read in a bounded throwaway process and
  # kept (see the moduledoc): `:error` when its name, description or schema
  # failed, or (for now) when the read ran over.
  @spec info(module()) :: {:ok, info()} | :error
  def info(module) do
    if Untrusted.untrusted?(module) do
      untrusted_info({__MODULE__, module}, module)
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

  defp untrusted_info(key, module) do
    case :persistent_term.get(key, nil) do
      nil ->
        read_and_keep(key, module, @retries_ms)

      {:retry_after, at, left} ->
        retry(System.monotonic_time(:millisecond) >= at, key, module, left)

      info ->
        info
    end
  end

  defp retry(true, key, module, left), do: read_and_keep(key, module, left)
  defp retry(false, _key, _module, _left), do: :error

  defp read_and_keep(key, module, retries) do
    case {read_untrusted(module), retries} do
      {:timeout, [wait | left]} ->
        left_out(module, "ran over; it is read again in #{div(wait, 60_000)} min")

        :persistent_term.put(
          key,
          {:retry_after, System.monotonic_time(:millisecond) + wait, left}
        )

        :error

      {:timeout, []} ->
        left_out(module, "ran over again; it stays out")
        :persistent_term.put(key, :error)
        :error

      {info, _} ->
        :persistent_term.put(key, info)
        info
    end
  end

  @doc false
  # Drops what `info/1` kept of `modules` (the Dyn compiler calls it when
  # it unloads them).
  @spec forget([module()]) :: :ok
  def forget(modules) do
    for module <- modules, do: :persistent_term.erase({__MODULE__, module})
    :ok
  end

  # One bounded read of all five callbacks: `:timeout` if it ran over.
  defp read_untrusted(module) do
    declared =
      Untrusted.call(fn ->
        {name, description, schema} =
          {module.name(), module.description(), module.parameter_schema()}

        # What the loop will build from it must build.
        _ = req_llm_tool(name, description, schema)
        {name, description, schema, timeout_of(module), concurrency_of(module)}
      end)

    case declared do
      {:ok, {name, description, schema, timeout, concurrency}}
      when is_binary(name) and is_binary(description) and is_map(schema) ->
        if String.valid?(name) and String.valid?(description) and json?(schema) do
          {:ok,
           %{
             name: name,
             description: description,
             parameter_schema: schema,
             timeout_ms: timeout,
             concurrency: concurrency
           }}
        else
          left_out(module, "didn't return a string / a JSON Schema map")
          :error
        end

      :timeout ->
        :timeout

      _ ->
        left_out(module, "raised or didn't return a string / a JSON Schema map")
        :error
    end
  end

  # In the helper: the optional callbacks' answers, the default if absent,
  # failing or out of range.
  defp timeout_of(module) do
    ms = optional(module, :timeout_ms)
    if ms in 1..@max_timeout_ms//1, do: ms, else: @default_timeout_ms
  end

  defp concurrency_of(module),
    do: if(optional(module, :concurrency) == :exclusive, do: :exclusive, else: :parallel)

  defp optional(module, fun) do
    if function_exported?(module, fun, 0), do: apply(module, fun, [])
  catch
    _, _ -> nil
  end

  defp left_out(module, why) do
    Logger.warning(
      "[tool] #{inspect(module)} is left out: its name/0, description/0 or " <>
        "parameter_schema/0 " <> why
    )
  end

  # JSON-able plain data: no structs, tuples, funs, pids; proper lists only.
  defp json?(%{__struct__: _}), do: false
  defp json?(%{} = map), do: Enum.all?(map, fn {k, v} -> json_key?(k) and json?(v) end)
  defp json?([head | tail]), do: json?(head) and (tail == [] or (is_list(tail) and json?(tail)))
  defp json?([]), do: true
  defp json?(text) when is_binary(text), do: String.valid?(text)
  # Integers bounded (as `Rho.Untrusted` bounds them): encoding a huge one
  # for every request would cost seconds.
  defp json?(value) when is_integer(value),
    do: value <= @int_bound and value >= -@int_bound

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
  The req_llm declaration sent to the model, nil for an untrusted tool
  whose declaration failed (it isn't offered). Execution never goes
  through req_llm's callback: the loop runs tools itself (in parallel,
  gated, with timeouts).
  """
  @spec to_req_llm(module()) :: ReqLLM.Tool.t() | nil
  def to_req_llm(module) do
    case info(module) do
      {:ok, info} -> req_llm_tool(info.name, info.description, info.parameter_schema)
      :error -> nil
    end
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
