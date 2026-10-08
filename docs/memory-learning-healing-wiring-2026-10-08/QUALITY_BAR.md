# Memory, learning, improvement, healing on every channel — quality bar

**Task:** make memory, learning, self-improvement and self-healing reach chat turns on every channel ·
**Owner:** Ghassan · **Size:** L · **Set:** 2026-10-08 (before the change)
**Plan:** this folder (`FUTURE_PLAN.md` for what is deferred) · **Governing ADRs / invariants:** ADR-016,
ADR-023, ADR-026, ADR-027, ADR-028, ADR-052 · **Branch:** verify-few-things-wired

Status values: `PASS` (evidence named) · `FAIL` · `OPEN` · `BLOCKED` · `WAIVED` (owner only).

## 0. Outcome and fence

**Outcome:** a Telegram (or any gateway/worker channel) chat turn that fails is classified by the healing
assessor; a chat turn that finishes leaves a reported Experience record; and the CLI reads, writes and
consolidates the same memory the worker channels use.

Evidence that started this task (live runtime `~/.tamoz`, 2026-10-08): 46 Telegram turns, 0 memory
records, 0 `healing.assessment` events; `tamoz memory` reads `<session-dir>/memory.sqlite3`, a store the
worker never writes.

**Done when:** every row is PASS (or WAIVED), the review log has no open critical/high finding, and the
last loop iteration changed nothing.

**Not in scope (→ `FUTURE_PLAN.md`):** scheduled or automatic consolidation; operator-configured healing
rules and running `SelfHealingCoordinator` remediation; generating improvement candidates from chat
turns; per-correspondent memory owners.

**Owner decision still open:** chat Experience is written under the one `sources.memory.owner`, so with
more than one admitted correspondent each could `recall_memory` the others' messages (Experience is never
auto-injected). Safe today — `telegram-ops` admits one correspondent — and `FUTURE_PLAN.md` §4 has the
fix; the owner accepts or blocks it.

**Owner decisions taken (2026-10-08, "all"):** (1) assess chat-route failures and crashes, mark ADR-028
Partial; (2) one memory store per runtime; (3) finished chat turns admit reported Experience — this
reverses `docs/memory-next-level-2026-09-28` row C1 for `answered` and `done_unverified`; (4) automatic
learning and remediation become a future plan.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seams extended | `SelfHealingAssessor` (`gems/tamoz-agent/lib/tamoz/agent/self_healing_assessor.rb`), `Worker#emit_healing_assessment` and `#handle_thread_failure`; `SessionMemory#record_episode_memory`; `CLIMemoryCommands#open_memory` |
| 1.2 | What already does part of it | `Memory::Access#record_experience` already admits self-certified episodes as `:reported` with 90-day expiry; `Memory::Engine.open` is the facade the CLI uses; the assessor already maps error classes (`TOOL_ERROR_CATEGORY`) |
| 1.3 | Blast radius | worker settle paths (all durable channels); work and plan routes' terminal node; CLI `code`/`chat`/`memory` |
| 1.4 | Baseline | enola `set_baseline` pinned 2026-10-08 before editing |

## A. Safety and authority

| # | Property | Check | Status |
|---|---|---|---|
| A1 | A chat episode is admitted only as `:reported`, never `:observed`, and never holds the answer prose | `test/memory_work_route_test.rb` C1/C2; episodes go through `Access#record_experience` (no reconciled outcome → `:reported`) | PASS |
| A2 | Failed, stopped, handed-off and cancelled turns admit no Experience | `test/memory_work_route_test.rb` C1; mutation: drop the reason filter → 1 failure | PASS |
| A3 | Healing stays read-only: the assessor executes nothing; an unmapped failure or crash is `unknown`, which never mutates and escalates | `test/self_healing_assessor_test.rb` (10 runs, 0 failures); assessor still only builds records and classifies | PASS |
| A4 | A successful turn with a repaired tool failure produces no assessment | `test/self_healing_worker_test.rb`; mutation: assess observations on completed turns → 1 failure | PASS |
| A5 | The CLI reaches memory only through `Memory::Engine.open`; boundary test green | `test/memory_boundary_test.rb` green inside `rake ci` test_fast (332 files passed) | PASS |
| A7 | Sharing the runtime database: the CLI is a second writer and claims pending behavior transitions; recorded in memory DESIGN | review | PASS |
| A6 | Child-task sessions still get no memory | unchanged code path (`build_child_session`), reviewed: `build_child_session` still passes `memory: nil` | PASS |

## B. Function (scripted providers — plumbing, not intelligence)

