defmodule Rho.Tools.DynTool do
  @moduledoc """
  What the `dyn_*` Core tools share: the agent edits its Dyn layer's
  staging copy and proposes it (`Rho.Dyn`). There is deliberately
  no tool to activate or revert: those need the human's approval (the screen lock).

  The tools act on the app's Keeper, or on `ctx[:dyn]` (a Keeper name; the
  selftests use their own Keeper on a temp dir, `with_selftest_keeper/1`).
  """

  alias Rho.Dyn
  alias Rho.Dyn.Keeper

  @selftest_keeper Rho.Tools.DynTool.SelftestKeeper

  @doc "The Keeper the tools act on."
  @spec keeper(map()) :: atom()
  def keeper(ctx), do: Map.get(ctx, :dyn, Keeper)

  @doc "The `path` argument's JSON Schema."
  @spec path_schema() :: map()
  def path_schema do
    %{
      "type" => "string",
      "description" =>
        "Relative source path in staging, ending in .ex, e.g. `weather.ex` or `tools/weather.ex`."
    }
  end

  @doc "A tool error for `Rho.Dyn`'s staging errors."
  @spec error(term(), String.t() | nil) :: {:error, String.t()}
  def error(:bad_path, _path),
    do:
      {:error,
       "bad path: use a relative path ending in .ex whose parts are letters, digits and _, " <>
         "e.g. weather.ex or tools/weather.ex"}

  def error(:not_found, path), do: {:error, "#{path} is not in staging (see dyn_files)"}
  def error(:not_running, _path), do: {:error, "the Dyn layer isn't running"}
  def error(other, _path), do: {:error, inspect(other)}

  @doc "Does staging differ from the current generation's sources?"
  @spec staging_line(atom()) :: String.t()
  def staging_line(keeper) do
    n = Dyn.status(keeper).generation

    if Dyn.staged(keeper) == Dyn.sources(n, keeper),
      do: "Staging matches what runs (generation G#{n}).",
      else: "Staging has changes against generation G#{n} that aren't proposed yet."
  end

  @doc """
  Runs `fun.(ctx)` against a fresh Keeper on a temp dir (no generation, Core
  approval refusing everything), for the tools' selftests.
  """
  @spec with_selftest_keeper((map() -> result)) :: result when result: term()
  def with_selftest_keeper(fun) do
    dir = Path.join(System.tmp_dir!(), "rho-dyn-tool-selftest")
    File.rm_rf!(dir)

    {:ok, pid} =
      Keeper.start_link(
        name: @selftest_keeper,
        dir: dir,
        approval: Rho.Dyn.Approval.Biometric,
        # Its launches aren't the app's: they never end an update's probation.
        on_stable: nil
      )

    try do
      _ = Keeper.boot(@selftest_keeper)
      fun.(%{dyn: @selftest_keeper, data_dir: dir})
    after
      GenServer.stop(pid)
      File.rm_rf!(dir)
    end
  end

  @doc "`:ok` if `result` matches, else `{:error, result}` (for selftests)."
  @spec expect(term(), (term() -> boolean())) :: :ok | {:error, term()}
  def expect(result, ok?), do: if(ok?.(result), do: :ok, else: {:error, result})
end
