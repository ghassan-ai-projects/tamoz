# D-4 / D-5 UTF-8 contract plan review

Review target: `docs/D4_D5_UTF8_CONTRACT_PLAN.md` (revised)

## Decision

**Accepted with minor corrections.** The revised plan correctly addresses the critical and
high findings from the first review: it adds the null-byte rejection to patch arguments,
removes the dead rescue clauses, splits the encoding error messages, orders the
`valid_encoding?` check before other content operations, explicitly scopes `list_directory`
out, extends the invariant-17 conformance matrix, and explains the scorecard preservation.
The remaining issues are small implementation-clarity gaps in `search_text`.

## Findings and corrections required

| Severity | Finding | Correction required |
|---|---|---|
| Medium | The plan does not explicitly state what happens to the existing `search_text` `rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError` clause. That clause currently silently skips invalid-UTF-8 targets; after fail-closed validation, encoding errors must not be swallowed. The broad `ArgumentError` rescue could also mask other bugs. | Explicitly state that the `search_text` rescue clause is removed (or narrowed to filesystem-only `SystemCallError`/`IOError`-class errors) and that invalid-UTF-8 targets produce `ToolError` through the explicit pre-scan validation, not through rescue conversion. |
| Low | The `search_text` error message "file is not valid UTF-8 text" does not identify which candidate file is invalid. For a recursive search, the caller cannot tell which path caused the rejection. | Either include the relative path in the message (e.g., `"#{relative}: file is not valid UTF-8 text"`) or explicitly document that the invalid path is not reported and that callers must use `read_file` to locate it. |
| Low | The plan says "validate the query is UTF-8 encoded and valid" but does not state whether this validation belongs in `validate` or in `search_text`. Placing it only in `search_text` would let `validate` accept an invalid query. | State that query encoding, validity, and null-byte checks run inside `validate` so that `execute` cannot receive a non-UTF-8 query. |

## Previously raised findings — status

| Original finding | Status |
|---|---|
| Missing null-byte rejection in patch arguments | Resolved: `validate_patch_text!` now rejects `\0` with an accurate message before encoding checks. |
| Dead rescue clauses mischaracterized as a defensive boundary | Resolved: plan now requires removing them and documents why they are dead. |
| Inaccurate "must be valid UTF-8" message for ASCII-8BIT-only-ASCII inputs | Resolved: messages split into "must be UTF-8 encoded" and "must be valid UTF-8". |
| Ambiguous ordering of `valid_encoding?` vs. `\0` check | Resolved: plan requires `valid_encoding?` immediately after `path.read` and before any other content operation. |
| `search_text` UTF-8 contract gap | Resolved: plan extends fail-closed validation to queries and targets. |
| Missing invariant-17 conformance matrix extension | Resolved: plan lists seven new rejection categories and requires `ToolError` boundary assertions. |
| Unexplained scorecard preservation | Resolved: plan notes the 12 pinned cases do not exercise invalid-UTF-8 paths. |
| `list_directory` scope unaddressed | Resolved: explicitly scoped out with residual-risk note. |
| Invariant 21 not cited | Resolved: safety invariants now tie D-4 closure to truthful effect receipts. |

## Residual risks

- `search_text` fail-closed behavior on invalid targets is a scope expansion. If real
  workspaces contain single bad files and searches become unusable, the stop/redesign
  criterion allows falling back to documented silent skip. This escape hatch is acceptable
  but must not be used to avoid the explicit validation tests.
- Rejecting byte-valid ASCII-8BIT strings is the correct fail-closed choice, but it is an
  API-breaking change for programmatic callers. The accurate error message mitigates but
  does not eliminate migration friction.
- `list_directory` directory-entry encoding remains unaddressed. On platforms where
  filesystem names are not UTF-8, the tool may return undecodable strings.

## Implementation gate

Implementation may begin after these minor plan corrections are committed:

1. State that the `search_text` rescue clause is removed or narrowed so encoding errors are
   not silently skipped.
2. Decide and document whether the invalid-UTF-8 `search_text` target error includes the
   relative path.
3. State that query validation occurs inside `validate`, not only inside `search_text`.

Then:

4. `read_file` checks `content.valid_encoding?` immediately after read and before any other
   content operation; the dead rescue clause is removed.
5. `prepare_patch` checks `content.valid_encoding?` immediately after read and before
   `content.scan(before)`; the dead rescue clause is removed.
6. `validate_patch_text!` rejects null bytes, non-UTF-8 encoding tags, and invalid UTF-8
   bytes with accurate per-cause messages.
7. `search_text` rejects non-UTF-8/invalid queries and invalid-UTF-8 targets with
   `ToolError`.
8. Unit tests cover every matrix row, including byte-identical rejection and accurate error
   messages.
9. The invariant-17 conformance matrix is extended with the seven new rejection categories
   and asserts each returns `Tamoz::Agent::ToolError`.
10. `rbenv exec bundle exec rake ci` passes under both `LC_ALL=en_US.UTF-8` and
    `LC_ALL=C`.
11. `rbenv exec bundle exec tamoz-eval scorecard agent-smoke` reports the existing baseline:
    6/12 successes, all hard gates pass, zero unsafe/bypassed actions, zero false-positive
    completions (unless the correction honestly raises the score).
12. The worktree is clean and the change is committed as a single reviewed implementation
    checkpoint after the plan/review checkpoint.

Only after this correction closes should work begin on `docs/P4_COMPOUND_EDIT_PLAN.md`.