| # | Property | Check | Status |
|---|---|---|---|
| B1 | Worker emits `healing.assessment` for a failed chat turn (model refusal), a finished-but-failed chat turn (`work_failed`, `handed_off`), a blocked turn, and a crashed terminal request; not for a clean turn | `test/self_healing_worker_test.rb` 7 runs, 0 failures; mutation: drop crash assessment → 1 error | PASS |
| B2 | `tamoz memory list` sees what the runtime database holds; no `<session-dir>/memory.sqlite3` is created | `test/agent_cli_memory_test.rb` 2 runs, 0 failures; mutation: session-dir path → 2 failures | PASS |
| B3 | An `answered` turn's episode reads `Task: … \| Outcome: answered` with no dangling separator | `test_a_chat_answer_is_one_episode_per_distinct_message` | PASS |
| B4 | Repeating the same message in one conversation does not duplicate its episode | same test: `Hey` twice → one record | PASS |

## C. Evaluation — real model smoke (not a behavior claim)

| # | Property | Check | Status |
|---|---|---|---|
| C1 | With Z.ai `glm-5.3-flash` through `bin/tamoz-chat-sim` (in-process Telegram, worker path): a "remember …" message stores a user-quoted record; a later turn finds it; finished turns leave Experience. n=1, reported as a smoke, not a rate | scratchpad driver over `ExperienceSim::Harness` (routing :work, memory on), 2026-10-08: `remember` stored 2 user-quoted Knowledge records; after `/new` (new thread) the brief injected both and the model answered from them; 3 `answered` turns left 3 reported Experience records | PASS |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files, one per command | 5 touched test files green, one per command | PASS |
| D2 | `rake ci` | design, adr:validate, adr:verify, syntax, test_fast (332 files) and quality:architecture pass; `stream:proto:check` known-red | PASS |
| D4 | RuboCop: no new offense in touched files | per-file offense counts equal HEAD (assessor 29/29); new worker test 0 | PASS |
| D5 | enola `diff_snapshot` vs baseline: no new cycle, layer violation or coupling | `diff_snapshot`: 0 regressions; coupling added only inside changed classes | PASS |

**Known-red at HEAD:** `stream:proto:check` — grpc-tools ships an x86_64 `protoc`, this Mac is arm64 without Rosetta (`Errno::EBADARCH`); reproduced in a detached HEAD worktree.

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | No new class; the assessor gains one entry point for a settled turn and one for a crash | no new class; two assessor entry points, one memory predicate | PASS |
| E2 | No shim: the old `<session-dir>/memory.sqlite3` is not read (ADR-059) | old file never read | PASS |
| E3 | Comments per `AGENTS.md` | review | PASS |
| E4 | No scratch files in the repo | driver kept in session scratchpad, not the repo | PASS |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | Report separates plumbing tests from the real-model smoke | PR body: scripted tests are plumbing; one n=1 real-model smoke | PASS |
| F2 | `documentation/reference/cli.md`, memory DESIGN/QUALITY_BAR C1 match what was built | cli.md, memory DESIGN (W1, C1 text, CLI paragraph), memory QUALITY_BAR C1/E5 updated | PASS |
| F3 | ADR-028 `Implementation: Partial` with what is missing; `rake adr:validate adr:verify` green | ADR-028 Partial with the gap; catalog regenerated; `adr:validate` + `adr:verify` pass | PASS |

## Review log

| Package | Findings (c / h / m / l) | Resolution | Commit |
|---|---|---|---|
| all | 0 / 2 / 3 / 6 — H1 the agenteval memory pack judged `<session-dir>/memory.sqlite3`, which no longer exists; H2 `tamoz memory list` scoped to cwd, so it missed what the worker stored; M1 shared owner; M2 ADR-028 overclaimed and plan/adaptive-route reasons were unmapped; M3 shared-DB side effects undocumented; lows: lint, a comment, `model_refused` category, cli.md flag, `:reported` untested, test DB protection | H1/H2 fixed with tests seen to fail on revert; M2 reasons mapped, `direct_response` added, ADR reworded; M3 documented; M1 put to the owner; lows fixed except the anonymous-class crash code (cannot happen) and history docs PLAN/STATUS (left as history) | follow-up commit |

## Loop log

| Iteration | Date | What changed | Rows moved | Still open | Next |
|---|---|---|---|---|---|
| 1 | 2026-10-08 | healing on every settle path and crash; one memory store; finished chat turns admit Experience; docs, ADR-028 | all to PASS | review log | apply review findings |
| 2 | 2026-10-08 | review fixes (eval store path, `tamoz memory` scope, route coverage, docs) | D4 back to PASS after lint | M1 owner decision | none |
