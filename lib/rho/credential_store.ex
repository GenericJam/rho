defmodule Rho.CredentialStore do
  @moduledoc """
  Where rho keeps secrets: the provider sign-ins and API keys
  (`Rho.Auth`), a binary value per string key. A host seam:
  `config :rho, :credential_store, Module` picks the backend.

  The default, `Rho.CredentialStore.File`, keeps each key in a 0600 file
  under `<data dir>/secure/`: right for a computer and for tests. A phone
  app plugs in the platform's secure store (Android Keystore / iOS
  Keychain); the mob_secure_store plugin's `MobSecureStore` has exactly
  this shape and can be configured as it is. A store that can't work on
  this device (its native code missing) should fail closed, answering
  every call `{:error, :secure_store_unavailable}`, rather than fall back
  to plain files: `Rho.Auth` then reports it instead of signing in.

  Keys are non-empty UTF-8 strings; values arbitrary binaries (rho stores
  JSON).
  """

  @doc "The value at `key`: `{:ok, value}`, `:error` when there is none, `{:error, reason}` when the store failed."
  @callback get(key :: String.t()) :: {:ok, binary()} | :error | {:error, term()}

  @doc "Upserts `key`, durably (`:ok` means written, not queued)."
  @callback put(key :: String.t(), value :: binary()) :: :ok | {:error, term()}

  @doc "Removes `key`; removing an absent one is `:ok`."
  @callback delete(key :: String.t()) :: :ok | {:error, term()}

  @spec get(String.t()) :: {:ok, binary()} | :error | {:error, term()}
  def get(key), do: backend().get(key)

  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(key, value), do: backend().put(key, value)

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key), do: backend().delete(key)

  @doc "The backend in effect (`Rho.Config.credential_store/0`)."
  @spec backend() :: module()
  def backend, do: Rho.Config.credential_store()
end

defmodule Rho.CredentialStore.File do
  @moduledoc """
  The default backend: one 0600 file per key under `<data dir>/secure/`,
  the key made filename-safe. Written through a temp file created 0600
  before the secret goes in, then renamed over the old one.
  """
  @behaviour Rho.CredentialStore

  @impl true
  def get(key) do
    case File.read(path(key)) do
      {:ok, value} -> {:ok, value}
      {:error, :enoent} -> :error
      {:error, _} = error -> error
    end
  end

  @impl true
  def put(key, value) do
    path = path(key)
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, ""),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, value) do
      File.rename(tmp, path)
    end
  end

  @impl true
  def delete(key) do
    case File.rm(path(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec path(String.t()) :: Path.t()
  def path(key), do: Path.join([Rho.Config.data_dir(), "secure", safe(key)])

  defp safe(key), do: String.replace(key, Regex.compile!("[^\\w.-]", "u"), "_")
end
