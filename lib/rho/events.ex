defmodule Rho.Events do
  @moduledoc """
  What a loop tells its subscribers, as `{:rho, session_id, event}`
  messages (plain `send`, no PubSub). The lifecycle is pi's
  (`pi-agent-core/src/agent-loop.ts`):

      agent_start
        turn_start                       (one per model call)
          message_start / message_end    (the user / steering messages injected)
          compaction_start, compaction   (when the context is over the threshold)
          message_start                  (assistant)
          message_update*                (streamed deltas)
          compaction_start, compaction,  (when the provider rejects the context
          message_start, message_update*  as too long: compacted, retried once)
          message_end                    (assistant, persisted)
          tool_execution_start / _end*   (in completion order)
          message_start / message_end*   (tool results, in call order)
        turn_end                         (always, even on error or stop)
      agent_end

  Events (maps):

    * `%{type: :agent_start}`
    * `%{type: :turn_start, turn: pos_integer}`
    * `%{type: :message_start, entry: entry}`, `%{type: :message_end, entry: entry}`:
      `entry` is the session entry (`Rho.Session`); the assistant's
      `message_start` carries an unpersisted entry with empty content
    * `%{type: :message_update, kind: :text | :thinking, delta: String.t()}`
    * `%{type: :tool_execution_start, id:, name:, arguments:}`
    * `%{type: :tool_execution_end, id:, name:, text:, is_error:}`
    * `%{type: :turn_end, turn:, entry: assistant entry | nil, tool_results: [entry], error: String.t() | nil}`
    * `%{type: :retry, attempt:, delay_ms:, error:}`: the assistant message
      being streamed is discarded; the next `message_start` restarts it
    * `%{type: :queue, steering: [String.t()], follow_up: [String.t()]}`
    * `%{type: :model_change, model: String.t()}`
    * `%{type: :compaction_start, reason: :threshold | :overflow, tokens: integer}`:
      the summary call starts (`tokens` is the estimated context size); for
      `:overflow` the assistant message being streamed is discarded
    * `%{type: :compaction, entry: entry}`: the persisted `compaction` entry
      (`Rho.Session.compaction/4`); the model call that follows uses
      the compacted context. A failed summary ends the run instead, with an
      error notice (`message_start` / `message_end`) and `turn_end`
    * `%{type: :agent_end, reason: :done | :stopped | :error | :max_iterations | :cost_cap}`
  """

  @type event :: %{required(:type) => atom(), optional(atom()) => term()}

  @spec broadcast(Enumerable.t(), String.t(), event()) :: :ok
  def broadcast(subscribers, session_id, event) do
    Enum.each(subscribers, &send(&1, {:rho, session_id, event}))
  end
end
