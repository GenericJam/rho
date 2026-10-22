# Changelog

All notable changes to rho are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and rho uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.5.3] - 2026-10-22

### Security

- **req_llm `~> 1.29`** (was `~> 1.26`): req_llm 1.9.0 through 1.28.0 did
  not verify TLS certificates on `wss://` WebSocket sessions (OpenAI
  Responses, Realtime and Codex WebSocket modes), exposing the API key or
  OAuth token to an on-path attacker
  ([GHSA-6vww-5m28-f26v](https://github.com/agentjido/req_llm/security/advisories/GHSA-6vww-5m28-f26v)).
  rho never selects those transports (streaming stays on SSE over Finch,
  which verifies certificates), so rho was not exposed; the bump keeps
  hosts from resolving an affected req_llm.

## [0.5.2] - 2026-10-22

### Changed

- **The `:resolve_attachment` hook's `ctx`** carries `data_dir: dir`
  when the loop was started with a `:data_dir` (a consult: its own
  `:data_dir` or its loop's; `Rho.Loop.context/1` and
  `Rho.Session.messages/2`'s `:data_dir` likewise), so a host with
  several accounts can tell whose conversation a file belongs to when two
  accounts hold the same session id. Without one, `ctx` is
  `%{session_id: id}` as before.

## [0.5.1] - 2026-10-19

The ChatGPT sign-in's models are the ones it accepts.

### Changed

- **`Rho.Models.catalog(:openai_codex)`** is Codex's own list for the
  account (`GET /backend-api/codex/models`, in Codex's order, the first
  its default), fetched and kept by the new **`Rho.Models.Codex`** per
  sign-in (per data dir: a loop's `:data_dir` and `:credential`, else the
  node's): in memory (an ETS table; `Rho.Supervisor` starts its owner) and
  in the dir's `codex_models.json`, fetched again in the background once 6
  hours old (5 minutes after a failed try, one fetch at a time). Before the
  first fetch it is the list shipped in `priv/models/openai_codex.json`,
  now Codex's of 2026-10-19 (gpt-5.5 and Daybreak Blue, which the
  backend refuses for a ChatGPT account, are gone). A picker should ask
  each time it opens rather than keep the list. `catalog/2` takes the
  sign-in (`:data_dir`, `:credential`).
- **A session on a ChatGPT model the sign-in no longer accepts** moves to
  the sign-in's default for good (a `model_change` entry and a one-line
  notice) when a run starts on it, or when the backend refuses it; the
  refused call is made again on the default, once per run.
- An HTTP error req_llm reports as a bare "HTTP 400" carries the
  provider's own message from the body (Codex's `detail`).

### Added

- `Rho.Models.resolve/2`: the model a saved spec runs as (a ChatGPT
  model the sign-in no longer accepts resolves to its default).
- `config :rho, :codex_models_refresh` (default `true`): `false` turns
  the background fetch off.

### Removed

- `Rho.Images.models/1`: `Rho.Models.Codex.fetch/1` returns the same list
  with names and context windows.

## [0.5.0] - 2026-10-19

Credentials per account, for a host serving several (a website whose
accounts are phones). A host with one set of sign-ins changes nothing.

### Added

- **`Rho.Auth.Vault`**: one account's credentials in memory only (never
  on disk), with `Rho.Auth`'s API (`put/3`, `put_api_key/3`, `delete/2`,
  `get/2`, `signed_in?/2`, `status/1`, `credential/2`, `subscribe/1`) and
  its rules for a rotating refresh token: one refresh per provider at a
  time, a put wins over a refresh in flight, a refreshed sign-in handed
  out only once kept. `:on_refresh` (`fn provider, creds -> :ok |
  {:error, reason}`) is told of every refresh rho did, before anyone gets
  the token; `:refresher` (`fn provider -> {:ok, creds} | :local`) lets
  whoever holds the account refresh it instead (20 s, then the vault
  does). Both share one implementation with `Rho.Auth`.
- **A loop's own sign-ins**: `Rho.LLM.ReqLLM` honours its `:credential`
  option (`llm: {Rho.LLM.ReqLLM, credential: fun}`; the default is
  `Rho.Auth.credential/1`), so turns, compaction and consults use it, and
  its `:status` option says who is signed in for the loop
  (`Rho.LLM.status/1`), read by the fallback check and `ask_model`.
- `Rho.Consult.models/1` and `allowed/2` take a status function (default
  `Rho.Auth.status/0`).
- `Rho.Supervisor` option `auth: false`: neither `Rho.Auth` nor
  `Rho.Auth.Login` is started; `Rho.Auth.credential/1` then answers
  `{:error, :signed_out}` for what the credential store doesn't hold.
