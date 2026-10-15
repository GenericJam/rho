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
- No Hex publish or version bump meant to publish without Kevin's say-so.
  There's no release workflow yet on purpose: adding one publishes on push.

## Before a commit

```bash
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
```

CI (`.github/workflows/test.yml`) runs the same; watch the run after a
push (`gh run watch <id> --exit-status`).
