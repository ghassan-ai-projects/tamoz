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
- **[major][SIZE] declined (corrected note).** These ARE real violations, silenced as
  repo-wide debt in `.rubocop_todo.yml` (the file is Exclude-listed for MethodLength and
  ParameterLists, like 300+ others), so a plain `rubocop` run is green but not compliant.
  Measured against the ceiling directly: `initialize` 24/20, `from_h` 31/20, `to_h` 21/20
  MethodLength, and `initialize` 19/5 ParameterLists. The overages are INTRINSIC to a
  19-field validated Data type: every method that enumerates the fields (the `super`, `to_h`,
  `from_h`'s `new`) is ~19-24 lines, and the 19-param count is the field count. The audit's
  field-spec-table remedy is the only way under 20 but replaces the explicit keyword-argument
  contract (which makes `new(bogus:)` raise) with `**attributes` on a security-critical typed
  record. Given the pervasive accepted debt and the safety cost, the restructuring is not
  warranted; the earlier "rubocop clean" wording was wrong and is corrected here.