- `Rho.Session.size/1`, `read_from/3` and `append_bytes/3`: a session
  file's whole lines by byte offset, to keep a copy in step (idempotent on
  a resend, `{:error, {:conflict, size}}` when the copies diverged).
- A request (`t:Rho.LLM.request/0`) carries the loop's or consult's
  `:data_dir`.

### Changed

- A model call's usage is recorded in, and a 429 reads, the loop's (or
  consult's) `:data_dir` instead of always `Rho.Config.data_dir/0`; the
  default fallback check reads the loop's too.
- `Rho.LLM.usable/2` takes options (`:status`, `:data_dir`, `:now`)
  instead of `usable(model, dir, now)`. The loop's `:fallback_check`
  default is now `:usable` (that, over the loop's data dir and status).
- `Rho.Auth` subscribers also get `{:rho_auth, :changed}` after a
  refresh that worked (a phone tells its linked computers from it).
- A put or delete during a refresh stops the refresh (its result was
  dropped already), so one not yet sent never spends the refresh token.

## [0.4.0] - 2026-10-18

### Added

- **Pictures on the ChatGPT sign-in** (`Rho.Images.generate/2`): the
  user's ChatGPT Plus/Pro sign-in (`:openai_codex`) draws a picture as
  Codex does, through the Codex Responses endpoint with OpenAI's hosted
  `image_generation` tool, from words and optional reference pictures
  (an edit). It returns the bytes, type, the tool's revised prompt, size
  and action; options `:size`, `:quality`, `:format`, `:references`,
  `:model`, `:timeout` (the whole drawing, 4 minutes by default; the
  stream is parsed as it arrives, bounded). No API key and no per-picture
  bill: it counts against the subscription's Codex limits, recorded in
  `Rho.Usage` like a model call
  (tokens, windows, a 429's reset). Errors are `Rho.LLM.error/0`s. A
  focused Req call: req_llm's `openai_codex` provider drops the
  `image_generation_call` item and, for the gpt-5.6 models, strips hosted
  tools from the request.
- `Rho.Images.models/1`: the Codex models the ChatGPT account may use
  (Codex's `GET /backend-api/codex/models`). The driving model defaults
  to `gpt-5.6-luna`; when the account refuses a model (gpt-5.5 and
  gpt-image-2 are refused), `generate/2` draws once with the first model
  that list gives (Codex's default).

## [0.3.1] - 2026-10-18

### Fixed

- **Model calls are priced.** req_llm prices a reply only when every
  conditional tariff of the model is settled by the caller's
  `:pricing_context`. llm_db's tariffs for Claude 4 and later (as of
  llm_db 2026.10), gpt-5.6 and later, and some Gemini 3.x models (3.1
  Pro, 3.8 Flash) carry such conditions (batch, fast mode, service tier,
  US-only inference or regional processing, cache TTL or explicit-cache
  storage), so calls to those models came back unpriced and rho counted
  $0: in `usage.json`, the sessions' `usage.cost`, `Rho.Session.totals/1`
  and the daily cap (`Rho.Budget`). Models with a flat tariff (gpt-5.5,
  Gemini 2.5) were priced already. `Rho.LLM.ReqLLM` now passes what rho's
  requests are (not batched, standard speed and tier, global inference,
  Anthropic's 5-minute cache, Gemini's implicit cache). A subscription
  call is priced at its API-key price, as the docs already said
  (notional), so a loop's daily cap (`:budget`) now counts Claude
  subscription calls, and Codex calls on such models, too:
  `Rho.Settings.File`'s default cap is $1.00 a day, which a session on a
  subscription can reach in an hour. Upstream:
  [req_llm#1121](https://github.com/agentjido/req_llm/issues/1121).
- **Claude's uncached input tokens** were recorded as 0: `Rho.Session.usage/1`
  took the cache's tokens off req_llm's `input_tokens`, which for
  Anthropic (`input_includes_cached: false`) doesn't hold them. pi's
  `cost` split is filled in too: `input`, `cacheRead`, `cacheWrite` and
  `output` from the reply's priced line items (they were the input and
  output costs with the cache's inside, and 0 for the cache).

## [0.3.0] - 2026-10-18

### Added

- **Consults** (`Rho.Consult`): `run(model, prompt, opts)` asks another
  model (a `google:` Gemini model while Claude leads, say) and returns
  `{:ok, %{text, model, purpose, usage}}`, or `{:error, reason}`
  (`{:signed_out, provider}` without a credential, `:stopped`,
  `{:cost_cap, spent, cap}`, the model call's error; `describe/1` words
  it). Options: `:purpose` (`"critique"`, `"second_opinion"` or free
  text), `:system`, `:attachments` (by ref or path), `:tools` the
  consulted model may call (with `:max_iterations`), `:max_tokens`,
  `:llm`, `:budget`. With `:loop` the consult is the session's:
  `consult_start` / `consult_delta` / `consult_end` events to the loop's
  subscribers, its usage recorded as a `custom` `"<ns>.consult"` entry
  (`Rho.Session.consult/1`, counted by `Rho.Session.totals/1`) and
  against the loop's daily cost cap, stopped by `Rho.Loop.stop/1` (even
  when the loop is idle) or the loop exiting, and `:include_conversation`
  sends the conversation so far as a transcript (the calls in flight left
  out, the newest part when it's too long). The model call runs in a
  worker that dies with its caller.
- **`ask_model`** (`Rho.Tools.Consult`, not a built-in): the lead model
  consults another (`model`, `purpose`, `prompt`, `include_conversation`)
  and gets `"<model> (<purpose>):"` and its answer back, with `%{model,
  purpose, usage}` as the result's details.
- **Attributed messages**: `Rho.Loop.prompt/3`, `steer/3` and
  `follow_up/3` take options as their third argument (`:attachments`,
  `:attribution`, `:instruction`); `attribution: {:model, model,
  purpose}` stores the text as that model's message, a `custom_message`
  `"<ns>.model_message"` (`Rho.Session.model_message/4`, read back with
  `Rho.Session.attribution/1`), sent to the lead marked as that model's,
  not the user's, followed by the `:instruction`.
- `config :rho, :consult_models` (the models that may be consulted; default
  every catalog model of a signed-in provider; `Rho.Consult.models/0`,
  `allowed/1`) and `:consult_system` (a consulted model's system prompt
  per purpose).
- `Rho.Loop.snapshot/1` lists the consults running (`consults`).

## [0.2.0] - 2026-10-18

### Added

- **Attachments by reference**: an attachment with `ref:` (the host's own
  id for the file, a material id say) is stored in the session as its ref
  and metadata, never its bytes (no image part; the ref in the envelope and
  in the message's `attachments`; `path` is then optional). Each model
  call fetches a referenced picture (when the model takes pictures) or PDF
  (when it takes PDFs) through the new `:resolve_attachment` hook
  (`fn attachment, ctx -> {:ok, {mime, bytes}} | {:error, reason} end` or
  an MFA; `ctx` is `%{session_id: id}`), once per kind and ref, in the call's own
  process, not the loop's, and sends it where an inline one would go; with
  no hook, an error, a raise or a bad answer the model gets "(<name>
  couldn't be loaded, so it isn't sent.)" instead. A tool can answer with
  pictures by reference, `%{ref:, mime:, name:}` in its `:images`, stored
  as the tool result's `attachments` (one answer's pictures are all inline
  or all by reference). `Rho.Session.attachments/1` lists a user message's
  or tool result's files (`kind`, `name`, `mimeType`, and `ref` / `path` /
  `about` / `pages` when present) for the host's chat. Sessions with inline
  pictures are read as before, and pictures the model makes stay inline.
- `Rho.Session.fetch/2`: `Rho.Session.messages/2` leaves placeholders for
  the files whose bytes aren't in the session (pictures by reference, PDFs)
  with `fetch: false`, to be fetched later in another process; without it
  (the default) it fetches them before returning, given `session_id:`.

### Changed

- Attached PDFs read from their paths are read by the model call's
  process, not the loop's, and each attachment counts against the
  100-page / 20 MB budget (one attached twice used to go twice on one
  place in it). `Rho.Loop.context/1` fetches in the caller's process.
- `Rho.Loop.prompt/3`, `steer/3` and `follow_up/3` raise `ArgumentError`
  in the caller for an attachment with neither `:path` nor `:ref`.

## [0.1.0] - 2026-10-16

The first release: the agent core taken out of
[Operator](https://github.com/GenericJam/operator) so Operator and Bezalel
can share it.

### Added

- **Loop** (`Rho.Loop`): a GenServer per session with pi-agent-core's
  lifecycle and events (`Rho.Events`): streamed replies, the reply's tool
  calls run in parallel (or one at a time when a tool is `:exclusive`)
  with results in call order, steering and follow-ups while a run is going,
  stop, retries with backoff, rate limits waited out within a budget then a
  fallback model, a per-day cost cap (`Rho.Budget`), a wrap-up turn at the
  iteration limit, and a reminder while the session's todo list has open
  items.
- **Sessions** (`Rho.Session`): omp/pi's JSONL session format (version 3),
  append-only, unknown entry types kept, so a session moves between omp on
  a computer and a rho app on a phone; tool results keep the host's pick of
  a tool's details (`:keep_details`) and the pictures a model makes.
- **Compaction** (`Rho.Compaction`): pi's local summary, before a call that
  would overflow the window and after a provider rejects one.
- **Tools** (`Rho.Tool`, `Rho.ToolRunner`, `Rho.ToolRegistry`): plain
  modules, each call in its own task with a timeout and a
  `before_tool_call` gate; pictures for the model (`{:images, ...}`), data
  for the host's screens (`{:details, output, details}`, also on errors);
  oversized output spilled to an artifact the agent pages through
  (`Rho.Artifacts`, the `read_artifact` tool); the `todo` tool; tool
  sources for tool sets that change while the app runs
  (`Rho.ToolRegistry.Source`).
- **Models** (`Rho.LLM`, `Rho.LLM.ReqLLM`, `Rho.Models`, `Rho.LLMCatalog`,
  `Rho.Usage`): Anthropic, OpenAI, OpenAI Codex and Google on req_llm, with
  subscription usage windows and per-model counters, and a model catalog
  trimmed to those providers (`llm_catalog: false` keeps llm_db's own).
- **Sign-in** (`Rho.Auth`, `Rho.Auth.Login`, `Rho.CredentialStore`):
  Claude Pro/Max and ChatGPT (Codex) subscriptions through omp's OAuth PKCE
  flows, with refresh coordination and refresh-token rotation, or an API key
  for Anthropic, OpenAI or Gemini.
- **Host seams** (`Rho.Config`, `Rho.Supervisor`, `Rho.Settings`): no OTP
  application callback (the host starts `Rho.Supervisor`); data dir,
  credential store, settings, system prompt, app name and hints are the
  host's.
- **Dyn** (`Rho.Dyn`, optional): tools and screens the agent writes,
  checks, compiles and selftests on the device as versioned generations,
  activated only with the human's approval, on probation and reverted on
  crashes or a failed launch, with safe mode, background rebuilds for a new
  Core, a shipped seed (`Rho.Dyn.Seed`) and mob screens
  (`Rho.Dyn.Screens.Mob`).
- **Untrusted terms** (`Rho.Untrusted`): nothing Dyn code hands over runs
  its code in a Core process. Crashes are formatted, with their stack,
  where they happened (a tool's task, a selftest's or compile's process),
  in a helper with a time and heap bound that ends without a crash report
  and dies with its caller; the loop, the Keeper and a proposal's caller
  only describe the exit reasons they receive (total over any term,
  improper lists and huge integers included), never calling an exception's
  `message/1` or a Dyn struct's `Inspect`, `String.Chars` or
  `Jason.Encoder`. A Dyn tool's answer and details are plain data (structs
  as maps) before they leave its task, and its declaration is read in one
  bounded process outside the loop and kept; a tool whose declaration
  fails is left out, one that ran over is read again after 1, 5 and 30
  minutes, then stays out. Hosts watch their own Dyn processes with
  `Rho.Dyn.watch/2` and `Rho.Dyn.unwatch/1` and may exit them with
  `{:rho_crash, text}` (`Rho.Untrusted.crash/3`) to report `text`. A
  primary logger filter (`Rho.Dyn.LogGuard`) describes any log event that
  holds a Dyn struct (within a 10,000-term budget; bigger events pass
  through), so a Dyn process's crash report runs none of its code
  in `:logger_proxy`; the check refuses `:logger`, `:error_logger`,
  `:logger_backends`, `:telemetry`, `:gen_event`, `:gen_statem` and
  `Logger`'s translators, backends and configuration.
- **Threat model**: the static check (`Rho.Dyn.Check`) is a best-effort
  deny-list against the model's mistakes, not a sandbox against hostile
  code; `Rho.Untrusted` and `Rho.Dyn.LogGuard` lower the chance that a
  built tool's crash takes a trusted process down. Known ways around the
  check (raw messages to `:logger_proxy`, Logger.App and logger backend
  modules, children started under trusted supervisors, `:alarm_handler`,
  resource floods) are listed in `Rho.Dyn.Check` and the README.

[Unreleased]: https://github.com/GenericJam/rho/compare/v0.5.3...HEAD
[0.5.3]: https://github.com/GenericJam/rho/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/GenericJam/rho/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/GenericJam/rho/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/GenericJam/rho/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/GenericJam/rho/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/GenericJam/rho/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/GenericJam/rho/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/GenericJam/rho/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/GenericJam/rho/releases/tag/v0.1.0
