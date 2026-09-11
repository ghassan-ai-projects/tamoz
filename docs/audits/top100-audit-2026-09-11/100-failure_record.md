# Audit 100 — `gems/tamoz-agent-healing/lib/tamoz/agent/healing/failure_record.rb`

Rank 100 · 434 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 2 minor) · Bar fails: SIZE, DEAD, ERR

A well-guarded typed contract whose initializer and loader breach the hard method ceiling, and
which carries two dead convenience readers and a split error vocabulary for one invariant.

## Findings

- **[major][SIZE]** `FailureRecord#initialize` is 47 lines and `::from_h` is 35, both over the
  hard 30-line ceiling. Owning seam: a field-spec table (name → validator) beside the validators
  collapses both. (failure_record.rb:88-134, 227-261)
- **[minor][DEAD]** `#pre_dispatch?` and `#effect_safety` have zero consumers repo-wide
  (grep-proven): classification reads the same facts via typed_signal's "retryability" hash — a
  second, unused spelling of an existing concept. Owning seam: typed_signal as the single
  classifier view. (failure_record.rb:196-197)
- **[minor][ERR]** The same unsupported-format_version gate raises two different errors —
  CheckpointVersionError in `from_h` (233-236) vs HealingPolicyError in `initialize` (277-282).
  One boundary spelling owns it. (failure_record.rb:233-236, 277-282)

## Resolution — 2026-09-11

- **[minor][DEAD] fixed.** Deleted `#pre_dispatch?` and `#effect_safety` (zero consumers
  repo-wide, grep-proven); classification reads the same facts via typed_signal.
- **[minor][ERR] fixed.** `validate_format_version!` now raises `CheckpointVersionError`
  (was `HealingPolicyError`), so the unsupported-format_version invariant has one spelling
  across from_h's version-first gate and direct construction. A version/serialization skew
  is not a healing-policy violation. from_h's pre-check is kept — it must run before the
  field reads to honour Invariant 18 (version fails before any field is read). No test
  expected `HealingPolicyError` from a bad-version construction.
- **[major][SIZE] rejected — not an enforced violation.** The repo's own linter
  (`Metrics/MethodLength Max: 20`) reports **no offenses** on this file; the audit's "47/35
  lines" counts the multi-line keyword *signatures*, which RuboCop does not count toward
  method length. Bodies are within the ceiling. The proposed field-spec table would also
  erase the explicit keyword-argument contract that guards this security-critical typed
  record (`new(unknown:)` would stop raising), a net regression. No restructuring warranted.
