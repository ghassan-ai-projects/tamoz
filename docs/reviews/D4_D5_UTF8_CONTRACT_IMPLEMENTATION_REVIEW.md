# D-4 / D-5 UTF-8 contract implementation review

Review target: `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb` and `test/agent_toolbox_test.rb`
Baseline for A/B comparison: commit `019ea40`

## Decision

**Accepted with minor corrections.** The implementation honestly closes the two committed
D-4/D-5 defects: invalid-UTF-8 targets are rejected with typed `Tamoz::Agent::ToolError`,
patch arguments are rejected when they contain null bytes or are not valid UTF-8, and
`search_text` queries are validated fail-closed inside `validate`. All targeted tests pass,
full `rake ci` passes under both `LC_ALL=en_US.UTF-8` and `LC_ALL=C`, and the agent-smoke
scorecard preserves the 6/12 baseline with zero safety-counter regressions. No existing
rejection path is weakened and no target file is mutated on rejection.

The single material gap is that the explicit invariant-17 conformance matrix extension
required by the plan is not present as a committed artifact or dedicated test file; the
matrix rows are exercised only inside the general unit tests.

## Findings and corrections required

| Severity | Finding | Correction required |
|---|---|---|
| Medium | The invariant-17 conformance matrix extension is not committed. The plan and plan review require a distinct matrix that lists the seven new rejection categories and asserts each returns `Tamoz::Agent::ToolError`. The current `test/agent_toolbox_test.rb` exercises every category, but no standalone matrix or extension of an existing invariant-17 conformance file exists. | Add a committed invariant-17 conformance matrix extension (either as a new test file or as an extension of the existing invariant-17 test shape) that explicitly enumerates the seven categories and asserts the `ToolError` boundary. |
| Low | The existing `test_every_patch_rejection_leaves_the_target_byte_identical` case `"invalid utf-8 after"` now fails inside `validate_patch_text!` during `validate`, before any filesystem access. The test still passes and still proves the byte-identical safety claim, but the case label no longer describes a filesystem-level patch rejection. | Rename the case to `"invalid utf-8 after argument"` or move it to the dedicated `validate_patch_text!` tests so the byte-identical rejection suite stays focused on filesystem-side rejections. |
| Low | The implementation is not yet committed. The plan's definition of done requires a single reviewed implementation checkpoint. | Commit the two modified files as the implementation checkpoint after addressing the invariant-17 matrix gap. |

## Previously raised findings — status

| Original finding | Status |
|---|---|
| Missing null-byte rejection in patch arguments | Closed: `validate_patch_text!` rejects `\0` before encoding checks with `"before/after must not contain a null byte"`. |
| Dead rescue clauses mischaracterized as a defensive boundary | Closed: the `Encoding::...` rescue clauses are removed from `read_file` and `prepare_patch`; the `search_text` rescue is narrowed to `SystemCallError, IOError`. |
| Inaccurate "must be valid UTF-8" message for ASCII-8BIT-only-ASCII inputs | Closed: messages split into `"must be UTF-8 encoded"` and `"must be valid UTF-8"`. |
| Ambiguous ordering of `valid_encoding?` vs. `\0` check | Closed: `valid_encoding?` runs immediately after `path.read(encoding: Encoding::UTF_8)` and before `include?("\0")` or `scan`; null-byte checks in `validate_patch_text!` run before encoding checks. |
| `search_text` UTF-8 contract gap | Closed: query validation runs inside `validate`; invalid-UTF-8 targets raise path-qualified `ToolError`. |
| Missing invariant-17 conformance matrix extension | **Not closed:** unit tests cover the categories, but the explicit matrix artifact is missing. |
| Unexplained scorecard preservation | Closed: scorecard remains 6/12 with zero unsafe/bypassed actions and zero false-positive completions. |
| `list_directory` scope unaddressed | Closed: explicitly scoped out; residual risk documented. |
| Invariant 21 not cited | Closed: byte-identical rejection is asserted for invalid-UTF-8 patch targets. |

## Verification performed

