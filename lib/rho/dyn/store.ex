defmodule Rho.Dyn.Store do
  @moduledoc """
  The Dyn layer on disk, under one root dir (`<data dir>/dyn` by default,
  `Rho.Config.data_dir/0`):

      gens/<n>/src/**/*.ex     the generation's full source set, as the agent
                               wrote it (logical `Dyn.*` names)
      gens/<n>/ebin/*.beam     the compiled, selftested binaries
                               (versioned `Dyn.G<n>.*` names)
      gens/<n>/manifest.json   a `Rho.Dyn.Generation`
      gens/<n>/diff.patch      unified diff against the parent's sources
      current                  the active generation's number (0, or no
                               file: no Dyn layer)
      staging/src/**/*.ex      where edits go before a proposal
      boot.json                launch markers: `boot_attempts` (launches since
                               the last one that reached stable) and `stable`
      log.jsonl                crash, revert and safe-mode reports
      seed                     the generation the seed (the default sources
                               the host ships, `Rho.Dyn.Seed`) was last installed as
      seed.json                what that install was built from: each seed
                               file's sha256 as shipped (`files`), and the
                               digest of a newer seed that was rejected
                               (`rejected`), so it isn't retried every launch

  Everything that decides what runs (`current`, manifests, `boot.json`) is
  written to a temp file and renamed over the old one, so a crash mid-write
  leaves the old file.

  `Rho.Dyn`, `Rho.Dyn.Keeper`, `Rho.Dyn.Compiler` and `Rho.Dyn.Seed` read
  and write it; hosts read Dyn state through `Rho.Dyn` instead. Every
  function takes the root dir first.
  """

  alias Rho.Dyn.Generation

  @log_keep 200
  @log_max_bytes 256 * 1024

  @doc "The default root dir: `dyn` under `Rho.Config.data_dir/0`."
  @spec default_root() :: Path.t()
  def default_root, do: Path.join(Rho.Config.data_dir(), "dyn")

  # ── the current pointer ──

  @doc "The active generation's number; 0 when there is none (or the pointer is unreadable)."
  @spec current(Path.t()) :: non_neg_integer()
  def current(root) do
    with {:ok, text} <- File.read(Path.join(root, "current")),
         {n, ""} when n >= 0 <- Integer.parse(String.trim(text)) do
      n
    else
      _ -> 0
    end
  end

  @doc "Points `current` at generation `n` (0: no Dyn layer)."
  @spec put_current(Path.t(), non_neg_integer()) :: :ok | {:error, term()}
  def put_current(root, n) when is_integer(n) and n >= 0,
    do: write_atomic(Path.join(root, "current"), Integer.to_string(n))

  # ── the seed ──

  @doc "The generation the seed was installed as, or nil before it was."
  @spec seed(Path.t()) :: pos_integer() | nil
  def seed(root) do
    with {:ok, text} <- File.read(Path.join(root, "seed")),
         {n, ""} when n > 0 <- Integer.parse(String.trim(text)) do
      n
    else
      _ -> nil
    end
  end

  @doc "Records that the seed was installed as generation `n`."
  @spec put_seed(Path.t(), pos_integer()) :: :ok | {:error, term()}
  def put_seed(root, n) when is_integer(n) and n > 0,
    do: write_atomic(Path.join(root, "seed"), Integer.to_string(n))

  @doc """
  The seed's record (`seed.json`): `files`, each seed file's sha256 as it
  shipped in the install's seed (nil when an older app installed it and
  didn't record them), and `rejected`, the digest of a seed whose install
  failed its check, compile or selftests.
  """
  @spec seed_files(Path.t()) :: %{
          files: %{String.t() => String.t()} | nil,
          rejected: String.t() | nil
        }
  def seed_files(root) do
    with {:ok, json} <- File.read(Path.join(root, "seed.json")),
         {:ok, %{} = map} <- Jason.decode(json) do
      files = map["files"]
      rejected = map["rejected"]

      %{
        files: if(is_map(files), do: files),
        rejected: if(is_binary(rejected), do: rejected)
      }
    else
      _ -> %{files: nil, rejected: nil}
    end
  end

  @doc "Writes the seed's record (`seed.json`, see `seed_files/1`)."
  @spec put_seed_files(Path.t(), %{String.t() => String.t()} | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def put_seed_files(root, files, rejected) do
    File.mkdir_p!(root)
    json = Jason.encode!(%{files: files, rejected: rejected})
    write_atomic(Path.join(root, "seed.json"), json)
  end

  # ── generations ──

  @doc "Reserves the next generation number by creating its directory."
  @spec allocate(Path.t()) :: pos_integer()
  def allocate(root) do
    File.mkdir_p!(gens_dir(root))
    n = Enum.max(numbers(root), fn -> 0 end) + 1

    case File.mkdir(gen_dir(root, n)) do
      :ok -> n
      {:error, :eexist} -> allocate(root)
    end
  end

  @doc "Every generation with a readable manifest, newest first, then generation 0."
  @spec generations(Path.t()) :: [Generation.t()]
  def generations(root) do
    stored =
      for n <- Enum.sort(numbers(root), :desc),
          {:ok, gen} <- [generation(root, n)],
          do: gen

    stored ++ [Generation.empty()]
  end

  @doc "Generation `n`'s manifest; generation 0 is `Rho.Dyn.Generation.empty/0`."
  @spec generation(Path.t(), non_neg_integer()) :: {:ok, Generation.t()} | {:error, :not_found}
  def generation(_root, 0), do: {:ok, Generation.empty()}

  def generation(root, n) do
    with {:ok, json} <- File.read(manifest_path(root, n)),
         {:ok, %{} = map} <- Jason.decode(json) do
      {:ok, Generation.from_json(map)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Writes generation `gen.n`'s manifest."
  @spec put_generation(Path.t(), Generation.t()) :: :ok | {:error, term()}
  def put_generation(root, %Generation{n: n} = gen) when n > 0,
    do: write_atomic(manifest_path(root, n), Jason.encode!(Generation.to_json(gen), pretty: true))

  @doc "Reads generation `n`, applies `fun`, writes the result back."
  @spec update_generation(Path.t(), pos_integer(), (Generation.t() -> Generation.t())) ::
          {:ok, Generation.t()} | {:error, term()}
  def update_generation(root, n, fun) do
    with {:ok, gen} <- generation(root, n),
         gen = fun.(gen),
         :ok <- put_generation(root, gen),
         do: {:ok, gen}
  end

  # ── sources, binaries, diffs ──

  @doc "Generation `n`'s sources as `%{relative_path => source}`."
  @spec sources(Path.t(), non_neg_integer()) :: %{String.t() => String.t()}
  def sources(_root, 0), do: %{}
  def sources(root, n), do: read_tree(src_dir(root, n))

  @doc "Writes generation `n`'s sources (`%{relative_path => source}`)."
  @spec put_sources(Path.t(), pos_integer(), %{String.t() => String.t()}) :: :ok
  def put_sources(root, n, sources), do: write_tree(src_dir(root, n), sources)

  @doc "Generation `n`'s source dir (compile diagnostics point into it)."
  @spec src_dir(Path.t(), pos_integer()) :: Path.t()
  def src_dir(root, n), do: Path.join(gen_dir(root, n), "src")

  @doc "Writes generation `n`'s compiled binaries."
  @spec put_beams(Path.t(), pos_integer(), [{module(), binary()}]) :: :ok
  def put_beams(root, n, beams) do
    dir = Path.join(gen_dir(root, n), "ebin")
    File.mkdir_p!(dir)
    Enum.each(beams, fn {mod, bin} -> File.write!(Path.join(dir, "#{mod}.beam"), bin) end)
  end

  @doc "Generation `n`'s stored binaries (the module name comes from each binary)."
  @spec beams(Path.t(), pos_integer()) :: [{module(), binary()}]
  def beams(root, n) do
    for path <- Path.wildcard(Path.join([gen_dir(root, n), "ebin", "*.beam"])),
        bin <- [File.read!(path)],
        {:ok, {mod, _}} <- [:beam_lib.chunks(bin, [])],
        do: {mod, bin}
  end

  @doc """
  Generation `n`'s compile dependencies (`Rho.Dyn.Reuse`), or nil
  if it has none recorded (built before they were, or unreadable): then
  nothing of it is reused.
  """
  @spec deps(Path.t(), non_neg_integer()) :: map() | nil
  def deps(_root, 0), do: nil

  def deps(root, n) do
    with {:ok, json} <- File.read(Path.join(gen_dir(root, n), "deps.json")),
         {:ok, %{"files" => %{}, "refs" => %{}} = deps} <- Jason.decode(json) do
      deps
    else
      _ -> nil
    end
  end

  @doc "Writes generation `n`'s compile dependencies (see `deps/2`)."
  @spec put_deps(Path.t(), pos_integer(), map()) :: :ok
  def put_deps(root, n, deps),
    do: File.write!(Path.join(gen_dir(root, n), "deps.json"), Jason.encode!(deps))

  @doc "Writes generation `n`'s diff against its parent."
  @spec put_diff(Path.t(), pos_integer(), String.t()) :: :ok
  def put_diff(root, n, text), do: File.write!(Path.join(gen_dir(root, n), "diff.patch"), text)

  @doc "Generation `n`'s unified diff against its parent; `\"\"` when there is none."
  @spec diff(Path.t(), non_neg_integer()) :: String.t()
  def diff(_root, 0), do: ""

  def diff(root, n) do
    case File.read(Path.join(gen_dir(root, n), "diff.patch")) do
      {:ok, text} -> text
      {:error, _} -> ""
    end
  end

  # ── staging ──

  @doc "The staged sources as `%{relative_path => source}`."
  @spec staged(Path.t()) :: %{String.t() => String.t()}
  def staged(root), do: read_tree(staging_dir(root))

  @doc "Has staging been set up (it is created from the current generation once)?"
  @spec staging?(Path.t()) :: boolean()
  def staging?(root), do: File.dir?(staging_dir(root))

  @doc "One staged source; `rel` must pass `valid_rel/1`."
  @spec stage_read(Path.t(), String.t()) :: {:ok, String.t()} | {:error, :bad_path | :not_found}
  def stage_read(root, rel) do
    with {:ok, rel} <- valid_rel(rel) do
      case File.read(Path.join(staging_dir(root), rel)) do
        {:ok, source} -> {:ok, source}
        {:error, _} -> {:error, :not_found}
      end
    end
  end

  @doc "Replaces the staging copy with `sources` (normally the current generation's)."
  @spec reset_staging(Path.t(), %{String.t() => String.t()}) :: :ok
  def reset_staging(root, sources) do
    File.rm_rf!(staging_dir(root))
    File.mkdir_p!(staging_dir(root))
    write_tree(staging_dir(root), sources)
  end

  @doc "Writes (creates or replaces) one staged source; `rel` must pass `valid_rel/1`."
  @spec stage_put(Path.t(), String.t(), String.t()) :: :ok | {:error, :bad_path}
  def stage_put(root, rel, source) when is_binary(source) do
    with {:ok, rel} <- valid_rel(rel) do
      path = Path.join(staging_dir(root), rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
    end
  end

  @doc "Creates a staging source only when `rel` does not already exist."
  @spec stage_create(Path.t(), String.t(), String.t()) ::
          :ok | {:error, :bad_path | :exists | File.posix()}
  def stage_create(root, rel, source) when is_binary(source) do
    with {:ok, rel} <- valid_rel(rel) do
      path = Path.join(staging_dir(root), rel)
      File.mkdir_p!(Path.dirname(path))

      case File.open(path, [:write, :exclusive], &IO.binwrite(&1, source)) do
        {:ok, :ok} -> :ok
        {:error, :eexist} -> {:error, :exists}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Removes one staged source; `:ok` when it was already absent."
  @spec stage_delete(Path.t(), String.t()) :: :ok | {:error, :bad_path}
  def stage_delete(root, rel) do
    with {:ok, rel} <- valid_rel(rel) do
      _ = File.rm(Path.join(staging_dir(root), rel))
      :ok
    end
  end

  @doc "Source paths are relative, `.ex`, made of `[A-Za-z0-9_]` segments."
  @spec valid_rel(String.t()) :: {:ok, String.t()} | {:error, :bad_path}
  def valid_rel(rel) when is_binary(rel) do
    segments = String.split(rel, "/")
    {dirs, [file]} = Enum.split(segments, -1)

    if Enum.all?(dirs, &Regex.match?(Regex.compile!("\\A[A-Za-z0-9_]+\\z"), &1)) and
         Regex.match?(Regex.compile!("\\A[A-Za-z0-9_]+\\.ex\\z"), file),
       do: {:ok, rel},
       else: {:error, :bad_path}
  end

  # ── launch markers ──

  @typedoc """
  `boot.json`: launches since the last stable one, whether the last reached
  stable, and the delivered Core update (mob_deliver manifest id) the last
  counted launch ran, `nil` for the build's own code.
  """
  @type boot_markers :: %{
          boot_attempts: non_neg_integer(),
          stable: boolean(),
          core: String.t() | nil
        }

  @doc "The launch markers (`t:boot_markers/0`); a fresh, stable record when there are none."
  @spec boot_markers(Path.t()) :: boot_markers()
  def boot_markers(root) do
    with {:ok, json} <- File.read(Path.join(root, "boot.json")),
         {:ok, %{"boot_attempts" => a, "stable" => s} = m} when is_integer(a) and is_boolean(s) <-
           Jason.decode(json) do
      core = m["core"]
      %{boot_attempts: a, stable: s, core: if(is_binary(core), do: core)}
    else
      _ -> %{boot_attempts: 0, stable: true, core: nil}
    end
  end

  @doc "Writes the launch markers (`t:boot_markers/0`)."
  @spec put_boot_markers(Path.t(), %{
          required(:boot_attempts) => non_neg_integer(),
          required(:stable) => boolean(),
          optional(:core) => String.t() | nil
        }) :: :ok | {:error, term()}
  def put_boot_markers(root, %{boot_attempts: a, stable: s} = markers) do
    File.mkdir_p!(root)
    json = Jason.encode!(%{boot_attempts: a, stable: s, core: Map.get(markers, :core)})
    write_atomic(Path.join(root, "boot.json"), json)
  end

  # ── the log ──

  @doc "Appends a report (a JSON-encodable map) to the log; the file keeps the last #{@log_keep}."
  @spec append_log(Path.t(), map()) :: :ok
  def append_log(root, entry) do
    File.mkdir_p!(root)
    path = Path.join(root, "log.jsonl")
    File.write!(path, [Jason.encode!(entry), ?\n], [:append])

    case File.stat(path) do
      {:ok, %{size: size}} when size > @log_max_bytes ->
        keep = path |> File.read!() |> String.split("\n", trim: true) |> Enum.take(-@log_keep)
        write_atomic(path, Enum.map(keep, &[&1, ?\n]))

      _ ->
        :ok
    end
  end

  @doc "The last `limit` reports, oldest first (string keys, as stored)."
  @spec log(Path.t(), pos_integer()) :: [map()]
  def log(root, limit) do
    case File.read(Path.join(root, "log.jsonl")) do
      {:ok, text} ->
        for line <- text |> String.split("\n", trim: true) |> Enum.take(-limit),
            {:ok, %{} = entry} <- [Jason.decode(line)],
            do: entry

      {:error, _} ->
        []
    end
  end

  # ── helpers ──

  defp numbers(root) do
    case File.ls(gens_dir(root)) do
      {:ok, names} ->
        for name <- names, {n, ""} <- [Integer.parse(name)], n > 0, do: n

      {:error, _} ->
        []
    end
  end

  defp gens_dir(root), do: Path.join(root, "gens")
  defp gen_dir(root, n), do: Path.join(gens_dir(root), Integer.to_string(n))
  defp manifest_path(root, n), do: Path.join(gen_dir(root, n), "manifest.json")
  defp staging_dir(root), do: Path.join([root, "staging", "src"])

  defp read_tree(dir) do
    for path <- Path.wildcard(Path.join(dir, "**/*.ex")), into: %{} do
      {Path.relative_to(path, dir), File.read!(path)}
    end
  end

  defp write_tree(dir, sources) do
    Enum.each(sources, fn {rel, source} ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
    end)
  end

  defp write_atomic(path, data) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, data, [:sync]),
         do: File.rename(tmp, path)
  end
end
