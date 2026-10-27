# Rule promotion, first slice (Tamoz) — quality bar

**Task:** TZ-1 to TZ-5 of `docs/RULE_PROMOTION_PLAN.md` · **Owner:** Ghassan · **Size:** L · **Set:** 2026-10-27 (before the change)
**Plan:** `docs/RULE_PROMOTION_PLAN.md` · **Governing ADRs / invariants:** ADR-016 (effect journal), ADR-024 (real model only for real runs), ADR-052 (gem boundaries), ADR-058 (domain knowledge as data), ADR-059 (no backward compatibility); invariant 34 (no self-promotion) · **Branch:** `rule-promotion`

Status values: `PASS` (evidence named) · `FAIL` · `OPEN` · `BLOCKED` · `WAIVED`.

## 0. Outcome and fence

**Outcome:** a worker decision carries the `diagnosis_code` Tamoz derived; the admitted experience keeps
the case key; the worker announces `draft_playbook_rule` and answers `DraftPlaybookRule` with a strictly
parsed `PlaybookProposal` or `NoProposal` through the journaled model call; a data-driven
`rule_proposal` scorecard grades drafting offline with controls; no Tamoz path can set a rule's mode.

**Done when:** every row is PASS (or WAIVED by the owner), the review log has no open critical or high
finding, and the loop log's last iteration changed nothing.

**Not in scope:** nomination from memory, feedback from approvals, a rule-candidate record, a tenant
leak test for candidates (plan §6); real-model drafting evidence (session 4 runs it).

**Owner decisions needed:** none to start; deviations are recorded in the plan's §9.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seams extended | `DecisionNodeBuilder#outcome_projection` + `DecisionBuilder#build` (TZ-1); `SituationRequest#episode_content_for` (TZ-1); a draft document parser beside `ReasoningDocument` (TZ-2); `EpisodeWorker` service + handshake features (TZ-3); the episode graph's reason/validate/repair nodes (TZ-3); the evals runner's scorecard families (TZ-4). |
| 1.2 | What already does part of it | `ReasoningDocument` derives `selected_code`; `EffectDispatcher.run` journals model calls; `EpisodeFrameBuilder` bounds facts; `agenteval` controls. |
| 1.3 | Blast radius | `impact_analysis` per round, recorded in the loop log. |
| 1.4 | Baseline pinned | enola `set_baseline` at 2026-10-27 before TZ-1. |

## A. Safety and authority

| # | Property | Check | Status |
|---|---|---|---|
| A1 | A draft document cannot express `mode`, `active`, `envelope`, approval, or a free value; unknown keys refused | parser refusal tests (TZ-2), TZ-5 test | OPEN |
| A2 | The draft model call goes through `EffectDispatcher.run`; a replay returns the receipt | draft path test (TZ-3) | OPEN |
| A3 | Case summaries are framed as untrusted data, never as instructions | frame test (TZ-3) + injection eval case (TZ-4) | OPEN |
| A4 | No new cross-gem reach past a facade; enola shows no new cycle | `enola check`, `diff_snapshot` | OPEN |
| A5 | No Tamoz code path writes Agentic Stream state or a rule's mode | TZ-5 adversarial test | OPEN |
| A6 | An oversized draft request is refused, not truncated | TZ-3 test | OPEN |

## B. Function (fake provider: plumbing only)

| # | Property | Check | Status |
|---|---|---|---|
| B1 | A DIAGNOSE decision carries the selected code; a RECONSIDER decision carries none; schema-valid | `stream_decision_builder_test`, `stream_situation_request_test`, `stream_episode_reconsider_test` | PASS (TZ-1) |
| B2 | The admitted statement holds the case key line | — | WAIVED (owner, 2026-10-27: deferred to plan §6) |
| B3 | Consistent cases → proposal; contradicting → `no_proposal`; reply never carries a mode | TZ-3 worker tests | OPEN |
| B4 | The handshake announces `draft_playbook_rule`; vendored proto has no drift | handshake test, `rake stream:proto:check` | OPEN |

## C. Evaluation

| # | Property | Check | Status |
|---|---|---|---|
| C1 | Controls discriminate offline: oracle passes, null fails, adversary caught | `rule_proposal` scorecard control test | OPEN |
| C2 | Pump-station cases are data in `test/fixtures/domains/pump-station.json` | fixture test | OPEN |
| C3 | Real-model drafting quality | BLOCKED until session 4 runs a real model; never claimed here | BLOCKED |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files, one per command | `ruby -Itest test/<file>.rb` | OPEN |
| D2 | `rake ci` | output | OPEN |
| D4 | RuboCop autocorrect on touched files | `bundle exec rubocop -a` | OPEN |
| D5 | enola `diff_snapshot` vs baseline: no new cycle or unintended coupling; `enola check` | enola output | OPEN |

**Known-red at HEAD:** `stream:proto:check` — grpc-tools 1.83 ships only an x86_64 `protoc` and this Mac has no
Rosetta (`Errno::EBADARCH` before reading any proto, so it fails identically at HEAD). `rake ci`'s test phase,
design, ADR and architecture gates were run on their own.

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Simplest design; reuse reason/validate/repair, no second model-call path | review | OPEN |
| E2 | No compatibility shim (ADR-059) | diff review | OPEN |
| E3 | Comments per `AGENTS.md` | review | OPEN |
| E4 | File modes 644, no scratch files | `git status` | OPEN |
| E6 | No domain literal in Ruby (ADR-058) | review | OPEN |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | Report separates plumbing from real-model results | review | OPEN |
| F2 | Plan §9 records state, commits and deviations | review | OPEN |
| F3 | Affected ADRs stay true (`rake adr:validate adr:verify`) | ADR tooling | OPEN |

## Review log

| Package | Findings (c / h / m / l) | Resolution | Commit |
|---|---|---|---|
| TZ-1 | 0 / 0 / 1 / 4 | RECONSIDER assertion added; summary reads the code without a default; the `unknown` decision runs through the schema; 64-char `CODE_PATTERN` left (optional) | see git log |

## Loop log

| Iteration | Date | What changed | Rows moved | Still open | Next |
|---|---|---|---|---|---|
| 1 | 2026-10-27 | TZ-1: `diagnosis_code` on the decision; empty `validate_terminal_memory_consistency!` removed | B1 PASS, B2 WAIVED | TZ-2..TZ-5 rows | TZ-2 |
