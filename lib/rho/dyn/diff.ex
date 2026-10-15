defmodule Rho.Dyn.Diff do
  @moduledoc """
  Unified diff (as `diff -u` and git print it, three lines of context) between
  two source sets `%{relative_path => source}`: what the approval card and
  the rescue screen show for a generation.
  """

  @context 3

  @spec unified(%{String.t() => String.t()}, %{String.t() => String.t()}) :: String.t()
  def unified(old, new) do
    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map_join(&file(&1, Map.get(old, &1), Map.get(new, &1)))
  end

  defp file(_path, same, same), do: ""

  defp file(path, old, new) do
    from = if old, do: "a/" <> path, else: "/dev/null"
    to = if new, do: "b/" <> path, else: "/dev/null"
    "--- #{from}\n+++ #{to}\n" <> hunks(lines(old), lines(new))
  end

  defp lines(nil), do: []

  defp lines(text) do
    case String.split(text, "\n") do
      [""] -> []
      parts -> if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
    end
  end

  # Each op carries the old/new line counts consumed before it, so a hunk's
  # header comes from its first op.
  defp hunks(old, new) do
    ops =
      old
      |> List.myers_difference(new)
      |> Enum.flat_map(fn {kind, lines} -> Enum.map(lines, &{kind, &1}) end)
      |> number()

    ops
    |> Enum.with_index()
    |> Enum.reject(fn {{kind, _, _, _}, _} -> kind == :eq end)
    |> Enum.map(&elem(&1, 1))
    |> ranges(length(ops))
    |> Enum.map_join(fn {first, last} -> hunk(Enum.slice(ops, first..last//1)) end)
  end

  defp number(ops) do
    {numbered, _} =
      Enum.map_reduce(ops, {0, 0}, fn {kind, line}, {o, n} ->
        next =
          case kind do
            :eq -> {o + 1, n + 1}
            :del -> {o + 1, n}
            :ins -> {o, n + 1}
          end

        {{kind, line, o, n}, next}
      end)

    numbered
  end

  # Changed op indexes → [{first, last}] windows with context, merged when
  # they touch.
  defp ranges(changed, count) do
    changed
    |> Enum.map(&{max(&1 - @context, 0), min(&1 + @context, count - 1)})
    |> Enum.reduce([], fn
      {first, last}, [{f, l} | rest] when first <= l + 1 -> [{f, max(l, last)} | rest]
      range, acc -> [range | acc]
    end)
    |> Enum.reverse()
  end

  defp hunk([{_, _, o, n} | _] = ops) do
    old_count = Enum.count(ops, fn {kind, _, _, _} -> kind != :ins end)
    new_count = Enum.count(ops, fn {kind, _, _, _} -> kind != :del end)
    old_start = if old_count == 0, do: o, else: o + 1
    new_start = if new_count == 0, do: n, else: n + 1

    body =
      Enum.map_join(ops, fn
        {:eq, line, _, _} -> " " <> line <> "\n"
        {:del, line, _, _} -> "-" <> line <> "\n"
        {:ins, line, _, _} -> "+" <> line <> "\n"
      end)

    "@@ -#{old_start},#{old_count} +#{new_start},#{new_count} @@\n" <> body
  end
end
