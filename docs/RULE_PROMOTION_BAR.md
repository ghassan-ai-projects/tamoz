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
| A1 | A draft document cannot express `mode`, `active`, `envelope`, approval, or a free value; unknown keys refused | `agent_playbook_draft_test` (mutation: dropped key check → red); TZ-5 test | PASS (TZ-2; TZ-5 adds the cross-path test) |
| A2 | The draft model call goes through `EffectDispatcher.run`; a replay returns the receipt | `stream_draft_playbook_rule_test` — redelivered draft makes no new call; repair is a second journaled call | PASS (TZ-3) |
| A3 | Case summaries are framed as untrusted data, never as instructions | `agent_playbook_draft_frame_test` (summary only in the user section) + injection eval case (TZ-4) | PASS (TZ-3 frame) |
| A4 | No new cross-gem reach past a facade; enola shows no new cycle | `enola check` PASS; tamoz-stream requires no kernel file; the evals runner uses the kernel's public `FeatureCondition` (declared dependency) | PASS |
| A5 | No Tamoz code path writes Agentic Stream state or a rule's mode | `rule_promotion_authority_test` (wire fields, served/dialled RPCs, the one proposal builder, a smuggled `mode` refused through repair) | PASS (TZ-5) |
| A6 | An oversized draft request is refused, not truncated | `stream_draft_playbook_rule_test`, `agent_playbook_draft_frame_test` (21 cases, a 5 KB case, an id over 120 bytes; no model call) | PASS |

## B. Function (fake provider: plumbing only)

| # | Property | Check | Status |
|---|---|---|---|
| B1 | A DIAGNOSE decision carries the selected code; a RECONSIDER decision carries none; schema-valid | `stream_decision_builder_test`, `stream_situation_request_test`, `stream_episode_reconsider_test` | PASS (TZ-1) |
| B2 | The admitted statement holds the case key line | — | WAIVED (owner, 2026-10-27: deferred to plan §6) |
| B3 | Consistent cases → proposal; contradicting → `no_proposal`; reply never carries a mode | `stream_draft_playbook_rule_test` (fixture provider: plumbing), over gRPC too | PASS |
| B4 | The handshake announces `draft_playbook_rule`; vendored proto has no drift | handshake + launcher tests PASS; `stream:proto:check` BLOCKED here (x86 protoc), messages proven byte-identical with native protoc | PASS / BLOCKED (drift check) |

## C. Evaluation

| # | Property | Check | Status |
|---|---|---|---|
| C1 | Controls discriminate offline: oracle passes, null fails, adversary caught | `rule_proposal_scorecard_test#test_the_controls_discriminate` (oracle 8/8; null, "true" 0; overfit and decline win no rule-requiring case); mutations of the held-out and reason checks go red | PASS |
| C2 | Pump-station cases are data in `test/fixtures/domains/pump-station.json` | digest pin in `rule_proposal_scorecard_test` | PASS |
| C3 | Real-model drafting quality | BLOCKED until session 4 runs a real model; never claimed here | BLOCKED |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files, one per command | each round's files, after every fix | PASS |
| D2 | `rake ci` | `design:validate adr:validate adr:verify syntax test_fast quality:architecture` PASS; `stream:proto:check` known-red here (see above) | PASS / BLOCKED (proto check) |
| D4 | RuboCop autocorrect on touched files | `bundle exec rubocop -a` on every touched file; leftovers not hand-fixed (owner rule) | PASS |
| D5 | enola `diff_snapshot` vs baseline: no new cycle or unintended coupling; `enola check` | no new cycle or coupling; new findings are false positives (vendored proto message `DraftRule`, a Hash `fetch` in a loop) | PASS |

