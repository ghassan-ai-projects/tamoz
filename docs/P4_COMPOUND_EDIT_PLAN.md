# P4 plan — compound existing-file edits

Status: accepted — ready for implementation

## 1. Outcome

P4 extends `apply_patch` so that one reviewed plan step and one approval atomically apply several exact, non-overlapping replacements to one existing UTF-8 file under a single before digest. The legacy single-replacement path remains byte-compatible. The new `replacements` array is validated, preflighted, diffed, approved, executed, and receipted as one indivisible effect.

Product proof: `agent.multi-location-edit` flips from a capability gap to a success, raising the agent-smoke scorecard from 6/12 to at least 7/12 while every P3 hard safety gate stays zero.

## 2. Scope

### Files and methods that change

- `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb`
  - `ACTION_DESCRIPTIONS["apply_patch"]` — document the new `replacements` array.
  - `validate` — accept the new schema, enforce mutual exclusion, bounded count, and per-replacement text validation.
  - `apply_patch` — drive the compound preflight and atomic publication.
  - `prepare_patch` — refactor into a compound-capable preflight that returns a value containing the canonical replacement set under a `:replacements` key (e.g., `{path:, before_digest:, replacements: [...]}`). Each element carries `byte_start`, `byte_end`, `before_text`, `after_text`, and `line`.
  - `render_diff` — accept the value returned by `prepare_patch` and iterate its `:replacements` array in source order, emitting one hunk per replacement.
  - New constant `MAX_REPLACEMENTS = 32`.
- `gems/tamoz-agent/lib/tamoz/agent/runtime.rb`
  - `action_signature` — canonicalize a `replacements` array lexicographically so caller order cannot accidentally change the signature.
- `gems/tamoz-evals/suites/agent/smoke/` and the smoke harness
  - Update the scripted model response for `agent.multi-location-edit` to emit one `apply_patch` with a `replacements` array; the case identity (`case_id`, `case_version`) must not change.
- `test/agent_toolbox_test.rb` and `test/agent_toolbox_invariant17_test.rb`
  - Unit and adversarial tests for single-replacement compatibility, compound success, and every failure class.

### Work packages

- **P4-D** Specify backward-compatible tool arguments, canonical replacement ordering, overlap/ambiguity rules, unified diff rules, receipt, and failure taxonomy. (This document.)
- **P4-A** Add immutable replacement values and structural validation: bounded count and bytes, exact original-source matching, no overlap, no partial applicability.
- **P4-B** Preflight all replacements against one digest, render one exact preview, request one approval, and perform one existing atomic replace.
- **P4-C** Integrate action signatures, repair evidence, output budgets, CLI rendering, public API/docs, and packaging.
- **P4-E** Turn `agent.multi-location-edit` into success without changing its case identity or weakening any P3 hard gate.

## 3. Exact API and argument schema

`apply_patch` keeps the existing single-replacement schema and adds an optional `replacements` array. The two schemas are mutually exclusive in one call.

### Legacy single replacement (unchanged)

```json
{
  "path": "relative/file",
  "expected_sha256": "64 lowercase hex characters",
  "before": "exact existing text",
  "after": "replacement text"
}
```

### New compound replacement

```json
{
  "path": "relative/file",
  "expected_sha256": "64 lowercase hex characters",
  "replacements": [
    {"before": "first exact existing text", "after": "first replacement"},
    {"before": "second exact existing text", "after": "second replacement"}
  ]
}
```

### Validation rules

1. `path` and `expected_sha256` are required and validated as today.
2. Exactly one of these must be present:
   - `before` and `after` (legacy), or
   - `replacements` (array of objects, each containing `before` and `after`).
   Providing both is a structural `ToolError`.
