# Conveyor domain fixture — quality bar

**Task:** a conveyor domain fixture whose diagnosis codes are the agentic-stream conveyor specs' codes · **Owner:** Ghassan ·
**Size:** S · **Set:** 2026-11-09 (before the change)
**Plan:** streams-simulator `docs/belt-conveyor-drives/M4-DESIGN.md` row 9 (T1), decisions O36 and O38 ·
**Governing ADRs / invariants:** ADR-058 (domain knowledge is data) · **Branch:** `belt-m4-evidence`

## 0. Outcome and fence

**Outcome:** `test/fixtures/domains/conveyor.json` carries the diagnosis codes of agentic-stream's
`examples/belt-conveyor/testdata/drive-degradation.situation.yaml` and `line-overload.situation.yaml`
(`unknown`, `drive_degrading`, `bearing`, `gearbox_seizing`, `drive_tripped`, `transient_none`) with their wording, the
specs' intents and risk classes, and a test drives each spec step through the real episode graph and gets a decision
with that step's diagnosis at the catalog's risk.

**Not in scope:** codes the specs do not have (`feed_surge`: the specs call a shared rise `transient_none`;
`sensor_stuck`: M4 row 3 adds it to agentic-stream first; `idler_drag`: a simulator fault, no spec code); a benchmark
family and fixture responses for the conveyor (no caller; a future plan when a conveyor benchmark is wanted); the
runtime, which needs no fixture (catalogs and prompt arrive on the wire).

**Owner decisions needed:** none. Choices recorded: one fixture for both specs; `transient_none` has a different
description in each spec, so the fixture joins both phrases; the objective is both specs' objectives in order, the
prompt, the watch preset and the snapshot facts are the drive-degradation spec's (line-overload's watch preset
`features.feed_kg_s > 20.0` is not carried; the overload case runs on a degradation snapshot, which a fixture provider
does not read).

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seam extended | `DomainLoader` (`test/support/domain_loader.rb`) discovers `test/fixtures/domains/*.json`; the thermal tests' episode helper (`test/support/thermal_episode_fixture.rb` at HEAD) drives the real episode graph for one domain |
| 1.2 | What already does part of it | That helper runs one fixture-provider episode; it is generalised to the including test's `Domain` and renamed `DomainEpisodeFixture` (`test/support/domain_episode_fixture.rb`) instead of copied |
| 1.3 | Blast radius | `DomainLoader.domains` gains `conveyor`; `BenchmarkFamilies` skips it (no `benchmark_family`); `script/generate_benchmark_protocol` names its domains explicitly, so the protocol SHA is unchanged |
| 1.4 | Known red at HEAD | from `EPISODE_FRAME_PHASE_BAR.md`: `rake ci` needs `LANG=en_US.UTF-8`; `DocumentationTest#test_local_markdown_links_resolve` reads the owner's untracked `outreach/` |

## B. Function

| # | Property | Check | Status |
|---|---|---|---|
| B1 | Each spec step (degrading, shedding, cause_bearing, cause_gearbox, overload) yields a produced decision with the step's diagnosis code, intent, parameters and the catalog's risk | `test/conveyor_decision_test.rb` — `test_each_spec_step_is_decided_with_its_diagnosis_at_the_catalog_risk`, risks pinned in the test from the specs; mutation: `stop_feed` R1 in the fixture → red. Fixture provider: plumbing, not reasoning | PASS |
| B2 | A step with `unknown` is refused (`action_without_diagnosis`) while `drive_degrading` carries the same step (O36) | `test_a_step_with_an_unknown_cause_is_refused_where_drive_degrading_carries_it`; mutation: `refuse_action_without_diagnosis!` returns early → red. The terminal carries only `failed`, so the refusal code is proven by the mutation, not asserted | PASS |
| B3 | A shared rise (`transient_none`) with no step produces a decision without an action | `test_a_diagnosis_with_no_step_falls_back_to_the_watch`. Not a guard: the graph produces `transient_none` with `reduce_feed` (reviewer probe); only the objective forbids acting on a shared rise | PASS |
| B4 | Every catalog code but `unknown` is exercised by a case; `vfd_trip` is absent (O38) | `test_every_code_but_unknown_and_the_shared_rise_is_a_step_diagnosis` | PASS |
| B5 | The thermal tests still pass with the generalised episode helper | `ruby -Itest test/thermal_lab_decision_test.rb` 5 runs 0 failures; `test/thermal_evidence_gate_eval_test.rb` 3 runs, 3 skips (its standing PENDING gaps) | PASS |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files, one per command | `ruby -Itest test/conveyor_decision_test.rb`: 4 runs, 0 failures; benchmark_families 2 runs, 0 failures | PASS |
| D2 | `rake ci` (UTF-8 locale) | `rake ci` (UTF-8): test_fast 1156 runs, 3 red, none this change: the known documentation link (1.4); `SubprocessRunnerTest#test_timeout_stops_cooperative_child_with_term` and `TEST FILE OVER CAP: agent_session_effect_test.rb` 7.8 s, both under load (the owner's tamoz processes run), both pass alone (1.95 s each); `rake stream:proto:check quality:architecture` by name: exit 0, enola "no structural regression" | PASS (known-red and load only) |
| D4 | RuboCop autocorrect on touched Ruby files | `bundle exec rubocop -a` on the five Ruby files: no offenses left (the three leftovers fixed by a Haiku subagent) | PASS |

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Data plus one test; the helper generalised, not copied | diff review | PASS |
| E2 | No shim or alias for the renamed helper | diff review: no alias for the old name | PASS |
| E3 | Comments per AGENTS.md | one class comment line | PASS |
| E4 | New files mode 644 | new files 644 | PASS |
| E6 | Conveyor words only in the JSON and the test's asserted values (ADR-058) | review | PASS |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | The report calls the test plumbing; no claim about a model | report | PASS |
| F3 | ADR-058 unchanged and true: a new domain is a new JSON file | review | PASS |

## Review log

| Package | Findings | Resolution | Commit |
|---|---|---|---|
| conveyor fixture | 0 critical, 0 high; medium: the shared-rise test overclaimed (the graph does not refuse acting on `transient_none`), risks were read from the fixture under test, the phase is not read by a fixture provider; low: refusal code not visible at the terminal, order-coupled code comparison, history in `source`, line-overload's watch preset and snapshot not carried, ceiling R2 for the overload step | Test renamed to the watch fallback and B3 states the gap; risks pinned in `STEPS`; sorted comparison; `source` shortened; the rest recorded in 0 and B2 | this commit |

## Loop log

| Iteration | Changed | Rows still FAIL/OPEN |
|---|---|---|
| 1 | Fixture generated from the specs' YAML, helper generalised, test; RuboCop leftovers to Haiku | review, D2 |
| 2 | `rake ci` (known-red and load only); review findings applied; mutations seen red | none |
