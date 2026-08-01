# P4 compound edit plan review

Review target: `docs/P4_COMPOUND_EDIT_PLAN.md` (final revision)

## Decision

**Accepted.** The plan now correctly specifies set-level matching, preserves legacy
byte compatibility, defines byte-safe construction, concretely canonicalizes action
signatures, and binds the replacement set with a deterministic receipt digest. The
remaining corrections from the previous review have been addressed; no new gaps
were introduced.

## Findings and corrections verified

| Severity | Original finding | Resolution in final plan |
|---|---|---|
| Critical | Per-replacement ambiguity blocked identical-`before` multi-location edits. | Resolved. §3 Validation rule #5 specifies set-level matching with left-to-right occurrence assignment. |
| Critical | Legacy receipt was changed unconditionally. | Resolved. §5 Receipt returns the exact P3 format for legacy calls and the new format only for compound calls. |
| Critical | P3 construction mixed byte offsets with character lengths. | Resolved. §5 Byte-safe construction specifies byte offsets, `before.bytesize`, and byte-slice concatenation. |
| High | Action signature canonicalization was unspecified. | Resolved. §5 Action signature specifies a stable sort by `before` only, preserving within-group caller order. |
| High | `replacement_digest` excluded positions from its input. | Resolved. The digest now covers the `byte_start`-sorted canonical set including `byte_start`, `byte_end`, `before`, and `after`. |
| High | Zero-context diff lacked a testable correctness claim. | Resolved. §5 Unified diff requires a dedicated byte-identity test between preview and executed result. |
| Medium | Stable sort by `(before, after)` would have collapsed materially different occurrence assignments. | Resolved. The sort is now stable by `before` only, and §6 adds adversarial tests for swapped identical-`before`/different-`after` pairs. |
| Low | `replacement_digest` serialization was not canonicalized. | Resolved. §5 Receipt specifies JSON with stable object-key ordering and exact field order. |

## Residual risks

- Set-level matching is more complex than independent replacement validation; the
  implementation must follow the left-to-right assignment rule exactly.
- The zero-context diff format is minimal; the required byte-identity test is the
  primary safety backstop.
- Dual-schema support is correct for compatibility but adds long-term maintenance
  surface; P15 should revisit deprecation.

## Implementation gate

Implementation may proceed. The phase must stop and redesign if:

- a failure can apply only part of the replacement set;
- the approval preview can differ from the executed bytes;
- replacement order accidentally changes the result or action signature;
- the compound path weakens any existing invariant-17 handling, symlink/root/binary checks, or digest validation;
- the scorecard does not reach at least 7/12 or any hard safety gate becomes non-zero; or
- the implementation drifts toward multi-file transactions, file creation/deletion/rename, or generic unified-diff application.
