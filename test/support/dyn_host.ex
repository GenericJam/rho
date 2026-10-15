defmodule Notebook.Card do
  @moduledoc """
  A test host's own UI kit, not mob: a "card" is a module that `use`s this
  and shows itself as text (`show/1`). The host runs each card in a
  process of its own that enters through `show/1`.
  """

  @callback show(params :: map()) :: {:ok, String.t()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Notebook.Card
    end
  end
end

defmodule Notebook.Api do
  @moduledoc "The test host's Core module its Dyn code may call."

  @spec ping() :: :pong
  def ping, do: :pong
end

defmodule Notebook.Secret do
  @moduledoc "Test host Core code Dyn code may not call."

  @spec token() :: String.t()
  def token, do: "secret"
end

defmodule Notebook.Screens do
  @moduledoc """
  The test host's `Rho.Dyn.Screens`: cards are its screens. The UI's
  first-frame hook and the Keeper it reports app events to are kept in
  persistent terms, for the test to drive.
  """
  @behaviour Rho.Dyn.Screens

  @impl true
  def screen_source?(forms),
    do: Enum.any?(forms, &match?({:use, _, [{:__aliases__, _, [:Notebook, :Card]} | _]}, &1))

  @impl true
  def entry, do: {:show, 1}

  @impl true
  def screen?(mod), do: function_exported?(mod, :show, 1)

  @impl true
  def selftest(mod) do
    case mod.show(%{}) do
      {:ok, text} when is_binary(text) -> {:ok, "card: showed #{inspect(text)}"}
      other -> {:error, "show/1 must return {:ok, text}, got: #{inspect(other)}"}
    end
  end

  @impl true
  def after_first_render(mfa) do
    :persistent_term.put({__MODULE__, :first_render}, mfa)
    :ok
  end

  @impl true
  def subscribe_app_events do
    :persistent_term.put({__MODULE__, :keeper}, self())
    :ok
  end

  @impl true
  def left_app?({:notebook, :closed}), do: true
  def left_app?(_message), do: false

  @impl true
  def live(_n), do: :live

  @impl true
  def guide, do: "- A card: `use Notebook.Card` with `show/1` returning `{:ok, text}`."

  @doc "The UI drew its first frame (applies the registered hook)."
  @spec first_frame() :: term()
  def first_frame do
    {m, f, a} = :persistent_term.get({__MODULE__, :first_render})
    apply(m, f, a ++ [nil])
  end

  @doc "The user closed the app."
  @spec close() :: term()
  def close, do: send(:persistent_term.get({__MODULE__, :keeper}), {:notebook, :closed})
end
