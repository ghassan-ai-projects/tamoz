# One setup for every channel — quality bar

**Task:** one runtime is one agent: every channel and the CLI share its models, sources, workspace and
abilities · **Owner:** Ghassan · **Size:** L · **Set:** 2026-10-09 (before the change)
**Plan:** [`PLAN.md`](PLAN.md) · **Governing ADRs / invariants:** ADR-042 (gateway process and its keys),
ADR-048 (model boundary, role credentials), ADR-052 (gem boundaries), ADR-059 (no backward compatibility),
ADR-061 (talk channel); invariants 56, 57 · **Branch:** `one-setup-every-channel`

Status values: `PASS` (evidence named) · `FAIL` (what is wrong) · `OPEN` (not built) ·
`BLOCKED` (cannot be done here; reason named; never counted as a pass) · `WAIVED` (owner decision,
named and dated; never by the author).

## 0. Outcome and fence

**Outcome:** on one runtime, `tamoz start` (and the installed service) runs Telegram and the talk page through
one gateway and one worker with the chat model, roles, sources, workspace and abilities read from the
runtime's `config.yaml`; `tamoz ask` on the same runtime uses the same model and workspace with no flags; the
owner's `~/.tamoz` runs this way with its history, memory and pairing intact.

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

| # | Property | Check | Status |
|---|---|---|---|
| A1 | A config `credential` is a variable name matching `*_API_KEY`, never a key; a key-shaped value is refused and never echoed | config validation test; mutation: drop the shape check | OPEN |
| A2 | Each child gets only its keys: the worker never a channel token or the voice key; the gateway never the chat key; the chat key refused as the voice key by name and by value | `child_environments_test` driven by a config; mutation per rule | OPEN |
| A3 | A thread bound before migration still validates its profile pin after it | migration test with a bound-thread fixture of the owner's shape; mutation: rewrite the profile | OPEN |
| A4 | No code path reads `TAMOZ_PROVIDER`, `TAMOZ_MODEL` or `TAMOZ_<ROLE>_*` | source scan test; mutation: re-add one reader | OPEN |
| A5 | `start` refuses a second running instance and a runtime folder inside the workspace | `start` tests | OPEN |
| A6 | The service plists hold exactly the arguments and environment `ChildEnvironments` gives; the worker plist holds no channel token, the gateway plist no chat key; files are 0600 | golden plists with keys masked; mutation: pass the full env | OPEN |

## B. Function — fixture providers prove plumbing only

| # | Property | Check | Status |
|---|---|---|---|
| B1 | Schema 3 validates `models` and `abilities`; `start` refuses a runtime without `models.chat` | `runtime_directory` tests | OPEN |
| B2 | `migrate!` 2 → 3 backs up and changes nothing but adding `models`/`abilities`; 1 → 3 works | migration tests (byte comparison of the rest) | OPEN |
| B3 | The worker, the CLI and the probes build the chat model and each role from the config | model builder and attachment model tests | OPEN |
| B4 | `tamoz setup` creates and updates a runtime; a re-run changes only what is passed | `setup` tests | OPEN |
| B5 | `channel add telegram` pairs as today and names the runtime's abilities; never writes a profile when one is set | channel tests (moved Telegram setup tests) | OPEN |
| B6 | `channel add talk` writes the channel and token as today, with the runtime's abilities | channel tests (moved talk setup tests) | OPEN |
| B7 | `start` runs one gateway serving Telegram and talk together and one worker answering both | end-to-end test with the fake Telegram API and the talk HTTP API (slow lane) | OPEN |
| B8 | A failing voice probe runs text-only and says so; a failing chat or transcription probe stops with its name | `start` tests | OPEN |
| B9 | `service install/status/uninstall` write, load, report and remove only their own jobs (launchctl injected) | service tests | OPEN |
| B10 | `tamoz ask` on a runtime uses its model, workspace and sources with no flags; `--provider/--model` override for one run; history stays in the session dir | CLI tests | OPEN |

## C. Evaluation

| # | Property | Check | Status |
|---|---|---|---|
| C1 | Live: the owner's migrated `~/.tamoz` answers on Telegram and the talk page with the same model, and a web search works from the talk page | owner session, recorded in the loop log (real models) | OPEN |

## D. Gates

| # | Property | Check | Status |
|---|---|---|---|
| D1 | Every touched or new test file, one per command | `ruby -Itest test/<file>.rb` | OPEN |
| D2 | `rake ci` stages (`stream:proto:check` known red) | output per stage | OPEN |
| D3 | `rake ci_full` slices that cover packaging and the CLI | output | OPEN |
| D4 | `rubocop -a` on every touched Ruby file | output | OPEN |
| D5 | enola `diff_snapshot` vs the baseline: no new cycle, layer violation or unintended coupling | enola output | OPEN |
| D6 | New files mode 644 (scripts 755) | `git ls-files -s` | OPEN |
| D7 | No everyday test file over 5 s on the pipeline (`.agent/rules/testing.md`) | CI timings | OPEN |

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Less machinery than today: two setups and two starts become one each; nothing from `PLAN.md` §7 built | diff review | OPEN |
| E2 | No shim, alias or legacy reader (ADR-059): removed commands and env variables are gone, not deprecated | diff review, source scan | OPEN |
| E3 | Comments per AGENTS.md | review | OPEN |
| E4 | No scratch files in the repo | `git status` | OPEN |
| E5 | Gem boundaries: config reading stays in `tamoz-agent` (`RuntimeDirectory`); the CLI uses its facade | review, boundary tests | OPEN |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | The final report separates plumbing from the live real-model check and claims nothing not run | review | OPEN |
| F2 | ADR-062 (a runtime is one agent; channels are ways in); ADR-042, 048 and 061 updated where they name the removed commands or variables; `rake adr:validate adr:verify` | ADR tooling | OPEN |
| F3 | Guides (`getting-started`, `telegram`, `talk`), `reference/cli.md`, README match the new commands | `documentation_test`, review | OPEN |
| F4 | The owner is told plainly what changed on `~/.tamoz` and how to roll it back | final report | OPEN |

## Review log

| Package | Reviewer | Lens | Findings (c / h / m / l) | Resolution | Commit |
|---|---|---|---|---|---|

## Loop log

| Iteration | Date | What changed | Rows moved | Still open | Next |
|---|---|---|---|---|---|
| 0 | 2026-10-09 | Plan and bar set before code | 1.4 PASS | all others | P0 reviews |