**Known-red at HEAD:** `stream:proto:check` — grpc-tools 1.83 ships only an x86_64 `protoc` and this Mac has no
Rosetta (`Errno::EBADARCH` before reading any proto, so it fails identically at HEAD). `rake ci`'s test phase,
design, ADR and architecture gates were run on their own.

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Simplest design; reuse reason/validate/repair, no second model-call path | draft route on the one graph; two-lens review: duplication removed (`BudgetLimits`, test worker helper, one controls check) | PASS |
| E2 | No compatibility shim (ADR-059) | diff review: none; graph version bumped, no old-version reader | PASS |
| E3 | Comments per `AGENTS.md` | one-line class docs and short "why" lines only, trimmed after review | PASS |
| E4 | File modes 644, no scratch files | `ls -l`, `git status` (scripts 755) | PASS |
| E6 | No domain literal in Ruby (ADR-058) | review: pump features, codes and thresholds only in `pump-station.json`; a pump line in the draft prompt was removed | PASS |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | Report separates plumbing from real-model results | tests named plumbing; reports tagged; real-model run reported separately | PASS |
| F2 | Plan §9 records state, commits and deviations | §9 rounds, review fixes and open owner decisions | PASS |
| F3 | Affected ADRs stay true (`rake adr:validate adr:verify`) | ADR-055 (new RPC), ADR-058 evidence row; tooling PASS | PASS |

## Review log

| Package | Findings (c / h / m / l) | Resolution | Commit |
|---|---|---|---|
| PR #82, two lenses | 0 / 0 / 9 / 12 | restored the memory-digest integrity check removed in TZ-1 (with a test); Go-encoded `-0`/large-integer features read as doubles; a condition must read a feature; catalog codes ≤ 63 chars as Agentic Stream's schema; untested admission guards tested; `BudgetLimits`, one test worker helper, one controls check; Go retrying a failed draft under the same id and Go ignoring draft diagnostics left to the owner (plan §9) | see git log |
| TZ-4/5 | 0 / 1 / 3 / 6 | held-out `must_hold` cases, more look-alikes, overfit and always-decline controls; decline reasons graded; injection case is a proposal case that may decline; malformed answers fail the case; per-run fresh database and temp cleanup in the script, `RUNS`; tautological assertions replaced; TZ-5 scans broadened to any `PlaybookProposal` reference | see git log |
| TZ-3 | 0 / 1 / 3 / 5 | id bound to the store's 128-byte request id; `draft_failed` fallback code; duplicate case ids refused; tests for repair exhaustion with usage, fixture-mode refusal; wall-time-in-flight and token under-count kept as for episodes (noted in plan §9) | see git log |
| TZ-2 | 0 / 1 / 2 / 3 | int literals refused (CEL never mixes int and double); finite literals, depth ≤ 32; repair directive names why a case fails; comments trimmed; precedence tests strengthened; eager `&&`/`||` kept (stricter than CEL) | see git log |
| TZ-1 | 0 / 0 / 1 / 4 | RECONSIDER assertion added; summary reads the code without a default; the `unknown` decision runs through the schema; 64-char `CODE_PATTERN` left (optional) | see git log |

## Loop log

| Iteration | Date | What changed | Rows moved | Still open | Next |
|---|---|---|---|---|---|
| 5 | 2026-10-27 | Two-lens PR review fixes | all OPEN rows graded | C3 (real-model run reported separately) | owner decisions in plan §9 |
| 4 | 2026-10-27 | TZ-4 scorecard, fixture, controls, real-model script; TZ-5 authority test | A5, C1, C2 PASS; C3 BLOCKED (no real-model run in this session) | C3, D2 proto check | owner: real-model run |
| 3 | 2026-10-27 | TZ-3: draft route, runner, worker RPC, launcher flag; benchmark protocol re-pinned (graph version 5) | A2, A3, A6, B3 PASS; B4 PASS/BLOCKED | C, A5, D | TZ-4 |
| 2 | 2026-10-27 | TZ-2: draft parser, condition evaluator, reply builder, proto vendored | A1 PASS | B3, B4, C, A2-A6 | TZ-3 |
| 1 | 2026-10-27 | TZ-1: `diagnosis_code` on the decision; the call to `validate_terminal_memory_consistency!` was removed in error (the author misread two concatenated outputs as an empty method); restored with a test in iteration 5 | B1 PASS, B2 WAIVED | TZ-2..TZ-5 rows | TZ-2 |
