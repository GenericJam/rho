defmodule Rho.Untrusted do
  @moduledoc """
  Text and data from code rho doesn't trust, the Dyn layer's (`Rho.Dyn`),
  for the processes it does: the loop, the Keeper, the caller of a compile
  or a selftest.

  Turning a term into text can run code the term chose:
  `Exception.message/1` calls the exception's module, and `inspect/2`,
  interpolation, `to_string/1` and `Jason.encode/1` dispatch protocols,
  which Dyn code may implement for its own structs. Run in a trusted
  process, that code could loop forever, raise, or send messages as that
  process. So:

    * `format/3` turns a caught raise, throw or exit into text **in the
      untrusted process that caught it** (a tool's task, a selftest, a
      compile), in a throwaway helper with a time and heap bound that
      never ends in a crash report and dies with its caller; if that
      fails or runs over, it falls back to describing the term;
    * `crash/3` does that and exits with `{:rho_crash, text}`, the exit
      reason a host's own untrusted processes can use so a watcher (the
      Keeper, say) reports the text as it is;
    * `describe/1` and `exit_text/1` describe any term without running
      anything of it: no protocol of its structs, no exception message
      callback (an exception's `:message` field is read as data). That is
      what a trusted process uses for a term it still receives, a `:DOWN`
      reason say. Both are total;
    * `plain/1` turns a Dyn tool's answer into plain data (no structs, no
      funs) before it leaves the task.

  Every text is valid UTF-8 and at most `max` bytes (4000 by default).

  One limit stays the host's: a Dyn process that crashes with an
  exception whose `message/1` fails in certain ways can make OTP remove
  Elixir's logger translator VM-wide (later crash logs are untranslated).
  That code runs in the Dyn process itself, never in a trusted one.
  """

  @max_bytes 4_000
  @timeout_ms 1_000
  @max_heap_mb 32
  # Integers past this print as a placeholder: turning a bignum into
  # decimal is superlinear (a 4M-bit one takes half a minute).
  @int_bound Bitwise.bsl(1, 1024)

  # The exit reason of a process that already formatted its crash itself
  # (`crash/3`): `exit_text/1` returns the text as it is.
  @crash_tag :rho_crash

  @doc """
  Is `module` untrusted code: a Dyn generation's module or a protocol
  implementation for one (`Rho.Dyn.dyn_module?/1`)?
  """
  @spec untrusted?(module()) :: boolean()
  def untrusted?(module) when is_atom(module), do: Rho.Dyn.dyn_module?(module)
  def untrusted?(_other), do: false

  @doc """
  Describes `term` without running any of its code: `inspect/2` with
  `structs: false` (a struct prints as the map it is, so no `Inspect`
  implementation runs), integers past 1024 bits as a placeholder (their
  decimal text costs seconds), cut to `max` bytes.
  """
  @spec describe(term(), pos_integer()) :: String.t()
  def describe(term, max \\ @max_bytes) do
    term
    |> inspect(
      structs: false,
      limit: 50,
      printable_limit: max,
      width: :infinity,
      inspect_fun: &bounded_inspect/2
    )
    |> cap(max)
  end

  defp bounded_inspect(int, _opts)
       when is_integer(int) and (int > @int_bound or int < -@int_bound),
       do: "#Integer<too large to print>"

  defp bounded_inspect(term, opts), do: Inspect.inspect(term, opts)

  @doc """
  Text for an exit reason (a `:DOWN` or `:EXIT` message's), without running
  any of its code: an exception with its stacktrace reads as
  `** (Module) message` and the stack (the `:message` field when it is a
  string, else the exception's fields), a reason a process formatted
  itself (`crash/3`) as that text, anything else as `describe/1` does.
  Total: any term gives a text (improper lists, odd stack entries and
  deep or huge terms are described, cut to `max`).
  """
  @spec exit_text(term(), pos_integer()) :: String.t()
  def exit_text(reason, max \\ @max_bytes) do
    exception_text(reason, max)
  catch
    _, _ -> safe_describe(reason, max)
  end

  defp exception_text({@crash_tag, text}, max) when is_binary(text), do: cap(text, max)

  defp exception_text({%{__exception__: true, __struct__: module} = exception, stack}, max)
       when is_atom(module) and is_list(stack) do
    cap("** (#{inspect(module)}) #{message_field(exception, max)}#{stack_text(stack, max)}", max)
  end

  defp exception_text(reason, max), do: describe(reason, max)

  defp safe_describe(reason, max) do
    describe(reason, max)
  catch
    _, _ -> "an exit reason rho could not describe"
  end

  @doc """
  A caught `kind, reason, stack` as text, as `Exception.format/3` writes
  it (banner and stacktrace), formatted in a throwaway helper process so
  the caller's own mailbox and state stay out of reach. The helper has a
  heap limit, never ends in a crash report and dies with its caller; if
  it fails or runs over `:timeout_ms` (#{@timeout_ms}), the term is
  described instead (as `exit_text/2` and `describe/2` do). Call it in the
  untrusted process that caught the error, never in a trusted one.
  Options: `:timeout_ms`, `:max` (bytes).
  """
  @spec format(:error | :exit | :throw, term(), Exception.stacktrace(), keyword()) :: String.t()
  def format(kind, reason, stack, opts \\ []) do
    max = Keyword.get(opts, :max, @max_bytes)

    case call(fn -> Exception.format(kind, reason, stack) end, opts) do
      {:ok, text} when is_binary(text) -> text |> String.trim_trailing() |> cap(max)
      _ -> caught_text(kind, reason, stack, max)
    end
  end

  @doc false
  # `kind, reason` as text without running any of its code (`exit_text/1`
  # for an error, `describe/1` for the rest): for a trusted process that
  # caught something it can't vouch for.
  @spec caught_text(:error | :exit | :throw, term(), Exception.stacktrace(), pos_integer()) ::
          String.t()
  def caught_text(kind, reason, stack, max \\ @max_bytes)

  def caught_text(:error, %{__exception__: true} = exception, stack, max),
    do: exit_text({exception, stack}, max)

  def caught_text(kind, reason, _stack, max),
    do: cap("** (#{kind}) " <> describe(reason, max), max)

  @doc """
  Formats the caught `kind, reason` (`format/4`) and exits with it as the
  reason (`{:rho_crash, text}`), so whoever watches this process gets the
  text, not the term: `exit_text/1` reads it back. An orderly exit
  (`:normal`, `:shutdown`, `{:shutdown, _}`) stays as it was.
  """
  @spec crash(:error | :exit | :throw, term(), Exception.stacktrace()) :: no_return()
  def crash(:exit, reason, _stack)
      when reason in [:normal, :shutdown] or
             (is_tuple(reason) and tuple_size(reason) == 2 and elem(reason, 0) == :shutdown),
      do: exit(reason)

  def crash(kind, reason, stack), do: exit({@crash_tag, format(kind, reason, stack)})

  @doc false
  # Runs `fun` in a throwaway process with a heap limit (@max_heap_mb MB)
  # and a time limit (`:timeout_ms`): `{:ok, result}`, `:error` if it
  # raised, threw, exited or was killed, `:timeout` if it ran over. The
  # helper catches everything and ends `:normal`, so no crash report (whose
  # formatting would run the term's code in the logger) is ever made; a
  # watcher kills it if the caller dies first, so the time limit holds (it
  # runs `fun` only once the watcher watches both).
  # The result is still the untrusted code's: check its shape before use.
  @spec call((-> result), keyword()) :: {:ok, result} | :error | :timeout when result: term()
  def call(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)
    caller = self()
    ref = make_ref()

    {pid, mref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: div(@max_heap_mb * 1024 * 1024, :erlang.system_info(:wordsize)),
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        receive do
          :go ->
            result =
              try do
                {:ok, fun.()}
              catch
                _, _ -> :error
              end

            send(caller, {ref, result})
        after
          # The caller died before its watcher started, or the watcher came
          # too late: the caller reads that as running over.
          timeout -> send(caller, {ref, :timeout})
        end
      end)

    watch(caller, pid)

    receive do
      {^ref, result} ->
        Process.demonitor(mref, [:flush])
        result

      {:DOWN, ^mref, :process, ^pid, _reason} ->
        :error
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^mref, :process, ^pid, _} -> :ok
        end

        # A result sent just before the kill.
        receive do
          {^ref, _} -> :ok
        after
          0 -> :ok
        end

        :timeout
    end
  end

  # Kills `helper` if `caller` dies before it ends (not a link: the
  # helper's heap-limit kill must not take the caller down), then lets the
  # helper start.
  defp watch(caller, helper) do
    spawn(fn ->
      caller_ref = Process.monitor(caller)
      helper_ref = Process.monitor(helper)
      send(helper, :go)

      receive do
        {:DOWN, ^helper_ref, :process, _, _} -> :ok
        {:DOWN, ^caller_ref, :process, _, _} -> Process.exit(helper, :kill)
      end
    end)

    :ok
  end

  @doc """
  `term` as plain data: every struct a map of its fields (without
  `__struct__` and `__exception__`), every fun its `describe/1` text,
  through lists, tuples and map keys and values. What a Dyn tool answers
  goes through it in its own task, before anything trusted touches it.
  """
  @spec plain(term()) :: term()
  def plain(%{} = map) do
    map
    |> Map.drop([:__struct__, :__exception__])
    |> Map.new(fn {k, v} -> {plain(k), plain(v)} end)
  end

  def plain(list) when is_list(list), do: plain_list(list)

  def plain(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> plain_list() |> List.to_tuple()

  def plain(fun) when is_function(fun), do: describe(fun)

  # Encoding a huge integer as JSON costs what inspecting it does.
  def plain(int) when is_integer(int) and (int > @int_bound or int < -@int_bound),
    do: "#Integer<too large to print>"

  def plain(other), do: other

  # Improper lists too.
  defp plain_list([head | tail]), do: [plain(head) | plain_list(tail)]
  defp plain_list([]), do: []
  defp plain_list(tail), do: plain(tail)

  @doc false
  # `text` cut to `max` bytes at a character boundary, invalid UTF-8
  # replaced: safe to log, encode as JSON or show.
  @spec cap(binary(), pos_integer()) :: String.t()
  def cap(text, max \\ @max_bytes)

  def cap(text, max) when is_binary(text) and byte_size(text) <= max do
    if String.valid?(text), do: text, else: text |> String.replace_invalid() |> cut(max)
  end

  def cap(text, max) when is_binary(text), do: text |> binary_part(0, max) |> cap(max)

  # `text` is valid UTF-8: cutting it can only break its last character.
  defp cut(text, max) when byte_size(text) <= max, do: text
  defp cut(text, max), do: text |> binary_part(0, max) |> whole()

  defp whole(text) do
    if String.valid?(text), do: text, else: whole(binary_part(text, 0, byte_size(text) - 1))
  end

  defp message_field(exception, max) do
    case Map.get(exception, :message) do
      message when is_binary(message) ->
        if String.valid?(message), do: cap(message, max), else: describe(message, max)

      _ ->
        exception |> Map.drop([:__struct__, :__exception__]) |> describe(max)
    end
  end

  # At most 20 entries; an improper tail ends the walk and is described.
  defp stack_text(stack, max), do: stack_lines(stack, 20, max, [])

  defp stack_lines([entry | rest], left, max, acc) when left > 0,
    do: stack_lines(rest, left - 1, max, ["\n    " <> stack_entry(entry, max) | acc])

  defp stack_lines(tail, _left, max, acc) when tail != [] and not is_list(tail),
    do: ["\n    " <> describe(tail, max) | acc] |> Enum.reverse() |> Enum.join()

  defp stack_lines(_rest, _left, _max, acc), do: acc |> Enum.reverse() |> Enum.join()

  # Only well-formed entries go through `Exception.format_stacktrace_entry/1`,
  # with the arguments reduced to their count (formatting them would inspect
  # them); anything else is described.
  defp stack_entry({module, fun, args, location} = entry, max)
       when is_atom(module) and is_atom(fun) and is_list(location) do
    with {:ok, arity} <- arity(args),
         true <- location?(location) do
      Exception.format_stacktrace_entry({module, fun, arity, location})
    else
      _ -> describe(entry, max)
    end
  end

  defp stack_entry({fun, args, location} = entry, max)
       when is_function(fun) and is_list(location) do
    with {:ok, arity} <- arity(args),
         true <- location?(location) do
      Exception.format_stacktrace_entry({fun, arity, location})
    else
      _ -> describe(entry, max)
    end
  end

  defp stack_entry(entry, max), do: describe(entry, max)

  defp arity(args) when is_list(args) do
    if proper_list?(args), do: {:ok, length(args)}, else: :error
  end

  defp arity(arity) when is_integer(arity) and arity in 0..255, do: {:ok, arity}
  defp arity(_args), do: :error

  defp location?(location) do
    proper_list?(location) and
      Enum.all?(location, fn
        {:file, file} -> is_list(file) and proper_list?(file) and List.ascii_printable?(file)
        {:line, line} -> is_integer(line) and line in 0..0xFFFFFFFF
        {:column, column} -> is_integer(column) and column in 0..0xFFFFFFFF
        {:error_info, _} -> true
        _ -> false
      end)
  end

  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?([]), do: true
  defp proper_list?(_), do: false
end
