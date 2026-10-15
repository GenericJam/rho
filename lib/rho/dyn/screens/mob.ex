# Compiled only when the host has mob (an optional dependency of rho).
if Code.ensure_loaded?(Mob.Screen) do
  defmodule Rho.Dyn.Screens.Mob do
    @moduledoc """
    Mob screens as Dyn screens (`config :rho, :dyn, screens:
    Rho.Dyn.Screens.Mob`, see `Rho.Dyn.Screens`):

      * a screen is a module that `use Mob.Screen`s and defines `mount/3`;
        its `mount/3` is wrapped to register the screen process with the
        Keeper (mob's router runs each screen in a process of its own);
      * its selftest mounts it on an empty socket (with a placeholder size
        class) and renders it: `render/1` must return a view tree
        (`%{type: atom, children: [...]}` all the way down);
      * mob's router calls the `:after_first_render` hook after the first
        frame; `Mob.Device`'s `:app` events `:will_resign_active`,
        `:did_enter_background` and `:will_terminate` mean the user left.
    """
    @behaviour Rho.Dyn.Screens

    alias Mob.Router.Hooks

    # Mob.Device `:app` events that mean the user left the app.
    @left [:will_resign_active, :did_enter_background, :will_terminate]

    @impl true
    def screen_source?(forms),
      do: Enum.any?(forms, &match?({:use, _, [{:__aliases__, _, [:Mob, :Screen]} | _]}, &1))

    @impl true
    def entry, do: {:mount, 3}

    @impl true
    def screen?(mod),
      do: function_exported?(mod, :mount, 3) and function_exported?(mod, :render, 1)

    @impl true
    def selftest(mod) do
      socket =
        mod |> Mob.Socket.new() |> Mob.Socket.assign(:size_class, Mob.SizeClass.placeholder())

      with {:ok, %Mob.Socket{} = socket} <- mounted(mod.mount(%{}, %{}, socket)),
           tree = mod.render(socket.assigns),
           :ok <- expect(tree?(tree), "render/1 must return a view tree, got: #{short(tree)}") do
        {:ok, "screen: mounted and rendered #{count(tree)} nodes"}
      end
    end

    defp mounted({:ok, %Mob.Socket{}} = ok), do: ok
    defp mounted(other), do: {:error, "mount/3 must return {:ok, socket}, got: #{short(other)}"}

    defp expect(true, _message), do: :ok
    defp expect(false, message), do: {:error, message}

    defp tree?(%{type: type} = node) when is_atom(type) do
      case Map.get(node, :children, []) do
        kids when is_list(kids) -> Enum.all?(List.flatten(kids), &tree?/1)
        _ -> false
      end
    end

    defp tree?(_other), do: false

    defp count(%{} = node),
      do:
        1 + (node |> Map.get(:children, []) |> List.flatten() |> Enum.map(&count/1) |> Enum.sum())

    defp short(term), do: inspect(term, limit: 10, printable_limit: 200)

    @impl true
    def after_first_render(mfa), do: Hooks.register(:after_first_render, mfa)

    @impl true
    def subscribe_app_events do
      if Process.whereis(Mob.Device), do: Mob.Device.subscribe(:app)
      :ok
    catch
      :exit, _ -> :ok
    end

    @impl true
    def left_app?({:mob_device, event}), do: event in @left
    def left_app?(_message), do: false

    @impl true
    def guide do
      """
      - A screen: `use Mob.Screen` with `mount/3` and `render/1` (a `~MOB` template); it must \
      mount on an empty socket and render. `selftest/0` is optional for screens and other modules.
      - Of Mob, its app-facing modules (screens, UI, theme, permissions, device features such as \
      `Mob.Motion`; not the router or renderer, not `Mob.Storage`) and the capability plugins \
      (`MobCamera`, `MobSensors`, `MobLocation`, `MobMishka`, ...). `use Mob.Screen` and `~MOB` \
      are fine.\
      """
    end
  end
end
