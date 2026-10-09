# One setup for every channel — quality bar

**Task:** one runtime is one agent: every channel and the CLI share its models, sources, workspace and
abilities · **Owner:** Ghassan · **Size:** L · **Set:** 2026-10-09 (before the change)
**Plan:** [`PLAN.md`](PLAN.md) (revision 2) · **Governing ADRs / invariants:** ADR-042 (gateway process and its keys),
ADR-048 (model boundary, role credentials), ADR-052 (gem boundaries), ADR-059 (no backward compatibility),
ADR-061 (talk channel); invariants 56, 57 · **Branch:** `one-setup-every-channel`

Status values: `PASS` (evidence named) · `FAIL` (what is wrong) · `OPEN` (not built) ·
`BLOCKED` (cannot be done here; reason named; never counted as a pass) · `WAIVED` (owner decision,
named and dated; never by the author).

## 0. Outcome and fence

**Outcome:** on one runtime, `tamoz start` (and the installed service) runs Telegram and the talk page through
one gateway per channel and one worker, with the chat model, roles, sources, workspace and abilities read from
the runtime; `tamoz ask --runtime-dir` uses the same model, roles and sources; the owner's `~/.tamoz` runs this
way with its history, memory, web search and pairing intact.

**Done when:** every row below is PASS (or WAIVED by the owner), the review log has no open critical or high
finding, and the loop log's last iteration changed nothing.

**Not in scope:** the CLI as a channel; a session-history tool; non-macOS services; the talk findings not
about setup (`PLAN.md` §7).

**Owner decisions needed:** OD1–OD4 taken 2026-10-09 (`PLAN.md` §2). New ones are raised, not assumed.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seams extended | `RuntimeDirectory` (schema, `create!`, `migrate!`), `CLI::ModelBuilder#build`, `attachment_model`, `ChildEnvironments`, `write_chat_profile`, the telegram pairing and talk channel writers, `comms serve` (all surfaces), the worker command |
| 1.2 | What already does part of it | `comms serve` already serves every enabled surface; `migrate!` already backs up and migrates; `write_chat_profile` already writes the abilities; `ChildEnvironments` already decides each child's keys. Nothing new may duplicate these. |
| 1.3 | Blast radius | PASS — 2026-10-09 enola: `RuntimeDirectory` 34 dependents within 2 hops (19 test refs, 7 symbols incl. the evals benchmark runner, `bin/`, `script/`); `ChildEnvironments` 5 (tests and `script/`); `CLI::ModelBuilder` 1 (its test). The config change reaches the benchmark runner and scripts, which the source-scan test (A4) must cover |
| 1.4 | Baseline | PASS — 2026-10-09: enola baseline pinned on `3faf1c8b`; known red at HEAD: `stream:proto:check` (x86 protoc on arm64) |

## A. Safety and authority

| # | Property | Check (mutation) | Status |
|---|---|---|---|
| A1 | A config `credential` is an `*_API_KEY` variable name; a key-shaped value is refused and never echoed; one rule serves the config and the children | config test (drop the shape check; echo the value in the error) | OPEN |
| A2 | Each child gets exactly its keys: the worker the chat key, endpoints, role credentials and every enabled source's `credential_refs`/`env_allowlist`, never a channel token or the voice key; the telegram gateway only its token; the talk gateway its token and the voice key, never the chat key (by name or value) | golden child environments from a config with web search and talk (forward the full `.env`) | OPEN |
| A3 | A thread bound before the change still validates its profile pin after `setup`, `channel add` and the migration; no command rewrites an existing profile | fixture of the owner's shape with a bound thread (rewrite the profile) | OPEN |
| A4 | No code reads `TAMOZ_PROVIDER`, `TAMOZ_MODEL` or `TAMOZ_<ROLE>_*` | source scan over the files named in `PLAN.md` §3 plus the CLI, scripts, agenteval and test support; allowlist: the CLI flags (re-add one reader) | OPEN |
| A5 | `start` refuses: a second `start`; a runtime served by a loaded `com.tamoz.*` job (launchctl fake); a talk-only runtime already served; a runtime folder inside the workspace | `start` tests, one per case (drop each guard) | OPEN |
| A6 | Plists are 0600, written atomically; `.env` readable by group/others is refused; no output, log line or error contains a secret value; `service status` never runs `launchctl print` | service tests (chmod after write; print the env) | OPEN |
| A7 | Two chat channels naming different profiles are refused by `RuntimeDirectory` | config test (drop the rule) | OPEN |

