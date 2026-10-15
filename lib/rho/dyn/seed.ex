defmodule Rho.Dyn.Seed do
  @moduledoc """
  The seed: the Dyn sources an install starts from, which the host ships
  (Operator's default front: a welcome screen, a component library, the
  front's settings). The host embeds them at build time
  (`Application.app_dir/2` can't resolve priv/ on the device) and hands them
  to `start/2`.

  `start/2` installs it in the background after the launch's Dyn step
  (`Rho.Dyn.seed/3`): compiling a big seed whole takes about half a minute
  on a Moto G 2021. The seed becomes a generation like any other, so its
  screens are the agent's to change, and reverting to that generation
  restores the defaults.

  **A newer seed on a phone that has one** (an app update that changed
  the seed). The install records each seed file's sha256 as it shipped
  (`Rho.Dyn.Store.seed_files/1`). When this build's seed differs, it is
  installed again, merged three ways with what runs now (`merge/3`): a
  seed file the user (or the agent) never changed is replaced by the new
  one (or removed, when the new seed dropped it); a new seed file is added
  unless the user already has a file at that path; a file the user
  changed, deleted or wrote stays exactly as it is. So user edits are never
  lost, at the price that an edited seed file doesn't get the update
  (reverting to the seed's generation, or asking the agent, does). The
  merged generation goes through the whole check, compile and selftest; if
  it fails (an edited file relies on something the new seed changed),
  nothing changes and that seed is recorded as rejected, so it isn't
  retried every launch; the next app update with a different seed tries
  again. An install that recorded nothing (an older app's) is taken to have
  shipped the `:legacy` digests, if the host has them (Operator 1.0's);
  the seed generation's own sources can't stand in for them, since that
  install merged the user's files into it.
  """

  alias Rho.Dyn
  alias Rho.Dyn.Registry
  alias Rho.Dyn.Store

  require Logger

  @rationale "The default sources (the seed)"

  @doc "Each file's sha256 (hex), as `needed/3` and the seed's record compare them."
  @spec digests(%{String.t() => String.t()}) :: %{String.t() => String.t()}
  def digests(sources), do: Map.new(sources, fn {path, source} -> {path, sha256(source)} end)

  @doc "Is the seed being installed right now?"
  @spec running?() :: boolean()
  def running?, do: Process.whereis(__MODULE__) != nil

  @doc """
  What the Dyn store at `dir` needs for a seed whose files have `digests`:
  `:install` (no seed yet), `{:update, shipped}` (an older seed is
  installed; `shipped` its files' digests as they shipped, `legacy` when it
  recorded none) or `:none` (this seed, or this seed was rejected there).
  """
  @spec needed(Path.t(), %{String.t() => String.t()}, %{String.t() => String.t()}) ::
          :install | {:update, %{String.t() => String.t()}} | :none
  def needed(dir, digests, legacy \\ %{}) do
    case Store.seed(dir) do
      nil ->
        :install

      _n ->
        record = Store.seed_files(dir)
        shipped = record.files || legacy

        cond do
          shipped == digests -> :none
          record.rejected == version(digests) -> :none
          true -> {:update, shipped}
        end
    end
  end

  @doc """
  The sources to install: `seed` over `current` (what runs now), given
  `shipped` (path => sha256 of the seed files as the installed seed shipped
  them; `%{}` for a first install). See the moduledoc for the rules.
  """
  @spec merge(
          %{String.t() => String.t()},
          %{String.t() => String.t()},
          %{String.t() => String.t()}
        ) :: %{String.t() => String.t()}
  def merge(current, shipped, seed) do
    [current, shipped, seed]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn path, acc ->
      case pick(Map.get(current, path), Map.get(shipped, path), Map.get(seed, path)) do
        nil -> acc
        source -> Map.put(acc, path, source)
      end
    end)
  end

  # Unchanged since it shipped: the new seed's (nil: dropped).
  defp pick(current, shipped, new) when is_binary(current) and is_binary(shipped) do
    if sha256(current) == shipped, do: new, else: current
  end

  # A seed file the user deleted stays deleted.
  defp pick(nil, shipped, _new) when is_binary(shipped), do: nil
  # The user's own file wins over a new seed file at its path.
  defp pick(current, nil, _new) when is_binary(current), do: current
  defp pick(nil, nil, new), do: new

  @doc """
  Installs (or updates) the seed `sources` in a process of its own
  (registered under this module's name) unless it's current, or can't be
  now (safe mode, a proposal pending: the next launch tries again). When it
  ends, `:notify` runs (the host's front redraws). Options: `:keeper`
  (`Rho.Dyn.Keeper`), `:notify` (a 0-arity function, default none),
  `:rationale`, `:legacy` (see `needed/3`).
  """
  @spec start(%{String.t() => String.t()}, keyword()) :: {:ok, pid()} | :ignore
  def start(sources, opts \\ []) do
    keeper = Keyword.get(opts, :keeper, Dyn.Keeper)
    notify = Keyword.get(opts, :notify, fn -> :ok end)
    digests = digests(sources)

    with false <- running?(),
         {:ok, %{dir: dir}} <- Registry.config(keeper),
         need when need != :none <- needed(dir, digests, Keyword.get(opts, :legacy, %{})),
         %{mode: :normal, pending: nil} <- Dyn.status(keeper) do
      shipped = if match?({:update, _}, need), do: elem(need, 1), else: %{}

      job = %{
        keeper: keeper,
        dir: dir,
        sources: sources,
        digests: digests,
        shipped: shipped,
        rationale: Keyword.get(opts, :rationale, @rationale)
      }

      # Registered before it starts, so running?/0 says so from now on.
      {:ok, pid} = Task.start(fn -> receive(do: (:go -> install(job, notify))) end)
      Process.register(pid, __MODULE__)
      send(pid, :go)
      {:ok, pid}
    else
      _ -> :ignore
    end
  end

  defp install(job, notify) do
    # After a Core update the current generation rebuilds first: the seed
    # goes on top of it, and one compile at a time is all a phone manages.
    :ok = Dyn.await_rebuild(job.keeper)
    merge = &merge(&1, job.shipped, job.sources)
    {us, result} = :timer.tc(fn -> Dyn.seed(merge, job.rationale, job.keeper) end)
    ms = div(us, 1000)

    case result do
      {:ok, n} ->
        record(job.dir, job.digests, nil)
        Logger.info("[dyn] seed installed as generation #{n} in #{ms} ms")

      # Everything it would change is the user's: nothing to install.
      {:error, :no_changes} ->
        record(job.dir, job.digests, nil)
        Logger.info("[dyn] seed is current (the user's files kept)")

      {:error, %{stage: stage} = rejection} ->
        # Not retried until a different seed ships; the old one keeps running.
        record(job.dir, Store.seed_files(job.dir).files, version(job.digests))
        Logger.error("[dyn] seed rejected at #{stage}: #{inspect(rejection, limit: 20)}")

      {:error, reason} ->
        Logger.error("[dyn] seed not installed: #{inspect(reason, limit: 20)}")
    end

    # Unregistered first: the front, redrawing, mustn't see it still running.
    Process.unregister(__MODULE__)
    notify.()
  end

  defp record(dir, files, rejected) do
    case Store.put_seed_files(dir, files, rejected) do
      :ok -> :ok
      {:error, e} -> Logger.error("[dyn] can't record the seed's files: #{inspect(e)}")
    end
  end

  defp version(digests),
    do:
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(Enum.sort(digests)))
      |> Base.encode16(case: :lower)

  defp sha256(source), do: :sha256 |> :crypto.hash(source) |> Base.encode16(case: :lower)
end
