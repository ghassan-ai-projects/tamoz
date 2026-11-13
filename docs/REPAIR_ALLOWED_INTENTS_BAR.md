# The repair directive names the allowed intents — quality bar

**Task:** the repair message after a rejected document lists the intent types the model may recommend · **Owner:**
Ghassan · **Size:** S · **Set:** 2026-11-10 (before the change)
**Plan:** streams-simulator `docs/belt-conveyor-drives/M4-DESIGN.md` row 9 (T2: verify `c4a758f1`, plus the allowed
intents in the repair message) · **Governing ADRs / invariants:** P1 frame sections, P2 one repair · **Branch:**
`belt-m4-evidence`

## 0. Outcome and fence

**Outcome:** every non-draft repair directive ends with the intent types the frame's INTENTS section lists (the watch
plus the episode's allowed types the catalog knows, within the risk ceiling), whatever the rejection was.

Found by checking `c4a758f1`: the directive restates the document keys and shape
(`ReasoningDocumentShape.repair_directive`); it names allowed types only when the rejection itself is
`intent_type_not_allowed`. A model refused for `action_without_diagnosis` or a malformed key is not told in the repair
which steps it may take.

**Not in scope:** the frame's INTENTS section and the prompt templates (unchanged); the playbook-draft repair (it has no
intents); the `intent_type_not_allowed` message, which lists the allowed types before the ceiling filter (a type above
the ceiling would read as allowed there and not in the list; no conveyor spec allows a type above its ceiling).

**Owner decisions needed:** none.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seam extended | `EpisodeNodes#repair_directive_for` and `ReasoningDocumentShape.repair_directive` (`gems/tamoz-agent-kernel/lib/tamoz/agent/`) |
| 1.2 | What already does part of it | `EpisodeNodes#recommendable_intents` computes the frame's list; the directive reuses it, no second rule |
| 1.3 | Blast radius | The text of a repair directive, which enters the rebuilt frame's user section on the one repair call; one caller of `repair_directive` |
| 1.4 | Known red at HEAD | `42dd3e68` bar: documentation link in untracked `outreach/`; load-sensitive `SubprocessRunnerTest` and the `agent_session_effect_test` time cap |

## B. Function

| # | Property | Check | Status |
|---|---|---|---|
| B1 | A repair after any rejection names the frame's intent types | `test/agent_episode_frame_shape_test.rb` — `test_every_repair_names_the_intent_types_the_frame_lists` (a malformed document and `too_many_actions`); mutation: an empty list → red | PASS |
| B2 | Types above the risk ceiling are not named (same list as the frame) | same test, ceilings R1 and R0; mutation: the unfiltered `recommendable_types` → red | PASS |
| B3 | The existing repair tests keep passing (`stream_episode_investigation_test`, `stream_episode_loop_test`, `stream_episode_replay_test`) | investigation 17 runs, loop 11, replay 3, `agent_episode_investigation_test` 10, `benchmark_controls_test` 14, `conveyor_decision_test` 4: 0 failures | PASS |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files, one per command | `ruby -Itest test/agent_episode_frame_shape_test.rb`: 9 runs, 0 failures | PASS |
| D2 | `rake ci` (UTF-8 locale) | `rake ci` (UTF-8): one failure, the known documentation link in untracked `outreach/` (1.4); `rake stream:proto:check quality:architecture` by name: enola "no structural regression" | PASS (known-red only) |
| D4 | RuboCop autocorrect on touched Ruby files | `bundle exec rubocop -a` on the three files: no offenses left | PASS |

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | One keyword argument and one sentence; the list comes from the existing method | diff review | PASS |
| E2 | No shim (pre-1.0) | no other caller; the keyword is required | PASS |
| E3 | No new comment | diff review | PASS |
| E6 | No domain literal in Ruby | review | PASS |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | Plumbing test only; whether a real model repairs better is not claimed | report | PASS |
| F3 | No ADR states the repair directive's text | grep: none | PASS |

## Review log

| Package | Findings | Resolution | Commit |
|---|---|---|---|
| repair intents | 0 critical, 0 high, 0 medium; low: a bad wire catalog now fails in `repair_directive_for` instead of one node later (same typed error, `build_frame` already verified it); the `intent_type_not_allowed` message lists types before the ceiling filter; the test does not cover that rejection or a draft; an empty list would render as "types: ." like the frame | Noted here, not built: no conveyor spec allows a type above its ceiling, and the watch is always listed | this commit |

## Loop log

| Iteration | Changed | Rows still FAIL/OPEN |
|---|---|---|
| 1 | Keyword argument, one sentence, test; mutations seen red | review, D2 |
| 2 | Review (lows only); `rake ci` known-red only | none |
