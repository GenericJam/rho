defmodule Rho.Tools.DynDelete do
  @moduledoc "Core tool: delete a staged Dyn source file (see `Rho.Tools.DynTool`)."
  @behaviour Rho.Tool

  alias Rho.Dyn
  alias Rho.Tools.DynTool

  @impl true
  def name, do: "dyn_delete"

  @impl true
  def description,
    do:
      "Delete a source file of your Dyn layer from staging (takes effect with the next proposal)."

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{"path" => DynTool.path_schema()},
      "required" => ["path"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(%{"path" => path}, ctx) when is_binary(path) do
    keeper = DynTool.keeper(ctx)

    with {:ok, _} <- Dyn.stage_read(path, keeper),
         :ok <- Dyn.stage_delete(path, keeper) do
      {:ok, "Deleted #{path} from staging."}
    else
      {:error, reason} -> DynTool.error(reason, path)
    end
  end

  def run(_args, _ctx), do: {:error, "`path` is required"}

  @impl true
  def selftest do
    DynTool.with_selftest_keeper(fn ctx ->
      :ok = Dyn.stage_put("d.ex", "x", ctx.dyn)

      with :ok <-
             DynTool.expect(
               run(%{"path" => "d.ex"}, ctx),
               &(&1 == {:ok, "Deleted d.ex from staging."})
             ) do
        DynTool.expect(run(%{"path" => "d.ex"}, ctx), &match?({:error, _}, &1))
      end
    end)
  end
end