## B. Function — fixture providers prove plumbing only

| # | Property | Check | Status |
|---|---|---|---|
| B1 | `models` validated and exposed; absent `models.chat` stops `start`, not `setup` | `runtime_directory` tests | OPEN |
| B2 | `setup` writes `models` after a backup; every other key semantically equal; old code ignores the key | config tests | OPEN |
| B3 | Worker, `start` probes, CLI and `memory consolidate` build the chat model and roles from the config with the stated precedence (CLI flag > `models.chat` > profile `primary`) | model builder tests | OPEN |
| B4 | `setup` creates a runtime and updates `models`; writes the chat profile only when none exists; refuses `--workspace` on a runtime that has one; re-run unchanged is a no-op; a missing key is reported, not refused | `setup` tests | OPEN |
| B5 | `channel add telegram` pairs as today and names the runtime's profile; twice is a no-op | channel tests (moved from the Telegram setup tests) | OPEN |
| B6 | `channel add talk` writes the channel and token as today and names the runtime's profile; `--rotate-token` says to re-run `service install` | channel tests (moved from the talk setup tests) | OPEN |
| B7 | One `start` serves Telegram and the page through two gateways and one worker; both answer | end-to-end test, slow lane (fake Telegram API, talk HTTP, injected waits, free ports) | OPEN |
| B8 | A failing voice probe runs text-only and says so; a failing chat or transcription probe stops with its name | `start` tests | OPEN |
| B9 | `service install/status/uninstall`: plists are pure output (golden, keys masked), match the owner's current plists field by field, escape XML; install twice is a no-op; uninstall with files gone succeeds and touches only its labels; old plists backed up | service tests with a launchctl fake (run on Linux CI, never skipped) | OPEN |
| B10 | `ask` with a runtime uses its model, roles and sources; workspace stays the current folder; `--provider/--model` override for one run | CLI tests | OPEN |
| B11 | Rollback restores the old config and plists, and the old start validates the runtime | migration rollback test | OPEN |

## C. Evaluation — live, real models, the owner present (P7)

| # | Property | Check | Status |
|---|---|---|---|
| C1 | The rehearsal on a consistent copy passes the same checks before the live runtime is touched | runbook step 4, recorded | OPEN |
| C2 | Telegram answers on the migrated `~/.tamoz` | owner message | OPEN |
| C3 | The talk page answers with the same chat model (worker log) | owner session | OPEN |
| C4 | A web search works from the talk page | owner session | OPEN |
| C5 | A Telegram voice note is transcribed (the old worker had no transcription settings) | owner voice note | OPEN |
| C6 | With the voice provider down, `start` runs text-only and says so | observed or simulated with a bad voice model | OPEN |
| C7 | No old job or orphan worker serves the runtime; the row counts and thread digests match step 1 | runbook step 7 | OPEN |

## D. Gates

