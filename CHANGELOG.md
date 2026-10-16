# Changelog

All notable changes to rho are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and rho uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

The first release, 0.1.0: the agent core taken out of
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
  subscription usage windows and per-model counters, and a trimmed model
  catalog for phones.
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
  holds a Dyn struct, so a Dyn process's crash report runs none of its code
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
