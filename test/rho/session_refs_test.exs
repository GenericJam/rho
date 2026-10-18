defmodule Rho.SessionRefsTest do
  # Sets the VM-wide `:resolve_attachment` hook.
  use ExUnit.Case, async: false

  import Rho.Test.LoopHelpers

  alias Rho.Loop
  alias Rho.Session
  alias Rho.Test.FakeLLM

  @moduletag :tmp_dir
  @moduletag :capture_log

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9>>
  @small <<0xFF, 0xD8, 0xFF, 0xD9>>

  defmodule RefPicture do
    @moduledoc "Test tool: answers with a picture the host keeps, by reference."
    @behaviour Rho.Tool

    @impl true
    def name, do: "draw"
    @impl true
    def description, do: "Draws a picture."
    @impl true
    def parameter_schema, do: %{"type" => "object"}
    @impl true
    def run(_args, _ctx),
      do: {:ok, {:images, [%{ref: "m-drawn", mime: "image/png", name: "cat.png"}], "drew it"}}
  end

  setup do
    on_exit(fn -> Application.delete_env(:rho, :resolve_attachment) end)
  end

  # A hook answering from `files` (`ref => result`) and telling the test each call.
  defp resolve_with(files) do
    test = self()

    Application.put_env(:rho, :resolve_attachment, fn attachment, ctx ->
      send(test, {:resolved, attachment["ref"], ctx})
      Map.fetch!(files, attachment["ref"])
    end)
  end

  defp photo(ref, name \\ "IMG_0412.jpg") do
    %{kind: :image, name: name, mime: "image/jpeg", about: "1.2 MB · 3024×4032", ref: ref}
  end

  defp resolved_refs do
    receive do
      {:resolved, ref, _ctx} -> [ref | resolved_refs()]
    after
      0 -> []
    end
  end

  test "a file by reference is stored as its ref and metadata, never its bytes",
       %{tmp_dir: dir} do
    # bytes given anyway are not stored either
    attachment =
      Map.merge(photo("m-1"), %{path: "/ws/inbox/IMG_0412.jpg", image: {"image/jpeg", @jpeg}})

    s = Session.new(dir, model(), dir)
    {s, _} = Session.append(s, Session.user("what's this?", attachments: [attachment]))
    {:ok, _s, [_change, %{"message" => message}]} = Session.open(s.path, model())

    refute File.read!(s.path) =~ Base.encode64(@jpeg)
    refute Enum.any?(message["content"], &(&1["type"] == "image"))

    assert [%{"type" => "text", "text" => "what's this?"}, %{"text" => envelope}] =
             message["content"]

    assert envelope ==
             ~s|<attachment name="IMG_0412.jpg" type="image/jpeg" path="/ws/inbox/IMG_0412.jpg" ref="m-1">\n| <>
               "1.2 MB · 3024×4032\n</attachment>"

    assert Session.attachments(message) == [
             %{
               "kind" => "image",
               "name" => "IMG_0412.jpg",
               "mimeType" => "image/jpeg",
               "about" => "1.2 MB · 3024×4032",
               "path" => "/ws/inbox/IMG_0412.jpg",
               "ref" => "m-1"
             }
           ]

    assert Session.typed(message) == "what's this?"
  end

  test "an attachment needs a path or a ref; the loop says so in the caller", %{tmp_dir: dir} do
    %{loop: loop} = start_loop(dir, [])
    bad = Map.delete(photo("m-1"), :ref)

    assert_raise ArgumentError, ~r/IMG_0412.jpg.*needs a :path or a :ref/, fn ->
      Loop.prompt(loop, "", [bad])
    end

    assert Process.alive?(loop)
    assert_raise ArgumentError, fn -> Session.user("", attachments: [bad]) end
  end

  test "pictures by reference are fetched when the request is built, each after its envelope",
       %{tmp_dir: dir} do
    resolve_with(%{
      "m-1" => {:ok, {"image/webp", "webp-1"}},
      "m-2" => {:ok, {"image/jpeg", @jpeg}}
    })

    %{loop: loop, llm: llm, session: session} = start_loop(dir, [[{:text, "two cats"}]])

    inline = %{
      kind: :image,
      name: "old.jpg",
      path: "/ws/old.jpg",
      mime: "image/jpeg",
      about: "inline",
      image: {"image/jpeg", @small}
    }

    :ok = Loop.prompt(loop, "compare", [photo("m-1", "a.jpg"), inline, photo("m-2", "b.jpg")])
    collect()

    [request] = FakeLLM.requests(llm)
    [%{role: :user, content: parts}] = request.messages

    assert [
             %{type: :text, text: "compare"},
             %{type: :text, text: "<attachment name=\"a.jpg\"" <> _},
             # the hook's mime, not the stored one: the host may re-encode
             %{type: :image, data: "webp-1", media_type: "image/webp"},
             %{type: :text, text: "<attachment name=\"old.jpg\"" <> _},
             %{type: :image, data: @small, media_type: "image/jpeg"},
             %{type: :text, text: "<attachment name=\"b.jpg\"" <> _},
             %{type: :image, data: @jpeg, media_type: "image/jpeg"}
           ] = parts

    # the hook is told the session; the inline picture never reaches it
    sid = session.id
    assert_received {:resolved, "m-1", %{session_id: ^sid}}
    assert_received {:resolved, "m-2", %{session_id: ^sid}}
    assert resolved_refs() == []
    refute File.read!(session.path) =~ "d2VicC0x"
  end

  test "each ref is fetched once a request, however often it's attached" do
    resolve_with(%{"m-1" => {:ok, {"image/jpeg", @jpeg}}})

    entries = [
      Session.user("one", attachments: [photo("m-1")]),
      Session.user("again", attachments: [photo("m-1")])
    ]

    [first, again] = Session.messages(entries)
    assert [:text, :text, :image] = Enum.map(first.content, & &1.type)
    assert [:text, :text, :image] = Enum.map(again.content, & &1.type)
    assert resolved_refs() == ["m-1"]
  end

  test "without a hook, or when it fails, the model gets a note in the picture's place" do
    entries = [Session.user("look", attachments: [photo("m-1", "gone.jpg")])]
    note = "(gone.jpg couldn't be loaded, so it isn't sent.)"

    # no hook configured
    assert [%{content: [_typed, _envelope, %{type: :text, text: ^note}]}] =
             Session.messages(entries)

    for result <- [{:error, :enoent}, :nope, {:ok, "no mime"}] do
      resolve_with(%{"m-1" => result})
      assert [%{content: [_, _, %{type: :text, text: ^note}]}] = Session.messages(entries)
    end

    Application.put_env(:rho, :resolve_attachment, fn _a, _ctx -> raise "store down" end)
    assert [%{content: [_, _, %{type: :text, text: ^note}]}] = Session.messages(entries)

    Application.put_env(:rho, :resolve_attachment, fn _a, _ctx -> exit(:timeout) end)
    assert [%{content: [_, _, %{type: :text, text: ^note}]}] = Session.messages(entries)
  end

  test "a model without pictures gets the usual note and the hook isn't called" do
    resolve_with(%{"m-1" => {:ok, {"image/jpeg", @jpeg}}})
    entries = [Session.user("", attachments: [photo("m-1")])]

    assert [%{content: [%{text: "<attachment " <> _}, %{text: note}]}] =
             Session.messages(entries, inputs: [:text])

    assert note =~ "doesn't take pictures"
    assert resolved_refs() == []

    # a text-only use (compaction's summary) leaves them out without fetching
    assert [%{content: [%{text: "<attachment " <> _}]}] = Session.messages(entries, fetch: false)
    assert resolved_refs() == []
  end

  test "PDFs by reference go as documents, newest first within 100 pages" do
    resolve_with(%{
      "p-old" => {:ok, {"application/pdf", "%PDF old"}},
      "p-new" => {:ok, {"application/pdf", "%PDF new"}}
    })

    pdf = fn ref, pages ->
      %{
        kind: :pdf,
        name: "#{ref}.pdf",
        mime: "application/pdf",
        about: "x",
        ref: ref,
        pages: pages
      }
    end

    entries = [
      Session.user("old", attachments: [pdf.("p-old", 30)]),
      Session.user("new", attachments: [pdf.("p-new", 80)])
    ]

    [old, new] = Session.messages(entries, inputs: [:text, :pdf])

    assert [_, _, %{type: :file, data: "%PDF new", media_type: "application/pdf"}] = new.content
    assert [_, _, %{type: :text, text: note}] = old.content

    assert note ==
             "(p-old.pdf isn't sent as a document this time: newer documents fill the request.)"

    # a model without PDFs: envelopes only, nothing fetched
    _ = resolved_refs()

    assert [[:text, :text], [:text, :text]] =
             for(m <- Session.messages(entries), do: Enum.map(m.content, & &1.type))

    assert resolved_refs() == []
  end

  test "a tool's picture by reference is stored as an attachment and fetched for the model",
       %{tmp_dir: dir} do
    resolve_with(%{"m-drawn" => {:ok, {"image/png", "png-bytes"}}})
    script = [[{:tool_call, "c1", "draw", %{}}], [{:text, "Here it is."}]]
    %{loop: loop, llm: llm, session: session} = start_loop(dir, script, tools: [RefPicture])
    :ok = Loop.prompt(loop, "draw a cat")
    collect()

    {:ok, _s, entries} = Session.open(session.path, model())
    result = Enum.find_value(entries, &(&1["message"]["role"] == "toolResult" && &1["message"]))

    assert result["content"] == [%{"type" => "text", "text" => "drew it"}]

    assert Session.attachments(result) == [
             %{
               "kind" => "image",
               "name" => "cat.png",
               "mimeType" => "image/png",
               "ref" => "m-drawn"
             }
           ]

    assert Session.typed(result) == "drew it"

    [_first, second] = FakeLLM.requests(llm)
    tool_message = Enum.find(second.messages, &(&1.role == :tool))

    assert [
             %{type: :text, text: "drew it"},
             %{type: :image, data: "png-bytes", media_type: "image/png"}
           ] =
             tool_message.content
  end

  test "a summarized-away file by reference is listed by its ref" do
    entries = [
      Map.put(Session.user("look", attachments: [photo("m-1")]), "id", "u1"),
      Map.put(Session.user("next"), "id", "u2"),
      Map.put(Session.compaction("S", "u2", 1, 1), "id", "c1")
    ]

    [summary, _kept] = Session.context(entries)
    [%{text: text}] = summary.content
    assert text =~ "- IMG_0412.jpg (image/jpeg), ref m-1: 1.2 MB · 3024×4032"
    assert resolved_refs() == []
  end
end
