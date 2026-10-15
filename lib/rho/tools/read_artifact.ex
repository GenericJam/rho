defmodule Rho.Tools.ReadArtifact do
  @moduledoc """
  Core tool: read a page of a tool output that was too big to give whole
  (`Rho.Artifacts`). A page stays under the output budget, so
  reading never spills again.
  """
  @behaviour Rho.Tool

  alias Rho.Artifacts

  @default_limit 200
  @page_bytes 12 * 1024

  @impl true
  def name, do: "read_artifact"

  @impl true
  def description do
    "Read lines of a tool output that was cut because it was too long " <>
      "(the cut output names it: artifact://<id>). offset is the first line (1-based), " <>
      "limit the number of lines (default #{@default_limit}); a page ends early at about " <>
      "#{div(@page_bytes, 1024)} KiB and says where to continue."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "description" => "The artifact id from artifact://<id>."},
        "offset" => %{"type" => "integer", "minimum" => 1},
        "limit" => %{"type" => "integer", "minimum" => 1}
      },
      "required" => ["id"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(%{"id" => id} = args, ctx) when is_binary(id) do
    offset = positive(args["offset"], 1)
    limit = positive(args["limit"], @default_limit)

    with {:ok, path} <- Artifacts.find(ctx.data_dir, ctx.session_id, id),
         {:ok, text} <- File.read(path) do
      {:ok, page(String.split(text, "\n"), offset, limit)}
    else
      {:error, :not_found} -> {:error, "no artifact #{inspect(id)} in this session"}
      {:error, reason} -> {:error, "could not read the artifact: #{:file.format_error(reason)}"}
    end
  end

  def run(_args, _ctx), do: {:error, "read_artifact needs an `id`"}

  defp page(lines, offset, _limit) when offset > length(lines),
    do: "(the artifact has #{length(lines)} lines; offset #{offset} is past the end)"

  defp page(lines, offset, limit) do
    total = length(lines)
    wanted = lines |> Enum.drop(offset - 1) |> Enum.take(limit)
    {taken, _bytes} = take_bytes(wanted, [], 0)
    last = offset + length(taken) - 1

    footer =
      if last < total,
        do: "\n[lines #{offset}-#{last} of #{total}; continue with offset #{last + 1}]",
        else: "\n[lines #{offset}-#{last} of #{total}; end]"

    Enum.join(taken, "\n") <> footer
  end

  # At least one line, then lines while the page stays under @page_bytes
  # (a single huge line is cut).
  defp take_bytes([], acc, bytes), do: {Enum.reverse(acc), bytes}

  defp take_bytes([line | rest], [], 0) when byte_size(line) > @page_bytes,
    do: take_bytes(rest, [binary_part(line, 0, @page_bytes) <> " […line cut]"], @page_bytes)

  defp take_bytes([line | rest], acc, bytes) do
    size = byte_size(line) + 1

    if acc != [] and bytes + size > @page_bytes,
      do: {Enum.reverse(acc), bytes},
      else: take_bytes(rest, [line | acc], bytes + size)
  end

  defp positive(n, _default) when is_integer(n) and n > 0, do: n
  defp positive(_n, default), do: default

  @impl true
  def selftest do
    dir =
      Path.join(
        System.tmp_dir!(),
        "rho-artifact-selftest-#{System.unique_integer([:positive])}"
      )

    try do
      big = Enum.map_join(1..5_000, "\n", &"line #{&1}")
      cut = Artifacts.limit(big, dir, "s", "c1")

      with true <- cut =~ "artifact://c1",
           {:ok, page} <-
             run(%{"id" => "c1", "offset" => 4_999}, %{data_dir: dir, session_id: "s"}),
           true <- page =~ "line 5000" do
        :ok
      else
        other -> {:error, "selftest failed: #{inspect(other)}"}
      end
    after
      File.rm_rf(dir)
    end
  end
end
