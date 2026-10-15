defmodule Rho.Dyn.Generation do
  @moduledoc """
  One generation of the Dyn layer: what `gens/<n>/manifest.json` holds
  (see `Rho.Dyn.Store`).

  Status lifecycle:

    * `:building` while a proposal compiles and selftests (a crash leaves it so);
    * `:rejected` (check, compile or selftest failed: `reason` says why) or
      `:candidate` (passed; waiting for approval);
    * `:superseded` when a newer proposal replaced a candidate, `:discarded`
      when the human (or agent) dropped it;
    * `:probation` once activated, until it is proven: 60 s without a Dyn
      crash (`quiet`) **and** a later app start reached stable (`restarted`);
    * `:proven`, or `:reverted` (automatically or by hand; `reason`).

  Generation 0 is the empty Dyn layer: no sources, always proven, the root
  every revert chain ends at.

  `modules` has one entry per compiled module: the `module` the agent wrote
  (`"Dyn.Notes"`), the `versioned` one it was compiled into
  (`"Dyn.G3.Notes"`), its `kind` (`:tool`, `:screen` or `:module`),
  the logical `name` the registry files it under (a tool's `name/0`, the
  module name below `Dyn.` otherwise) and the `sha256` of its BEAM.
  `selftests` has one `%{module, kind, ok, detail, ms}` per module.
  """

  @statuses [
    :building,
    :candidate,
    :rejected,
    :superseded,
    :discarded,
    :probation,
    :proven,
    :reverted
  ]
  @kinds [:tool, :screen, :module]

  defstruct n: 0,
            parent: nil,
            created_at: nil,
            rationale: "",
            status: :building,
            files: [],
            modules: [],
            selftests: [],
            compile_ms: nil,
            warnings: [],
            runtime: nil,
            reason: nil,
            activated_at: nil,
            proven_at: nil,
            reverted_at: nil,
            quiet: false,
            restarted: false

  @type status ::
          :building
          | :candidate
          | :rejected
          | :superseded
          | :discarded
          | :probation
          | :proven
          | :reverted
  @type kind :: :tool | :screen | :module
  @type module_entry :: %{
          module: String.t(),
          versioned: String.t(),
          kind: kind(),
          name: String.t(),
          sha256: String.t()
        }
  @type selftest :: %{
          module: String.t(),
          kind: kind(),
          ok: boolean(),
          detail: String.t(),
          ms: non_neg_integer()
        }
  @type t :: %__MODULE__{
          n: non_neg_integer(),
          parent: non_neg_integer() | nil,
          created_at: String.t() | nil,
          rationale: String.t(),
          status: status(),
          files: [String.t()],
          modules: [module_entry()],
          selftests: [selftest()],
          compile_ms: non_neg_integer() | nil,
          warnings: [String.t()],
          runtime: String.t() | nil,
          reason: String.t() | nil,
          activated_at: String.t() | nil,
          proven_at: String.t() | nil,
          reverted_at: String.t() | nil,
          quiet: boolean(),
          restarted: boolean()
        }

  @doc "Generation 0: the empty Dyn layer."
  @spec empty() :: t()
  def empty, do: %__MODULE__{n: 0, status: :proven, rationale: "No Dyn layer"}

  @doc "Was it ever the active generation (so reverting to it makes sense)?"
  @spec ever_active?(t()) :: boolean()
  def ever_active?(%__MODULE__{n: 0}), do: true
  def ever_active?(%__MODULE__{status: status}), do: status in [:probation, :proven, :reverted]

  @spec now() :: String.t()
  def now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = g) do
    g
    |> Map.from_struct()
    |> Map.update!(:status, &Atom.to_string/1)
    |> Map.update!(:modules, fn mods -> Enum.map(mods, &stringify_kind/1) end)
    |> Map.update!(:selftests, fn tests -> Enum.map(tests, &stringify_kind/1) end)
  end

  @spec from_json(map()) :: t()
  def from_json(%{} = json) do
    %__MODULE__{
      n: json["n"],
      parent: json["parent"],
      created_at: json["created_at"],
      rationale: json["rationale"] || "",
      status: atom(json["status"], @statuses, :building),
      files: json["files"] || [],
      modules: Enum.map(json["modules"] || [], &module_entry/1),
      selftests: Enum.map(json["selftests"] || [], &selftest/1),
      compile_ms: json["compile_ms"],
      warnings: json["warnings"] || [],
      runtime: json["runtime"],
      reason: json["reason"],
      activated_at: json["activated_at"],
      proven_at: json["proven_at"],
      reverted_at: json["reverted_at"],
      quiet: json["quiet"] == true,
      restarted: json["restarted"] == true
    }
  end

  defp module_entry(m) do
    %{
      module: m["module"],
      versioned: m["versioned"],
      kind: atom(m["kind"], @kinds, :module),
      name: m["name"],
      sha256: m["sha256"]
    }
  end

  defp selftest(t) do
    %{
      module: t["module"],
      kind: atom(t["kind"], @kinds, :module),
      ok: t["ok"] == true,
      detail: t["detail"] || "",
      ms: t["ms"] || 0
    }
  end

  defp stringify_kind(%{kind: kind} = map), do: %{map | kind: Atom.to_string(kind)}

  defp atom(value, allowed, default),
    do: Enum.find(allowed, default, &(Atom.to_string(&1) == value))
end
