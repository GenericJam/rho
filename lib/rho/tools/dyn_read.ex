defmodule Rho.Tools.DynRead do
  @moduledoc "Core tool: read a staged Dyn source file with line numbers (see `Rho.Tools.DynTool`)."
  @behaviour Rho.Tool

  alias Rho.Dyn
  alias Rho.Tools.DynTool

  @default_limit 400

  @impl true
  def name, do: "dyn_read"

  @impl true
  def description do
    "Read a staged source file of your Dyn layer, with line numbers. `offset` is the first " <>
      "line (1-based, default 1), `limit` the number of lines (default #{@default_limit})."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => DynTool.path_schema(),
        "offset" => %{"type" => "integer", "minimum" => 1},
        "limit" => %{"type" => "integer", "minimum" => 1}
      },
      "required" => ["path"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(%{"path" => path} = args, ctx) when is_binary(path) do
    offset = positive(args["offset"], 1)
    limit = positive(args["limit"], @default_limit)

    case Dyn.stage_read(path, DynTool.keeper(ctx)) do
      {:ok, source} -> {:ok, numbered(source, offset, limit)}
      {:error, reason} -> DynTool.error(reason, path)
    end
  end

  def run(_args, _ctx), do: {:error, "`path` is required"}

  defp numbered(source, offset, limit) do
    lines = String.split(source, "\n")
    total = length(lines)
    shown = lines |> Enum.drop(offset - 1) |> Enum.take(limit)
    last = offset + length(shown) - 1
    width = total |> Integer.to_string() |> byte_size()

    body =
      shown
      |> Enum.with_index(offset)
      |> Enum.map_join("\n", fn {line, n} ->
        String.pad_leading(Integer.to_string(n), width) <> "| " <> line
      end)

    cond do
      shown == [] -> "(no lines from #{offset}; the file has #{total})"
      offset == 1 and last == total -> body
      true -> body <> "\n(lines #{offset}-#{last} of #{total})"
    end
  end

  defp positive(n, _default) when is_integer(n) and n > 0, do: n
  defp positive(_n, default), do: default

  @impl true
  def selftest do
    DynTool.with_selftest_keeper(fn ctx ->
      :ok = Dyn.stage_put("a.ex", "one\ntwo\nthree", ctx.dyn)

      with :ok <-
             DynTool.expect(
               run(%{"path" => "a.ex"}, ctx),
               &(&1 == {:ok, "1| one\n2| two\n3| three"})
             ),
           :ok <-
             DynTool.expect(
               run(%{"path" => "a.ex", "offset" => 2, "limit" => 1}, ctx),
               &(&1 == {:ok, "2| two\n(lines 2-2 of 3)"})
             ) do
        DynTool.expect(run(%{"path" => "b.ex"}, ctx), &match?({:error, _}, &1))
      end
    end)
  end
end
