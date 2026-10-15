defmodule Rho.Dyn.Source do
  @moduledoc """
  The Dyn layer as a `Rho.ToolRegistry.Source`: the current generation's
  tools, read from the Keeper's registry table on every call, so an
  activation or a revert (by hand, or automatic) changes the tools the
  loop offers from its next model call. Every tool call's task is handed
  to the Keeper first (`watch/2`), so a Dyn tool's crash, or the kill at
  its timeout, counts against its generation.

  `Rho.Supervisor` adds it to the registry's sources when Dyn is enabled
  (`Rho.Dyn.Config`); a host starting the registry itself lists it in
  `:tool_sources`. It reads the app's Keeper (`Rho.Dyn.Keeper`).
  """
  @behaviour Rho.ToolRegistry.Source

  alias Rho.Dyn

  @impl true
  def tools, do: Dyn.tools()

  @impl true
  def lookup(name), do: Dyn.lookup({:tool, name})

  @impl true
  def watch(pid, module), do: Dyn.watch(pid, module)

  @doc """
  The core tools that edit and propose the Dyn layer (`dyn_*`), which a
  host offers with it. There is deliberately none that activates or
  reverts: those take the human's approval.
  """
  @spec core_tools() :: [module()]
  def core_tools do
    [
      Rho.Tools.DynFiles,
      Rho.Tools.DynRead,
      Rho.Tools.DynWrite,
      Rho.Tools.DynEdit,
      Rho.Tools.DynCopy,
      Rho.Tools.DynDelete,
      Rho.Tools.DynReset,
      Rho.Tools.DynPropose,
      Rho.Tools.DynStatus
    ]
  end
end
