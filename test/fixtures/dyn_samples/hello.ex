defmodule TestHost.Dyn.Hello do
  @moduledoc "Compiled on the phone from source the app wrote itself."
  use Mob.Screen

  @compiled_at DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  def mount(_params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, taps: 0, compiled_at: @compiled_at)}
  end

  def render(assigns) do
    tap = {self(), :bump}
    taps = "Taps: " <> Integer.to_string(assigns.taps)
    stamp = "Compiled on device at " <> assigns.compiled_at

    ~MOB"""
    <Column background={:background} padding={:space_lg}>
      <Text text="Hello from on-device code" text_size={:xl} text_color={:on_surface} />
      <Text text={stamp} text_size={:sm} text_color={:muted} />
      <Spacer size={16} />
      <Text text={taps} text_color={:primary} />
      <Button text="Tap me" on_tap={tap} background={:primary} text_color={:on_primary} />
    </Column>
    """
  end

  def handle_info({:tap, :bump}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :taps, socket.assigns.taps + 1)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ExUnit-free assertion: the Dyn selftest runs it before a proposal.
  def selftest do
    texts = collect(render(%{taps: 2, compiled_at: "x"}))
    unless "Taps: 2" in texts, do: raise("render missing tap count: #{inspect(texts)}")
    :ok
  end

  defp collect(%{props: props, children: kids}),
    do: List.wrap(props[:text]) ++ Enum.flat_map(kids, &collect/1)

  defp collect(_), do: []
end
