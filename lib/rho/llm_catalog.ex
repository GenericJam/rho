defmodule Rho.LLMCatalog do
  @moduledoc """
  Gives llm_db (the model catalog req_llm resolves models through) a
  snapshot that works on a phone.

  llm_db reads its packaged `priv/llm_db/snapshot.json` (10 MB, 230
  providers) at runtime, but deps' priv/ isn't shipped to a mob device and
  `Application.app_dir/2` doesn't resolve there. `compile_embed: true`
  works but costs a 12.9 MB beam and a 2.4-20 s first lookup on a
  1-scheduler phone BEAM. rho only talks to Anthropic, OpenAI (req_llm
  resolves `openai_codex:` models through `openai`'s) and Google, so this
  module trims the packaged snapshot to those providers at compile time
  (its own snapshot_id, so llm_db's strict integrity check still holds),
  and `install!/0` writes it to the data dir and points
  `config :llm_db, :snapshot_path` at it before the first lookup
  (`Rho.Supervisor` does this when it starts).
  """

  @providers ["anthropic", "openai", "google"]
  @source :llm_db |> :code.priv_dir() |> Path.join("llm_db/snapshot.json")
  @external_resource @source

  @json (
          snapshot = @source |> File.read!() |> Jason.decode!()
          snapshot = Map.update!(snapshot, "providers", &Map.take(&1, @providers))
          snapshot = Map.put(snapshot, "snapshot_id", LLMDB.Snapshot.snapshot_id(snapshot))
          LLMDB.Snapshot.encode(snapshot)
        )

  @doc "The providers the trimmed snapshot keeps."
  @spec providers() :: [String.t()]
  def providers, do: @providers

  @spec install!() :: :ok
  def install! do
    path = Path.join(Rho.Config.data_dir(), "llm_db_snapshot.json")
    File.write!(path, @json)
    Application.put_env(:llm_db, :snapshot_path, path)
  end
end
