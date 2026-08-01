# D-4 / D-5 plan — tighten the Toolbox UTF-8 text contract

Status: accepted with corrections

## 1. Outcome

Close two committed defects in `Tamoz::Agent::Toolbox` before P4 expands the patch surface.

What changes:

- `read_file` rejects a file whose bytes are not valid UTF-8 with the documented typed
  `Tamoz::Agent::ToolError`, instead of returning content that has `valid_encoding? == false`.
- `apply_patch` and `preview("apply_patch", ...)` reject a non-UTF-8 target file with a typed
  `ToolError`, instead of raising an untyped `ArgumentError` from `content.scan(before)`.
- `validate_patch_text!` requires the argument to be encoded as `Encoding::UTF_8`, valid in
  that encoding, and free of null bytes, so the public Ruby API cannot accept an
  `ASCII-8BIT` string or a string containing `\0`.
- `search_text` applies the same fail-closed contract: UTF-8-encoded, valid queries and
  rejection of invalid-UTF-8 targets with a typed `ToolError`, instead of silently skipping
  them.

What stays the same:

- Valid UTF-8 files continue to read, search, preview, and patch exactly as before, including
  all Round 1 multibyte and `LC_ALL=C` probes.
- Files containing `\0` continue to be rejected as "file is not text" by `read_file` and
  `prepare_patch`.
- Every rejection path for `apply_patch` leaves the target file byte-identical.
- Tool schemas, public method signatures, and CLI argument parsing do not change.
- The agent-smoke scorecard baseline remains 6/12: none of the 12 pinned cases reads or patches
  invalid UTF-8, so the expected score stays at the floor unless the correction honestly
  exposes a previously hidden defect.

## 2. Scope

One production file changes:

- `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb`
  - `read_file` — check `content.valid_encoding?` immediately after
    `path.read(encoding: Encoding::UTF_8)` and before any other content operation; remove the
    dead `Encoding::...` rescue clause.
  - `prepare_patch` — check `content.valid_encoding?` immediately after reading the target
    file and before `content.scan(before)`; remove the dead `Encoding::...` rescue clause.
  - `validate_patch_text!` — add a `value.include?("\0")` check, then reject non-UTF-8 encoding
    tags and invalid UTF-8 byte sequences with separate, accurate messages.
  - `search_text` — validate the query inside `validate` (UTF-8 tag, valid bytes, no null
    bytes) so `execute` cannot receive a non-UTF-8 query; inside `search_text`, validate each
    candidate file's decoded content before scanning and raise `ToolError` that includes the
    relative path on any invalid target. Remove the existing `Encoding::...` rescue clause, or
    narrow it to filesystem-only errors (`SystemCallError`/`IOError` class) so encoding failures
    are not silently skipped.

Explicitly out of scope:

- `list_directory` directory-entry encoding. D-4/D-5 covers text-file content and patch/query
  arguments, not filesystem name bytes. If supported platforms can return non-UTF-8 directory
  names, that remains a residual risk for P5 file creation to address.

No new dependencies, no new public classes, no generic abstraction, and no change to the
scorecard runner, CLI, or other tools.

## 3. Required behavior matrix

All rows assume a workspace rooted in a temporary directory and a change-capable toolbox.

| Scenario | Input / target | Expected result | File bytes after call |
|---|---|---|---|
| Valid UTF-8 target read | file contains `héllo 日本語` | `read_file` returns content with correct digest | unchanged |
| Invalid UTF-8 target read | file contains `\xC3\x28` | `read_file` raises `ToolError`: "file is not valid UTF-8 text" | unchanged |
| Valid UTF-8 target patch | file contains `héllo` | `apply_patch` / `preview` succeed exactly as Round 1 | replaced as requested |
| Invalid UTF-8 target patch | file contains `\xC3\x28` | `apply_patch` / `preview` raise `ToolError`: "file is not valid UTF-8 text" | unchanged |
| Valid UTF-8 patch argument | `before`/`after` are UTF-8 strings | validation passes | — |
| ASCII-8BIT argument (any byte content) | `"abc"` or `"\xFF"` tagged `ASCII-8BIT` | `validate_patch_text!` raises `ToolError`: "before must be UTF-8 encoded" / "after must be UTF-8 encoded" | — |
| UTF-8 argument with invalid bytes | `"\xFF"` tagged `UTF-8` | `validate_patch_text!` raises `ToolError`: "before must be valid UTF-8" / "after must be valid UTF-8" | — |
| UTF-8 argument containing `\0` | `"a\0b"` tagged `UTF-8` | `validate_patch_text!` raises `ToolError`: "before must not contain a null byte" / "after must not contain a null byte" | — |
| `LC_ALL=C` multibyte search | multibyte query against valid UTF-8 file | `search_text` returns matches (D-3 fix preserved) | unchanged |
| Invalid-UTF-8 search target | workspace contains `\xC3\x28` file | `search_text` raises `ToolError`: "<relative>: file is not valid UTF-8 text" | unchanged |
| Non-UTF-8 or null-byte search query | `ASCII-8BIT` or `"a\0b"` query | `search_text` raises `ToolError`: "query must be UTF-8 encoded", "query must be valid UTF-8", or "query must not contain a null byte" | unchanged |

The `read_file` and `prepare_patch` `Encoding::...` rescue clauses are removed because
`Pathname#read(encoding: Encoding::UTF_8)` tags bytes without transcoding; those exceptions do
not fire on that path. The explicit `valid_encoding?` check is the single relied-upon boundary.

## 4. Safety invariants and failure model

- **Fail-closed on invalid text.** Any path that cannot produce a valid UTF-8 string becomes a
  typed `Tamoz::Agent::ToolError`. It is treated by the runtime as a recoverable tool failure
  (invariant 17), not a propagating programmer bug.
