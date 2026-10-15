defmodule Rho.Test.FlakyCredentialStore do
  @moduledoc """
  The default file store, except the operations named by `fail/1` return
  `{:error, :disk_full}`. App-wide (`config :rho, :credential_store, ...`,
  read by the Rho.Auth process), so tests using it are `async: false`.
  """
  @behaviour Rho.CredentialStore

  alias Rho.CredentialStore.File, as: Store

  @doc "Installs this store; `ops` (`:put`, `:delete`) fail until `fail([])`."
  @spec install(list()) :: :ok
  def install(ops \\ []) do
    Application.put_env(:rho, :credential_store, __MODULE__)
    fail(ops)
  end

  @spec fail(list()) :: :ok
  def fail(ops), do: Application.put_env(:rho, :flaky_credential_store, ops)

  @spec restore() :: :ok
  def restore do
    Application.delete_env(:rho, :credential_store)
    Application.delete_env(:rho, :flaky_credential_store)
  end

  @impl true
  def get(key), do: Store.get(key)

  @impl true
  def put(key, value), do: unless_failing(:put, fn -> Store.put(key, value) end)

  @impl true
  def delete(key), do: unless_failing(:delete, fn -> Store.delete(key) end)

  defp unless_failing(op, fun) do
    if op in Application.get_env(:rho, :flaky_credential_store, []),
      do: {:error, :disk_full},
      else: fun.()
  end
end

defmodule Rho.Test.UnavailableStore do
  @moduledoc "A device store whose native code isn't loaded: refuses everything (fails closed)."
  @behaviour Rho.CredentialStore

  @impl true
  def get(_key), do: {:error, :secure_store_unavailable}

  @impl true
  def put(_key, _value), do: {:error, :secure_store_unavailable}

  @impl true
  def delete(_key), do: {:error, :secure_store_unavailable}
end
