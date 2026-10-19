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
      `display`) for loop notices, and `"<ns>.model_message"` for another
      model's message injected into the conversation (`model_message/4`,
      read back with `attribution/1`)
    * `custom` (pi's extension entry, never sent to a model)
      `"<ns>.consult"`: one consult's model, purpose and usage
      (`consult/1`, `Rho.Consult`)
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

  # ── the file as bytes (keeping a copy elsewhere in step) ──

  @doc """
  The size of a session file's whole lines: its byte size up to and
  including the last newline (a torn last write, a line without its
  newline, isn't counted). Session files only grow, by whole lines, so
  this is a sound cursor for keeping a copy in step: `read_from/3` the
  bytes after the copy's size, `append_bytes/3` them to the copy.
  `{:error, posix}` when the file can't be read (`:enoent`: not written yet).
  """
  @spec size(Path.t()) :: {:ok, non_neg_integer()} | {:error, File.posix()}
  def size(path) do
    with {:ok, io} <- :file.open(path, [:read, :raw, :binary]) do
      try do
        {:ok, raw} = :file.position(io, :eof)
        {:ok, whole_lines(io, raw)}
      after
        :file.close(io)
      end
    end
  end

  @tail_chunk 65_536

  # The offset just past the last "\n" at or before `pos`, scanning back.
  defp whole_lines(_io, 0), do: 0

  defp whole_lines(io, pos) do
    from = max(pos - @tail_chunk, 0)
    {:ok, chunk} = :file.pread(io, from, pos - from)

    case :binary.matches(chunk, "\n") do
      [] -> whole_lines(io, from)
      matches -> from + elem(List.last(matches), 0) + 1
    end
  end

  @doc """
  The session file's bytes from `offset` to the end of its whole lines
  (`size/1`), at most `:max_bytes` of them (default all; a chunk may then
  end mid-line: continue from `offset + byte_size(bytes)`). `{:error,
  :past_end}` when `offset` is beyond `size/1`.
  """
  @spec read_from(Path.t(), non_neg_integer(), keyword()) ::
          {:ok, binary()} | {:error, :past_end | File.posix()}
  def read_from(path, offset, opts \\ []) when is_integer(offset) and offset >= 0 do
    with {:ok, size} <- size(path) do
      to =
        case Keyword.get(opts, :max_bytes, :infinity) do
          :infinity -> size
          max -> min(size, offset + max)
        end

      cond do
        offset > size -> {:error, :past_end}
        offset == size -> {:ok, ""}
        true -> pread(path, offset, to)
      end
    end
  end

  defp pread(path, from, to) do
    with {:ok, io} <- :file.open(path, [:read, :raw, :binary]) do
      try do
        case :file.pread(io, from, to - from) do
          {:ok, bytes} -> {:ok, bytes}
          :eof -> {:ok, ""}
          {:error, _} = error -> error
        end
      after
        :file.close(io)
      end
    end
  end

  @doc """
  Appends `bytes` (whole lines from another copy's `read_from/3`) to the
  session file at `path` if its whole lines end at `offset`, creating it
  (and its directory) when `offset` is 0. Idempotent: a resend whose
  bytes the file already holds from `offset` (all of them, or the first
  lines of them, the rest then written) changes nothing more. A torn last
  line (no newline) is dropped first. Returns the new `size/1`, or
  `{:error, {:conflict, size}}` when the file's whole lines end elsewhere
  or hold other bytes there (the copies diverged), `{:error,
  :partial_line}` when `bytes` doesn't end with a newline.

  No loop may have the session open meanwhile: a loop keeps its leaf and
  entries in memory and would branch off its own last entry, leaving
  these out. Stop it, append, then start it again from `open/2`.
  """
  @spec append_bytes(Path.t(), non_neg_integer(), binary()) ::
          {:ok, non_neg_integer()}
          | {:error, {:conflict, non_neg_integer()} | :partial_line | File.posix()}
  def append_bytes(path, offset, bytes)
      when is_integer(offset) and offset >= 0 and is_binary(bytes) do
    if bytes != "" and :binary.last(bytes) != ?\n,
      do: {:error, :partial_line},
      else: append_at(path, offset, bytes)
  end

  defp append_at(path, offset, bytes) do
    case size(path) do
      {:ok, ^offset} ->
        write_at(path, offset, bytes)

      # A resend: what the file holds past `offset` must be where `bytes` starts.
      {:ok, size} when size > offset and size <= offset + byte_size(bytes) ->
        resend(path, offset, size, bytes)

      {:ok, size} ->
        {:error, {:conflict, size}}

      {:error, :enoent} when offset == 0 ->
        with :ok <- File.mkdir_p(Path.dirname(path)), do: write_at(path, 0, bytes)

      {:error, _} = error ->
        error
    end
  end

  defp resend(path, offset, size, bytes) do
    held = size - offset

    with {:ok, same} <- pread(path, offset, size),
         <<^same::binary-size(^held), rest::binary>> <- bytes do
      if rest == "", do: {:ok, size}, else: write_at(path, size, rest)
    else
      _ -> {:error, {:conflict, size}}
    end
  end

  # Writes `bytes` at `offset`, dropping whatever (a torn line) was past it.
  defp write_at(path, offset, bytes) do
    with {:ok, io} <- :file.open(path, [:read, :write, :raw, :binary]) do
      try do
        with {:ok, ^offset} <- :file.position(io, offset),
             :ok <- :file.truncate(io),
             :ok <- :file.write(io, bytes),
             :ok <- :file.sync(io) do
          {:ok, offset + byte_size(bytes)}
        end
      after
        :file.close(io)
      end
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
  `"image"`, see `attachments/1`) without its bytes and fetched for each
  model call, as a user's referenced picture is. The inline ones go before
  the referenced ones (`Rho.ToolRunner` lets a tool answer with only one
  form). `:details`
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

  @doc """
  Another model's message, injected into the conversation (`Rho.Loop.prompt/3`
  with `attribution: {:model, model, purpose}`): a `custom_message`
  (`customType` `"<namespace>.model_message"`) whose `content` is that
  model's text, as the chat shows it, and whose `details` say who wrote it
  and why: `"model"` (a req_llm spec), `"purpose"` (`"critique"`,
  `"second_opinion"` or free text) and, when given, `"instruction"`
  (`opts[:instruction]`, what the lead model is asked to do with it; sent
  to the model, not meant for the chat). `context/2` sends it as a user
  message marked as that model's, never the user's. `attribution/1` reads
  it back.
  """
  @spec model_message(String.t(), String.t(), String.t(), keyword()) :: entry()
  def model_message(text, model, purpose, opts \\ [])
      when is_binary(text) and is_binary(model) and is_binary(purpose) do
    opts = Keyword.validate!(opts, instruction: nil)
    details = %{"model" => model, "purpose" => purpose}

    details =
      case opts[:instruction] do
        i when i in [nil, ""] -> details
        i when is_binary(i) -> Map.put(details, "instruction", i)
      end

    %{
      "type" => "custom_message",
      "customType" => "#{Rho.Config.namespace()}.model_message",
      "content" => text,
      "display" => true,
      "attribution" => "agent",
      "details" => details
    }
  end

  @doc """
  Who wrote an injected model message (`model_message/4`, whatever
  namespace wrote it): `%{model: spec, purpose: purpose}`; nil for any
  other entry, the user's messages included.
  """
  @spec attribution(entry()) :: %{model: String.t(), purpose: String.t()} | nil
  def attribution(%{"type" => "custom_message", "customType" => type} = entry)
      when is_binary(type) do
    with true <- custom_type?(type, "model_message"),
         %{"model" => model, "purpose" => purpose} when is_binary(model) and is_binary(purpose) <-
           entry["details"] do
      %{model: model, purpose: purpose}
    else
      _ -> nil
    end
  end

  def attribution(_entry), do: nil

  @doc """
  The record of one consult (`Rho.Consult.run/3` with a `:loop`): pi's
  `custom` entry (`customType` `"<namespace>.consult"`, never sent to a
  model), its `data` holding `"id"`, `"model"`, `"purpose"`, `"status"`
  (`"ok"`, `"error"` or `"stopped"`), `"callId"` (the `ask_model` call it
  answered, or nil) and `"usage"` (pi's, summed over its model calls),
  which `totals/1` counts.
  """
  @spec consult(map()) :: entry()
  def consult(%{id: id, model: model, purpose: purpose, status: status, usage: usage} = c)
      when status in [:ok, :error, :stopped] do
    %{
      "type" => "custom",
      "customType" => "#{Rho.Config.namespace()}.consult",
      "data" => %{
        "id" => id,
        "model" => model,
        "purpose" => purpose,
        "status" => Atom.to_string(status),
        "callId" => c[:call_id],
        "usage" => usage
      }
    }
  end

  # `"<any namespace>.<kind>"`, as `notice_kind/1` reads them.
  defp custom_type?(type, kind), do: type |> String.split(".") |> List.last() == kind

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
  with `:pdf`, attached PDFs go as documents, the newest first while the
  request stays inside the provider's limits.

  Files whose bytes aren't in the session (pictures attached by reference,
  PDFs) are fetched by `fetch/2` (given `%{session_id: opts[:session_id]}`)
  before this returns. With `fetch: false` they are left as placeholders
  for the caller to `fetch/2` later, in another process (the loop's model
  call does), or to leave out (a text-only use, as compaction's summary).
  """
  @spec messages([entry()], keyword()) :: [ReqLLM.Message.t()]
  def messages(entries, opts \\ []) do
    ctx = %{inputs: Keyword.get(opts, :inputs, [:text, :image])}

    messages =
      entries
      |> Enum.flat_map(&to_messages(&1, ctx))
      |> close_dangling_calls()

    if Keyword.get(opts, :fetch, true),
      do: fetch(messages, %{session_id: opts[:session_id]}),
      else: messages
  end

  @doc """
  Fills in the placeholders `messages(entries, fetch: false)` left for the
  files whose bytes aren't in the session. A picture attached by reference
  comes from the host's `:resolve_attachment` hook
  (`Rho.Config.resolve_attachment/2`, given `ctx`, `%{session_id: id |
  nil}`), once per kind and ref; one it can't give becomes the note "(<name>
  couldn't be loaded, so it isn't sent.)". PDFs (by path, read from it, or
  by reference, from the hook) go as documents the newest first while the
  request stays inside the provider's limits (20 MB, 100 pages); the
  others become a note. The hook may be slow: the loop calls this in its
  model call's process, not its own.
  """
  @spec fetch([ReqLLM.Message.t()], map()) :: [ReqLLM.Message.t()]
  def fetch(messages, ctx) do
    files =
      for {%{content: parts}, i} <- Enum.with_index(messages),
          is_list(parts),
          {part, j} <- Enum.with_index(parts),
          a when a != nil <- [placeholder(part)],
          do: {{i, j}, part, a}

    if files == [] do
      messages
    else
      # newest first, so the newest documents get the budget
      {filled, _cache, _budget} =
        files
        |> Enum.reverse()
        |> Enum.reduce({%{}, %{}, {0, 0}}, fn {at, part, a}, {filled, cache, budget} ->
          {parts, cache, budget} = fill(part, a, cache, budget, ctx)
          {Map.put(filled, at, parts), cache, budget}
        end)

      for {m, i} <- Enum.with_index(messages), do: fill_in(m, i, filled)
    end
  end

  defp fill_in(%{content: parts} = m, i, filled) when is_list(parts) do
    parts =
      parts
      |> Enum.with_index()
      |> Enum.flat_map(fn {part, j} -> Map.get(filled, {i, j}, [part]) end)

    %{m | content: parts}
  end

  defp fill_in(m, _i, _filled), do: m

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
    files =
      for %{"type" => "message", "message" => %{"role" => "user"} = m} <- entries,
          a <- attachments(m),
          do: a

    {in_workspace, by_ref} = Enum.split_with(files, &is_binary(&1["path"]))

    files_note(
      "Files the user attached before this summary (still in the workspace; " <>
        "read them again with file_read):",
      in_workspace
    ) <>
      files_note(
        "Files the user attached by reference before this summary (not in the workspace):",
        by_ref
      )
  end

  defp files_note(_heading, []), do: ""

  defp files_note(heading, files) do
    lines =
      for a <- files do
        at = if a["path"], do: " at #{a["path"]}", else: ""
        ref = if a["ref"], do: ", ref #{a["ref"]}", else: ""
        "- #{a["name"]} (#{a["mimeType"]})#{at}#{ref}: #{a["about"]}"
      end

    "\n\n#{heading}\n" <> Enum.join(lines, "\n")
  end

  @no_picture "(The picture isn't sent: this model doesn't take pictures.)"

  # The metadata key of a placeholder part (the attachment map), for `fetch/2`.
  @fetch :rho_fetch

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

    content =
      case List.flatten(images) do
        [] -> text(m["content"])
        images -> [ContentPart.text(text(m["content"])) | images]
      end

    [Context.tool_result(m["toolCallId"], m["toolName"], content)]
  end

  defp to_messages(%{"type" => "custom_message", "content" => content} = entry, _ctx) do
    case {text(content), attribution(entry)} do
      {"", _} -> []
      {text, nil} -> [Context.user(text)]
      {text, by} -> [Context.user(from_model(text, by, entry["details"]["instruction"]))]
    end
  end

  defp to_messages(_entry, _ctx), do: []

  # Another model's message, marked as that model's (not the user's); the
  # lead's instruction, when there is one, after it.
  defp from_model(text, %{model: model, purpose: purpose}, instruction) do
    block =
      ~s|<model_message model="#{attr(model)}" purpose="#{attr(purpose)}">\n| <>
        "This is from another model (#{model}), not from the user.\n\n" <>
        String.replace(text, "</model_message", "&lt;/model_message") <> "\n</model_message>"

    if is_binary(instruction) and instruction != "",
      do: block <> "\n\n" <> instruction,
      else: block
  end

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

  # A picture by reference: a placeholder `fetch/2` fills in.
  defp ref_picture(%{"kind" => "image", "ref" => ref, "mimeType" => mime} = a, %{inputs: inputs})
       when is_binary(ref) do
    if :image in inputs,
      do: [ContentPart.image(nil, mime, %{@fetch => a})],
      else: [ContentPart.text(@no_picture)]
  end

  defp ref_picture(_attachment, _ctx), do: []

  defp decode64(data) do
    case Base.decode64(data) do
      {:ok, bytes} -> bytes
      :error -> nil
    end
  end

  # Attached PDFs (by path or by reference): placeholders `fetch/2` fills
  # in. One by path carries its size, for the token estimate.
  defp pdf_parts(m, %{inputs: inputs}) do
    if :pdf in inputs,
      do: for(%{"kind" => "pdf"} = a <- attachments(m), part <- pdf_placeholder(a), do: part),
      else: []
  end

  defp pdf_placeholder(%{"name" => name} = a) do
    meta = %{:pages => a["pages"], @fetch => a}

    cond do
      is_binary(a["ref"]) ->
        [ContentPart.file(nil, name, "application/pdf", meta)]

      is_binary(a["path"]) ->
        size =
          case File.stat(a["path"]) do
            {:ok, %File.Stat{size: size}} -> size
            {:error, _} -> nil
          end

        [ContentPart.file(nil, name, "application/pdf", Map.put(meta, :size, size))]

      true ->
        []
    end
  end

  defp placeholder(%ContentPart{metadata: %{@fetch => a}}), do: a
  defp placeholder(_part), do: nil

  defp fill(%ContentPart{type: :image}, a, cache, budget, ctx) do
    case cached(a, cache, ctx) do
      {{:ok, {mime, bytes}}, cache} -> {[ContentPart.image(bytes, mime)], cache, budget}
      {:error, cache} -> {[ContentPart.text(unfetched(a))], cache, budget}
    end
  end

  defp fill(%ContentPart{type: :file}, a, cache, budget, ctx) do
    case pdf_bytes(a, cache, budget, ctx) do
      {{:ok, bytes}, cache} -> admit(a, bytes, cache, budget)
      {{:skip, note}, cache} -> {[ContentPart.text(note)], cache, budget}
    end
  end

  defp admit(a, bytes, cache, budget) do
    case add_document(budget, byte_size(bytes), a["pages"]) do
      {:ok, budget} ->
        part = ContentPart.file(bytes, a["name"], "application/pdf", %{pages: a["pages"]})
        {[part], cache, budget}

      :full ->
        # the budget only fills up from here: an older copy won't fit
        # either, so don't keep the bytes
        cache = if a["ref"], do: Map.put(cache, {"pdf", a["ref"]}, :full), else: cache
        {[ContentPart.text(not_this_time(a))], cache, budget}
    end
  end

  defp unfetched(a), do: "(#{a["name"] || a["ref"]} couldn't be loaded, so it isn't sent.)"

  defp not_this_time(a) do
    "(#{a["name"]} isn't sent as a document this time: newer documents fill the request." <>
      if(a["path"], do: " It's at #{a["path"]}.)", else: ")")
  end

  # A PDF's bytes, unless its page count (or, by path, its size) is already
  # over what's left of the budget: `{{:ok, bytes} | {:skip, note}, cache}`.
  defp pdf_bytes(a, cache, budget, ctx) do
    known = a["pages"]

    cond do
      is_integer(known) and add_document(budget, 0, known) == :full ->
        {{:skip, not_this_time(a)}, cache}

      is_binary(a["ref"]) ->
        case cached(a, cache, ctx) do
          {{:ok, {_mime, bytes}}, cache} -> {{:ok, bytes}, cache}
          {:full, cache} -> {{:skip, not_this_time(a)}, cache}
          {:error, cache} -> {{:skip, unfetched(a)}, cache}
        end

      true ->
        {pdf_file(a, budget), cache}
    end
  end

  defp pdf_file(%{"path" => path, "name" => name} = a, budget) do
    gone = {:skip, "(#{name} is no longer at #{path}.)"}

    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, _budget} <- add_document(budget, size, a["pages"]),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      :full -> {:skip, not_this_time(a)}
      {:error, _} -> gone
    end
  end

  # The attached PDFs sent as documents: the newest first, while the request
  # stays inside the provider's limits (Anthropic: 32 MB and 100 pages);
  # a count the PDF hides is a page per 100 KB.
  @docs_bytes 20_000_000
  @docs_pages 100

  defp add_document({bytes, pages}, size, known) do
    more = known || max(1, div(size, 100_000))

    if bytes + size <= @docs_bytes and pages + more <= @docs_pages,
      do: {:ok, {bytes + size, pages + more}},
      else: :full
  end

  # A file by reference from the host's hook, once per `{kind, ref}`:
  # `{{:ok, {mime, bytes}} | :error | :full, cache}` (`:full`: a PDF over
  # the budget, its bytes dropped).
  defp cached(%{"kind" => kind, "ref" => ref} = a, cache, ctx) do
    case cache do
      %{{^kind, ^ref} => result} ->
        {result, cache}

      _ ->
        result = resolve(a, ctx)
        {result, Map.put(cache, {kind, ref}, result)}
    end
  end

  defp resolve(%{"kind" => kind, "ref" => ref} = a, ctx) do
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

  @doc """
  Summed usage over a branch's assistant messages and consult records
  (`consult/1`), pi `usage` shape.
  """
  @spec totals([entry()]) :: %{
          tokens: non_neg_integer(),
          output: non_neg_integer(),
          cost: float()
        }
  def totals(entries) do
    Enum.reduce(entries, %{tokens: 0, output: 0, cost: 0.0}, fn
      %{"type" => "message", "message" => %{"role" => "assistant", "usage" => %{} = u}}, acc ->
        add_usage(acc, u)

      %{"type" => "custom", "customType" => type, "data" => %{"usage" => %{} = u}}, acc
      when is_binary(type) ->
        if custom_type?(type, "consult"), do: add_usage(acc, u), else: acc

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
    output = u[:output_tokens] || 0

    # pi's input is the uncached part. req_llm's input_tokens holds the
    # cache's tokens too, except where the provider's doesn't (Anthropic:
    # input_includes_cached false).
    input =
      if u[:input_includes_cached] == false,
        do: u[:input_tokens] || 0,
        else: max((u[:input_tokens] || 0) - cache_read - cache_write, 0)

    %{
      "input" => input,
      "output" => output,
      "cacheRead" => cache_read,
      "cacheWrite" => cache_write,
      "totalTokens" => input + output + cache_read + cache_write,
      "cost" => cost(u)
    }
  end

  # pi splits the cost as it splits the tokens. req_llm's input_cost also
  # holds the cache's, so a priced reply's parts come from its line items;
  # tool calls and pictures count in the total only.
  defp cost(%{cost: %{line_items: items}} = u) when is_list(items) do
    parts = %{"input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0}

    items
    |> Enum.reduce(parts, fn item, acc ->
      case cost_part(item[:component]) do
        nil -> acc
        part -> Map.update!(acc, part, &(&1 + num(item[:cost])))
      end
    end)
    |> Map.put("total", num(u[:total_cost]))
  end

  defp cost(u) do
    %{
      "input" => num(u[:input_cost]),
      "output" => num(u[:output_cost]),
      "cacheRead" => 0,
      "cacheWrite" => 0,
      "total" => num(u[:total_cost] || u[:cost])
    }
  end

  # A line item's component id: "token.input", "token.cache_read",
  # "token.output.long_context", "token.text_cache_read_tokens", ...
  defp cost_part("token.cache_write" <> _), do: "cacheWrite"

  defp cost_part("token." <> meter) do
    cond do
      String.contains?(meter, "cache") -> "cacheRead"
      String.contains?(meter, "input") -> "input"
      true -> "output"
    end
  end

  defp cost_part(_), do: nil

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
