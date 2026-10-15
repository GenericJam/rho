defmodule TestHost.Dyn.Checklist do
  @moduledoc """
  A ~200-line screen used to time on-device compilation of a realistic
  screen: state, several event heads, filters, derived stats, and a
  selftest that drives the pure functions.
  """
  use Mob.Screen

  @filters [:all, :open, :done]
  @seed [
    %{id: 1, title: "Read the change log", done: true, tag: :ops},
    %{id: 2, title: "Pick a model", done: false, tag: :agent},
    %{id: 3, title: "Sign in to Claude", done: false, tag: :auth},
    %{id: 4, title: "Compile a screen on the phone", done: true, tag: :selfmod},
    %{id: 5, title: "Persist and recompile at boot", done: false, tag: :selfmod}
  ]

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       items: @seed,
       filter: :all,
       draft: "",
       next_id: length(@seed) + 1,
       history: []
     )}
  end

  def render(assigns) do
    visible = visible(assigns.items, assigns.filter)
    stats = stats(assigns.items)

    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Text text="Checklist (compiled on device)" text_size={:xl} text_color={:on_surface} />
        <Text text={summary(stats)} text_size={:sm} text_color={:muted} />
        <Spacer size={12} />
        {filter_row(assigns.filter)}
        <Spacer size={12} />
        {draft_row(assigns.draft)}
        <Spacer size={12} />
        {item_column(visible)}
        <Spacer size={12} />
        {footer(assigns)}
      </Column>
    </Scroll>
    """
  end

  # ── events ──

  def handle_info({:tap, {:filter, f}}, socket) when f in @filters,
    do: {:noreply, Mob.Socket.assign(socket, :filter, f)}

  def handle_info({:tap, {:toggle, id}}, socket),
    do: {:noreply, update_items(socket, &toggle(&1, id), {:toggle, id})}

  def handle_info({:tap, {:remove, id}}, socket),
    do: {:noreply, update_items(socket, &remove(&1, id), {:remove, id})}

  def handle_info({:change, :draft, value}, socket) when is_binary(value),
    do: {:noreply, Mob.Socket.assign(socket, :draft, value)}

  def handle_info({:tap, :add}, socket) do
    case add(socket.assigns.items, socket.assigns.draft, socket.assigns.next_id) do
      {:ok, items} ->
        socket = Mob.Socket.assign(socket, draft: "", next_id: socket.assigns.next_id + 1)
        {:noreply, update_items(socket, fn _ -> items end, :add)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:tap, :undo}, socket) do
    case socket.assigns.history do
      [{prev, _op} | rest] -> {:noreply, Mob.Socket.assign(socket, items: prev, history: rest)}
      [] -> {:noreply, socket}
    end
  end

  def handle_info({:tap, :clear_done}, socket),
    do: {:noreply, update_items(socket, &clear_done/1, :clear_done)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── pure model ──

  def visible(items, :all), do: items
  def visible(items, :open), do: Enum.reject(items, & &1.done)
  def visible(items, :done), do: Enum.filter(items, & &1.done)

  def toggle(items, id),
    do: Enum.map(items, fn i -> if i.id == id, do: %{i | done: not i.done}, else: i end)

  def remove(items, id), do: Enum.reject(items, &(&1.id == id))

  def clear_done(items), do: Enum.reject(items, & &1.done)

  def add(_items, title, _id) when not is_binary(title), do: {:error, :bad_title}

  def add(items, title, id) do
    case String.trim(title) do
      "" -> {:error, :empty}
      t when byte_size(t) > 120 -> {:error, :too_long}
      t -> {:ok, items ++ [%{id: id, title: t, done: false, tag: tag_for(t)}]}
    end
  end

  def tag_for(title) do
    down = String.downcase(title)

    cond do
      String.contains?(down, ["sign", "key", "auth"]) -> :auth
      String.contains?(down, ["compile", "screen", "module"]) -> :selfmod
      String.contains?(down, ["model", "agent", "tool"]) -> :agent
      true -> :misc
    end
  end

  def stats(items) do
    done = Enum.count(items, & &1.done)
    by_tag = Enum.frequencies_by(items, & &1.tag)
    %{total: length(items), done: done, open: length(items) - done, by_tag: by_tag}
  end

  def summary(%{total: 0}), do: "Nothing to do"

  def summary(%{total: t, done: d, by_tag: tags}) do
    top = tags |> Enum.max_by(fn {_t, n} -> n end) |> elem(0)
    "#{d}/#{t} done · mostly #{top}"
  end

  # ── view helpers ──

  defp update_items(socket, fun, op) do
    prev = socket.assigns.items

    Mob.Socket.assign(socket,
      items: fun.(prev),
      history: Enum.take([{prev, op} | socket.assigns.history], 20)
    )
  end

  defp filter_row(active) do
    buttons =
      Enum.map(@filters, fn f ->
        {bg, fg} = if f == active, do: {:primary, :on_primary}, else: {:surface, :on_surface}
        tap = {self(), {:filter, f}}
        text = label(f)

        ~MOB(<Button text={text} background={bg} text_color={fg} text_size={:sm} weight={1} on_tap={tap} />)
      end)

    %{type: :row, props: %{fill_width: true}, children: buttons}
  end

  defp draft_row(draft) do
    change = {self(), :draft}
    add = {self(), :add}

    %{
      type: :row,
      props: %{fill_width: true},
      children: [
        %{
          type: :text_field,
          props: %{value: draft, placeholder: "New item", weight: 3, on_change: change},
          children: []
        },
        ~MOB(<Button text="Add" background={:primary} text_color={:on_primary} weight={1} on_tap={add} />)
      ]
    }
  end

  defp item_column([]),
    do: ~MOB(<Text text="Nothing here" text_color={:muted} />)

  defp item_column(items) do
    %{type: :column, props: %{fill_width: true}, children: Enum.map(items, &item_row/1)}
  end

  defp item_row(item) do
    toggle = {self(), {:toggle, item.id}}
    remove = {self(), {:remove, item.id}}
    mark = if item.done, do: "[x] ", else: "[ ] "

    %{
      type: :row,
      props: %{fill_width: true},
      children: [
        ~MOB(<Button text={mark <> item.title} background={:surface} text_color={:on_surface} weight={5} on_tap={toggle} />),
        ~MOB(<Button text="✕" background={:surface} text_color={:muted} weight={1} on_tap={remove} />)
      ]
    }
  end

  defp footer(assigns) do
    undo = {self(), :undo}
    clear = {self(), :clear_done}
    undo_text = "Undo [#{length(assigns.history)}]"

    %{
      type: :row,
      props: %{fill_width: true},
      children: [
        ~MOB(<Button text={undo_text} background={:surface} text_color={:on_surface} weight={1} on_tap={undo} />),
        ~MOB(<Button text="Clear done" background={:surface} text_color={:on_surface} weight={1} on_tap={clear} />)
      ]
    }
  end

  defp label(:all), do: "All"
  defp label(:open), do: "Open"
  defp label(:done), do: "Done"

  # ── ExUnit-free selftest ──

  def selftest do
    check(length(visible(@seed, :open)) == 3, "open filter")
    check(length(visible(toggle(@seed, 2), :done)) == 3, "toggle")
    check(add(@seed, "   ", 9) == {:error, :empty}, "reject blank")
    {:ok, more} = add(@seed, "Sign the build", 9)
    check(List.last(more).tag == :auth, "tagging")
    check(stats(clear_done(@seed)).done == 0, "clear done")
    check(summary(stats(@seed)) == "2/5 done · mostly selfmod", "summary")
    :ok
  end

  defp check(true, _what), do: :ok
  defp check(false, what), do: raise("selftest failed: #{what}")
end
