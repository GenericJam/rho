# rho — agent instructions

rho is the agent core shared by Operator (`~/code/operator`) and Bezalel
(`~/code/bezalel`): pi-agent-core's loop, omp/pi JSONL sessions,
compaction, tools, models and sign-in (subscription OAuth or API keys) on
req_llm. It was extracted from Operator's `lib/operator/core/` and
`lib/operator/auth*`; the plan is `~/code/bezalel/PLAN.md` (phase 1), the
work is tracked in Bezalel's beads (`bezalel-23s.*`).

Follow `~/AGENTS.md` (commits, reviews, Muster).

## Rules

- **No host couplings.** rho never names an app module. Anything an app
  must supply is a behaviour or a `config :rho` key with a default that
  works on a computer (`Rho.Config` documents them; README has the table).
  A new coupling gets a seam the same way.
- **Session files stay pi's format** (`CURRENT_SESSION_VERSION` 3): only
  append; keep unknown entry types; a change that omp couldn't read back
  is a bug. `test/fixtures/omp_session.jsonl` is a real omp session.
- **Runs on a phone.** No Application callback (the host starts
  `Rho.Supervisor`); nothing read from `priv/` at run time (embed it at
  compile time, as `Rho.Models` and `Rho.LLMCatalog` do); the slow work
  (model calls, tools) never runs in the loop's process.
- **Secrets**: credentials only through `Rho.CredentialStore`; never log a
  token or key, never put one in an error message or a URL.
- **Tests don't touch the network**: inject the model client
  (`Rho.Test.FakeLLM`) and answer HTTP in-process (`:respond`).
- No compile-time `~r//` in module attributes (OTP 28 can't store
  compiled regexes there); new code uses `Regex.compile!/1`.
- **Dyn** (`lib/rho/dyn*`, `lib/rho/tools/dyn_*`) is Operator's
  self-modification layer, moved here: keep its semantics (approval
  tokens, probation, crash revert, safe mode, the proposal cap, deferred
  unloading) exactly. Host specifics go through `Rho.Dyn.Config` (namespace,
  Core prefixes, check lists) and `Rho.Dyn.Screens`. Its tests compile into
  the VM-wide code server: `async: false`, `purge_all/0` around each.
  mob is an optional dependency, only for `Rho.Dyn.Screens.Mob` and tests.
- **Terms from Dyn code are untrusted** (`Rho.Untrusted`). A Core process
  (the loop, the Keeper, a compile's or selftest's caller) never calls
  `Exception.message/format*`, `inspect/1`, interpolation, `to_string/1` or
  `Jason.encode` on a term Dyn code made, nor a Dyn module's functions
  (a Dyn tool's callbacks go through `Rho.Tool.info/1`): format in the
  process that ran the Dyn code (`Untrusted.format/4`), describe the rest
  (`Untrusted.describe/2`, `exit_text/2`), and hand over plain data
  (`Untrusted.plain/1`). Tests run with unconsolidated protocols so a Dyn
  `defimpl` dispatches (`test/rho/dyn/untrusted_test.exs`).
- No Hex publish or version bump meant to publish without Kevin's say-so.
  `.github/workflows/release.yml` publishes on any push to master that
  changes `mix.exs`: it runs the gates, tags `v<@version>`, creates the
  GitHub Release from the CHANGELOG section and runs `mix hex.publish`
  (each step skips what already exists). So a `mix.exs` change that isn't a
  release (a dep, the docs config) re-runs it harmlessly once `@version` is
  on Hex; a new `@version` publishes. Move `[Unreleased]` to
  `[x.y.z] - date` in the same commit as the bump.

## Before a commit

```bash
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
```

CI (`.github/workflows/test.yml`) runs the same; watch the run after a
push (`gh run watch <id> --exit-status`).