3. `replacements` must be a non-empty array with at most `MAX_REPLACEMENTS` (32) elements. This bound keeps the compound `apply_patch` receipt and diff within the tool's maximum effect output budget (`6 KiB`), well under `MAX_OBSERVATION_BYTES` (`160 KiB`), and small enough that the model-facing tool description remains concise and cache-prefix stable.
4. Each replacement's `before` and `after` are validated by the existing `validate_patch_text!` contract: string, non-empty `before`, bounded by `MAX_PATCH_BYTES` (64 KiB), no null bytes, UTF-8 encoded, valid UTF-8.
5. After the file digest is verified, matching is **set-level**, not per-replacement:
   - Group supplied replacements by distinct `before` text.
   - For each group, the occurrence count of that `before` in the original content must be **greater than or equal to** the number of supplied replacements with that `before`.
   - Assign matches left-to-right: sort the occurrences of each `before` by ascending `byte_start`, pair them in order with the supplied replacements for that `before`, and record each replacement's `byte_start`, `byte_end`, and `line`.
   - If any `before` is requested more times than it occurs, reject with `ToolError: patch text requested N times but found M occurrences`.
   - After assignment, sort the entire replacement set by `byte_start` ascending and reject any overlap (`byte_end_i > byte_start_{i+1}`) with `ToolError: replacements overlap`.

### Canonical internal representation

Regardless of which schema the caller uses, the implementation converts the call into an internal canonical replacement set:

- Each element is an immutable value: `{byte_start, byte_end, before_text, after_text, line}`.
- `byte_start` is the byte offset in the original content where the assigned occurrence of `before` begins.
- `byte_end` is `byte_start + before.bytesize`.
- `line` is the 1-based line number of that occurrence in the original content, used for diff headers.

The canonical set is sorted by `byte_start` ascending. Execution applies replacements in the reverse of that order (largest `byte_start` first) so that earlier replacements do not shift the byte offsets of later ones.

### Design decision: extend the schema, do not migrate

We add `replacements` alongside the legacy `before`/`after` rather than replacing it. Justification:

- P1–P3 tests, examples, and scorecard cases depend on the single-replacement schema.
- A migration would force every caller and every plan example to change simultaneously, increasing the risk of a silent regression.
- The legacy path is a true subset of the new path; keeping it avoids changing signatures for existing successful behavior.
- The model can adopt the new array form gradually; the runtime canonicalizes both forms internally.

## 4. Required behavior matrix

| Scenario | Expected behavior | File bytes changed? |
|---|---|---|
| One legacy replacement | Same as P3: exact match, atomic rename, receipt. | Yes, on success. |
| Two ordered replacements in different locations | Both applied; one diff, one approval, one receipt. | Yes. |
| Replacements provided out of source order | Canonical sort before preflight and execution; result and signature are deterministic. | Yes. |
| Stale `expected_sha256` | `ToolError: file changed: expected digest ..., observed ...` | No. |
| Zero match for any requested `before` | `ToolError: patch text was not found` | No. |
| Requested `before` more times than it occurs | `ToolError: patch text requested N times but found M occurrences` | No. |
| Overlapping replacement byte ranges after assignment | `ToolError: replacements overlap` | No. |
| Result file would exceed `MAX_FILE_BYTES` | `ToolError: patched file exceeds 65536 bytes` | No. |
| `replacements` count exceeds 32 | `ToolError: replacements exceeds 32` | No. |
| Symlink in path | Existing `ToolError: patch path must not contain symlinks` | No. |
| Non-UTF-8 or binary target | Existing `ToolError: file is not valid UTF-8 text` / `file is not text` | No. |
| Root escape or absolute path | Existing `ToolError: path escapes the workspace root` | No. |
| Atomic rename failure (disk full, etc.) | `ToolError: atomic patch failed: ...`; original file intact. | No. |
| One replacement fails preflight | Whole set rejected; no bytes written. | No. |

## 5. Safety invariants and failure model

### Invariants enforced

- **Invariant 17 (recoverable failures only):** Every validation, preflight, and environment failure becomes a typed `ToolError`. Programmatic errors and storage corruption propagate.
- **Invariant 21 (replay-safe effects):** The effect is one atomic `File.rename` of a fully written temporary file. The receipt binds the original digest, the replacement set digest, and the final digest.
- **Invariant 25 (reviewed plan gates action):** The compound edit is one plan step; approval is requested once before any filesystem effect.
- **Invariant 26 (material change requires re-review):** Changing any replacement text, count, or order in the planned arguments changes the canonical action signature.
- **Invariant 27 (material completion requires evidence):** `agent.multi-location-edit` requires a configured check; success is scored only when the check passes.

