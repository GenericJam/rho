defmodule Rho.Supervisor do
  @moduledoc """
  rho's processes, for the host to start in its own tree (rho has no OTP
  application callback: a mob app starts its code by hand):

      children = [
        {Rho.Supervisor, tools: [MyApp.Tools.Search, Rho.Tools.Todo, Rho.Tools.ReadArtifact]}
      ]

  Starts, in order: `Rho.Auth` (sign-ins, token refresh), `Rho.Auth.Login`
  (the OAuth browser flow), with Dyn the approval store
  (`Rho.Dyn.Approval.Biometric`) and `Rho.Dyn.Keeper`, then
  `Rho.ToolRegistry`, `Rho.Usage`'s subscriber registry, the task
  supervisor tools run under (`Rho.TaskSup`) and the loops' supervisor
  (`Rho.LoopSup`, see `Rho.start_loop/1`).

  Options:

    * `:tools`, `:tool_sources`: `Rho.ToolRegistry`'s (default from
      `config :rho`, else `Rho.ToolRegistry.builtin_tools/0` and none)
    * `:auth`, `:login`: start options of `Rho.Auth` / `Rho.Auth.Login`
    * `:llm_catalog`: install rho's trimmed model catalog
      (`Rho.LLMCatalog.install!/0`) before anything looks a model up;
      default `true`
    * `:dyn`: start the Dyn layer (`Rho.Dyn`): `true`, or the Keeper's
      options; default `config :rho, :dyn, enabled: ...` (off,
      `Rho.Dyn.Config`). With it the registry also offers the `dyn_*`
      tools (`Rho.Dyn.Source.core_tools/0`) and the current generation's
      (`Rho.Dyn.Source`). The host still calls `Rho.Dyn.boot/1` in its
      boot, once this tree is up.
  """
  use Supervisor

  alias Rho.Dyn

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :llm_catalog, true), do: Rho.LLMCatalog.install!()
    dyn = dyn(Keyword.get_lazy(opts, :dyn, &Dyn.Config.enabled?/0))

    children =
      [
        {Rho.Auth, Keyword.get(opts, :auth, [])},
        {Rho.Auth.Login, Keyword.get(opts, :login, [])}
      ] ++
        dyn_children(dyn) ++
        [
          {Rho.ToolRegistry, registry_opts(opts, dyn)},
          Rho.Usage,
          {Task.Supervisor, name: Rho.TaskSup},
          {DynamicSupervisor, name: Rho.LoopSup, strategy: :one_for_one}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp dyn(true), do: []
  defp dyn(opts) when is_list(opts), do: opts
  defp dyn(_off), do: nil

  defp dyn_children(nil), do: []
  defp dyn_children(opts), do: [Dyn.Approval.Biometric, {Dyn.Keeper, opts}]

  defp registry_opts(opts, nil), do: Keyword.take(opts, [:tools, :tool_sources])

  defp registry_opts(opts, _dyn) do
    tools =
      Keyword.get_lazy(opts, :tools, fn ->
        Application.get_env(:rho, :tools, Rho.ToolRegistry.builtin_tools())
      end)

    sources =
      Keyword.get_lazy(opts, :tool_sources, fn -> Application.get_env(:rho, :tool_sources, []) end)

    [
      tools: Enum.uniq(tools ++ Dyn.Source.core_tools()),
      tool_sources: Enum.uniq(sources ++ [Dyn.Source])
    ]
  end
end
