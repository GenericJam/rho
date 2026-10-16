defmodule Rho.Dyn.Registry do
  @moduledoc """
  Reads the Dyn registry: one ETS table owned (and only written) by
  `Rho.Dyn.Keeper`, named like the Keeper. It maps logical names
  to the current generation's modules:

    * `{:tool, "weather"}` (a tool's `c:Rho.Tool.name/0`),
    * `{:screen, "Notes"}` (the module name below `Dyn.`),
    * `{:module, "Helpers"}` (anything else).

  The whole mapping is one row, `{:generation, n, entries}`, so a switch
  of generations is a single insert: a reader sees the old set or the new
  one, never a mix. Other rows: `{:mode, :booting | :normal | :safe}`,
  `{:rebuilding, n}` while the launch rebuilds generation `n` for a new
  Core in the background (its entries are empty until it loads), and
  `{:config, map}` (the Keeper's data dir and options, for
  `Rho.Dyn`).

  Every read takes the table (the Keeper's name, `Rho.Dyn.Keeper` for the
  app's) and answers sensibly while no Keeper runs (no Dyn layer).
  `Rho.Dyn` wraps the common reads with the app's Keeper as default.
  """

  @type key :: {:tool | :screen | :module, String.t()}

  @doc "The current generation's module for `key`; `:error` when it has none."
  @spec lookup(key(), atom()) :: {:ok, module()} | :error
  def lookup(key, table), do: Map.fetch(entries(table), key)

  @doc "The current generation's `{name, module}` of `kind`, sorted by name."
  @spec all(:tool | :screen | :module, atom()) :: [{String.t(), module()}]
  def all(kind, table) do
    for {{^kind, name}, mod} <- Enum.sort(entries(table)), do: {name, mod}
  end

  @doc "The current generation's number; 0 when none is loaded."
  @spec generation(atom()) :: non_neg_integer()
  def generation(table) do
    case read(table, :generation) do
      [{:generation, n, _}] -> n
      [] -> 0
    end
  end

  @doc "The current generation's whole mapping, `%{key => module}` (empty when none)."
  @spec entries(atom()) :: %{key() => module()}
  def entries(table) do
    case read(table, :generation) do
      [{:generation, _, entries}] -> entries
      [] -> %{}
    end
  end

  @doc "The Keeper's mode: `:booting`, `:normal`, `:safe` (no Dyn code loaded), or `:off` (no Keeper)."
  @spec mode(atom()) :: :off | :booting | :normal | :safe
  def mode(table) do
    case read(table, :mode) do
      [{:mode, mode}] -> mode
      [] -> :off
    end
  end

  @doc "The generation this launch is rebuilding for a new Core, or nil."
  @spec rebuilding(atom()) :: pos_integer() | nil
  def rebuilding(table) do
    case read(table, :rebuilding) do
      [{:rebuilding, n}] -> n
      [] -> nil
    end
  end

  @doc """
  The Keeper's config: `:dir` (its data dir, `Rho.Dyn.Store`'s root),
  `:keeper`, `:approval`, `:build` and `:rebuild_timeout_ms`;
  `{:error, :not_running}` without a Keeper.
  """
  @spec config(atom()) :: {:ok, map()} | {:error, :not_running}
  def config(table) do
    case read(table, :config) do
      [{:config, config}] -> {:ok, config}
      [] -> {:error, :not_running}
    end
  end

  # No table: no Keeper (or one restarting).
  defp read(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> []
  end
end