| # | Property | Check | Status |
|---|---|---|---|
| D1 | Every touched or new test file, one per command | `ruby -Itest test/<file>.rb` | OPEN |
| D2 | `rake ci` stages (`stream:proto:check` known red) | output per stage | OPEN |
| D3 | `rake ci_full` slices covering packaging and the CLI | output | OPEN |
| D4 | `rubocop -a` on every touched Ruby file | output | OPEN |
| D5 | enola `diff_snapshot` vs the baseline: no new cycle, layer violation or unintended coupling | enola output | OPEN |
| D6 | New files mode 644 (scripts 755) | `git ls-files -s` | OPEN |
| D7 | No everyday test file over 5 s on the pipeline; process-driving tests in `SLOW_TESTS` | CI timings | OPEN |

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Less machinery: two setups and two starts become one each; no schema bump; no `abilities` key; nothing from `PLAN.md` §7 built | diff review | OPEN |
| E2 | No shim, alias or legacy reader (ADR-059) | diff review, A4 | OPEN |
| E3 | Comments per AGENTS.md | review | OPEN |
| E4 | No scratch files in the repo | `git status` | OPEN |
| E5 | Config reading stays in `tamoz-agent` (`RuntimeDirectory`, `ChildEnvironments`); the CLI uses them | review, boundary tests | OPEN |
| E6 | Owner (2026-10-10): high-quality code. Every new or changed production method meets the clean-code bar: ≤ 20 lines, cyclomatic and perceived complexity ≤ 8, ABC ≤ 20, ≤ 5 parameters, no boolean parameter, one responsibility, named for intent (`CODING_STANDARD.md` §4; `docs/code-improvement-2026-10-03/CLEAN_CODE_BAR.md` B1–B4) | `bundle exec rubocop -c docs/code-improvement-2026-10-03/metrics.rubocop.yml <touched files>` → 0 offenses in new and changed code, compared with `main` | OPEN |
| E7 | New code is written clean, not cleaned after: no new `rubocop:disable`, `.rubocop_todo.yml` does not grow, no new offense in a touched file vs `main` (`rubocop -a` stays the only lint pass, per the owner's rule) | `bundle exec rubocop <touched files>` vs `git show main:<file>`; `git diff main -- .rubocop_todo.yml` | OPEN |
| E8 | No new structural smell: enola shows no new complexity outlier, god-class or dead method in touched code, and touched methods' complexity does not rise | `diff_snapshot` vs the baseline, `--focus` each touched file | OPEN |
| E9 | Each phase is also reviewed through a code-quality lens (`CODING_STANDARD.md` §12 checklist, naming per §3.1, no new abstraction without two consumers) by a fresh reviewer, and its findings fixed before commit | review log | OPEN |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | The report separates plumbing from the live checks and claims nothing not run | review | OPEN |
| F2 | ADR-062; ADR-042/048/061 updated where they name removed commands or variables; `rake adr:validate adr:verify` | ADR tooling | OPEN |
| F3 | Guides, `reference/cli.md`, READMEs (`apps/tamoz-agent`, `gems/tamoz-agent`) match the new commands | `documentation_test`, review | OPEN |
| F4 | `RUNBOOK.md` delivered; each step names its check and the rollback | review, B11 | OPEN |

## Review log

| Package | Reviewer | Lens | Findings (c / h / m / l) | Resolution | Commit |
|---|---|---|---|---|---|
| Plan rev 1 | Sonnet 5.5, fresh | architecture fit, seams | 0 / 4 / 5 / 5 | Revision 2: work in a worktree (the live service runs the checkout); `ChildEnvironments` forwards sources' keys (web search was lost); env readers removed in the same phase as the old starts; CLI scope narrowed (owner, OD1); one gateway per channel (owner, OD5); no schema bump and no `abilities` key; precedence stated; `memory consolidate` and every env reader listed; `channel list/remove` deferred | plan rev 2 |
| Plan rev 1 | Sonnet 5.5, fresh | operator, live migration, testability | 0 / 3 / 8 / 6 | Revision 2: `start` refuses a runtime the service serves; a runbook with stop, consistent copy, rehearsal, verify and a tested rollback (B11); a plist writer for what `ChildEnvironments` does not hold, compared with the owner's plists; `.env` mode, atomic 0600 plists, no secret in output; idempotence and error rows; source-scan scope; launchctl fake on Linux; slow-lane rule; live checks split (C1–C7) | plan rev 2 |

## Loop log

| Iteration | Date | What changed | Rows moved | Still open | Next |
|---|---|---|---|---|---|
| 0 | 2026-10-09 | Plan and bar set before code | 1.4 PASS | all others | P0 reviews |
| 1 | 2026-10-10 | Two plan reviews; revision 2; owner decisions OD1 narrowed, OD5 added; work moved to a worktree | 1.3 PASS | all A–F rows | owner OK, then P1 |
