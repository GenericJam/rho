defmodule Rho.Tools.DynFiles do
  @moduledoc "Core tool: list the Dyn layer's staged source files (see `Rho.Tools.DynTool`)."
  @behaviour Rho.Tool

  alias Rho.Dyn
  alias Rho.Tools.DynTool

  @impl true
  def name, do: "dyn_files"

  @impl true
  def description do
    "List the source files of your Dyn layer (your own tools and screens) in the staging " <>
      "copy, with sizes, and whether staging differs from what runs."
  end

  @impl true
  def parameter_schema,
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(_args, ctx) do
    keeper = DynTool.keeper(ctx)

    if Dyn.status(keeper).mode == :off do
      DynTool.error(:not_running, nil)
    else
      {:ok, listing(Dyn.staged(keeper)) <> "\n" <> DynTool.staging_line(keeper)}
    end
  end

  defp listing(files) when map_size(files) == 0,
    do: "Staging is empty: no Dyn sources yet. Create one with dyn_write."

  defp listing(files) do
    rows =
      for {path, source} <- Enum.sort(files) do
        lines = source |> String.split("\n") |> length()
        "#{path}  #{byte_size(source)} bytes, #{lines} lines"
      end

    Enum.join(["#{map_size(files)} staged files:" | rows], "\n")
  end

  @impl true
  def selftest do
    DynTool.with_selftest_keeper(fn ctx ->
      with :ok <- DynTool.expect(run(%{}, ctx), &match?({:ok, "Staging is empty" <> _}, &1)),
           :ok <- Dyn.stage_put("a.ex", "x\n", ctx.dyn) do
        DynTool.expect(run(%{}, ctx), &match?({:ok, "1 staged files:\na.ex  2 bytes" <> _}, &1))
      end
    end)
  end
end
