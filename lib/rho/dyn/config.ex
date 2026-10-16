defmodule Rho.Dyn.Config do
  @moduledoc """
  The host's settings for the Dyn layer, `config :rho, :dyn, [...]` (see
  `Rho.Dyn`). Every key has a default; a host that doesn't use Dyn sets
  none of them.

    * `:enabled`: `Rho.Supervisor` starts the Dyn processes (the Keeper
      and the approval store), adds the `dyn_*` tools to the registry's
      core tools and `Rho.Dyn.Source` to its sources. Default `false`;
      `Rho.Supervisor`'s `:dyn` option overrides it.
    * `:namespace`: the module namespace the agent writes in
      (`defmodule Dyn.Weather`), compiled as `<namespace>.G<n>.*`. Default
      `Dyn`. Fixed for an install: generations on disk name it. It may be
      below a Core prefix (Operator's `Operator.Dyn`, below `Operator`),
      but not below `Rho` (rho's own modules live there), nor at or above
      a Core prefix (the Core's modules would count as Dyn code and drop
      out of the runtime digest): `Rho.Dyn.Keeper` refuses to start then
      (`validate!/0`).
    * `:app`: the host's OTP application. Its version and modules are part
      of the Core (`Rho.Dyn.Compiler.runtime/0`: a new Core rebuilds every
      generation). Default `nil` (rho's own only).
    * `:core`: the host's own module prefixes (`[MyApp]`): its Core code,
      in the runtime digest and off limits to Dyn code except `:allowed`.
      `Rho` is always one. Default `[]`.
    * `:allowed`: Core modules Dyn code may call (`[MyApp.Files]`). `Rho.Tool`
      is always one. Default `[]`.
    * `:check`: the static check's lists, merged over its defaults
      (`Rho.Dyn.Check.defaults/0`: Operator's, except the entries naming
      Operator's own code): `:banned` (`%{module =>
      why}`), `:banned_erlang` (`%{atom => why}`), `:partial` (`%{module
      => [function]}`: allowed modules with forbidden functions), `:gated`
      (`%{prefix => [module]}`: only those modules below the prefix),
      `:forging` (`%{atom => why}`: atoms Dyn code may not hold),
      `:sigils` (`%{sigil_atom => module}`: template sigils whose
      expressions are code, expanded by that module's macro before the
      check), `:handlers` (`[{module, function, arity, index}]`: calls
      whose argument `index` is a `{Module, :function}` handler run later,
      checked as a call). A `nil` value drops a default entry.
    * `:screens`: the host's screen integration, a `Rho.Dyn.Screens`
      module. Default `Rho.Dyn.Screens.None` (no screens: the first
      "render" is the boot); a mob app sets `Rho.Dyn.Screens.Mob`.
    * `:guide`: text appended to `Rho.Dyn.agent_guide/0` (the host's own
      rules: its file roots, a menu Dyn code adds rows to, ...), a string
      or an MFA / 0-arity function. Default none.
    * The Keeper's options (`Rho.Dyn.Keeper`): `:approval`,
      `:probation_ms`, `:crash_limit`, `:on_stable`, ...
  """

  @doc "The whole `config :rho, :dyn` keyword list (`[]` when unset)."
  @spec get() :: keyword()
  def get, do: Application.get_env(:rho, :dyn, [])

  @doc "Is `:enabled` set to `true`?"
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(get(), :enabled, false) == true

  @doc "The namespace module (`Dyn` by default)."
  @spec namespace() :: module()
  def namespace, do: Keyword.get(get(), :namespace, Dyn)

  @doc ~S|The namespace as written (`"Dyn"`, `"MyApp.Dyn"`).|
  @spec namespace_name() :: String.t()
  def namespace_name, do: inspect(namespace())

  @doc "The namespace's alias segments (`[:MyApp, :Dyn]`)."
  @spec namespace_segments() :: [atom()]
  def namespace_segments, do: namespace() |> Module.split() |> Enum.map(&String.to_atom/1)

  @doc ~S|The prefix of generation `n`'s module names, as atoms print (`"Elixir.Dyn.G3."`).|
  @spec generation_prefix(non_neg_integer()) :: String.t()
  def generation_prefix(n), do: "Elixir.#{namespace_name()}.G#{n}."

  @doc "The `:screens` module (`Rho.Dyn.Screens.None` by default)."
  @spec screens() :: module()
  def screens, do: Keyword.get(get(), :screens, Rho.Dyn.Screens.None)

  @doc "The host's OTP application (`:app`), or nil."
  @spec app() :: atom() | nil
  def app, do: Keyword.get(get(), :app)

  @doc ~S|The Core's module prefixes as written (`["Rho", "MyApp"]`).|
  @spec core() :: [String.t()]
  def core, do: Enum.uniq(["Rho" | Enum.map(Keyword.get(get(), :core, []), &name/1)])

  @doc "The Core modules Dyn code may call, as written."
  @spec allowed() :: [String.t()]
  def allowed, do: Enum.uniq(["Rho.Tool" | Enum.map(Keyword.get(get(), :allowed, []), &name/1)])

  @doc "The `:check` overrides as given (`Rho.Dyn.Check` merges them over its defaults)."
  @spec check() :: keyword()
  def check, do: Keyword.get(get(), :check, [])

  @doc """
  Raises `ArgumentError` if the namespace is below `Rho`, or is a Core
  prefix or above one (see `:namespace`).
  """
  @spec validate!() :: :ok
  def validate! do
    ns = namespace_name()

    cond do
      under?(ns, "Rho") ->
        raise ArgumentError,
              "the Dyn namespace #{ns} must not be below Rho (rho's own modules live there)"

      prefix = Enum.find(core(), &under?(&1, ns)) ->
        raise ArgumentError,
              "the Dyn namespace #{ns} must not be the Core prefix #{prefix} or above it"

      true ->
        :ok
    end
  end

  @doc "The `:guide` text, resolved; nil when unset."
  @spec guide() :: String.t() | nil
  def guide do
    case Keyword.get(get(), :guide) do
      nil -> nil
      value -> Rho.Config.resolve(value, [])
    end
  end

  @doc ~S|A module as written: `MyApp.Files` and `"MyApp.Files"` are `"MyApp.Files"`.|
  @spec name(module() | String.t()) :: String.t()
  def name(name) when is_binary(name), do: String.replace_prefix(name, "Elixir.", "")
  def name(module) when is_atom(module), do: inspect(module)

  @doc "Is `name` (as written) `prefix` or below it?"
  @spec under?(String.t(), String.t()) :: boolean()
  def under?(name, prefix), do: name == prefix or String.starts_with?(name, prefix <> ".")
end
