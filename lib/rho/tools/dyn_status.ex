defmodule Rho.Tools.DynStatus do
  @moduledoc "Core tool: what the Dyn layer runs, what's pending, and its recent crash reports (see `Rho.Tools.DynTool`)."
  @behaviour Rho.Tool

  alias Rho.Dyn
  alias Rho.Tools.DynTool

  @events 10

  @impl true
  def name, do: "dyn_status"

  @impl true
  def description do
    "Show your Dyn layer's state: the generation that runs and its status (probation or " <>
      "proven), safe mode, the proposal waiting for the human, and the last #{@events} events " <>
      "(crash reports, reverts) to fix from."
  end

  @impl true
  def parameter_schema,
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(_args, ctx) do
    keeper = DynTool.keeper(ctx)

    case Dyn.status(keeper) do
      %{mode: :off} ->
        DynTool.error(:not_running, nil)

      status ->
        lines = [
          running(status),
          pending(status, keeper),
          DynTool.staging_line(keeper),
          events(Dyn.log(@events, keeper))
        ]

        {:ok, Enum.join(lines, "\n")}
    end
  end

  defp running(%{generation: n, status: status, parent: parent, mode: mode}) do
    parent = if parent, do: ", parent G#{parent}", else: ""

    mode =
      if mode == :safe,
        do: " SAFE MODE: the last launches failed, so no Dyn code is loaded.",
        else: ""

    "Running generation G#{n} (#{status}#{parent}).#{mode}"
  end

  defp pending(%{pending: nil}, _keeper), do: "No proposal is waiting."

  defp pending(%{pending: n}, keeper) do
    rationale =
      case Dyn.generation(n, keeper) do
        {:ok, gen} -> ": " <> gen.rationale
        {:error, _} -> ""
      end

    "Proposal G#{n} waits for the human's approval#{rationale}"
  end

  defp events([]), do: "No recent events."

  defp events(entries) do
    rows =
      Enum.map(entries, fn e ->
        parts = [
          e[:at],
          e[:type],
          e[:gen] && "G#{e[:gen]}",
          e[:from] && "from G#{e[:from]}",
          e[:to] && "to G#{e[:to]}",
          e[:module],
          e[:reason]
        ]

        "- " <> (parts |> Enum.filter(& &1) |> Enum.map_join(" ", &to_string/1))
      end)

    Enum.join(["Recent events (oldest first):" | rows], "\n")
  end

  @impl true
  def selftest do
    DynTool.with_selftest_keeper(fn ctx ->
      DynTool.expect(
        run(%{}, ctx),
        &match?({:ok, "Running generation G0 (proven).\nNo proposal is waiting." <> _}, &1)
      )
    end)
  end
end
