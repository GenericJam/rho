defmodule Rho.SessionTest do
  use ExUnit.Case, async: true

  import Rho.Test.LoopHelpers

  alias Rho.Loop
  alias Rho.Session

  @moduletag :tmp_dir
  @moduletag :capture_log
  @fixture Path.expand("../fixtures/omp_session.jsonl", __DIR__)

  defp lines(path),
    do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  describe "a session rho writes" do
    setup %{tmp_dir: dir} do
      script = [
        [
          {:thinking, "plan"},
          {:text, "Checking."},
          {:tool_call, "t1", "echo", %{"text" => "hi"}}
        ],
        [{:text, "Done."}],
        [{:error, {:http, 402, "can only afford 8000"}}]
      ]

      %{loop: loop, session: session} = start_loop(dir, script)
      :ok = Loop.prompt(loop, "first line\nsecond line")
      collect()
      :ok = Loop.set_model(loop, "openai_codex:gpt-5-mini")
      :ok = Loop.prompt(loop, "again")
      collect()
      %{path: session.path, loop: loop}
    end

    test "matches omp's SessionHeader and SessionEntryBase", %{path: path, tmp_dir: dir} do
      [header | entries] = lines(path)

      assert Map.keys(header) |> Enum.sort() ==
               ~w(cwd id timestamp title titleSource type version)

      assert %{
               "type" => "session",
               "version" => 3,
               "cwd" => ^dir,
               "title" => "first line",
               "titleSource" => "auto"
             } = header

      # UUIDv7: version nibble 7, variant 10xx
      assert header["id"] =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      assert Path.basename(path) =~
               ~r/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z_#{header["id"]}\.jsonl$/

      assert {:ok, _, _} = DateTime.from_iso8601(header["timestamp"])

      ids = Enum.map(entries, & &1["id"])
      assert Enum.all?(ids, &(&1 =~ ~r/^[0-9a-f]{8}$/))
      assert Enum.uniq(ids) == ids
      assert Enum.map(entries, & &1["parentId"]) == [nil | Enum.drop(ids, -1)]
      assert Enum.all?(entries, &match?({:ok, _, _}, DateTime.from_iso8601(&1["timestamp"])))

      assert %{"type" => "model_change", "model" => "anthropic/claude-haiku-4-5"} =
               hd(entries)
    end

    test "messages have pi's AgentMessage shapes", %{path: path} do
      [_header | entries] = lines(path)
      messages = for %{"type" => "message", "message" => m} <- entries, do: m

      [user | _] = for %{"role" => "user"} = m <- messages, do: m
      assert Map.keys(user) |> Enum.sort() == ~w(attribution content role timestamp)

      assert %{
               "attribution" => "user",
               "content" => [%{"type" => "text", "text" => "first line\nsecond line"}]
             } = user

      assert is_integer(user["timestamp"])

      [tool_turn, _done, error_turn] = for %{"role" => "assistant"} = m <- messages, do: m

      assert Map.keys(tool_turn) |> Enum.sort() ==
               ~w(api content model provider role stopReason timestamp usage)

      assert %{
               "api" => "anthropic-messages",
               "provider" => "anthropic",
               "model" => "claude-haiku-4-5"
             } = tool_turn

      assert "toolUse" = tool_turn["stopReason"]

      assert [
               %{"type" => "thinking", "thinking" => "plan"},
               %{"type" => "text", "text" => "Checking."},
               %{
                 "type" => "toolCall",
                 "id" => "t1",
                 "name" => "echo",
                 "arguments" => %{"text" => "hi"}
               }
             ] = tool_turn["content"]

      usage = tool_turn["usage"]

      assert Map.keys(usage) |> Enum.sort() ==
               ~w(cacheRead cacheWrite cost input output totalTokens)

      assert Map.keys(usage["cost"]) |> Enum.sort() == ~w(cacheRead cacheWrite input output total)

      assert %{
               "input" => 100,
               "output" => 20,
               "totalTokens" => 120,
               "cost" => %{"total" => 0.001}
             } = usage

      assert %{"stopReason" => "error", "content" => [], "errorMessage" => error} = error_turn

      # after the switch, pi's provider id and api for OpenAI Codex
      assert %{
               "api" => "openai-codex-responses",
               "provider" => "openai-codex",
               "model" => "gpt-5-mini"
             } = error_turn

      assert error =~ "402"

      [result] = for %{"role" => "toolResult"} = m <- messages, do: m

      assert Map.keys(result) |> Enum.sort() ==
               ~w(content isError role timestamp toolCallId toolName)

      assert %{
               "toolCallId" => "t1",
               "toolName" => "echo",
               "isError" => false,
               "content" => [%{"type" => "text", "text" => "hi"}]
             } = result

      assert [%{"model" => "openai-codex/gpt-5-mini"}] =
               for(%{"type" => "model_change"} = e <- tl(entries), do: e)

      for m <- messages, do: assert(m["role"] in ~w(user assistant toolResult))

      for %{"role" => "assistant", "stopReason" => r} <- messages,
          do: assert(r in ~w(stop length toolUse error aborted))
    end

    test "custom_message entries carry customType, content and display", %{tmp_dir: dir} do
      %{loop: loop, session: session} = start_loop(dir, [[{:text, "x"}, :block]])
      :ok = Loop.prompt(loop, "go")
      await_event(:message_update)
      :ok = Loop.stop(loop)
      collect()

      [notice] = for %{"type" => "custom_message"} = e <- lines(session.path), do: e

      assert Map.keys(notice) |> Enum.sort() ==
               ~w(attribution content customType display id parentId timestamp type)

      assert %{
               "customType" => "rho.notice",
               "content" => "Stopped by the user.",
               "display" => true
             } = notice
    end

    test "reopens to the same context and model", %{path: path, loop: loop} do
      {:ok, session, entries} = Session.open(path, "unused")
      assert Session.context(entries) == Loop.context(loop)
      assert session.model == "openai_codex:gpt-5-mini"
      assert session.title == "first line"
    end
  end

  describe "a real omp session" do
    setup %{tmp_dir: dir} do
      path = Path.join(dir, Path.basename(@fixture))
      File.cp!(@fixture, path)
      %{path: path}
    end

    test "opens: every entry kept, title slot skipped, model from model_change", %{path: path} do
      {:ok, session, entries} = Session.open(path, "unused")

      assert session.id == "01a0f133-128d-7000-92d9-6e4387f35ebb"
      assert session.model == "anthropic:claude-opus-5-5"
      assert session.leaf_id == "13076871"
      assert Enum.count(entries) == 78

      types = entries |> Enum.map(& &1["type"]) |> Enum.uniq() |> Enum.sort()

      assert types ==
               ~w(credential_pin custom message model_change thinking_level_change title_change)
    end

    test "rebuilds a valid req_llm context from its message entries", %{path: path} do
      {:ok, _session, entries} = Session.open(path, "unused")
      context = Session.context(entries)

      roles = Enum.frequencies_by(context, & &1.role)
      assert roles == %{user: 3, assistant: 17, tool: 27}

      # every tool result answers a call of the assistant message before it
      Enum.reduce(context, MapSet.new(), fn
        %{role: :assistant, tool_calls: calls}, _open -> MapSet.new(calls || [], & &1.id)
        %{role: :tool, tool_call_id: id}, open -> assert(MapSet.member?(open, id)) && open
        _msg, _open -> MapSet.new()
      end)

      [first | _] = context
      assert [%{text: "Read up on ~/code/mob" <> _}] = first.content
      assert {:ok, _} = ReqLLM.Context.validate(ReqLLM.Context.new(context))
    end

    test "appending continues the leaf without touching omp's lines", %{path: path} do
      before = File.read!(path)
      {:ok, session, _entries} = Session.open(path, "unused")
      {_session, entry} = Session.append(session, Session.user("from the phone"))

      assert String.starts_with?(File.read!(path), before)
      assert entry["parentId"] == "13076871"
      {:ok, _, entries} = Session.open(path, "unused")
      assert List.last(entries)["id"] == entry["id"]
    end

    test "a tool call without a result gets pi's synthetic aborted result" do
      call = %{"type" => "toolCall", "id" => "c1", "name" => "bash", "arguments" => %{}}

      entries = [
        %{"type" => "message", "message" => %{"role" => "user", "content" => "hi"}},
        %{"type" => "message", "message" => %{"role" => "assistant", "content" => [call]}},
        %{
          "type" => "message",
          "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => "again"}]}
        }
      ]

      assert [
               %{role: :user},
               %{role: :assistant},
               %{role: :tool, tool_call_id: "c1"} = synthetic,
               %{role: :user}
             ] =
               Session.context(entries)

      assert [%{text: text}] = synthetic.content
      assert text == Session.aborted_tool_text()
    end
  end

  describe "a compacted branch" do
    defp e(entry, id), do: Map.put(entry, "id", id)

    defp reply(text, calls \\ []),
      do: Session.assistant(%{text: text, tool_calls: calls, stop_reason: "stop"}, model())

    defp texts(messages),
      do: Enum.map(messages, &{&1.role, Enum.map_join(&1.content, "", fn p -> p.text end)})

    test "sends the latest summary as pi renders it, then the kept entries, then the rest" do
      call = %{"id" => "t1", "name" => "echo", "arguments" => %{}}

      entries = [
        e(Session.user("old question"), "u1"),
        e(reply("old answer"), "a1"),
        e(Session.user("kept question"), "u2"),
        e(Session.compaction("FIRST", "u1", 100, 50), "c1"),
        e(reply("kept answer", [call]), "a2"),
        e(Session.tool_result("t1", "echo", "out", false), "r2"),
        e(Session.compaction("## Goal\n- x", "u2", 300, 80), "c2"),
        e(Session.user("new question"), "u3")
      ]

      assert texts(Session.context(entries)) == [
               {:user,
                "Prior model work/tool state available.\n" <>
                  "MUST build on prior work; NEVER duplicate prior work.\n\n" <>
                  "<summary>\n## Goal\n- x\n</summary>"},
               {:user, "kept question"},
               {:assistant, "kept answer"},
               {:tool, "out"},
               {:user, "new question"}
             ]

      # a first kept entry not before the compaction: nothing kept but the summary
      gone = [
        e(Session.user("a"), "u1"),
        e(Session.compaction("S", "zz", 1, 1), "c1"),
        e(Session.user("b"), "u2")
      ]

      assert [{:user, "Prior model work" <> _}, {:user, "b"}] = texts(Session.context(gone))
    end

    test "attachments survive a compaction: listed in the summary, kept ones whole" do
      photo = %{
        kind: :image,
        name: "IMG_0412.jpg",
        path: "/ws/inbox/IMG_0412.jpg",
        mime: "image/jpeg",
        about: "1.2 MB · 3024×4032 · taken 2026:10:01 09:12:00",
        image: {"image/jpeg", <<0xFF, 0xD8, 0xFF, 0xD9>>}
      }

      notes = %{kind: :text, name: "notes.txt", path: "/ws/inbox/notes.txt", mime: "text/plain"}
      notes = Map.merge(notes, %{about: "12 B", text: "buy milk"})

      entries = [
        e(Session.user("what's this?", attachments: [photo]), "u1"),
        e(reply("a cat"), "a1"),
        e(Session.user("", attachments: [notes]), "u2"),
        e(Session.compaction("## Goal\n- cat", "u2", 9_000, 300), "c1")
      ]

      [summary, kept] = Session.context(entries)
      [%{text: summary_text}] = summary.content

      assert summary_text =~ "<summary>\n## Goal\n- cat\n</summary>"

      assert summary_text =~
               "- IMG_0412.jpg (image/jpeg) at /ws/inbox/IMG_0412.jpg: 1.2 MB · 3024×4032"

      refute summary_text =~ "notes.txt"
      assert [%{type: :text, text: "<attachment name=\"notes.txt\"" <> rest}] = kept.content
      assert rest =~ "buy milk"

      # kept from the photo on: its picture still goes to the model
      [_summary, first | _] =
        Session.context(List.replace_at(entries, 3, e(Session.compaction("S", "u1", 1, 1), "c1")))

      assert [:text, :text, :image] == Enum.map(first.content, & &1.type)
    end
  end

  describe "attachments" do
    defp pdf(dir, name, pages) do
      path = Path.join(dir, name)
      File.write!(path, "%PDF-1.7 " <> name)
      %{kind: :pdf, name: name, path: path, mime: "application/pdf", about: "x", pages: pages}
    end

    test "PDFs go as documents newest first, within 100 pages a request", %{tmp_dir: dir} do
      entries = [
        Session.user("old", attachments: [pdf(dir, "old.pdf", 30)]),
        Session.user("new", attachments: [pdf(dir, "new.pdf", 80)]),
        Session.user("small", attachments: [pdf(dir, "small.pdf", 20)])
      ]

      [old, new, small] = Session.messages(entries, inputs: [:text, :image, :pdf])
      assert [:text, :text, :file] = Enum.map(small.content, & &1.type)
      assert [:text, :text, :file] = Enum.map(new.content, & &1.type)
      assert [_, _, %{type: :text, text: note}] = old.content
      assert note =~ "old.pdf isn't sent as a document this time"

      # a model without PDFs gets the envelopes (path and about) only
      assert [[:text, :text], [:text, :text], [:text, :text]] =
               for(m <- Session.messages(entries), do: Enum.map(m.content, & &1.type))
    end

    test "what the user typed is told from the files by the message's attachments" do
      typed = Session.user("<attachment hi> is a tag", attachments: [pdf("/tmp", "a.pdf", 1)])
      assert Session.typed(typed["message"]) == "<attachment hi> is a tag"
      assert Session.typed(Session.user("<attachment x>")["message"]) == "<attachment x>"

      assert Session.typed(Session.user("", attachments: [pdf("/tmp", "b.pdf", 1)])["message"]) ==
               ""
    end
  end

  test "tool details and the model's pictures are kept in the file, never sent to the model",
       %{tmp_dir: dir} do
    png = <<137, 80, 78, 71, 1, 2, 3>>
    call = %{"id" => "c1", "name" => "passage", "arguments" => %{}}

    reply =
      %{text: "Here.", images: [{"image/png", png}], tool_calls: [call], stop_reason: "toolUse"}

    s = Session.new(dir, model(), dir)
    {s, _} = Session.append(s, Session.user("show me"))
    {s, _} = Session.append(s, Session.assistant(reply, model()))

    {s, _} =
      Session.append(
        s,
        Session.tool_result("c1", "passage", "Gen 1:1", false,
          details: %{ref: "Gen 1:1", verses: [1]}
        )
      )

    {_s, _} = Session.append(s, Session.tool_result("c2", "passage", "none", false))

    {:ok, _s, entries} = Session.open(s.path, model())
    [_change, _user, assistant, kept, plain] = Enum.map(entries, & &1["message"])

    assert [
             %{"type" => "text", "text" => "Here."},
             %{"type" => "image", "mimeType" => "image/png", "data" => data},
             %{"type" => "toolCall", "id" => "c1"}
           ] = assistant["content"]

    assert Base.decode64!(data) == png
    assert kept["details"] == %{"ref" => "Gen 1:1", "verses" => [1]}
    refute Map.has_key?(plain, "details")

    assert [_user, sent, result, _plain] = Session.messages(entries)
    assert [%{type: :text, text: "Here."}] = sent.content
    assert [%{type: :text, text: "Gen 1:1"}] = result.content
    refute inspect(Session.context(entries)) =~ "verses"
  end

  test "a reply that was only pictures stays in the model's history as a note, without them",
       %{tmp_dir: dir} do
    reply = %{text: "", images: [{"image/png", <<1>>}, {"image/png", <<2>>}], stop_reason: "stop"}
    s = Session.new(dir, model(), dir)
    {s, _} = Session.append(s, Session.user("draw two"))
    {s, _} = Session.append(s, Session.assistant(reply, model()))
    {_s, _} = Session.append(s, Session.user("again"))
    {:ok, _s, entries} = Session.open(s.path, model())

    assert [_, %{role: :assistant, content: [%{type: :text, text: "(made 2 pictures)"}]}, _] =
             Session.messages(entries)
  end

  test "lists sessions newest first, by header", %{tmp_dir: dir} do
    a = Session.new(dir, model(), dir)
    {_, _} = Session.append(a, Session.user("older"))
    File.touch!(a.path, System.os_time(:second) - 60)
    b = Session.new(dir, model(), dir)
    {_, _} = Session.append(b, Session.user("newer"))

    assert [%{title: "newer", path: path_b}, %{title: "older"}] = Session.list(dir)
    assert path_b == b.path
    assert Session.latest(dir) == b.path
  end

  describe "keeping a copy in step by bytes" do
    test "a copy kept in step from its size, in chunks, reads back the same", %{tmp_dir: dir} do
      s = Session.new(Path.join(dir, "phone"), model(), dir)
      {s, _} = Session.append(s, Session.user("first"))
      copy = Path.join([dir, "server", Path.basename(s.path)])

      # what a link does: the bytes past the copy's size, in 64-byte chunks
      # (one may end mid-line), joined, then appended at that size
      sync = fn ->
        {:ok, from} = with({:error, :enoent} <- Session.size(copy), do: {:ok, 0})
        {:ok, to} = Session.size(s.path)

        bytes =
          Stream.unfold(from, fn
            ^to ->
              nil

            at ->
              with {:ok, chunk} <- Session.read_from(s.path, at, max_bytes: 64),
                   do: {chunk, at + byte_size(chunk)}
          end)
          |> Enum.join()

        Session.append_bytes(copy, from, bytes)
      end

      assert {:ok, n} = sync.()
      {_s, _} = Session.append(s, Session.user("second"))
      assert {:ok, m} = sync.()
      assert m > n
      assert File.read!(copy) == File.read!(s.path)
      {:ok, _, entries} = Session.open(copy, model())
      assert List.last(entries)["message"]["content"] == [%{"type" => "text", "text" => "second"}]
    end

    test "size counts whole lines only; read_from stops there", %{tmp_dir: dir} do
      path = Path.join(dir, "s.jsonl")
      File.write!(path, "{\"a\":1}\n{\"b\":2}\n{\"torn")

      assert Session.size(path) == {:ok, 16}
      assert Session.read_from(path, 8) == {:ok, "{\"b\":2}\n"}
      assert Session.read_from(path, 16) == {:ok, ""}
      assert Session.read_from(path, 17) == {:error, :past_end}
      assert Session.read_from(path, 0, max_bytes: 3) == {:ok, "{\"a"}
      assert Session.size(Path.join(dir, "none.jsonl")) == {:error, :enoent}

      # a line longer than one scan chunk
      long = String.duplicate("x", 70_000)
      File.write!(path, "#{long}\n#{long}")
      assert Session.size(path) == {:ok, 70_001}
    end

    test "append_bytes: idempotent on a resend, refuses a diverged copy, drops a torn line",
         %{tmp_dir: dir} do
      path = Path.join([dir, "new", "s.jsonl"])
      a = "{\"a\":1}\n"
      b = "{\"b\":2}\n"

      assert Session.append_bytes(path, 0, a) == {:ok, 8}
      assert Session.append_bytes(path, 8, b) == {:ok, 16}
      # the ack was lost and the same bytes come again
      assert Session.append_bytes(path, 8, b) == {:ok, 16}
      assert File.read!(path) == a <> b

      # different bytes where these were: the copies diverged
      assert Session.append_bytes(path, 8, "{\"c\":3}\n") == {:error, {:conflict, 16}}
      assert Session.append_bytes(path, 4, b) == {:error, {:conflict, 16}}
      assert Session.append_bytes(path, 16, "{\"c\":") == {:error, :partial_line}

      File.write!(path, "{\"torn", [:append])
      assert Session.append_bytes(path, 16, "{\"c\":3}\n") == {:ok, 24}
      assert File.read!(path) == a <> b <> "{\"c\":3}\n"

      assert Session.append_bytes(Path.join(dir, "missing.jsonl"), 8, a) == {:error, :enoent}
    end
  end
end