### Atomicity rule

No byte of the target file is written until:

1. The file digest matches `expected_sha256`.
2. Every replacement matches exactly one non-overlapping byte range in the original content.
3. The resulting content size is within bounds.
4. Approval has been granted (action mode).

If any preflight step fails, the implementation returns a `ToolError` and never calls `atomic_replace`.

### Overlap detection

Overlap detection runs after set-level matching has assigned each replacement to a concrete byte range. The assigned replacements are sorted by `byte_start`. For each adjacent pair `(i, i+1)`, reject with `ToolError: replacements overlap` if `byte_end_i > byte_start_{i+1}`. Touching ranges (`byte_end_i == byte_start_{i+1}`) are allowed because they are non-overlapping. Two identical `before` strings assigned to adjacent occurrences are non-overlapping as long as their byte ranges do not intersect.

### Partial applicability

The implementation never applies a subset. Preflight is all-or-nothing; execution follows only after a successful preflight. The atomic rename is indivisible.

### Byte-safe construction

All indices are byte offsets into the original UTF-8 string. `content.index(before)` returns the byte offset of the matched occurrence. The replaced region spans `before.bytesize` bytes starting at that offset. The patched content is built by concatenating byte slices of the original content between consecutive replacement boundaries, substituting each replacement's `after` bytes at its assigned offset. No character-index splicing is used. This avoids the D-2 class of bugs where multi-byte UTF-8 `before` text corrupts surrounding content.

### Action signature

`Runtime#action_signature` already canonicalizes each action step's arguments recursively. For `apply_patch`, before the recursive canonicalization runs:

1. Detect a step whose `tool` is `apply_patch` and whose `arguments` contain a `replacements` array.
2. Perform a **stable sort by `before` only**: reorder the array so that elements are grouped by `before` in lexicographic order, but preserve the original relative order of elements that share the same `before`.
3. Leave all other argument fields (`path`, `expected_sha256`, legacy `before`, legacy `after`) untouched; the existing recursive canonicalization continues to handle key sorting and non-array fields.

Cross-`before` caller order is irrelevant to the result because set-level matching assigns occurrences independently per `before` group. Within a `before` group, however, caller order determines which `after` value applies to which occurrence, so it must be part of the signature. The stable sort keeps cross-`before` order deterministic while preserving that within-group order, satisfying Invariant 26 (material change requires re-review). The legacy single-replacement path remains hash-stable with its existing schema. Non-array fields (`path`, `expected_sha256`, legacy `before`/`after`) continue to be handled by the existing recursive key-sort canonicalization.

### Receipt

Legacy single-replacement calls return the exact P3 receipt:

```text
Applied <path>
before_sha256: <original digest>
after_sha256: <final digest>
```

Compound calls return:

```text
Applied <path>
replacements: <count>
replacement_digest: <sha256 over position-bound canonical replacement set>
before_sha256: <original digest>
after_sha256: <final digest>
```

The `replacement_digest` is computed over the replacement set sorted by `byte_start` ascending. The digest input is JSON with stable object-key ordering:

- Top-level: an array of replacement objects in `byte_start` ascending order.
- Each replacement object has keys in this exact order: `byte_start`, `byte_end`, `before`, `after`.
- No extra whitespace or line breaks are added beyond what a stable canonical JSON serializer produces.

This binds the complete assigned replacement set to the receipt and makes the digest reproducible across implementations and Ruby versions.

### Unified diff

`preview` renders one diff containing one hunk per replacement in source order (ascending `byte_start` / `line`). Each hunk uses the existing minimal format:

```text
--- a/<path>
+++ b/<path>
@@ -<line>,<old_count> +<line>,<new_count> @@
-<old line 1>
-<old line N>
+<new line 1>
+<new line N>
```

