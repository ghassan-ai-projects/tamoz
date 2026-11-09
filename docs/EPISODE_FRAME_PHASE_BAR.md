# Episode frame shows the situation's phase — quality bar

**Task:** the episode frame's situation section carries the verified snapshot's `phase` · **Owner:** Ghassan ·
**Size:** S · **Set:** 2026-11-09 (before the change)
**Plan:** streams-simulator `docs/belt-conveyor-drives/PLAN.md` §4.3 (T2 family), M4 arm B (O28) ·
**Governing ADRs / invariants:** P1 frame sections (trusted policy / untrusted situation) · **Branch:** `belt-m4-evidence`

## 0. Outcome and fence

**Outcome:** when the agentic-stream snapshot carries a `phase`, the model sees it in the frame's situation section as
`fact:situation.phase` and may cite it; a snapshot without a phase yields the same frame bytes as before.

Found while preparing the conveyor live-model runs: the drive-degradation spec's objective names its step per phase
("in degrading shed the feed; in shedding run the belt empty; ..."), the snapshot carries the phase at its top level
(agentic-stream `SituationVersionRecord.Phase`), but `EpisodeFrameBuilder#build_facts` read only `snapshot["facts"]`,
so the model could not see which step was due.

**Not in scope:** other snapshot fields (severity, completeness); a conveyor domain fixture (T1: the runtime needs none,
intents and prompt arrive on the wire).

**Owner decisions needed:** none.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seam extended | `Tamoz::Agent::EpisodeFrameBuilder#build_facts` (`gems/tamoz-agent-kernel/lib/tamoz/agent/episode_frame_builder.rb`) |
| 1.2 | What already does part of it | `build_facts` renders snapshot facts as `fact:<id>` entries and evidence ids; the phase becomes one more entry, no new class |
| 1.3 | Blast radius | Only the frame bytes of snapshots that carry `phase` (agentic-stream episodes); facts and evidence ids otherwise unchanged. agentic-stream grounds intent evidence ids in the decision's own `facts_used`, so a cited `fact:situation.phase` is accepted |
| 1.4 | Known red at HEAD | `rake ci` needs `LANG=en_US.UTF-8` (9 `TalkEvalControlsTest` encoding errors under US-ASCII). Under UTF-8 one failure, not this change: `DocumentationTest#test_local_markdown_links_resolve` reads the owner's untracked `outreach/research/03-pilot-readiness-barriers.md`, whose `file://` link points into agentic-stream |

## B. Function

| # | Property | Check | Status |
|---|---|---|---|
| B1 | The phase is the first situation entry and a citable evidence id; a snapshot without phase is unchanged | `test/agent_episode_frame_shape_test.rb` — `test_the_situation_section_shows_the_snapshot_phase_as_a_citable_fact` | PASS |
| B2 | The phase entry passes the same size check and fact cap as every fact (one path) | `build_facts` iterates the phase pair and the facts together; review | PASS |
| B3 | Frame bytes change only for snapshots with a phase (intended) | same test, last assertion (no phase: only `fact:x`) | PASS |
| B4 | `benchmark_controls` control 5 (hidden fields leave the frame unchanged) holds: its snapshots carry no `phase` | `ruby -Itest test/benchmark_controls_test.rb`: 14 runs, 0 failures. A snapshot's phase is now model-visible by design | PASS |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test file | `ruby -Itest test/agent_episode_frame_shape_test.rb`: 8 runs, 0 failures | PASS |
| D2 | `rake ci` (UTF-8 locale) | 435 runs, 1 failure: the known-red documentation link in untracked `outreach/` (1.4) | PASS (known-red only) |
| D4 | RuboCop autocorrect on touched files | `bundle exec rubocop -a` on both files: no offenses left | PASS |

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | One constant and one helper; no new mechanism | diff review | PASS |
| E2 | No shim (pre-1.0) | diff review | PASS |
| E3 | One comment line of why | diff review | PASS |
| E6 | No domain literal in Ruby: `phase` is the agentic-stream snapshot's own field, not a conveyor word | review | PASS |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | The real-model effect is reported from the conveyor runs, not claimed here | report | PASS |
| F3 | No ADR states the frame's situation entries | `grep -ril 'episode frame' documentation/adr`: none | PASS |

## Review log

| Package | Findings | Resolution | Commit |
|---|---|---|---|
| frame phase | 0 critical, 0 high; medium: the phase skipped the fact size check; low: phase counts toward `MAX_FACTS` (a 64-fact snapshot loses its last fact), a real fact named `situation.phase` would duplicate the id, `SITUATION_FIELDS` + `filter_map` more machinery than one field needs; note control 5 | Medium and the machinery fixed (one loop, one constant); the 64-fact edge and a fact literally named `situation.phase` noted here, not built (no spec has either); control 5 is B4 | this commit |

## Loop log

| Iteration | Changed | Rows still FAIL/OPEN |
|---|---|---|
| 1 | Change, test, RuboCop | D2 |
| 2 | Review: phase through the fact loop (size check, cap); `rake ci` (known-red only), `rake stream:proto:check quality:architecture` exit 0 | none |
