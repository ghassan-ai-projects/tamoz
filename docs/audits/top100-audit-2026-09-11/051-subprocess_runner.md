# Audit 051 — `gems/tamoz-evals-runner/lib/tamoz/evals/harness/subprocess_runner.rb`

Rank 51 · 616 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 2 minor) · Bar fails: SIZE

A rigorously safe subprocess harness whose process-lifecycle methods overgrow the Q6 method
ceiling and mix launch/await/teardown phases.

## Findings

- **[major][SIZE]** `execute` runs 53 lines stitching four lifecycle phases — spawn, reader-thread
  startup, wait/intervention arbitration, result assembly — plus rescue translation and ensure
  cleanup. Owning seam: a launch/await phase split in private steps of this class.
  (subprocess_runner.rb:166-218)
- **[minor][SIZE]** `wait_for_child` is 44 lines of interleaved deadline/stop-signal/poller/
  intervention branches and `escalate_termination` is 31; both exceed the 30-line ceiling.
  (subprocess_runner.rb:273-348)
- **[minor][SIZE]** Boolean keyword param `allow_empty:` on `normalize_text` selects two validation
  modes. Owning seam: separate empty-allowed vs strict normalizers, or a policy value.
  (subprocess_runner.rb:539, 575)
