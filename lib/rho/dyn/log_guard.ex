defmodule Rho.Dyn.LogGuard do
  @moduledoc """
  A primary `:logger` filter that keeps Dyn code out of the processes that
  log for others.

  A plain process that dies with an error is reported by the emulator, and
  that report is formatted in OTP's `:logger_proxy`: Elixir's translator
  calls the exception's `message/1` there and inspects the reason. A Dyn
  process (`spawn(fn -> raise MyError end)`) would so get its own code run
  in a process every crash report of the VM goes through. This filter runs
  before the translator and, for any log event that holds a struct of a
  Dyn module (`Rho.Untrusted.untrusted?/1`), replaces the message with its
  `Rho.Untrusted.describe/2` text and keeps only the metadata that holds
  no Dyn term. It reads terms as data (no protocol of any struct runs) and
  looks at most 10,000 terms of an event; a bigger event is let through
  unchecked. The Keeper installs it when it starts.

  Best effort, like `Rho.Dyn.Check`: it lowers the chance that a Dyn
  process's crash takes a logger process down; it does not stop code that
  sets out to reach the logger (a `report_cb` sent to `:logger_proxy` as a
  raw message, a filter added after this one, Logger restarted without it).
  """

  alias Rho.Untrusted

  @id :rho_dyn_terms
  # Terms looked at per event; an event bigger than this is let through.
  @budget 10_000

  @doc "Installs the filter (once; a second call is a no-op)."
  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(@id, {&__MODULE__.filter/2, nil}) do
      :ok -> :ok
      {:error, {:already_exist, @id}} -> :ok
    end
  end

  @doc false
  # The filter: the event as it is, or with a described message.
  def filter(%{msg: msg, meta: meta} = event, _arg) do
    if scan({msg, meta}) == :dyn, do: described(event), else: event
  catch
    _, _ ->
      %{
        event
        | msg: {:string, "(a log event rho could not check)"},
          meta: Map.take(meta, [:time, :pid, :gl, :domain])
      }
  end

  def filter(event, _arg), do: event

  defp described(%{msg: msg} = event) do
    text = "(a log event held a Dyn term) " <> Untrusted.describe(msg, 4_000)

    meta =
      for {k, v} <- event.meta, k != :report_cb, scan({k, v}) == :clean, into: %{}, do: {k, v}

    %{event | msg: {:string, text}, meta: meta}
  end

  # :clean, :dyn (holds a Dyn struct), or :over (too big to look through
  # within the budget; let through as it is).
  defp scan(term) do
    case walk(term, @budget) do
      :dyn -> :dyn
      left when left > 0 -> :clean
      _ -> :over
    end
  end

  # Remaining budget, or :dyn on a Dyn struct. Maps (structs too) are
  # walked with a map iterator: no protocol of a struct runs, and a big map
  # is never copied whole.
  defp walk(_term, left) when left <= 0, do: 0

  defp walk(%{__struct__: module} = map, left) when is_atom(module) do
    if Untrusted.untrusted?(module), do: :dyn, else: walk_iter(:maps.iterator(map), left - 1)
  end

  defp walk(%{} = map, left), do: walk_iter(:maps.iterator(map), left - 1)
  defp walk([head | tail], left), do: walk_pair(head, tail, left - 1)
  defp walk(tuple, left) when is_tuple(tuple) and tuple_size(tuple) >= left, do: 0
  defp walk(tuple, left) when is_tuple(tuple), do: walk(Tuple.to_list(tuple), left - 1)
  defp walk(_term, left), do: left - 1

  defp walk_iter(_iter, left) when left <= 0, do: 0

  defp walk_iter(iter, left) do
    case :maps.next(iter) do
      :none ->
        left

      {k, v, next} ->
        case walk_pair(k, v, left) do
          :dyn -> :dyn
          left -> walk_iter(next, left)
        end
    end
  end

  defp walk_pair(a, b, left) do
    case walk(a, left) do
      :dyn -> :dyn
      left -> walk(b, left)
    end
  end
end
