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
- **Dyn** (`Rho.Dyn`, optional): tools and screens the agent writes,
  compiles and runs on the device, one approved generation at a time, on
  probation and reverted when they crash.

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
  [{:rho, "~> 0.1"}]
end
```

Until 0.1.0 is on Hex, use the GitHub repo: `{:rho, github: "GenericJam/rho"}`.

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
| `:app_name`, `:hints` (where the user signs in or switches model, in messages; how they approve a Dyn generation, in the agent's Dyn text) | "the app", "the app's settings", "on the phone with the screen lock" | |
| Attachments (`t:Rho.Session.attachment/0`: pictures, text, PDFs with a user message) | none: the host builds them from its pickers and camera | |
| Loop options (`Rho.Loop.start_link/1`): gate before each tool call, budget, guards, model client | allow all; no cap; pi's limits; `Rho.LLM.ReqLLM` | |
| `:dyn` (`Rho.Dyn.Config`): the Dyn layer and its seams, below | off | on, with mob screens |

On a phone, `Rho.Supervisor` also writes llm_db a catalog trimmed to the
four providers (`Rho.LLMCatalog`), since the packaged one isn't shipped
to the device.

## Dyn: code the agent writes on the device

`Rho.Dyn` lets the agent change the app it runs in without a release: it
writes Elixir tools (and, in a UI app, screens) in a staging copy with the
`dyn_*` tools, and `dyn_propose` statically checks, compiles and selftests
them as a new **generation**. Nothing runs until the human approves it with
the screen lock; then it is on **probation**: 3 crashes in 60 s, or a launch
that dies before it is stable, revert it to its parent, and two failed
launches in a row start the next one in **safe mode** (no Dyn code loaded),
so the fixed Core can always repair it. Generation `n` compiles the
agent's `Dyn.Foo` as `Dyn.G<n>.Foo`, next to the running one rather than
over it; old generations unload only once nothing runs their code.
Activations and reverts change the loop's tools from its next model call
(`Rho.Dyn.Source`, a `Rho.ToolRegistry.Source`).

It is off unless the host turns it on:

```elixir
# config/config.exs
config :rho, :dyn,
  enabled: true,
  namespace: MyApp.Dyn,
  app: :my_app,
  core: [MyApp],
  allowed: [MyApp.Files],
  screens: Rho.Dyn.Screens.Mob

# the host's boot, once Rho.Supervisor is up (it starts the Keeper):
Rho.Dyn.boot()
```

Its seams (`Rho.Dyn.Config` documents each):

| Seam | Default | Operator |
| --- | --- | --- |
| `:enabled` (or `Rho.Supervisor`'s `:dyn`): start `Rho.Dyn.Keeper` and the approval store, offer the `dyn_*` tools | off | on |
| `:namespace`: the modules the agent writes | `Dyn` | `Operator.Dyn` |
| `:app`, `:core`: the Core's modules (a new Core rebuilds every generation; Dyn code may not call them) | rho's | `:operator`, `[Operator]` |
| `:allowed`: Core modules Dyn code may call | `Rho.Tool` | its file, TFLite and terminal modules |
| `:check`: the static check's ban, allow and gate lists | Operator's (`Rho.Dyn.Check.defaults/0`) | the defaults, plus its own file module's message and caller-side functions |
| `:screens` (`Rho.Dyn.Screens`): what a screen is, its selftest, the first-frame hook, app lifecycle, "is it on screen yet" | `Rho.Dyn.Screens.None` (no screens) | `Rho.Dyn.Screens.Mob` plus its front |
| `:approval` (`Rho.Dyn.Approval`): tokens for activate / revert | `Rho.Dyn.Approval.Biometric` (the host's UI confirms after the screen-lock prompt) | the same, fed by its approve chip |
| `:on_stable`, `Rho.Dyn.boot/1`'s `core:` / `core_rolled_back:`: a launch reaching stable, the Core update it runs | none | mob_deliver's probation |
| `:guide`: the host's rules in `Rho.Dyn.agent_guide/0` | none | its file roots, menu rows |
| `Rho.Dyn.Seed`: default sources the host ships, merged with the user's on each new version | none | its default front |

The default check keeps Dyn code to Mob's Elixir modules: Mob's native
layer `:mob_nif` is banned (`banned_erlang`, and as a value in `forging`,
so it can't be held in a variable and called), and the host's `:gated` and
`:allowed` lists say which of Mob's modules Dyn code may use. The check is
defence in depth, not a sandbox (`Rho.Dyn.Check`). A host whose Dyn code
must call it drops both:
`check: [banned_erlang: %{mob_nif: nil}, forging: %{mob_nif: nil}]`.

Dyn code never runs in a Core process through what it hands over
(`Rho.Untrusted`). A crash is formatted, with its stacktrace, in the
process that crashed (a tool's task, a selftest, a compile), in a helper
with a time and heap bound that never ends in a crash report and dies
with its caller; the loop, the Keeper and a proposal's caller only
describe a reason they receive (total over any term; integers past 1024
bits print as a placeholder), without calling an
exception's `message/1` or any protocol (`Inspect`, `String.Chars`,
`Jason.Encoder`) a Dyn struct implements. A Dyn tool's answer and details
become plain data (structs as maps) in its task, and its name,
description, schema, timeout and concurrency are read in one bounded
throwaway process and kept; a tool whose declaration fails is left out
(one that ran over is read again after 1, 5 and 30 minutes, then stays
out). Crash events' `reason` stays a
string. A host watches its own Dyn processes with `Rho.Dyn.watch/2` and
`Rho.Dyn.unwatch/1`; one that exits `{:rho_crash, text}`
(`Rho.Untrusted.crash/3`) is reported with `text`. Known limit: a Dyn
process crashing with an exception whose `message/1` fails in certain
ways can make OTP drop Elixir's logger translator VM-wide (that code runs
in the Dyn process, not a Core one).

On a phone, Dyn needs the Elixir compiler at run time: the app's build must
ship `:elixir`'s compiler modules and `:compiler`, so a slim build that
strips them can't use Dyn.

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

MIT, see [LICENSE](https://github.com/GenericJam/rho/blob/master/LICENSE), which also carries pi's copyright notice for
the ported parts.
