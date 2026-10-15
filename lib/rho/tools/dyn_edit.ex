defmodule Rho.Tools.DynEdit do
  @moduledoc "Core tool: replace one exact, unique piece of a staged Dyn source file (see `Rho.Tools.DynTool`)."
  @behaviour Rho.Tool

  alias Rho.Dyn
  alias Rho.Tools.DynTool

  @impl true
  def name, do: "dyn_edit"

  @impl true
  def description do
    "Edit a staged Dyn source file: replace `old_text` (which must occur exactly once, " <>
      "whitespace included) with `new_text`. Read the file with dyn_read first."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => DynTool.path_schema(),
        "old_text" => %{"type" => "string", "description" => "Exact text to replace."},
        "new_text" => %{"type" => "string", "description" => "Its replacement."}
      },
      "required" => ["path", "old_text", "new_text"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(%{"path" => path, "old_text" => old, "new_text" => new}, ctx)
      when is_binary(path) and is_binary(old) and old != "" and is_binary(new) do
    keeper = DynTool.keeper(ctx)

    # One read-modify-write: parallel edits of the same file both land.
    edit = fn source ->
      with {:ok, _at} <- unique(source, old, path), do: {:ok, String.replace(source, old, new)}
    end

    case Dyn.stage_update(path, edit, keeper) do
      {:ok, source} ->
        {:ok, at} = unique(source, old, path)
        {:ok, "Edited #{path} at line #{line_of(source, at)}."}

      {:error, text} when is_binary(text) ->
        {:error, text}

      {:error, reason} ->
        DynTool.error(reason, path)
    end
  end

  def run(_args, _ctx), do: {:error, "`path`, a non-empty `old_text` and `new_text` are required"}

  defp unique(source, old, path) do
    case :binary.matches(source, old) do
      [{at, _len}] ->
        {:ok, at}

      [] ->
        {:error,
         "old_text was not found in #{path} (0 matches). dyn_read it and copy the text exactly, " <>
           "whitespace included."}

      matches ->
        {:error,
         "old_text matches #{length(matches)} times in #{path}. Include more surrounding lines " <>
           "so it matches exactly once."}
    end
  end

  defp line_of(source, at),
    do: (source |> binary_part(0, at) |> :binary.matches("\n") |> length()) + 1

  @impl true
  def selftest do
    DynTool.with_selftest_keeper(fn ctx ->
      :ok = Dyn.stage_put("e.ex", "a\nb\nb\n", ctx.dyn)

      edit = fn old, new ->
        run(%{"path" => "e.ex", "old_text" => old, "new_text" => new}, ctx)
      end

      with :ok <- DynTool.expect(edit.("a", "x"), &(&1 == {:ok, "Edited e.ex at line 1."})),
           :ok <-
             DynTool.expect(
               edit.("b", "y"),
               &match?({:error, "old_text matches 2 times" <> _}, &1)
             ),
           :ok <-
             DynTool.expect(
               edit.("zz", "y"),
               &match?({:error, "old_text was not found" <> _}, &1)
             ) do
        DynTool.expect(Dyn.stage_read("e.ex", ctx.dyn), &(&1 == {:ok, "x\nb\nb\n"}))
      end
    end)
  end
end