- **No filesystem mutation on rejection.** `prepare_patch` performs no replacement before the
  encoding check, and `atomic_replace` is never invoked. The target file must remain
  byte-identical on every rejection path (invariant 21: a truthful receipt must correspond to
  exact, intended bytes; closing D-4 removes the path where an invalid-UTF-8 read could lead to
  a truthful receipt for corrupted output).
- **No encoding-tag games.** `validate_patch_text!` inspects `value.encoding` directly and
  rejects strings not tagged as UTF-8, even when their byte content happens to be valid UTF-8.
  This removes ambiguity about the contract at the public Ruby API.
- **No null bytes in patch text.** `validate_patch_text!` rejects `\0` in `before`/`after`
  before encoding checks, preventing the creation of a file that `read_file` would then reject
  as "not text."
- **Locale independence.** The fix does not rely on `Encoding.default_external`. Tools specify
  `encoding: Encoding::UTF_8` on every read and validate the result explicitly.
- **No generic abstraction.** The change is a small set of explicit checks in the existing
  methods, not a new validator class or shared helper.

## 5. Required tests

### Unit tests in `test/agent_toolbox_test.rb`

1. `read_file` rejects an invalid-UTF-8 file (`\xC3\x28`) with `ToolError` and leaves the file
   unchanged.
2. `apply_patch` rejects an invalid-UTF-8 target file with `ToolError` and leaves the file
   byte-identical, both for `execute` and `preview`.
3. `validate_patch_text!` rejects a `\0` in `before` and `after` with the null-byte message.
4. `validate_patch_text!` rejects an `ASCII-8BIT` string (any byte content) for both `before`
   and `after` with the UTF-8-encoded message.
5. `validate_patch_text!` rejects a UTF-8-tagged string containing invalid bytes for both
   `before` and `after` with the valid-UTF-8 message.
6. All existing Round 1 multibyte patch cases still pass, including CJK and emoji ZWJ.
7. The existing `LC_ALL=C` `search_text` multibyte test still passes.
8. `search_text` raises `ToolError` when the workspace contains an invalid-UTF-8 file.
9. `validate("search_text", ...)` rejects an `ASCII-8BIT`, invalid-UTF-8, or null-byte query
   before `execute` reaches `search_text`; `execute` with such a query also raises `ToolError`.

### Invariant-17 conformance matrix extension

Extend the invariant-17 tool-error category matrix to include the new rejection types and
assert each returns `Tamoz::Agent::ToolError`, not a raw exception:

- invalid-UTF-8 `read_file` target,
- invalid-UTF-8 `apply_patch` target,
- non-UTF-8-tagged `before`/`after` argument,
- invalid-byte-sequence `before`/`after` argument,
- null-byte `before`/`after` argument,
- invalid-UTF-8 `search_text` target,
- non-UTF-8 or invalid-UTF-8 `search_text` query.

### Held-out probes (outside the committed tree, per Gauntlet protocol)

- Probe `p02` extension: add an invalid-UTF-8 target to the ten existing byte-level safety
  invariants; verify rejection leaves the file byte-identical.
- Probe `p05` extension: confirm `read_file`, `apply_patch`, and `search_text` behavior is
  identical under `LC_ALL=en_US.UTF-8` and `LC_ALL=C` for valid and invalid UTF-8 inputs.
- Adversarial argument probe: pass `before`/`after` as `ASCII-8BIT` with null bytes and invalid
  bytes through the public Ruby `validate` / `execute` path and confirm a `ToolError`, not a
  write.
- Search-target probe: place an invalid-UTF-8 file in an otherwise valid workspace and confirm
  `search_text` returns a typed `ToolError` rather than an omitted result or a raw exception.

## 6. Definition of done

- `read_file` raises `ToolError` for any file whose decoded bytes are not valid UTF-8.
- `apply_patch` and `preview("apply_patch", ...)` raise `ToolError` for any target file whose
  bytes are not valid UTF-8, without modifying the target.
- `validate_patch_text!` rejects any `before` or `after` string containing `\0`, not tagged as
  UTF-8, or not valid in UTF-8, with an accurate per-cause message.
- `search_text` rejects invalid-UTF-8 queries and targets with `ToolError`.
- `rbenv exec bundle exec rake ci` passes under both `LC_ALL=en_US.UTF-8` and `LC_ALL=C`.
- `rbenv exec bundle exec tamoz-eval scorecard agent-smoke` reports the existing baseline:
  6/12 successes, all hard gates pass, zero unsafe/bypassed actions, zero false-positive
  completions (unless the correction honestly raises the score).
- The worktree is clean and the change is committed as a single reviewed implementation
  checkpoint after this plan/review checkpoint.

## 7. Stop/redesign criteria

Stop and revise the plan before implementing if any of the following is discovered:

- The fix requires changing a public tool schema, method signature, or CLI argument contract.
- The fix weakens any existing rejection path (stale digest, ambiguous match, symlink, root
  escape, oversized file, etc.).
- A valid-UTF-8 Round 1 probe regresses, including under `LC_ALL=C`.
- The scorecard drops below 6/12 or any hard gate fails for a reason other than the correction
  honestly exposing a previously hidden problem.
- The only way to reject invalid UTF-8 is through a generic abstraction, new dependency, or
  non-local refactor rather than the explicit checks above.
- Any rejection path is found to mutate the target file or leave a temporary file behind.
- `search_text` fail-closed validation proves too disruptive to existing valid-UTF-8 cases;
  in that event, document the silent-skip behavior as a latent invariant-17 gap instead.

Only after this correction closes should work begin on `docs/P4_COMPOUND_EDIT_PLAN.md`.
