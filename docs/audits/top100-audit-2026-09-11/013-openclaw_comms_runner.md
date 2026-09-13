# Audit 013 — `test/support/openclaw_comms_runner.rb`

Rank 13 · 1030 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 3 minor) · Bar fails: SIZE, DUP, DEAD, B9

A capable fixture harness, but one 1000-line class carries driving, scoring, and artifact
persistence with copy-pasted parity legs and a naming-convention dispatch registry.

## Findings

- **[major][SIZE]** One class mixes scenario driving (ten `drive_*` methods), scoring/oracle
  dispatch, and artifact persistence (`write_atomic`, `build_manifest`). Owning seams: a
  manifest/artifact writer and per-scenario driver modules beside `OpenclawCommsOracles`.
  (openclaw_comms_runner.rb:26-1023, 146-185, 220-253)
- **[minor][DUP]** `drive_c1` and `drive_c6` duplicate the telegram-parity-leg scaffold verbatim
  (submit→work→drain→`leg_snapshot` twice each, same scripted task text). Owning seam: one shared
  parity-leg helper. (openclaw_comms_runner.rb:293-318, 369-402)
- **[minor][DEAD]** `drive` dispatches via `send("drive_#{id}")` — a metaprogrammed naming registry
  that defers a catalog typo to `score`'s rescue as a `blocked` record instead of failing
  `validate_scenarios!`. Owning seam: explicit dispatch, as `oracle_for` already is.
  (openclaw_comms_runner.rb:93-98, 278-280)
- **[minor][B9]** `INBOX_TASK_STATES` re-encodes the internal-status → lifecycle-word mapping as a
  Ruby literal in test/support; `Tamoz::Comms::Lifecycle` already owns the task-state vocabulary
  (`task_state_for`). (openclaw_comms_runner.rb:691-702)
