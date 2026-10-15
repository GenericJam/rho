defmodule Rho.Tools.Todo do
  @moduledoc """
  Core tool: the session's todo list (omp's `todo`), kept in
  `todos/<session_id>.json` in the app's data dir. Writing the steps of a
  multi-step job down and ticking them off keeps the agent from stopping
  halfway, or forgetting a step after a compaction; and the list survives a
  restart of the app. One item at a time is in progress: the first open one,
  moved on whenever an item is done or removed.

  `open_items/2` gives the items not done yet, so the loop can remind the
  agent when it ends a run with some left.
  """
  @behaviour Rho.Tool

  @dir "todos"
  @max_items 50
  @max_text 300

  @impl true
  def name, do: "todo"

  @impl true
  def description do
    "Your todo list for this session. For any job of three or more steps, set it first " <>
      "and mark each item done as you finish it; don't stop while items are open unless " <>
      "you are blocked or need the user. action=set replaces the list with `items` (the " <>
      "first is in progress); done marks an item (`index`, 1-based, or exact `text`) done " <>
      "and starts the next; add appends `items`; remove drops an item (`index` or `text`); " <>
      "view shows it. Each call returns the list: [x] done, [>] in progress, [ ] pending."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["set", "done", "add", "remove", "view"]},
        "items" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Item texts (action=set or add)."
        },
        "index" => %{"type" => "integer", "minimum" => 1, "description" => "1-based item number."},
        "text" => %{"type" => "string", "description" => "An item's exact text."}
      },
      "required" => ["action"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(args, %{session_id: id} = ctx) when is_binary(id) and id != "" do
    path = path(ctx.data_dir, id)

    case args["action"] do
      "view" ->
        {:ok, render(read(path))}

      action when action in ["set", "add", "done", "remove"] ->
        with_lock(path, fn -> change(action, args, path) end)

      other ->
        {:error, "unknown action: #{inspect(other)}; use set, done, add, remove or view"}
    end
  end

  def run(_args, _ctx), do: {:error, "the todo list needs a session"}

  # Under the list's lock: read, apply, write back.
  defp change(action, args, path) do
    with {:ok, items} <- apply_action(action, args, read(path)),
         items = normalize(items),
         :ok <- write_atomic(path, JSON.encode!(%{"items" => items})) do
      {:ok, render(items)}
    end
  end

  # One writer per list at a time, across the node's processes.
  defp with_lock(path, fun), do: :global.trans({{__MODULE__, path}, self()}, fun, [node()])

  # Through a temp file, so a crash never leaves half a file.
  defp write_atomic(path, body) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        {:error, "could not write #{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end

  @doc "The texts of the session's items not done yet, in order (`[]` when none)."
  @spec open_items(String.t(), String.t()) :: [String.t()]
  def open_items(data_dir, session_id) do
    for %{"status" => s, "text" => t} <- read(path(data_dir, session_id)), s != "done", do: t
  end

  defp apply_action("set", %{"items" => texts}, _items) when is_list(texts) do
    with {:ok, texts} <- clean(texts), do: limit(Enum.map(texts, &pending/1))
  end

  defp apply_action("set", _args, _items), do: {:error, "set needs `items`, a list of strings"}

  defp apply_action("add", %{"items" => texts}, items) when is_list(texts) do
    with {:ok, texts} <- clean(texts), do: limit(items ++ Enum.map(texts, &pending/1))
  end

  defp apply_action("add", _args, _items), do: {:error, "add needs `items`, a list of strings"}

  defp apply_action("done", args, items) do
    with {:ok, i} <- find(args, items),
         do: {:ok, List.update_at(items, i, &Map.put(&1, "status", "done"))}
  end

  defp apply_action("remove", args, items) do
    with {:ok, i} <- find(args, items), do: {:ok, List.delete_at(items, i)}
  end

  defp find(_args, []), do: {:error, "the todo list is empty; set it first"}

  defp find(%{"index" => i}, items) when is_integer(i) do
    if i >= 1 and i <= length(items),
      do: {:ok, i - 1},
      else: {:error, "no item #{i}; the list has #{length(items)}"}
  end

  defp find(%{"text" => text}, items) when is_binary(text) do
    text = String.trim(text)
    matches = for {%{"text" => ^text} = item, i} <- Enum.with_index(items), do: {item, i}

    # The same text twice: the first one not done yet.
    case Enum.find(matches, fn {item, _} -> item["status"] != "done" end) || List.first(matches) do
      {_item, i} -> {:ok, i}
      nil -> {:error, "no item with the exact text #{inspect(text)}; give its `index` instead"}
    end
  end

  defp find(_args, _items), do: {:error, "give the item's `index` (1-based) or exact `text`"}

  # Exactly one item in progress while any is open: the one already in
  # progress, else the first pending.
  defp normalize(items) do
    if Enum.any?(items, &(&1["status"] == "in_progress")) do
      items
    else
      case Enum.find_index(items, &(&1["status"] == "pending")) do
        nil -> items
        i -> List.update_at(items, i, &Map.put(&1, "status", "in_progress"))
      end
    end
  end

  defp clean(texts) do
    cleaned =
      for t <- texts, is_binary(t), t = String.trim(t), t != "" do
        t |> String.replace(~r/\s+/, " ") |> String.slice(0, @max_text)
      end

    if cleaned == [], do: {:error, "`items` has no non-empty strings"}, else: {:ok, cleaned}
  end

  defp limit(items) when length(items) <= @max_items, do: {:ok, items}

  defp limit(items),
    do: {:error, "#{length(items)} items is too many (at most #{@max_items}); group steps"}

  defp pending(text), do: %{"text" => text, "status" => "pending"}

  defp render([]), do: "(no todo list)"

  defp render(items) do
    lines =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {item, n} -> "#{n}. #{mark(item["status"])} #{item["text"]}" end)

    done = Enum.count(items, &(&1["status"] == "done"))

    footer =
      if done == length(items), do: "All done.", else: "#{done} of #{length(items)} done."

    Enum.join(lines ++ [footer], "\n")
  end

  defp mark("done"), do: "[x]"
  defp mark("in_progress"), do: "[>]"
  defp mark(_pending), do: "[ ]"

  defp read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"items" => items}} when is_list(items) <- JSON.decode(body) do
      for %{"text" => t, "status" => s} = item <- items, is_binary(t), is_binary(s), do: item
    else
      _ -> []
    end
  end

  # Session ids are UUIDs; anything else is made filename-safe.
  defp path(data_dir, session_id),
    do:
      Path.join([data_dir, @dir, String.replace(session_id, ~r/[^A-Za-z0-9_-]/, "_") <> ".json"])

  @impl true
  def selftest do
    dir = Path.join(System.tmp_dir!(), "rho-todo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ctx = %{data_dir: dir, session_id: "s"}

    try do
      with {:ok, "(no todo list)"} <- run(%{"action" => "view"}, ctx),
           {:ok, "1. [>] a\n2. [ ] b\n0 of 2 done."} <-
             run(%{"action" => "set", "items" => ["a", "b"]}, ctx),
           {:ok, "1. [x] a\n2. [>] b\n1 of 2 done."} <-
             run(%{"action" => "done", "index" => 1}, ctx),
           ["b"] <- open_items(dir, "s") do
        :ok
      else
        other -> {:error, other}
      end
    after
      File.rm_rf!(dir)
    end
  end
end
