defmodule Rho.Session do
  @moduledoc """
  Sessions in omp/pi's JSONL format (`pi-coding-agent/src/session/
  session-entries.ts`, `CURRENT_SESSION_VERSION = 3`), so a session can move
  between omp on a computer and a rho host (Operator on a phone, say).

  A file is a `session` header line, then entries. Every entry carries `type`,
  `id` (8 hex chars), `parentId` (the previous entry; entries form a tree and
  the last entry is the leaf) and an ISO `timestamp`. rho writes:

    * `model_change` (`model` as `"provider/modelId"`), first, and on a switch
    * `message` with pi's `AgentMessage` in `message`: `user`, `assistant`
      (text / thinking / image / toolCall content, `api`, `provider`,
      `model`, `usage`, `stopReason`, `errorMessage`; image parts in an
      assistant message are omp's pi extension, upstream pi has none),
      `toolResult` (with pi's `details` when the host keeps some,
      `tool_result/5`)
    * `custom_message` (`customType` `"<ns>.notice"` / `"<ns>.error"` /
      `"<ns>.aside"`, `<ns>` being `Rho.Config.namespace/0`, `content`,
      `display`) for loop notices
    * `compaction` (pi's `CompactionEntry`: `summary`, `firstKeptEntryId`,
      `tokensBefore`, `tokensAfter`, `method: "soft"`): the branch before
      `firstKeptEntryId`, summarized by the model (`Rho.Compaction`)

  A user message may carry attachments (`user/2`): each is a text part
  wrapped in `<attachment …>` (name, type, path, ref, a line about it and,
  for a text file, its text), then pi's image part for a picture. The
  message's `attachments` field (rho's; pi ignores it) lists them for the
  chat (`attachments/1`), and `typed/1` is what the user typed. A picture
  goes to the model only if it takes pictures, a PDF (read from its path)
  only if it takes PDFs (`context/2`'s `:inputs`); otherwise the model
  gets the path and the line about it. After a compaction, the summary
  message lists the attachments it summarized away, so their paths aren't
  lost.

  An attachment may be **by reference** instead: the host gives a `ref`
  (an opaque string of its own, a material id say) and the session keeps
  only the ref and the metadata, never the bytes: no image part, the ref in
  the envelope and in `attachments`. Each time a request is built, a
  referenced picture (when the model takes pictures) or PDF (when it takes
  PDFs) is fetched through the host's `:resolve_attachment` hook
  (`Rho.Config.resolve_attachment/2`) and goes to the model where the
  inline one would. When there's no hook, or it can't give the bytes, the
  model gets a short note in its place. A tool can answer with referenced
  pictures too (`tool_result/5`). Pictures the model makes stay inline:
  they arrive as bytes from the provider. Inline attachments (all of an
  older session's) are read as before.

  Reading keeps every entry, including types rho doesn't know (omp's
  `custom`, `title_change`, `thinking_level_change`, …). They are carried
  along (rho only appends, never rewrites) and ignored when building
  the model context. `context/2` walks the leaf's branch as pi's
  `buildSessionContext` does: the latest `compaction`'s summary first, then
  the entries from its `firstKeptEntryId` on, `message` and
  `custom_message` entries turned into req_llm messages.

  The loop builds every request with `context/1` over its entry list, and
  `append/2` returns the entry as it reads back from disk, so a resumed
  session sends exactly what the live one did.
  """

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  require Logger

  @version 3
  @aborted_tool_text "Tool was not executed because the run was aborted."

  defstruct [:id, :path, :cwd, :model, :title, leaf_id: nil, written?: false]

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          cwd: String.t(),
          model: String.t(),
          title: String.t() | nil,
          leaf_id: String.t() | nil,
          written?: boolean()
        }
  @type entry :: %{String.t() => term()}

  @doc "Where sessions live by default: `<data dir>/sessions`."
  @spec dir() :: String.t()
  def dir, do: Path.join(Rho.Config.data_dir(), "sessions")

  @doc """
  A new session in `dir` for `model` (a req_llm spec, `"anthropic:…"`).
  Nothing is written until the first `append/2`, which writes the header
  (titled `title` when set, else after the first entry when it is a user
  message) and a `model_change` entry.
  """
  @spec new(String.t(), String.t(), String.t()) :: t()
  def new(dir, model, cwd) do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    id = uuid_v7(now)
    stamp = now |> DateTime.to_iso8601() |> String.replace(":", "-") |> String.replace(".", "-")
    %__MODULE__{id: id, path: Path.join(dir, "#{stamp}_#{id}.jsonl"), cwd: cwd, model: model}
  end

  @doc """
  Reads a session file: returns the session and the entries on the leaf's
  branch, oldest first. Unknown entry types are kept; unparsable lines (a
  torn last write) are skipped and logged.
  """
  @spec open(String.t(), String.t()) :: {:ok, t(), [entry()]} | {:error, term()}
  def open(path, default_model) do
    with {:ok, body} <- File.read(path),
         {[%{"type" => "session", "id" => id} = header], entries} <-
           split_header(decode_lines(body, path)) do
      branch = branch(entries)
      leaf = List.last(branch)

      session = %__MODULE__{
        id: id,
        path: path,
        cwd: header["cwd"],
        title: header["title"],
        leaf_id: leaf && leaf["id"],
        written?: true,
        model: model_from(branch) || default_model
      }

      {:ok, session, branch}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_a_session}
    end
  end

  @doc """
  Appends one entry (adding `id`, `parentId`, `timestamp`). Returns the
  updated session and the entry as it reads back from disk.
  """
  @spec append(t(), entry()) :: {t(), entry()}
  def append(%__MODULE__{written?: false} = s, entry) do
    File.mkdir_p!(Path.dirname(s.path))
    title = if s.title in [nil, ""], do: title_for(entry), else: s.title

    header = %{
      "type" => "session",
      "version" => @version,
      "id" => s.id,
      "timestamp" => now_iso(),
      "cwd" => s.cwd,
      "title" => title,
      "titleSource" => "auto"
    }

    File.write!(s.path, [Jason.encode!(header), ?\n])
    {s, _} = append(%{s | written?: true, title: title}, model_change(s.model))
    append(s, entry)
  end

  def append(%__MODULE__{} = s, entry) when is_map(entry) do
    base = %{"id" => short_id(), "parentId" => s.leaf_id, "timestamp" => now_iso()}
    line = entry |> Map.merge(base) |> Jason.encode!()
    File.write!(s.path, [line, ?\n], [:append])
    written = Jason.decode!(line)
    model = if entry["type"] == "model_change", do: from_pi_model(entry["model"]), else: s.model
    {%{s | leaf_id: written["id"], model: model}, written}
  end

  @doc "Sessions in `dir`, most recently written first."
  @spec list(String.t()) :: [
          %{id: String.t(), path: String.t(), mtime: integer(), title: String.t() | nil}
        ]
  def list(dir) do
    dir
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case read_header(path) do
        %{"type" => "session", "id" => id} = header ->
          [
            %{
              id: id,
              path: path,
              mtime: File.stat!(path, time: :posix).mtime,
              title: header["title"]
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.sort_by(&{&1.mtime, &1.path}, :desc)
  end

  @doc "Path of the most recently written session in `dir`, or nil."
  @spec latest(String.t()) :: String.t() | nil
  def latest(dir) do
    case list(dir) do
      [%{path: path} | _] -> path
      [] -> nil
    end
  end

  # ── entry builders (pi shapes; id/parentId/timestamp added by append/2) ──

  @typedoc """
  A file going with a user message (built by the host from a picker, the
  camera, a download, ...):
  `kind` `:image` (with `image`, the picture for the model), `:text` (with
  `text`, already cut to the output budget), `:pdf` (with `pages` when
  known) or `:file`; `path` is its copy in the workspace, `about` one line
  for the model (size, when and where a photo was taken, ...).

  With `ref` (the host's own id for the file, an opaque string) the file
  is attached by reference: the session stores the ref, not the bytes
  (`image` is ignored), and a picture or PDF is fetched through the
  `:resolve_attachment` hook each time a request is built (see the
  moduledoc). `path` is then optional; an attachment needs one of the two.
  """
  @type attachment :: %{
          required(:kind) => :image | :text | :pdf | :file,
          required(:name) => String.t(),
          required(:mime) => String.t(),
          required(:about) => String.t(),
          optional(:path) => String.t() | nil,
          optional(:ref) => String.t() | nil,
          optional(:image) => {String.t(), binary()} | nil,
          optional(:text) => String.t() | nil,
          optional(:pages) => pos_integer() | nil
        }

  @doc """
  A user message: `text` (may be empty when `opts[:attachments]` isn't)
  then each attachment's parts. `opts[:steering]` marks a message sent
  while the agent was running; `opts[:ask]` (an id) a question another
  agent asked (`Rho.Loop.ask/4`), from node `opts[:from]`.
  """
  @spec user(String.t(), keyword()) :: entry()
  def user(text, opts \\ []) do
    attachments = Keyword.get(opts, :attachments, [])
    typed = if text == "", do: [], else: [text_part(text)]

    message = %{
      "role" => "user",
      "content" => typed ++ Enum.flat_map(attachments, &attachment_parts/1),
      "attribution" => "user",
      "timestamp" => now_ms()
    }

    message =
      if attachments == [],
        do: message,
        else: Map.put(message, "attachments", Enum.map(attachments, &attachment_meta/1))

    message = if opts[:steering], do: Map.put(message, "steering", true), else: message

    # A field of its own: "attribution" stays one of omp's values.
    message =
      if opts[:ask],
        do: Map.merge(message, %{"ask" => opts[:ask], "from" => to_string(opts[:from])}),
        else: message

    %{"type" => "message", "message" => message}
  end

  defp attachment_parts(a) do
    body = Enum.reject([a.about, a[:text]], &(&1 in [nil, ""]))

    attrs =
      for {key, value} <- [name: a.name, type: a.mime, path: a[:path], ref: a[:ref]],
          value != nil,
          do: ~s| #{key}="#{attr(value)}"|

    envelope = "<attachment#{Enum.join(attrs)}>\n" <> Enum.join(body, "\n") <> "\n</attachment>"
    image = if a[:image] && !a[:ref], do: [image_part(a.image)], else: []

    [text_part(envelope) | image]
  end

  # The loop checks a host's attachments in the caller (`Rho.Loop.prompt/3`),
  # so a bad one raises there, not in the loop.
  @doc false
  @spec check_attachments!([attachment()]) :: :ok
  def check_attachments!(attachments) do
    for a <- attachments,
        not (is_binary(a[:path]) or is_binary(a[:ref])),
        do: raise(ArgumentError, "attachment #{inspect(a[:name])} needs a :path or a :ref")

    :ok
  end

  defp attachment_meta(a) do
    check_attachments!([a])

    meta = %{
      "kind" => Atom.to_string(a.kind),
      "name" => a.name,
      "mimeType" => a.mime,
      "about" => a.about
    }

    for {key, value} <- [{"path", a[:path]}, {"ref", a[:ref]}, {"pages", a[:pages]}],
        value != nil,
        into: meta,
        do: {key, value}
  end

  defp attr(value), do: value |> to_string() |> String.replace(~s|"|, "'")

  @doc """
  An assistant message. `reply` has `:text`, `:thinking`, `:tool_calls`
  (`[%{"id", "name", "arguments"}]`), `:usage` (req_llm's usage map or nil),
  `:stop_reason` (pi's: `"stop" | "length" | "toolUse" | "error" |
  "aborted"`) and optionally `:error` and `:images` (`{mime_type, bytes}`
  each, pictures the model made), which go in as image parts (omp's pi;
  upstream pi's assistant messages have none) after the text, before the
  tool calls. They stay in the session for the chat; `messages/2` doesn't
  send them back to the model (a reply that was only pictures goes as
  "(made a picture)").
  """
  @spec assistant(map(), String.t()) :: entry()
  def assistant(reply, model) do
    {provider, model_id} = split_model(model)

    content =
      [
        reply[:thinking] not in [nil, ""] && %{"type" => "thinking", "thinking" => reply.thinking},
        reply[:text] not in [nil, ""] && text_part(reply.text)
        | Enum.map(reply[:images] || [], &image_part/1) ++
            for(c <- reply[:tool_calls] || [], do: Map.put(c, "type", "toolCall"))
      ]
      |> Enum.filter(& &1)

    message = %{
      "role" => "assistant",
      "content" => content,
      "api" => pi_api(provider),
      "provider" => provider,
      "model" => model_id,
      "usage" => usage(reply[:usage]),
      "stopReason" => reply.stop_reason,
      "timestamp" => now_ms()
    }

    message = if reply[:error], do: Map.put(message, "errorMessage", reply.error), else: message
    %{"type" => "message", "message" => message}
  end

  @doc """
  A tool's result. Options: `:images` go on to the model after the text:
  `{mime_type, bytes}` each (a screenshot or photos) go in as pi's image
  content parts; `%{ref: ref, mime: mime_type}` (optional `:name`) is a
  picture by reference, stored as the message's `attachments` (kind
  `"image"`, see `attachments/1`) without its bytes and fetched when a
  request is built, as a user's referenced picture is. `:details`
  (JSON-encodable; nil for none) is stored as the message's `details`
  (pi's `ToolResultMessage.details`): data for the host's screens, never
  sent to the model.
  """
  @spec tool_result(String.t(), String.t(), String.t(), boolean(), keyword()) :: entry()
  def tool_result(call_id, name, text, is_error, opts \\ []) do
    opts = Keyword.validate!(opts, images: [], details: nil)
    {inline, refs} = Enum.split_with(opts[:images], &is_tuple/1)
    details = opts[:details]

    message = %{
      "role" => "toolResult",
      "toolCallId" => call_id,
      "toolName" => name,
      "content" => [text_part(text) | Enum.map(inline, &image_part/1)],
      "isError" => is_error,
      "timestamp" => now_ms()
    }

    message =
      if refs == [],
        do: message,
        else: Map.put(message, "attachments", Enum.map(refs, &ref_image_meta/1))

    message = if details == nil, do: message, else: Map.put(message, "details", details)
    %{"type" => "message", "message" => message}
  end

  defp ref_image_meta(%{ref: ref, mime: mime} = image),
    do: %{"kind" => "image", "name" => image[:name] || ref, "mimeType" => mime, "ref" => ref}

  @doc """
  A loop notice: `kind` is `:notice`, `:error` or `:aside`; its
  `customType` is `"<namespace>.<kind>"` (`Rho.Config.namespace/0`).
  """
  @spec custom(atom(), String.t()) :: entry()
  def custom(kind, text) when kind in [:notice, :error, :aside] do
    %{
      "type" => "custom_message",
      "customType" => "#{Rho.Config.namespace()}.#{kind}",
      "content" => text,
      "display" => true,
      "attribution" => "agent"
    }
  end

  @doc """
  The kind of a loop notice entry (`custom/2`), whatever namespace wrote
  it (`"rho.error"` and `"operator.error"` are both `:error`); nil for any
  other entry.
  """
  @spec notice_kind(entry()) :: :notice | :error | :aside | nil
  def notice_kind(%{"type" => "custom_message", "customType" => type}) when is_binary(type) do
    case type |> String.split(".") |> List.last() do
      "notice" -> :notice
      "error" -> :error
      "aside" -> :aside
      _ -> nil
    end
  end

  def notice_kind(_entry), do: nil

  @doc ~S|Records a model switch; `model` is a req_llm spec (`"anthropic:…"`).|
  @spec model_change(String.t()) :: entry()
  def model_change(model), do: %{"type" => "model_change", "model" => to_pi_model(model)}

  @doc """
  A compaction, as pi's local summarizer writes its `CompactionEntry`
  (`method: "soft"`, `fromExtension: false`): from now on `context/1`
  sends `summary` in place of the branch before `first_kept_id`.
  """
  @spec compaction(String.t(), String.t(), non_neg_integer(), non_neg_integer()) :: entry()
  def compaction(summary, first_kept_id, tokens_before, tokens_after) do
    %{
      "type" => "compaction",
      "summary" => summary,
      "firstKeptEntryId" => first_kept_id,
      "tokensBefore" => tokens_before,
      "tokensAfter" => tokens_after,
      "method" => "soft",
      "fromExtension" => false
    }
  end

  # ── reading entries ──

  @doc "The text of a message's content (string or parts; text parts only)."
  @spec text(term()) :: String.t()
  def text(content) when is_binary(content), do: content

  def text(content) when is_list(content),
    do: Enum.map_join(for(%{"type" => "text", "text" => t} <- content, do: t), "", & &1)

  def text(_), do: ""

  @doc """
  What the user typed: a user message's text without its attachments
  (each adds one text part, its envelope, after the typed text).
  """
  @spec typed(map()) :: String.t()
  def typed(%{"content" => content} = message) do
    # a tool result's attachments add no envelope
    case if(message["role"] == "toolResult", do: [], else: attachments(message)) do
      [] ->
        text(content)

      files ->
        texts = for %{"type" => "text"} = part <- List.wrap(content), do: part
        texts |> Enum.drop(-length(files)) |> text()
    end
  end

  def typed(_message), do: ""

  @doc ~S"""
  The files a message carries, for the host's chat: a user message's
  attachments (`user/2`) and a tool result's referenced pictures
  (`tool_result/5`), in order, each
  `%{"kind" => "image" | "text" | "pdf" | "file", "name", "mimeType"}`
  plus, when there is one, `"ref"` (the host's reference: the file is
  attached by reference, its bytes aren't in the session), `"path"`,
  `"about"` and `"pages"`. A user's inline picture's bytes are the image
  part after its envelope in `"content"`, as in older sessions.
  """
  @spec attachments(map()) :: [map()]
  def attachments(%{"attachments" => list}) when is_list(list), do: list
  def attachments(_message), do: []

  @doc "Thinking text of an assistant message."
  @spec thinking(map()) :: String.t()
  def thinking(%{"content" => content}) when is_list(content),
    do: Enum.map_join(for(%{"type" => "thinking", "thinking" => t} <- content, do: t), "", & &1)

  def thinking(_), do: ""

  @doc ~S|Tool calls of an assistant message: `[%{"id", "name", "arguments"}]`.|
  @spec tool_calls(map()) :: [map()]
  def tool_calls(%{"content" => content}) when is_list(content),
    do: for(%{"type" => "toolCall"} = c <- content, do: c)

  def tool_calls(_), do: []

  # ── replay ──

  @doc """
  The req_llm messages for a branch (no system prompt), as pi's
  `buildSessionContext` builds them. With a `compaction` on the branch,
  the latest one's summary comes first (rendered as pi renders it, plus
  the attachments it summarized away), then the entries from its
  `firstKeptEntryId` up to it, then everything after it (see
  `compacted/1`); otherwise the whole branch. See `messages/2` for `opts`.
  """
  @spec context([entry()], keyword()) :: [ReqLLM.Message.t()]
  def context(entries, opts \\ []) do
    {compaction, kept, later} = compacted(entries)

    summary =
      for %{"summary" => s} when is_binary(s) <- List.wrap(compaction) do
        shown = MapSet.new(kept ++ later, & &1["id"])
        away = Enum.reject(entries, &MapSet.member?(shown, &1["id"]))
        Context.user(compaction_context(s) <> attachments_note(away))
      end

    summary ++ messages(kept ++ later, opts)
  end

  @doc """
  The req_llm messages for `entries` as given (no compaction applied).
  `message` and `custom_message` entries contribute; every other type is
  ignored. Assistant turns with no text and no tool calls (empty errors /
  aborts) and pi's superseded `retryRecovery` turns are dropped, and a
  tool call left without a result gets pi's synthetic "aborted" result,
  so the context is always valid for the provider.

  `opts[:inputs]` is what the model takes (`Rho.Models.inputs/1`,
  default `[:text, :image]`): without `:image`, pictures become a note;
  with `:pdf`, attached PDFs go as documents, read from their paths, the
  newest first while the request stays inside the provider's limits.

  Files attached by reference that the model takes (pictures with
  `:image`, PDFs with `:pdf`) are fetched once each through
  `Rho.Config.resolve_attachment/2`, given `%{session_id:
  opts[:session_id]}`; one it can't fetch becomes a note. With
  `fetch: false` (a text-only use, as compaction's summary) they are left
  out without fetching.
  """
  @spec messages([entry()], keyword()) :: [ReqLLM.Message.t()]
  def messages(entries, opts \\ []) do
    inputs = Keyword.get(opts, :inputs, [:text, :image])

    fetched =
      if Keyword.get(opts, :fetch, true),
        do: fetch_refs(entries, inputs, %{session_id: opts[:session_id]}),
        else: %{}

    ctx = %{inputs: inputs, fetched: fetched, docs: documents(entries, inputs, fetched)}

    entries
    |> Enum.flat_map(&to_messages(&1, ctx))
    |> close_dangling_calls()
  end

  @doc """
  Splits a branch at its latest `compaction`: `{compaction, kept, later}`.
  `kept` runs from the compaction's `firstKeptEntryId` up to it (empty
  when that entry is not before it), `later` is everything after it.
  Without a compaction: `{nil, [], entries}`.
  """
  @spec compacted([entry()]) :: {entry() | nil, [entry()], [entry()]}
  def compacted(entries) do
    last =
      entries
      |> Enum.with_index()
      |> Enum.reduce(nil, fn
        {%{"type" => "compaction"}, i}, _last -> i
        _entry, last -> last
      end)

    case last do
      nil ->
        {nil, [], entries}

      i ->
        {before, [compaction | later]} = Enum.split(entries, i)

        kept =
          case compaction["firstKeptEntryId"] do
            id when is_binary(id) -> Enum.drop_while(before, &(&1["id"] != id))
            _ -> []
          end

        {compaction, kept, later}
    end
  end

  # pi's prompts/compaction-summary-context.md.
  defp compaction_context(summary) do
    """
    Prior model work/tool state available.
    MUST build on prior work; NEVER duplicate prior work.

    <summary>
    #{summary}
    </summary>\
    """
  end

  defp attachments_note(entries) do
    lines =
      for %{"type" => "message", "message" => %{"role" => "user"} = m} <- entries,
          a <- attachments(m),
          do: "- #{a["name"]} (#{a["mimeType"]})#{where(a)}: #{a["about"]}"

    if lines == [],
      do: "",
      else:
        "\n\nFiles the user attached before this summary (still in the workspace; " <>
          "read them again with file_read):\n" <> Enum.join(lines, "\n")
  end

  defp where(a) do
    case {a["path"], a["ref"]} do
      {nil, ref} -> ", ref #{ref}"
      {path, nil} -> " at #{path}"
      {path, ref} -> " at #{path}, ref #{ref}"
    end
  end

  @no_picture "(The picture isn't sent: this model doesn't take pictures.)"

  defp to_messages(%{"type" => "message", "message" => %{"role" => role} = m}, ctx)
       when role in ["user", "developer"] do
    parts = user_parts(m, ctx) ++ pdf_parts(m, ctx)

    case parts do
      [] -> []
      [%ContentPart{type: :text, text: text}] -> [Context.user(text)]
      parts -> [Context.user(parts)]
    end
  end

  defp to_messages(%{"type" => "message", "message" => %{"role" => "assistant"} = m}, _ctx) do
    calls =
      for c <- tool_calls(m),
          do: ToolCall.new(c["id"], c["name"], Jason.encode!(c["arguments"] || %{}))

    text = reply_text(m["content"])

    if (text == "" and calls == []) or Map.has_key?(m, "retryRecovery"),
      do: [],
      else: [Context.assistant(text, tool_calls: calls)]
  end

  defp to_messages(%{"type" => "message", "message" => %{"role" => "toolResult"} = m}, ctx) do
    images =
      for(%{"type" => "image"} = part <- List.wrap(m["content"]), do: picture(part, ctx)) ++
        for(a <- attachments(m), do: ref_picture(a, ctx))

    images = List.flatten(images)

    content =
      if images == [],
        do: text(m["content"]),
        else: [ContentPart.text(text(m["content"])) | images]

    [Context.tool_result(m["toolCallId"], m["toolName"], content)]
  end

  defp to_messages(%{"type" => "custom_message", "content" => content}, _ctx) do
    case text(content) do
      "" -> []
      text -> [Context.user(text)]
    end
  end

  defp to_messages(_entry, _ctx), do: []

  # A reply's text for the model; one that was only pictures says so (the
  # pictures stay out).
  defp reply_text(content) do
    case {text(content), Enum.count(List.wrap(content), &(&1["type"] == "image"))} do
      {"", 0} -> ""
      {"", 1} -> "(made a picture)"
      {"", n} -> "(made #{n} pictures)"
      {text, _} -> text
    end
  end

  # Each attachment's envelope is one of the last text parts, in order: a
  # picture attached by reference goes right after its envelope, where an
  # inline one is.
  defp user_parts(m, ctx) do
    content =
      for part <- List.wrap(m["content"]),
          do: if(is_binary(part), do: text_part(part), else: part)

    files = attachments(m)
    first = Enum.count(content, &match?(%{"type" => "text"}, &1)) - length(files)

    {parts, _texts} =
      Enum.flat_map_reduce(content, 0, fn
        %{"type" => "text"} = part, i when first >= 0 and i >= first ->
          {user_part(part, ctx) ++ ref_picture(Enum.at(files, i - first), ctx), i + 1}

        %{"type" => "text"} = part, i ->
          {user_part(part, ctx), i + 1}

        part, i ->
          {user_part(part, ctx), i}
      end)

    # envelopes not where they should be: the pictures go last
    if first < 0, do: parts ++ Enum.flat_map(files, &ref_picture(&1, ctx)), else: parts
  end

  defp user_part(%{"type" => "text", "text" => ""}, _ctx), do: []

  defp user_part(%{"type" => "text", "text" => t}, _ctx) when is_binary(t),
    do: [ContentPart.text(t)]

  defp user_part(%{"type" => "image"} = part, ctx), do: picture(part, ctx)
  defp user_part(_part, _ctx), do: []

  defp picture(%{"data" => data, "mimeType" => mime}, %{inputs: inputs}) do
    cond do
      :image not in inputs -> [ContentPart.text(@no_picture)]
      bytes = decode64(data) -> [ContentPart.image(bytes, mime)]
      true -> []
    end
  end

  defp picture(_part, _ctx), do: []

  defp ref_picture(%{"kind" => "image", "ref" => ref} = a, %{inputs: inputs, fetched: fetched})
       when is_binary(ref) do
    case :image in inputs && fetched[{"image", ref}] do
      false -> [ContentPart.text(@no_picture)]
      {:ok, {mime, bytes}} -> [ContentPart.image(bytes, mime)]
      :error -> [ContentPart.text(unfetched(a))]
      nil -> []
    end
  end

  defp ref_picture(_attachment, _ctx), do: []

  defp unfetched(a), do: "(#{a["name"] || a["ref"]} couldn't be loaded, so it isn't sent.)"

  defp decode64(data) do
    case Base.decode64(data) do
      {:ok, bytes} -> bytes
      :error -> nil
    end
  end

  # The bytes of the files attached by reference that this model takes,
  # `%{{kind, ref} => {:ok, {mime, bytes}} | :error}`, each fetched once.
  defp fetch_refs(entries, inputs, ctx) do
    wanted = for {kind, input} <- [{"image", :image}, {"pdf", :pdf}], input in inputs, do: kind

    for %{"type" => "message", "message" => m} <- entries,
        %{"kind" => kind, "ref" => ref} = a when is_binary(ref) <- attachments(m),
        kind in wanted,
        reduce: %{} do
      acc when is_map_key(acc, {kind, ref}) -> acc
      acc -> Map.put(acc, {kind, ref}, fetch(a, ctx))
    end
  end

  defp fetch(%{"kind" => kind, "ref" => ref} = a, ctx) do
    case Rho.Config.resolve_attachment(a, ctx) do
      {:ok, {mime, bytes}} when is_binary(mime) and is_binary(bytes) ->
        {:ok, {mime, bytes}}

      other ->
        Logger.warning("[session] #{kind} #{ref} not loaded: #{inspect(other, limit: 5)}")
        :error
    end
  catch
    class, reason ->
      Logger.warning("[session] #{kind} #{ref} not loaded: #{inspect({class, reason}, limit: 5)}")

      :error
  end

  defp pdf_parts(m, %{inputs: inputs} = ctx) do
    if :pdf in inputs,
      do: for(%{"kind" => "pdf"} = a <- attachments(m), part <- pdf_part(a, ctx), do: part),
      else: []
  end

  defp pdf_part(%{"ref" => ref, "name" => name} = a, %{fetched: fetched, docs: docs})
       when is_binary(ref) do
    case fetched[{"pdf", ref}] do
      {:ok, {_mime, bytes}} ->
        if MapSet.member?(docs, {:ref, ref}),
          do: [ContentPart.file(bytes, name, "application/pdf", %{pages: a["pages"]})],
          else: [ContentPart.text(not_this_time(name, a["path"]))]

      :error ->
        [ContentPart.text(unfetched(a))]

      nil ->
        []
    end
  end

  defp pdf_part(%{"path" => path, "name" => name} = a, %{docs: docs}) do
    cond do
      not File.exists?(path) ->
        [ContentPart.text("(#{name} is no longer at #{path}.)")]

      MapSet.member?(docs, path) ->
        [ContentPart.file(File.read!(path), name, "application/pdf", %{pages: a["pages"]})]

      true ->
        [ContentPart.text(not_this_time(name, path))]
    end
  end

  defp pdf_part(_attachment, _ctx), do: []

  defp not_this_time(name, path) do
    "(#{name} isn't sent as a document this time: newer documents fill the request." <>
      if(path, do: " It's at #{path}.)", else: ")")
  end

  # The attached PDFs sent as documents: the newest first, while the request
  # stays inside the provider's limits (Anthropic: 32 MB and 100 pages). A
  # document by reference is `{:ref, ref}`, one by path its path.
  @docs_bytes 20_000_000
  @docs_pages 100

  defp documents(entries, inputs, fetched),
    do: if(:pdf in inputs, do: fit_documents(entries, fetched), else: MapSet.new())

  defp fit_documents(entries, fetched) do
    pdfs =
      for %{"type" => "message", "message" => %{"role" => "user"} = m} <- Enum.reverse(entries),
          %{"kind" => "pdf"} = a <- Enum.reverse(attachments(m)),
          {key, size} <- document(a, fetched),
          # a count the PDF hides: a page per 100 KB
          do: {key, size, a["pages"] || max(1, div(size, 100_000))}

    {docs, _bytes, _pages} = Enum.reduce(pdfs, {MapSet.new(), 0, 0}, &add_document/2)
    docs
  end

  defp document(%{"ref" => ref}, fetched) when is_binary(ref) do
    case fetched[{"pdf", ref}] do
      {:ok, {_mime, bytes}} -> [{{:ref, ref}, byte_size(bytes)}]
      _ -> []
    end
  end

  defp document(%{"path" => path}, _fetched) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> [{path, size}]
      _ -> []
    end
  end

  defp document(_attachment, _fetched), do: []

  defp add_document({key, size, more}, {docs, bytes, pages}) do
    if bytes + size <= @docs_bytes and pages + more <= @docs_pages,
      do: {MapSet.put(docs, key), bytes + size, pages + more},
      else: {docs, bytes, pages}
  end

  defp close_dangling_calls(messages) do
    {out, open} = Enum.reduce(messages, {[], []}, &track_calls/2)
    Enum.reverse(synthetic_results(open) ++ out)
  end

  defp track_calls(%{role: :tool, tool_call_id: id} = msg, {acc, open}),
    do: {[msg | acc], Enum.reject(open, &(elem(&1, 0) == id))}

  defp track_calls(msg, {acc, open}) do
    calls = for %ToolCall{id: id, function: %{name: name}} <- msg.tool_calls || [], do: {id, name}
    {[msg | synthetic_results(open) ++ acc], calls}
  end

  # `open` is in call order; the results come back reversed because they
  # are prepended to the reversed accumulator.
  defp synthetic_results(open),
    do:
      open
      |> Enum.reverse()
      |> Enum.map(fn {id, name} -> Context.tool_result(id, name, @aborted_tool_text) end)

  @doc "The text pi uses for a tool call that never ran."
  @spec aborted_tool_text() :: String.t()
  def aborted_tool_text, do: @aborted_tool_text

  @doc """
  The req_llm model spec in effect on a branch: the last default-role
  `model_change`, else the last assistant's provider/model, else nil.
  """
  @spec model_from([entry()]) :: String.t() | nil
  def model_from(entries) do
    explicit =
      for %{"type" => "model_change", "model" => m} = e <- entries,
          (e["role"] || "default") == "default",
          do: m

    inferred =
      for %{
            "type" => "message",
            "message" => %{"role" => "assistant", "provider" => p, "model" => m}
          } <- entries,
          do: "#{p}/#{m}"

    case List.last(explicit) || List.last(inferred) do
      nil -> nil
      pi_model -> from_pi_model(pi_model)
    end
  end

  @doc "Summed usage over a branch's assistant messages (pi `usage` shape)."
  @spec totals([entry()]) :: %{
          tokens: non_neg_integer(),
          output: non_neg_integer(),
          cost: float()
        }
  def totals(entries) do
    Enum.reduce(entries, %{tokens: 0, output: 0, cost: 0.0}, fn
      %{"type" => "message", "message" => %{"role" => "assistant", "usage" => %{} = u}}, acc ->
        add_usage(acc, u)

      _, acc ->
        acc
    end)
  end

  @doc """
  Adds one assistant message's pi `usage` map to a `totals/1` accumulator:
  for a host that keeps a running total as messages arrive.
  """
  @spec add_usage(map(), map()) :: map()
  def add_usage(acc, u) do
    %{
      tokens: acc.tokens + (u["totalTokens"] || 0),
      output: acc.output + (u["output"] || 0),
      cost: acc.cost + (get_in(u, ["cost", "total"]) || 0) * 1.0
    }
  end

  @doc "pi's `usage` (tokens; `cost` in dollars) from req_llm's usage map; nil gives zeros."
  @spec usage(map() | nil) :: map()
  def usage(nil), do: usage(%{})

  def usage(u) do
    cache_read = u[:cache_read_tokens] || u[:cached_tokens] || 0
    cache_write = u[:cache_write_tokens] || u[:cache_creation_tokens] || 0
    input = max((u[:input_tokens] || 0) - cache_read - cache_write, 0)
    output = u[:output_tokens] || 0

    %{
      "input" => input,
      "output" => output,
      "cacheRead" => cache_read,
      "cacheWrite" => cache_write,
      "totalTokens" => input + output + cache_read + cache_write,
      "cost" => %{
        "input" => num(u[:input_cost]),
        "output" => num(u[:output_cost]),
        "cacheRead" => 0,
        "cacheWrite" => 0,
        "total" => num(u[:total_cost] || u[:cost])
      }
    }
  end

  # req_llm's provider ids where pi's differ, and the `api` pi records per provider.
  @pi_providers %{"openai_codex" => "openai-codex"}
  @pi_apis %{
    "anthropic" => "anthropic-messages",
    "openai-codex" => "openai-codex-responses",
    "openai" => "openai-responses",
    "google" => "google-generative-ai"
  }

  @doc ~S|`"openai_codex:gpt-5"` (req_llm) → `"openai-codex/gpt-5"` (pi).|
  @spec to_pi_model(String.t()) :: String.t()
  def to_pi_model(spec) do
    {provider, id} = split_model(spec)
    "#{provider}/#{id}"
  end

  @doc ~S|`"openai-codex/gpt-5"` (pi) → `"openai_codex:gpt-5"` (req_llm).|
  @spec from_pi_model(String.t()) :: String.t()
  def from_pi_model(pi_model) do
    case String.split(pi_model, "/", parts: 2) do
      [provider, id] -> "#{req_llm_provider(provider)}:#{id}"
      [id] -> id
    end
  end

  defp req_llm_provider(pi_provider) do
    Enum.find_value(@pi_providers, pi_provider, fn {req_llm, pi} ->
      if pi == pi_provider, do: req_llm
    end)
  end

  defp pi_api(pi_provider), do: Map.get(@pi_apis, pi_provider, pi_provider)

  # ── helpers ──

  @doc """
  The leaf's branch: from the last entry with an id, follow `parentId` to
  the root. Entries without an id (pi's title slot) are not on any branch.
  """
  @spec branch([entry()]) :: [entry()]
  def branch(entries) do
    with_ids = Enum.filter(entries, &is_binary(&1["id"]))
    by_id = Map.new(with_ids, &{&1["id"], &1})

    case List.last(with_ids) do
      nil -> []
      leaf -> walk(leaf, by_id, MapSet.new(), [])
    end
  end

  defp walk(entry, by_id, seen, acc) do
    acc = [entry | acc]
    seen = MapSet.put(seen, entry["id"])
    parent = entry["parentId"] && Map.get(by_id, entry["parentId"])

    if parent && not MapSet.member?(seen, parent["id"]),
      do: walk(parent, by_id, seen, acc),
      else: acc
  end

  defp split_header(entries), do: Enum.split_with(entries, &(&1["type"] == "session"))

  defp decode_lines(body, path) do
    body
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => type} = entry} when is_binary(type) and type != "title" ->
          [entry]

        {:ok, %{"type" => "title"}} ->
          []

        other ->
          Logger.warning(
            "[session] skipping unreadable line in #{Path.basename(path)}: #{inspect(other, limit: 5)}"
          )

          []
      end
    end)
  end

  defp read_header(path) do
    path
    |> File.stream!()
    |> Enum.take(2)
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "session"} = header} -> header
        _ -> nil
      end
    end)
  end

  defp title_for(%{"type" => "message", "message" => %{"role" => "user"} = m}) do
    line =
      case typed(m) do
        "" -> Enum.map_join(attachments(m), ", ", & &1["name"])
        text -> text
      end

    line |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 60)
  end

  defp title_for(_entry), do: ""

  # `{pi provider, model id}` of a req_llm spec.
  defp split_model(model) do
    case String.split(model, ":", parts: 2) do
      [provider, id] -> {Map.get(@pi_providers, provider, provider), id}
      [id] -> {"unknown", id}
    end
  end

  defp num(n) when is_number(n), do: n
  defp num(_), do: 0

  defp text_part(text), do: %{"type" => "text", "text" => text}

  defp image_part({mime, data}),
    do: %{"type" => "image", "data" => Base.encode64(data), "mimeType" => mime}

  defp short_id, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  defp now_ms, do: System.os_time(:millisecond)

  # RFC 9562 UUIDv7: 48-bit Unix ms, version 7, variant 10, random rest.
  defp uuid_v7(now) do
    ms = DateTime.to_unix(now, :millisecond)
    <<a::12, b::62, _::6>> = :crypto.strong_rand_bytes(10)
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = <<ms::48, 7::4, a::12, 2::2, b::62>>

    [<<u0::32>>, <<u1::16>>, <<u2::16>>, <<u3::16>>, <<u4::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end
end
