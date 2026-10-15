# rho

An agent core for Elixir apps, on a computer or on a phone: the turn loop,
sessions, context compaction, tools, and model sign-in, on
[req_llm](https://hex.pm/packages/req_llm).

- **Loop** (`Rho.Loop`): a GenServer per session with pi-agent-core's
  lifecycle: streamed replies, the reply's tool calls in parallel with
  results in call order, steering and follow-ups while it runs, stop,
  retries with backoff, rate limits waited out within a budget then a
  fallback model, a per-day cost cap, a wrap-up turn at the iteration
  limit, and a reminder when the session's todo list still has open items.
- **Sessions** (`Rho.Session`): omp/pi's JSONL session format (version 3),
  so a session moves between [omp](https://github.com/can1357/oh-my-pi) on a
  computer and a rho app on a phone.
- **Compaction** (`Rho.Compaction`): pi's local summary method, before a
  call that would overflow the window and after a provider rejects one.
- **Tools** (`Rho.Tool`, `Rho.ToolRunner`, `Rho.ToolRegistry`): plain
  modules; each call in its own task with a timeout and a gate, oversized
  output spilled to an artifact the agent pages through.
- **Models** (`Rho.LLM`, `Rho.LLM.ReqLLM`, `Rho.Models`, `Rho.Usage`):
  Anthropic, OpenAI, OpenAI Codex and Google, with subscription usage
  windows and per-model counters.
- **Auth** (`Rho.Auth`, `Rho.Auth.Login`): Claude Pro/Max and ChatGPT
  (Codex) subscriptions through omp's OAuth PKCE flows, with refresh
  coordination and refresh-token rotation; or an API key for Anthropic,
  OpenAI or Gemini.

## Lineage

The loop, session format, compaction and sign-in flows are ports of
[pi](https://github.com/badlogic/pi-mono) (pi-agent-core, pi-ai,
pi-coding-agent) as [oh-my-pi](https://github.com/can1357/oh-my-pi) (omp)
runs them, first written in Elixir for
[Operator](https://github.com/GenericJam/operator), an omp-style agent that
runs on the phone. rho is that core taken out of Operator so other apps
(Operator itself, and Bezalel, a Bible-study app) can share it. Comments
name the pi source each piece follows.

## Install

```elixir
def deps do
  [{:rho, github: "GenericJam/rho"}]
end
```

## A minimal host

rho has no OTP application callback (mob apps start their code by hand),
so the host starts `Rho.Supervisor` in its own tree:

```elixir
defmodule MyApp.Tools.Weather do
  @behaviour Rho.Tool

  @impl true
  def name, do: "weather"
  @impl true
  def description, do: "Today's weather for a city."
  @impl true
  def parameter_schema,
    do: %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"]}

  @impl true
  def run(%{"city" => city}, _ctx), do: {:ok, "Sunny in #{city}."}
end

children = [
  {Rho.Supervisor, tools: [MyApp.Tools.Weather | Rho.ToolRegistry.builtin_tools()]}
]

Supervisor.start_link(children, strategy: :one_for_one)

:ok = Rho.Auth.put_api_key(:google, System.fetch_env!("GEMINI_API_KEY"))
{:ok, loop} = Rho.start_loop(model: "google:gemini-2.5-flash", system_prompt: "Be brief.")
:ok = Rho.Loop.subscribe(loop)
:ok = Rho.Loop.prompt(loop, "Weather in Lisbon?")

# {:rho, session_id, %{type: :message_update, kind: :text, delta: "..."}} ...
# {:rho, session_id, %{type: :agent_end, reason: :done}}
```

A subscription sign-in instead: `Rho.Auth.Login.begin(:anthropic)` opens
the provider's page (the callback comes back to a listener on localhost),
then `{:rho_login, :anthropic, :ok}` arrives.

## What a host provides

Every coupling to the app around it is a behaviour or a `config :rho`
key, each with a default that works on a computer (`Rho.Config` lists
them all):

| Seam | Default | On a phone |
| --- | --- | --- |
| `:data_dir`: sessions, artifacts, todo lists, cost ledger, usage, settings, model catalog | `MOB_DATA_DIR`, else the OS's per-user data dir | `MOB_DATA_DIR` (mob sets it) |
| `:credential_store` (`Rho.CredentialStore`: get/put/delete of a binary by key) | `Rho.CredentialStore.File`, a 0600 file per key | the Keystore / Keychain plugin (`MobSecureStore` fits as it is) |
| `:settings` (`Rho.Settings`: fallback model, daily cost cap) | `Rho.Settings.File` (`settings.json`) | the app's own settings, or the default |
| `:tools`, `:tool_sources` (`Rho.ToolRegistry.Source`: tool sets that change at run time) | `Rho.Tools.ReadArtifact`, `Rho.Tools.Todo`; no sources | the app's tools; agent-written ones through a source |
| `:system_prompt`, `:default_model` | a short generic prompt; `anthropic:claude-haiku-4-5` | the app's |
| `:open_url` (the sign-in page) | `open` / `xdg-open` / `start` | `{Mob.Device, :open_url, []}` |
| `:namespace` (`customType` of the loop's notices in a session) | `"rho"` | |
| `:app_name`, `:hints` (where the user signs in or switches model, in messages) | "the app", "the app's settings" | |
| Attachments (`t:Rho.Session.attachment/0`: pictures, text, PDFs with a user message) | none: the host builds them from its pickers and camera | |
| Loop options (`Rho.Loop.start_link/1`): gate before each tool call, budget, guards, model client | allow all; no cap; pi's limits; `Rho.LLM.ReqLLM` | |

On a phone, `Rho.Supervisor` also writes llm_db a catalog trimmed to the
four providers (`Rho.LLMCatalog`), since the packaged one isn't shipped
to the device.

## Development

```bash
mix deps.get
mix format --check-formatted
mix credo --strict
mix compile --warnings-as-errors
mix test
```

Tests never reach a network: the model client is a scripted fake, and the
OAuth and usage endpoints are answered in-process.

## License

MIT, see [LICENSE](LICENSE), which also carries pi's copyright notice for
the ported parts.
