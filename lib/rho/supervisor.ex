defmodule Rho.Supervisor do
  @moduledoc """
  rho's processes, for the host to start in its own tree (rho has no OTP
  application callback: a mob app starts its code by hand):

      children = [
        {Rho.Supervisor, tools: [MyApp.Tools.Search, Rho.Tools.Todo, Rho.Tools.ReadArtifact]}
      ]

  Starts, in order: `Rho.Auth` (sign-ins, token refresh), `Rho.Auth.Login`
  (the OAuth browser flow), `Rho.ToolRegistry`, `Rho.Usage`'s subscriber
  registry, the task supervisor tools run under (`Rho.TaskSup`) and the
  loops' supervisor (`Rho.LoopSup`, see `Rho.start_loop/1`).

  Options:

    * `:tools`, `:tool_sources`: `Rho.ToolRegistry`'s (default from
      `config :rho`, else `Rho.ToolRegistry.builtin_tools/0` and none)
    * `:auth`, `:login`: start options of `Rho.Auth` / `Rho.Auth.Login`
    * `:llm_catalog`: install rho's trimmed model catalog
      (`Rho.LLMCatalog.install!/0`) before anything looks a model up;
      default `true`
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :llm_catalog, true), do: Rho.LLMCatalog.install!()

    children = [
      {Rho.Auth, Keyword.get(opts, :auth, [])},
      {Rho.Auth.Login, Keyword.get(opts, :login, [])},
      {Rho.ToolRegistry, Keyword.take(opts, [:tools, :tool_sources])},
      Rho.Usage,
      {Task.Supervisor, name: Rho.TaskSup},
      {DynamicSupervisor, name: Rho.LoopSup, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
