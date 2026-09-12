# Audit 019 — `test/sqlite_selector_control_test.rb`

Rank 19 · 838 lines · 2026-09-11 · **Verdict: IMPROVE** (3 minor) · Bar fails: TEST, NAME, DEAD

Rigorous crash-injection contract tests that nonetheless reach through `send`/ivar injection,
resolve constants via `const_get`, and carry a duplicated assertion.

## Findings

- **[minor][TEST]** Private probing: `stopper.send(:write_control!)` twice,
  `CONTROL.send(:build_expectation, ...)`, and `stopper.instance_variable_set(:@owner_process,
  ...)`. Owning seam: a test-visible seam on the control.
  (sqlite_selector_control_test.rb:139-157, 584, 735-741)
- **[minor][NAME]** `CONTROL`/`REGISTRY` resolved via `const_get(:X, false)` (mirrored in the child
  script) — obfuscated spellings of direct constant references.
  (sqlite_selector_control_test.rb:7-8, 762-763)
- **[minor][DEAD]** Duplicate assertion `assert_equal "", result.stderr.text` at both 177 and 184
  in the same test. (sqlite_selector_control_test.rb:177, 184)

## Resolution — 2026-09-12

- [minor][TEST] `stopper.send(:write_control!)` and `CONTROL.send(:build_expectation, ...)`:
  STOPPED at the named seam — both are private on Tamoz::Evals::Harness::SQLiteSelectorControl /
  Stopper (gems/tamoz-evals-runner/.../sqlite_selector_control.rb:136-138,
  sqlite_selector_control_stopper.rb:105,144), so a test-visible seam is a gem change; frozen this
  round. Driving `write_control!` through the public `stopper.call` instead was rejected: it also
  consumes the selector's occurrence bookkeeping, so the second write would fail as an occurrence
  error, not "already exists" — a different contract. `instance_variable_set(:@owner_process, ...)`
  (584) likewise needs the seam: the owner pid is captured at construction and the mismatch branch
  is otherwise unreachable.
- [minor][NAME] `const_get(:SQLiteSelectorControl/:BoundaryRegistry, false)` at 7-8 and in the
  child script: REJECTED for now — both constants are `private_constant` in their gems, so a
  direct constant reference requires un-privating them (gem change; frozen this round). The
  child-script spelling is now generated in ONE place (test/support/sqlite_harness_inputs.rb
  `child_command`, hoisted per audit 041) instead of two test-local heredoc copies.
- [minor][DEAD] FIXED: the second `assert_equal "", result.stderr.text` (old line 184) removed;
  the pre-verify assertion at 177 stays with its "the child failed before its stop point"
  diagnostic. Suite green: 19 runs, 124 assertions.
