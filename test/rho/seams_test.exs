defmodule Rho.SeamsTest do
  # async: false: these change app-wide config (`config :rho, ...`).
  use ExUnit.Case, async: false

  alias Rho.Config
  alias Rho.CredentialStore
  alias Rho.Dyn
  alias Rho.Loop
  alias Rho.Session
  alias Rho.Settings
  alias Rho.Test.FakeLLM
  alias Rho.Tools.DynPropose

  @moduletag :tmp_dir

  defp put_env(key, value) do
    old = Application.fetch_env(:rho, key)
    Application.put_env(:rho, key, value)

    on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(:rho, key, v)
        :error -> Application.delete_env(:rho, key)
      end
    end)
  end

  describe "data dir" do
    test "the host's path, or an MFA read on every call; created on first read", %{tmp_dir: dir} do
      put_env(:data_dir, Path.join(dir, "a"))
      assert Config.data_dir() == Path.join(dir, "a")
      assert File.dir?(Path.join(dir, "a"))

      put_env(:data_dir, {Path, :join, [dir, "b"]})
      assert Config.data_dir() == Path.join(dir, "b")
    end

    test "default: MOB_DATA_DIR on a mob device, else the OS's user data dir", %{tmp_dir: dir} do
      old = Application.fetch_env!(:rho, :data_dir)
      Application.delete_env(:rho, :data_dir)
      System.put_env("MOB_DATA_DIR", dir)

      on_exit(fn ->
        System.delete_env("MOB_DATA_DIR")
        Application.put_env(:rho, :data_dir, old)
      end)

      assert Config.data_dir() == dir

      System.delete_env("MOB_DATA_DIR")
      assert Config.data_dir() == to_string(:filename.basedir(:user_data, "rho"))
    end
  end

  describe "credential store" do
    test "the default file store: absent is :error, put/get/delete round trip, 0600" do
      assert CredentialStore.backend() == CredentialStore.File
      key = "test:#{System.unique_integer([:positive])}"

      assert CredentialStore.get(key) == :error
      assert :ok = CredentialStore.put(key, <<0, 1, 255>>)
      assert CredentialStore.get(key) == {:ok, <<0, 1, 255>>}
      assert File.stat!(CredentialStore.File.path(key)).mode |> Bitwise.band(0o777) == 0o600
      assert :ok = CredentialStore.delete(key)
      assert :ok = CredentialStore.delete(key)
      assert CredentialStore.get(key) == :error
    end

    test "a host store is used as configured, and a failed-closed one reads as signed out" do
      put_env(:credential_store, Rho.Test.UnavailableStore)
      start_supervised!(Rho.Auth)

      assert Rho.Auth.get(:anthropic) == :error
      assert Rho.Auth.credential(:anthropic) == {:error, :signed_out}
      assert Rho.Auth.put_api_key(:anthropic, "sk") == {:error, :secure_store_unavailable}
    end
  end

  describe "settings" do
    test "defaults: a $1 daily cap and no fallback model", %{tmp_dir: dir} do
      assert Settings.daily_cap(dir) == 1.0
      assert Settings.fallback_model(dir) == nil
    end

    test "the file keeps what's put, and other keys in it", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "settings.json"), ~s({"voice": "off"}))
      :ok = Settings.File.put_daily_cap(2.5, dir)
      :ok = Settings.File.put_fallback_model("openai_codex:gpt-5", dir)

      assert Settings.daily_cap(dir) == 2.5
      assert Settings.fallback_model(dir) == "openai_codex:gpt-5"

      assert %{"voice" => "off", "daily_cap" => 2.5} =
               Jason.decode!(File.read!(Path.join(dir, "settings.json")))

      :ok = Settings.File.put_fallback_model(nil, dir)
      assert Settings.fallback_model(dir) == nil
    end

    test "an unreadable file or a bad value means the default", %{tmp_dir: dir} do
      path = Path.join(dir, "settings.json")
      File.write!(path, "{not json")
      assert Settings.daily_cap(dir) == 1.0
      File.write!(path, ~s({"daily_cap": -1, "fallback_model": ""}))
      assert Settings.daily_cap(dir) == 1.0
      assert Settings.fallback_model(dir) == nil
    end

    defmodule HostSettings do
      @behaviour Rho.Settings
      @impl true
      def fallback_model(_dir), do: "openai_codex:gpt-5"
      @impl true
      def daily_cap(_dir), do: 0.0
    end

    test "a host module replaces the file: the loop's cost cap follows it", %{tmp_dir: dir} do
      put_env(:settings, HostSettings)
      assert Settings.fallback_model(dir) == "openai_codex:gpt-5"

      {:ok, llm} = FakeLLM.start([[{:text, "never"}]])
      session = Session.new(dir, "anthropic:claude-haiku-4-5", dir)
      sup = start_supervised!(Task.Supervisor)

      loop =
        start_supervised!(
          {Loop,
           session: session,
           llm: {FakeLLM, llm},
           tools: [],
           task_supervisor: sup,
           data_dir: dir,
           budget: dir,
           system_prompt: "t"}
        )

      :ok = Loop.subscribe(loop)
      :ok = Loop.prompt(loop, "hi")
      assert_receive {:rho, _, %{type: :agent_end, reason: :cost_cap}}, 2_000
      refute_received {:llm_request, _, _}
    end
  end

  describe "session notices" do
    test "written under the host's namespace, read back whatever wrote them" do
      assert Session.custom(:notice, "x")["customType"] == "rho.notice"

      put_env(:namespace, "operator")
      entry = Session.custom(:error, "x")
      assert entry["customType"] == "operator.error"
      assert Session.notice_kind(entry) == :error
      assert Session.notice_kind(%{entry | "customType" => "rho.aside"}) == :aside
      assert Session.notice_kind(Session.user("hi")) == nil
    end
  end

  describe "host wording" do
    test "remedies and sign-in pages say where the host's settings are" do
      assert Rho.LLM.describe({:signed_out, :google}) ==
               "Not signed in to Gemini (Google): sign in from the app's settings."

      put_env(:hints, sign_in: "from [menu] › accounts")
      put_env(:app_name, "Operator")

      assert Rho.LLM.describe({:signed_out, :google}) ==
               "Not signed in to Gemini (Google): sign in from [menu] › accounts."

      assert Config.app_name() == "Operator"
    end

    test "Dyn's agent-facing text says how the host's human approves a generation" do
      assert Dyn.agent_guide() =~ "approves it on the phone with the screen lock"
      assert DynPropose.description() =~ "approve it on the phone with the screen lock"

      put_env(:hints, approve: "in the Workshop, with the proposal's Approve button")

      for text <- [Dyn.agent_guide(), DynPropose.description()] do
        assert text =~ "it in the Workshop, with the proposal's Approve button"
        refute text =~ "screen lock"
      end
    end

    test "open_url: the host's function, or an MFA with the URL appended" do
      test = self()
      put_env(:open_url, fn url -> send(test, {:opened, url}) && :ok end)
      Config.open_url("https://example.com/a")
      assert_received {:opened, "https://example.com/a"}

      put_env(:open_url, {Kernel, :send, [test]})
      Config.open_url("https://example.com/b")
      assert_received "https://example.com/b"
    end
  end

  describe "supervisor" do
    test "a host starts rho in its own tree and runs a loop on its tools", %{tmp_dir: dir} do
      put_env(:data_dir, dir)

      {:ok, llm} =
        FakeLLM.start([[{:tool_call, "c1", "echo", %{"text" => "hi"}}], [{:text, "ok"}]])

      start_supervised!(
        {Rho.Supervisor,
         tools: [Rho.Test.Tools.Echo], auth: [], login: [open_url: fn _ -> :ok end]}
      )

      assert Application.get_env(:llm_db, :snapshot_path) ==
               Path.join(dir, "llm_db_snapshot.json")

      assert Rho.ToolRegistry.core_tools() == [Rho.Test.Tools.Echo]

      {:ok, loop} = Rho.start_loop(llm: {FakeLLM, llm}, system_prompt: "t")
      :ok = Loop.subscribe(loop)
      :ok = Loop.prompt(loop, "go")
      assert_receive {:rho, _, %{type: :tool_execution_end, name: "echo", text: "hi"}}, 2_000
      assert_receive {:rho, _, %{type: :agent_end, reason: :done}}, 2_000

      %{path: path} = Loop.snapshot(loop)
      assert Path.dirname(path) == Path.join(dir, "sessions")
    end
  end
end
