defmodule Rho.Tools.DynReset do
  @moduledoc "Core tool: put the Dyn staging copy back to the current generation's sources (see `Rho.Tools.DynTool`)."
  @behaviour Rho.Tool

  alias Rho.Dyn
  alias Rho.Tools.DynTool

  @impl true
  def name, do: "dyn_reset"

  @impl true
  def description,
    do: "Throw away every unproposed change: staging becomes a copy of what runs now."

  @impl true
  def parameter_schema,
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(_args, ctx) do
    keeper = DynTool.keeper(ctx)

    case Dyn.stage_reset(keeper) do
      :ok ->
        n = Dyn.status(keeper).generation
        {:ok, "Staging reset to generation G#{n} (#{map_size(Dyn.staged(keeper))} files)."}

      {:error, reason} ->
        DynTool.error(reason, nil)
    end
  end

  @impl true
  def selftest do
    DynTool.with_selftest_keeper(fn ctx ->
      :ok = Dyn.stage_put("r.ex", "x", ctx.dyn)

      with :ok <-
             DynTool.expect(
               run(%{}, ctx),
               &(&1 == {:ok, "Staging reset to generation G0 (0 files)."})
             ) do
        DynTool.expect(Dyn.staged(ctx.dyn), &(&1 == %{}))
      end
    end)
  end
end
