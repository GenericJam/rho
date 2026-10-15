defmodule Rho do
  @moduledoc """
  An agent core for Elixir apps: pi-agent-core's loop (`Rho.Loop`), omp/pi
  JSONL sessions (`Rho.Session`), compaction, tools, and model sign-in
  (subscription OAuth or API keys, `Rho.Auth`) on req_llm.

  A host starts `Rho.Supervisor` in its own supervision tree, then a loop
  per session with `start_loop/1`. What a host can (or on a phone, must)
  provide is in `Rho.Config`.
  """

  alias Rho.Session

  @doc """
  Starts a loop under `Rho.Supervisor`'s loop supervisor. `opts` are
  `Rho.Loop.start_link/1`'s; without `:session`, a new session in
  `Rho.Session.dir/0` on `opts[:model]` (default
  `Rho.Config.default_model/0`), in the data dir.
  """
  @spec start_loop(keyword()) :: DynamicSupervisor.on_start_child()
  def start_loop(opts \\ []) do
    opts =
      if Keyword.has_key?(opts, :session) do
        opts
      else
        model = Keyword.get_lazy(opts, :model, &Rho.Config.default_model/0)
        dir = Rho.Config.data_dir()
        Keyword.merge([session: Session.new(Session.dir(), model, dir), entries: []], opts)
      end

    DynamicSupervisor.start_child(Rho.LoopSup, {Rho.Loop, Keyword.delete(opts, :model)})
  end

  @doc "The system prompt a loop uses when neither it nor `config :rho, :system_prompt` sets one."
  @spec default_system_prompt() :: String.t()
  def default_system_prompt do
    "You are a helpful assistant. Use tools when they help; never invent tool results. " <>
      "Be brief."
  end
end
