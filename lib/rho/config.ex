defmodule Rho.Config do
  @moduledoc """
  The host's settings for rho, `config :rho, ...`, each with a default that
  works on a computer. `:data_dir`, `:default_model` and `:system_prompt`
  may be given as `{module, function, args}` (or a 0-arity function),
  called each time the value is read, so a host can keep them in its own
  settings and change them at run time.

    * `:data_dir`: where rho keeps sessions, artifacts, todo lists, the
      cost ledger, `usage.json`, `settings.json`, the trimmed model catalog
      and (with the default credential store) the sign-ins. Default:
      `MOB_DATA_DIR` when set (a mob app's private files dir), else the
      OS's per-user data dir for `"rho"` (`:filename.basedir/2`). Created
      on first read.
    * `:credential_store`: a `Rho.CredentialStore` module. Default
      `Rho.CredentialStore.File` (0600 files under the data dir); a phone
      app plugs in the platform's secure store (Keystore / Keychain).
    * `:settings`: a `Rho.Settings` module (fallback model, daily cost
      cap). Default `Rho.Settings.File` (`settings.json` in the data dir).
    * `:default_model`: a req_llm spec, default
      `#{inspect("anthropic:claude-haiku-4-5")}`.
    * `:system_prompt`: the loop's system prompt when a loop isn't given
      one. Default `Rho.default_system_prompt/0`.
    * `:namespace`: the prefix of the `customType` of the loop's notices
      in a session (`"<namespace>.notice"`, `.error`, `.aside`). Default
      `"rho"`; Operator's sessions use `"operator"`.
    * `:open_url`: how `Rho.Auth.Login` opens the provider's sign-in page,
      `fn url -> :ok end` or an MFA taking the URL last. Default
      `Rho.Auth.Login.open_in_browser/1` (`open` / `xdg-open` / `start`);
      a mob app sets `{Mob.Device, :open_url, []}`.
    * `:app_name`: what the sign-in pages call the app ("Switch back to
      … to finish signing in"). Default `"the app"`.
    * `:hints`: where the user fixes a failed call, as `Rho.LLM.describe/1`
      and `Rho.Auth.Login` say it: `sign_in:` (default
      `"from the app's settings"`, as in "sign in again from …") and
      `switch_model:` (default `"in the app's settings"`); and, for Dyn
      (`Rho.Dyn.agent_guide/0`, `dyn_propose`), `approve:`, how the human
      approves a proposed generation (default `"on the phone with the screen
      lock (fingerprint, face, PIN, pattern, password or passcode)"`, as
      `Rho.Dyn.Approval.Biometric` behind an approve control).
    * `:tools`, `:tool_sources`: `Rho.ToolRegistry`'s core tools and
      registry sources, when `Rho.Supervisor` isn't given them.
    * `:resolve_attachment`: how rho gets the bytes of a file the host
      attached by reference (`ref` in `t:Rho.Session.attachment/0`, or a
      tool's `%{ref: …}` picture), `fn attachment, ctx -> … end` or an
      MFA taking those two last. `attachment` is the stored map
      (`Rho.Session.attachments/1`: `"kind"`, `"ref"`, `"mimeType"`,
      `"name"`, ...), `ctx` is `%{session_id: id}` (the loop's session; nil
      when a host builds the context itself without one). It returns
      `{:ok, {mime_type, bytes}}`, ready for the model (any resizing is the
      host's), or `{:error, reason}`. It is called for referenced pictures
      when the model takes pictures and PDFs when it takes PDFs, once per
      kind and ref every time the loop makes a model call, in that call's process
      (`Rho.Session.fetch/2`), not the loop's, so a slow store doesn't
      hold up the loop; the call waits for it. Default: none, so a
      referenced file reaches the model as a note saying it couldn't be
      loaded.
    * `:dyn`: the Dyn layer (agent-written code, `Rho.Dyn`), off by
      default; its keys are `Rho.Dyn.Config`'s.
  """

  alias Rho.Auth.Login

  @default_model "anthropic:claude-haiku-4-5"

  @doc "The data dir (created if missing)."
  @spec data_dir() :: String.t()
  def data_dir do
    dir =
      case Application.get_env(:rho, :data_dir) do
        nil -> default_data_dir()
        value -> resolve(value, [])
      end

    File.mkdir_p!(dir)
    dir
  end

  defp default_data_dir do
    case System.get_env("MOB_DATA_DIR") do
      dir when dir in [nil, ""] -> :filename.basedir(:user_data, "rho") |> to_string()
      dir -> dir
    end
  end

  @doc "The `:credential_store` module in effect."
  @spec credential_store() :: module()
  def credential_store, do: Application.get_env(:rho, :credential_store, Rho.CredentialStore.File)

  @doc "The `:settings` module in effect."
  @spec settings() :: module()
  def settings, do: Application.get_env(:rho, :settings, Rho.Settings.File)

  @doc "The `:default_model` spec, resolved: what `Rho.start_loop/1` uses without a `:model`."
  @spec default_model() :: String.t()
  def default_model,
    do: :rho |> Application.get_env(:default_model, @default_model) |> resolve([])

  @doc "The `:system_prompt`, resolved (`Rho.default_system_prompt/0` when unset)."
  @spec system_prompt() :: String.t()
  def system_prompt do
    case Application.get_env(:rho, :system_prompt) do
      nil -> Rho.default_system_prompt()
      value -> resolve(value, [])
    end
  end

  @doc "The `:namespace` prefix of the loop's notice `customType`s."
  @spec namespace() :: String.t()
  def namespace, do: Application.get_env(:rho, :namespace, "rho")

  @doc "Opens `url` for the user with the configured `:open_url`."
  @spec open_url(String.t()) :: term()
  def open_url(url) do
    :rho
    |> Application.get_env(:open_url, &Login.open_in_browser/1)
    |> resolve([url])
  end

  @doc "The `:app_name` the sign-in pages show."
  @spec app_name() :: String.t()
  def app_name, do: Application.get_env(:rho, :app_name, "the app")

  @doc """
  The bytes of a file attached by reference, from the `:resolve_attachment`
  hook (`{:error, :no_resolver}` without one). `ctx` is
  `%{session_id: id | nil}`.
  """
  @spec resolve_attachment(map(), map()) :: {:ok, {String.t(), binary()}} | {:error, term()}
  def resolve_attachment(attachment, ctx) do
    case Application.get_env(:rho, :resolve_attachment) do
      nil -> {:error, :no_resolver}
      hook -> resolve(hook, [attachment, ctx])
    end
  end

  @default_hints [
    sign_in: "from the app's settings",
    switch_model: "in the app's settings",
    approve:
      "on the phone with the screen lock (fingerprint, face, PIN, pattern, password or passcode)"
  ]

  @doc "The `:hints` entry `key` (`:sign_in`, `:switch_model` or `:approve`)."
  @spec hint(:sign_in | :switch_model | :approve) :: String.t()
  def hint(key), do: Application.get_env(:rho, :hints, [])[key] || @default_hints[key]

  @doc """
  A config value: a function or `{m, f, a}` is called (with `extra` args
  appended), anything else is returned as it is.
  """
  @spec resolve(term(), [term()]) :: term()
  def resolve({m, f, a}, extra) when is_atom(m) and is_atom(f) and is_list(a),
    do: apply(m, f, a ++ extra)

  def resolve(fun, extra) when is_function(fun), do: apply(fun, extra)
  def resolve(value, _extra), do: value
end
