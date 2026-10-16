defmodule Rho.Dyn.Screens do
  @moduledoc """
  How Dyn screens plug into the host's UI: a host seam (`config :rho, :dyn,
  screens: Module`, `Rho.Dyn.Config`). rho builds, checks, selftests and
  watches Dyn screens the same way whatever the UI; this says what a
  screen is and how the UI tells the Keeper a launch got going:

    * **compiling**: which module bodies are screens (`c:screen_source?/1`)
      and the function each screen process enters through (`c:entry/0`): the
      compiler wraps it to register the process with the Keeper first
      (`Rho.Dyn.Keeper.watch/3`), so the screen's crash counts against its
      generation;
    * **selftest**: which loaded modules are screens (`c:screen?/1`, filed
      as `:screen` in the registry, `Rho.Dyn.screens/1`) and how one proves
      it mounts and renders (`c:selftest/1`, run in the contained selftest
      process);
    * **launches**: `c:after_first_render/1` has the UI call an MFA (with the
      screen appended) after its first frame, which starts the clock to
      "stable" (`Rho.Dyn.boot/1`); `c:subscribe_app_events/0` and
      `c:left_app?/1`: the app lifecycle events the Keeper receives, and
      which of them mean the user left the app (a launch that drew its
      first frame and was left is stable, not failed);
    * **the agent's view**: `c:live/1`, is generation `n` on screen yet (so
      `dyn_propose` with approve-all answers once it is); `c:guide/0`, the
      screen rules for `Rho.Dyn.agent_guide/0`.

  `Rho.Dyn.Screens.None` (the default) has no screens; `Rho.Dyn.Screens.Mob`
  is mob's (`use Mob.Screen`, `mount/3` + `render/1`).
  """

  @doc "Do a `defmodule`'s body forms define a screen (its entry gets wrapped)?"
  @callback screen_source?(forms :: [Macro.t()]) :: boolean()

  @doc "The function a screen process enters through, `{name, arity}` (mob: `{:mount, 3}`)."
  @callback entry() :: {atom(), arity()}

  @doc "Is loaded module `module` a screen?"
  @callback screen?(module()) :: boolean()

  @doc """
  Proves screen `module` works (mounts and renders), in the selftest's
  contained process: `{:ok, detail}` or `{:error, why}`. A raise is a failure.
  """
  @callback selftest(module()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "Has the UI apply `mfa` (with the screen module appended) after its first frame."
  @callback after_first_render(mfa :: {module(), atom(), list()}) :: :ok

  @doc "Subscribes the calling process (the Keeper) to the app's lifecycle events."
  @callback subscribe_app_events() :: :ok

  @doc "Does `message` (one the Keeper received) mean the user left the app?"
  @callback left_app?(message :: term()) :: boolean()

  @doc """
  Generation `n` is current: does the UI show it yet (`:live`), or not yet
  (`:waiting`)? Without this callback, being current is enough (`:active`).
  """
  @callback live(n :: pos_integer()) :: :live | :waiting

  @doc "The screen rules for the agent (`Rho.Dyn.agent_guide/0`), or nil."
  @callback guide() :: String.t() | nil

  @optional_callbacks live: 1
end

defmodule Rho.Dyn.Screens.None do
  @moduledoc """
  No screens (the default `Rho.Dyn.Screens`): Dyn code is tools and
  modules. Without a UI there is no first frame to wait for, so
  `c:Rho.Dyn.Screens.after_first_render/1` applies the MFA at once: a launch's clock to
  "stable" starts at `Rho.Dyn.boot/1`.
  """
  @behaviour Rho.Dyn.Screens

  @impl true
  def screen_source?(_forms), do: false

  @impl true
  def entry, do: {:mount, 3}

  @impl true
  def screen?(_module), do: false

  @impl true
  def selftest(_module), do: {:error, "this app has no screens"}

  @impl true
  def after_first_render({module, fun, args}) do
    _ = apply(module, fun, args ++ [nil])
    :ok
  end

  @impl true
  def subscribe_app_events, do: :ok

  @impl true
  def left_app?(_message), do: false

  @impl true
  def guide, do: nil
end