- `rbenv exec bundle exec rake test TEST=test/agent_toolbox_test.rb` — **pass**, 19 runs, 135 assertions, 0 failures.
- `LC_ALL=en_US.UTF-8 rbenv exec bundle exec rake ci` — **pass**, 363 runs, 27311 assertions, 0 failures.
- `LC_ALL=C rbenv exec bundle exec rake ci` — **pass**, 363 runs, 27314 assertions, 0 failures.
- `rbenv exec bundle exec tamoz-eval scorecard agent-smoke` — **pass**, 6/12 task successes, 0 unsafe/bypassed actions, 0 false-positive completions, 0 incomplete evidence.
- Blind A/B probe against baseline `019ea40`:

| Probe | Baseline `019ea40` | New `HEAD` |
|---|---|---|
| `read_file` invalid-UTF-8 target | returns invalid content silently | `ToolError: file is not valid UTF-8 text` |
| `apply_patch` invalid-UTF-8 target | `ArgumentError: invalid byte sequence in UTF-8` | `ToolError: file is not valid UTF-8 text` |
| `search_text` invalid-UTF-8 target | silently skipped | `ToolError: bad.txt: file is not valid UTF-8 text` |
| `validate` ASCII-8BIT `before` | accepted | `ToolError: before must be UTF-8 encoded` |
| `validate` invalid-UTF-8 search query | accepted | `ToolError: query must be valid UTF-8` |

The A/B probe proves the intended behavior change and shows no regression on the old paths:
they were silently unsafe and are now fail-closed.

## Implementation details reviewed

- `read_file` (`toolbox.rb:227-229`) checks `content.valid_encoding?` immediately after the
  read and before `include?("\0")` or digest computation. The dead `Encoding::...` rescue is
  removed.
- `prepare_patch` (`toolbox.rb:294-296`) checks `content.valid_encoding?` before
  `content.scan(before)` and before `atomic_replace` can be reached. The dead `Encoding::...`
  rescue is removed.
- `validate_patch_text!` (`toolbox.rb:485-491`) rejects non-strings, empty `before`,
  oversized text, null bytes, non-UTF-8 encoding tags, and invalid UTF-8 bytes in that
  order, with per-cause messages.
- `search_text` validates the query inside `validate` (`toolbox.rb:141-147`) and validates
  each candidate file's decoded content before scanning (`toolbox.rb:260-264`), raising a
  path-qualified `ToolError` on invalid targets. The rescue is narrowed to
  `SystemCallError, IOError` (`toolbox.rb:273`).

## Safety assessment

- **No weakened rejection.** Every new check is additional; no existing check was removed or
  reordered to allow a previously rejected input.
- **No filesystem mutation on rejection.** `prepare_patch` returns before `atomic_replace` for
  all new rejection paths; `search_text` and `read_file` are read-only.
- **No untyped exception escape.** Encoding errors are converted to `ToolError` before they
  can propagate; the remaining `search_text` rescue covers only filesystem-class errors.
- **Public Ruby API break is intentional and documented.** ASCII-8BIT strings that happened to
  be byte-valid are now rejected; callers must tag strings as UTF-8. This is the accepted
  fail-closed contract.

## Residual risks

- The missing invariant-17 conformance matrix extension leaves the new `ToolError` boundary
  assertions dispersed in unit tests rather than centralized. If future refactors move or
  delete a test, the matrix guarantee could be lost.
- `list_directory` directory-entry encoding remains unaddressed, as scoped out.
- Rejecting byte-valid ASCII-8BIT strings is a breaking change for programmatic callers of
  the public Ruby API; migration guidance is limited to the accurate error message.

## Implementation gate

The implementation may be committed after:

1. Adding the invariant-17 conformance matrix extension as a committed artifact.
2. Optionally clarifying the `"invalid utf-8 after"` case label in
   `test_every_patch_rejection_leaves_the_target_byte_identical`.
3. Committing the two modified files as the reviewed implementation checkpoint.

Only after this correction closes should work begin on `docs/P4_COMPOUND_EDIT_PLAN.md`.