Hunks are separated by a blank line. Context lines are intentionally omitted; the preview is a minimal exact diff whose bytes are fully determined by the planned replacements and the original file. A dedicated test reconstructs the diff from the executed result and asserts it is byte-identical to the preview shown at approval time.

## 6. Required tests

### Unit tests (`test/agent_toolbox_test.rb`)

- Legacy single-replacement success remains byte-for-byte compatible.
- Compound success with two replacements in different locations.
- Compound success with two identical `before` strings and different `after` values assigned to two different occurrences (the `agent.multi-location-edit` shape).
- Compound success with replacements provided in reverse source order.
- Stale digest rejects and leaves file unchanged.
- Zero match rejects and leaves file unchanged.
- Requested `before` more times than it occurs rejects and leaves file unchanged.
- Overlapping replacements reject and leave file unchanged.
- Adjacent non-overlapping replacements succeed.
- Result size exceeded rejects and leaves file unchanged.
- `replacements` count exceeded rejects.
- Mixed legacy + `replacements` schema rejects.
- Empty `replacements` array rejects.
- Malformed replacement element (missing `before`/`after`, wrong type) rejects.
- Symlink, binary, root escape, and absolute path reject as before.

### Invariant-17 matrix (`test/agent_toolbox_invariant17_test.rb`)

Add compound-edit rows to the existing error-category matrix, asserting that every failure class returns `ToolError` and leaves the target byte-identical.

### Integration tests

- `preview` and `execute` produce consistent diffs and receipts for the same replacement set.
- Approval denial stops before any filesystem write.
- Two compound edits in one action plan are treated as separate approvals (each is a distinct step).
- Repair evidence includes the compound replacement set digest and the failed-check receipt.

### Adversarial tests

- Replacements in random caller order produce identical result and action signature; shuffle the array and assert the signature is stable.
- Two identical `before` strings with different `after` values, supplied in swapped caller order, produce different action signatures and different final file bytes (within-group order is semantically significant).
- Requesting the same `before` more times than it occurs rejects, even when the `after` values differ.
- A replacement whose `after` grows the file to exactly `MAX_FILE_BYTES` succeeds; one byte over fails.
- Multi-byte UTF-8 `before`/`after` with differing byte and character lengths (e.g., `héllo`, `日本語`) succeeds and leaves surrounding bytes unchanged (regression guard for D-2).
- Backslash literals in `after` are written literally, not interpreted (regression guard for D-2).
- One replacement's `after` text contains another replacement's `before` text; the second replacement still matches its original occurrence, not a byte created by the first replacement.

### Scorecard test (`test/agent_scorecard_test.rb`)

- `agent.multi-location-edit` scores as success.
- Scorecard rises to at least 7/12.
- All four hard gates remain zero.
- No existing P3 case regresses.

## 7. Definition of done

- `apply_patch` accepts both legacy and compound schemas with no behavioral regression for single replacements.
- All preflight failures leave the target file byte-identical.
- One diff, one approval, and one atomic rename bind the complete replacement set.
- The legacy single-replacement receipt remains byte-identical to P3; compound receipts add `replacements:` and `replacement_digest:`.
- Replacement caller order cannot change the result or the action signature.
- `agent.multi-location-edit` passes, the scorecard is at least 7/12, and safety gates are all zero.
- Full repository CI passes under both UTF-8 and C/POSIX locales.
- All five gems package successfully.
- P4 plan review is committed and accepted before any implementation commit.

## 8. Stop/redesign criteria

Stop and redesign the plan before further implementation if any of the following is discovered:

- A failure can apply only part of the replacement set.
- The approval preview can differ from the executed bytes.
- Replacement caller order changes the result or action signature.
- The compound path weakens any existing invariant-17 handling, symlink/root/binary checks, or digest validation.
- The scorecard does not reach at least 7/12 or any hard safety gate becomes non-zero.
- The implementation drifts toward multi-file transactions, file creation/deletion/rename, or generic unified-diff application.

If any of these occurs, revert to P4-D, record the conflict, and amend the plan before writing more code.
