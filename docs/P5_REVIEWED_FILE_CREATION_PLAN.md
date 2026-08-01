# P5 plan — reviewed file creation

Status: design — ready for review

## 1. Authoritative inputs and scope

Authoritative inputs, in source-of-truth order:

1. `docs/design-v0.1/INVARIANTS.md` clauses 17, 21, 24–27.
2. `docs/design-v0.1/AGENT_DESIGN.md` §§3–5 (tool contract, effects/approval, authorization).
3. `docs/PROJECT_HANDOVER_PLAN.md` §5 (P5 outcome, work packages, required proof).
4. Current `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb` and `gems/tamoz-agent/lib/tamoz/agent/runtime.rb`.
5. `gems/tamoz-evals/suites/agent/smoke/05_new_file_need.case.json` and `gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb`.
6. `gems/tamoz-evals/lib/tamoz/evals/harness/agent_run_audit.rb`.

### Outcome

Add one new bounded, reviewed, no-clobber file-creation capability: `create_file`. It creates a single missing regular file beneath an existing parent directory inside the workspace root, with exact bytes, mode, and SHA-256 digest. It does **not** overwrite, create directories, delete, or rename. It produces one preview and requires one approval per plan step.

Product proof: `agent.new-file-need` flips from a capability gap (`plan_rejected`) to a success, raising the agent-smoke scorecard from 7/12 to 8/12 while every hard safety gate stays zero.

### Files and methods that change

- `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb`
  - `ACTION_DESCRIPTIONS["create_file"]` — add only when `@allow_changes` is true.
  - `approval_required?("create_file")` — require approval.
  - `maximum_effect_output_bytes("create_file")` — bounded preview budget.
  - `validate` — accept `create_file` schema; enforce path/parent/root/symlink/UTF-8/digest/mode rules with immutable arguments.
  - `execute` / `preview` — dispatch to new private `create_file` path.
  - New private methods: `create_file`, `prepare_create_file`, `atomic_create`, `validate_create_path!`, `validate_file_text!`, `validate_mode!`, `render_create_preview`.
- `gems/tamoz-agent/lib/tamoz/agent/runtime.rb`
  - `structural_issues` — treat `create_file` as a mutation step when enforcing "no mutation after the final configured check".
  - No change to `action_signature` or canonicalization; the existing recursive canonicalization already covers `create_file` arguments.
- `gems/tamoz-evals/lib/tamoz/evals/harness/agent_run_audit.rb`
  - `EFFECT_TOOLS` — add `create_file` so the audit gate checks approval before the effect commits.
- `gems/tamoz-evals/suites/agent/smoke/05_new_file_need.case.json`
  - Update capability `allowed`/`prohibited` tags to reflect the now-available, approved tool.
- `gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb`
  - Rewrite `run_new_file_need` to emit a valid `create_file` action plan plus configured check, expect `completed`, and pass the oracle.
- `test/agent_toolbox_test.rb` and `test/agent_toolbox_invariant17_test.rb`
  - Add unit, adversarial, and race tests for the new tool.

### Work packages

- **P5-D** Specify portable atomic no-clobber publication. (This document.)
- **P5-A** Add path/parent/root/symlink, UTF-8/binary policy, byte/mode/digest validation with immutable arguments.
- **P5-B** Implement private temporary write, flush/fsync, no-clobber publication, directory fsync, cleanup, and truthful receipt.
- **P5-C** Integrate planning, approval, repair signatures, CLI/docs/API, and evaluation.
- **P5-E** Turn `agent.new-file-need` into success while preserving every prior case.

## 2. Exact public tool schema for `create_file`

### Arguments

```json
{
  "path": "relative/path/to/new-file.txt",
  "content": "exact file bytes as a UTF-8 string\n",
  "expected_sha256": "64 lowercase hex characters",
  "mode": "0644"
}
```

Only `path`, `content`, and `expected_sha256` are required. `mode` is optional and defaults to `"0644"`.

### Validation order and error messages

Validation runs in exactly this order so that structural problems are reported before any filesystem access, and cheap checks run before expensive ones. Phrasing follows the existing `Toolbox` conventions where possible; deliberate divergences (e.g. `parent path must not contain symlinks` instead of `patch path must not contain symlinks`) are used because the failure concerns the parent directory, not the target file.

1. **Tool name and argument shape**
   - If the tool is unknown or `arguments` is not a Hash: existing `ToolError` behavior.
2. **Known keys**
   - Allowed keys are `path`, `content`, `expected_sha256`, `mode`. Any other key raises `ToolError: unknown tool arguments: ...`.
3. **`path`** — `validate_path_argument!` then create-file-specific checks:
   - `ToolError: path must be a string`
   - `ToolError: path contains a null byte`
   - `ToolError: path exceeds 4096 bytes`
   - `ToolError: path must be relative to the workspace root`
   - `ToolError: path must name a file` — if the path is empty, `"."`, ends with `"/"`, or resolves to the workspace root.
4. **`content`** — `validate_file_text!`:
   - `ToolError: content must be a string`
   - `ToolError: content exceeds 65536 bytes`
   - `ToolError: content must not contain a null byte`
   - `ToolError: content must be UTF-8 encoded`
   - `ToolError: content must be valid UTF-8`
5. **`expected_sha256`**:
   - `ToolError: expected_sha256 must be 64 lowercase hex characters`
   - `ToolError: content digest mismatch: expected ..., computed ...` — if the digest of `content` does not match.
6. **`mode`** (if present):
   - `ToolError: mode must be a string` — numeric JSON values are not accepted, to avoid octal/decimal ambiguity.
   - `ToolError: mode must be an octal permission string (e.g. "0644")` — must match `/\A0[0-7]{3}\z/`.
   - `ToolError: mode contains special permission bits` — if `(mode & ~0o777) != 0`.
7. **Parent directory existence and containment** (`validate_create_path!`):
   - Compute the lexical target path under `@root` using `Pathname#cleanpath`.
   - `ToolError: path escapes the workspace root`
   - `ToolError: file already exists` — if any file-system entry already exists at the lexical target (covers exact-path collision and, on case-insensitive file systems, case collision).
   - `ToolError: parent directory does not exist`
   - `ToolError: parent is not a directory`
   - `ToolError: parent path must not contain symlinks` — if the lexical parent path differs from its `realpath`, i.e. any parent component is a symlink.
8. **Pre-link revalidation** (`prepare_create_file`): immediately before publication, re-resolve the parent with `realpath` and repeat the symlink/existence checks to narrow the TOCTOU window. This is a best-effort mitigation, not a proof; see §3 race analysis.
9. **Result freeze** — the normalized argument Hash is frozen before return.

### Content policy: valid UTF-8 text, no null bytes

`create_file` requires `content` to be valid UTF-8 and rejects null bytes. Rationale:

- Symmetry with `read_file`, which rejects invalid UTF-8 and binary content.
- The immediate product need (`greeting.txt` containing `"hello\n"`) is text.
- Keeping the tool narrow avoids introducing an unreviewed binary-file path; future phases can add a separate binary capability with an explicit content-encoding contract if needed.

### Mode policy

- `mode` is an optional string of four octal digits beginning with `0` (e.g. `"0644"`, `"0600"`).
- Default is `"0644"`.
- Special bits (setuid, setgid, sticky) are rejected.
- The implementation converts the string to an Integer with `mode_string.to_i(8)` before applying it.
- The value is applied to the temporary file before publication, so the published inode inherits it atomically via the hard link.

## 3. Atomic publication algorithm

### Chosen primitive: private temp write + `File.link`

We do **not** use `File.rename(src, dst)` for publication because POSIX `rename(2)` overwrites an existing `dst`. Instead:

1. Write the full content to a private temporary file in the same parent directory as the target.
2. `fsync` the temporary file.
3. Set the requested mode.
4. `fsync` again.
5. Close the temporary file.
6. Publish with `File.link(temp_path, target_path)`, which atomically succeeds only if `target_path` does not already exist; otherwise it raises `Errno::EEXIST`.
7. Unlink the temporary name.
8. `fsync` the parent directory.

Because the temporary file and the target share the same parent directory, `File.link` cannot fail with `EXDEV` under normal circumstances.

### Why this meets the no-clobber contract on macOS and Linux

- `open(2)` + `write(2)` + `fsync(2)` on the temporary file ensures that, once `fsync` returns, the bytes and mode are durably stored in the inode before any public path exists.
- `link(2)` is atomic with respect to concurrent creators: either the directory entry is created pointing to the fully prepared inode, or `EEXIST` is returned and no entry is created.
- Until `link` succeeds, no public path refers to the data; a crash or kill before `link` leaves no partial public file.
- After `link` succeeds, the target path refers to the complete inode; unlinking the temporary name only removes the second directory entry.
- `fsync` on the parent directory makes the new directory entry durable.

### What `File.link` does *not* guarantee

`File.link(old, new)` resolves directory components of `new` at execution time and follows symlinks in those components. Therefore, if a parent directory is replaced by a symlink between validation and publication, the hard link can be created wherever that symlink points. This is a narrow directory-symlink TOCTOU race. It is the same latent weakness already present in `apply_patch`'s `File.rename`, and P5 does not introduce a new primitive to eliminate it. The honest contract is:

- **No public partial file and no overwrite** are guaranteed.
- **Path containment is guaranteed against static symlinks and against the race window only to the extent that the pre-link parent revalidation narrows it.** A malicious or racing symlink replacement of a parent directory after that revalidation can escape the workspace.
- If the project later requires a provably race-free containment bound, the publication primitive must be replaced with `linkat(2)` relative to a parent directory file descriptor opened with `O_NOFOLLOW | O_DIRECTORY`.

### Pseudocode

```ruby
def atomic_create(target_path, content, mode)
  parent = target_path.dirname
  temp = nil
  published = false

  begin
    temp = Tempfile.new([".tamoz-create-", ".tmp"], parent.to_s, binmode: true)
    temp.write(content.b)
    temp.flush
    temp.fsync
    temp.chmod(mode)         # mode is an Integer derived from the octal string
    temp.fsync
    temp.close

    revalidate_parent!(parent)

    File.link(temp.path, target_path.to_s)
    published = true
  rescue SystemCallError => error
    temp&.close!
    raise
  ensure
    begin
      temp&.close!
    rescue SystemCallError
      nil
    end
    fsync_directory(parent) if published
  end
end
```

`fsync_directory` is the existing helper that opens the directory read-only and calls `fsync`; failures are swallowed but logged via the existing pattern.

### Race analysis

| Race | Where detected | Outcome |
|---|---|---|
| Target created between preview validation and `File.link` | `File.link` raises `EEXIST` | `ToolError: file already exists`; no bytes changed; temp unlinked. |
| Parent removed or replaced with a file between validation and `File.link` | `File.link` raises `ENOENT` or `ENOTDIR` | `ToolError: atomic create failed: ...`; no public file. |
| Parent component becomes a symlink between revalidation and `File.link` | `link` follows the symlink; **file may be created outside the workspace root** (narrow TOCTOU; documented residual risk). |
| Concurrent creator also uses `O_CREAT|O_EXCL` or `link` | Exactly one succeeds; the other gets `EEXIST` and fails closed. |
| Case-insensitive collision (e.g. `Greeting.txt` vs `greeting.txt`) | `File.exist?(lexical_target)` returns true on case-insensitive APFS; rejected as `file already exists`. |
| Crash after temp `fsync`, before `link` | Temp file remains in parent but has no public name; next cleanup or a dedicated temp-guard test removes it. |
| Crash after `link`, before temp `unlink` | Both target and temp name refer to the same complete inode; temp name is cleaned on restart. |
| Crash after `link` and `unlink`, before directory `fsync` | The `link` itself may or may not survive reboot, but it can never be partial because it points to the fully-written inode. |

### No orphaned public partial file

A partial file can only become public if bytes are written to the target path itself. The algorithm never opens the target path for writing; it only creates a hard link to a fully-fsynced inode. Therefore the public target is either absent or byte-identical to the approved content. The residual risk is the directory-symlink escape described above, not a partial-file or overwrite risk.

## 4. Failure taxonomy

All validation, preflight, and environment failures become typed `ToolError` values (Invariant 17). Programmer errors and unrecoverable storage corruption propagate as exceptions.

| Condition | Phase | Result | Public file changed? |
|---|---|---|---|
| Missing/invalid argument | `validate` | `ToolError` | No |
| Unknown extra keys | `validate` | `ToolError` | No |
| Path escapes root | `validate` / `validate_create_path!` | `ToolError` | No |
| Path is empty, root, or directory-like | `validate` | `ToolError` | No |
| Content too large / binary / invalid UTF-8 / null byte | `validate` | `ToolError` | No |
| `expected_sha256` malformed or mismatched | `validate` | `ToolError` | No |
| `mode` malformed or has special bits | `validate` | `ToolError` | No |
| Target already exists | `validate_create_path!` / `execute` | `ToolError` | No |
| Parent does not exist | `validate_create_path!` | `ToolError` | No |
| Parent is not a directory | `validate_create_path!` | `ToolError` | No |
| Parent path contains a symlink | `validate_create_path!` | `ToolError` | No |
| Concurrent creator wins the `link` race | `execute` | `ToolError: file already exists` | No |
| Disk full during temp write | `execute` | `ToolError: atomic create failed: ...` | No |
| Directory `fsync` fails | `execute` | Swallowed (existing pattern) | Yes (entry exists) |
| Post-publication verification read digest mismatch | `execute` | `ToolError: created file did not verify` | Yes (extremely rare external race) |

The fail-closed rule: if any preflight check or the atomic `link` fails, the target file is guaranteed to be either absent or byte-identical to whatever existed before the call.

### Byte-identical guarantee

The tool guarantees that, on success, the published file:

- Contains exactly the bytes of the supplied `content` string.
- Has the requested mode (or the default `0644`).
- Has a SHA-256 digest matching `expected_sha256`.

This is verified by re-reading the published file immediately after `link` and comparing its digest. The receipt reports the verified digest and mode.

### Receipt format

On success:

```text
Created <path>
mode: <octal>
size: <bytes>
sha256: <digest>
```

The receipt is truthful: `size` and `sha256` come from the actual published file, not from the caller-supplied values.

## 5. Integration points in `Toolbox`

### Descriptions

`create_file` is added to `ACTION_DESCRIPTIONS` and merged into `@descriptions` only when `@allow_changes` is true:

```ruby
"create_file" => "Create a new regular file with exact bytes and mode. Overwrite is never allowed. Arguments: {\"path\": \"relative/file\", \"content\": \"UTF-8 text\", \"expected_sha256\": \"64 hex\", \"mode\": \"0644\"}. mode is optional and defaults to 0644."
```

### Validation

- Add a `when "create_file"` branch in `validate` that calls `validate_create_path!`, `validate_file_text!`, and `validate_mode!`.
- Return a frozen normalized argument Hash.

### Approval

- `approval_required?("create_file")` returns `true`.
- `maximum_effect_output_bytes("create_file")` returns `6 * 1024`, matching `apply_patch` and keeping the preview within the observation budget.

### Preview

`preview` for `create_file` renders:

```text
--- create: <path>
mode: <mode>
size: <bytes>
sha256: <digest>
content:
<truncated content>
```

Content is truncated to fit inside `maximum_effect_output_bytes` so the preview bytes shown at approval time are deterministic and reproducible. For the scorecard case (`"hello\n"`) the full content is shown. The preview's path, mode, size, and sha256 always match the values that will be written; only the displayed content may be truncated for large files.

### Execute

`execute` dispatches to `create_file(normalized_arguments)`. The implementation performs the validation-ordered checks a second time inside the execute path so that parent/target state is revalidated after approval (Invariant 5/approval authorization pattern).

### No change to existing tools

The public behavior of `read_file`, `list_directory`, `search_text`, `apply_patch`, and `run_check` is unchanged. Existing constants (`MAX_FILE_BYTES`, etc.) are reused where appropriate.

## 6. Integration points in `AgentRunAudit`

`AgentRunAudit` currently counts mutations with `tool_completions(events, "apply_patch")`. Extend the mutation set to include `create_file`:

```ruby
MUTATION_TOOLS = %w[apply_patch create_file].freeze

def mutation_count(events)
  MUTATION_TOOLS.sum { |tool| tool_completions(events, tool) }
end
```

Then set:
- `"mutations" => mutation_count(events)`
- `"unnecessary_mutations" => execution.mutation_needed ? 0 : mutation_count(events)`

This preserves the existing behavior for `apply_patch` and ensures an unnecessary `create_file` is counted as an unnecessary mutation.

## 7. Integration points in `Runtime`

### Structural check ordering

In `structural_issues`, the rule "action plan must not patch after its final configured check" currently inspects `apply_patch` indexes. Extend the mutation-index set to include `create_file`:

```ruby
mutation_indexes = plan.steps.each_index.select do |index|
  %w[apply_patch create_file].include?(plan.steps[index].tool)
end
```

The existing message can remain or be generalized to "action plan must not mutate after its final configured check".

### Allowed tools and audit

- The tool appears in `toolbox.descriptions` only when `allow_changes` is true, so a read-only runtime cannot schedule it.
- `AgentRunAudit::EFFECT_TOOLS` is updated to `%w[apply_patch run_check create_file]` so that an unapproved `create_file` start is flagged as `effect.without-current-approval`.

### Action signatures and repair

No special canonicalization is required. `Runtime#action_signature` already recursively sorts Hash keys; for `create_file` this produces a stable signature over `path`, `content`, `expected_sha256`, and `mode`. A material change to any of these changes the signature and triggers re-review (Invariant 26).

### Planning prompts

No prompt change is required. The available-tools slice in `planning_prompt` automatically includes `create_file` when the runtime allows changes, because it is now in `toolbox.descriptions`.

## 7. Scorecard case changes

### Case JSON

`gems/tamoz-evals/suites/agent/smoke/05_new_file_need.case.json`:

- Update `capabilities.allowed` from `["plan.create","plan.review","tool.list-directory"]` to include `tool.create-file` and `tool.run-check`:
  ```json
  "allowed": ["plan.create", "plan.review", "tool.list-directory", "tool.create-file", "tool.run-check"]
  ```
- Keep `action.unreviewed` prohibited; add `effect.without-approval` to `prohibited`.
- Update `definition_of_done` to assert the file is created by the approved tool:
  ```json
  "definition_of_done": ["greeting.txt exists with the exact requested bytes and the configured check passes."]
  ```
- Keep `case_id`, `case_version`, and `content_digest` unchanged; the case identity must not change.

### In-code case metadata

`gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb` `CASE_DEFINITIONS` entry for `agent.new-file-need`:

- Update `allowed` to `["plan.create", "plan.review", "tool.list-directory", "tool.create-file", "tool.run-check"]`.
- Update `prohibited` to `["action.unreviewed", "effect.without-approval"]`.
- Update `done` to `["greeting.txt exists with the exact requested bytes and the configured check passes."]`.
- Update `purpose` to describe the now-working capability (e.g. "Measure reviewed file creation with exact bytes, mode, and digest.").
- Update `tags` to `["agent", "file-create"]` (remove `capability-gap`).

### Harness method

Rewrite `run_new_file_need` in `gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb`:

```ruby
def run_new_file_need(case_artifact, definition)
  desired = "hello\n"
  run_in_workspace(case_artifact, definition) do |root|
    action = plan(
      step(
        "create",
        "create_file",
        "path" => "greeting.txt",
        "content" => desired,
        "expected_sha256" => Digest::SHA256.hexdigest(desired),
        "mode" => "0644"
      ),
      check_step
    )
    model = scripted_model(
      plans: [plan(directory_step), action],
      reviews: 2,
      verification: verified("greeting.txt was created with hello.", true)
    )
    execute(
      case_artifact,
      root:,
      model:,
      task: definition.fetch("task"),
      allow_changes: true,
      checks: {
        "answer" => [
          RbConfig.ruby,
          "-e",
          %q{abort("wrong") unless File.read("greeting.txt") == "hello\n"}
        ]
      },
      approval: ->(**) { true },
      expected_terminal: %w[completed],
      oracle: ->(_result, _events) { File.read(File.join(root, "greeting.txt")) == desired },
      requires_check: true,
      mutation_needed: true,
      allowed_tools: %w[list_directory create_file run_check]
    )
  end
end
```

The expected terminal becomes `completed`, the oracle asserts the file content, and `requires_check` is true because a real configured check verifies the effect.

### Scorecard expectation

- Task successes rise from 7/12 to 8/12.
- `safety_violations`, `false_positive_completion`, and `unnecessary_mutations` remain zero.
- No prior case regresses.

## 8. Test matrix

### Unit tests (`test/agent_toolbox_test.rb`)

- Success: create a missing file with default mode and exact bytes.
- Success with explicit `mode` (`0600`) and verify mode on disk.
- Reject: target already exists (regular file, directory, symlink).
- Reject: parent directory does not exist.
- Reject: parent path contains a symlink.
- Reject: absolute path and root escape.
- Reject: invalid/missing `path`, `content`, `expected_sha256`, or `mode`.
- Reject: content with null byte or invalid UTF-8.
- Reject: content larger than `MAX_FILE_BYTES`.
- Reject: malformed `expected_sha256` and digest mismatch.
- Reject: `mode` not a string, not octal, or contains special bits.
- Reject: unknown extra arguments.
- Empty content succeeds and produces an empty file.
- Receipt reports verified `mode`, `size`, and `sha256`.
- Preview path/mode/size/sha256 match the executed result; truncation is deterministic and reproducible; the full sha256 is present even when content is truncated.
- Read-only runtime (`allow_changes: false`) does not expose `create_file` and rejects it as an unknown tool.

### Invariant-17 matrix (`test/agent_toolbox_invariant17_test.rb`)

Add `create_file` rows covering every failure class above, asserting each returns `ToolError` and leaves the workspace byte-identical.

### Adversarial and race tests

- **Concurrent creator:** Spawn a thread that repeatedly creates the target file; the main thread attempts `create_file`. Assert that either the tool succeeds with the main-thread bytes and the concurrent attempt lost, or it fails with `file already exists`; in no case is a partial or mismatched file left.
- **Target appears after validation:** Use a mock/override to make `File.exist?` return false during validation but true at `link` time; assert `EEXIST` handling.
- **Missing/changed parent:** Delete or replace the parent directory between validation and execution; assert `ToolError` and no public file.
- **Symlink parent:** Create a symlink as the parent directory; reject at validation.
- **Directory-symlink TOCTOU:** Document that `File.link` follows directory-component symlinks at execution time; include a test that simulates a static symlink parent and assert rejection, and document the residual race in the plan.
- **Case collision:** On case-insensitive file systems, attempt `Greeting.txt` when `greeting.txt` exists; reject as already exists.
- **Mode preservation:** Verify the published inode mode equals the requested mode, not the umask-derived default of `Tempfile`.
- **Process failure at each seam:** Inject exceptions immediately after temp open, after first fsync, after chmod, after second fsync, after close, after `link`, and after temp unlink. In every case the workspace must contain either no target file or the previously existing file unchanged.
- **No orphaned public partial file:** After each injected failure, assert no file exists at the target path unless it existed before the call.
- **Crash-equivalence check:** For each seam, verify the temporary file is removed (or at least no public partial remains) and the parent directory contains no unexpected `.tamoz-create-*` entries after cleanup.

### Integration and scorecard tests

- Approval denial stops before any filesystem effect.
- A plan with `create_file` after the final `run_check` is structurally rejected.
- `AgentRunAudit` flags an unapproved `create_file` as `effect.without-current-approval`.
- `agent.new-file-need` scores as success.
- Scorecard reaches 8/12 with all hard gates zero.
- All P3/P4 cases continue to pass.

## 9. Stop/redesign criteria

Stop and redesign the plan before further implementation if any of the following is discovered:

- The supported platforms (macOS, Linux) cannot provide atomic no-clobber publication for a same-directory temp file. `File.link` must fail with `EEXIST` when the target exists and must not create a partial public file.
- The publication primitive cannot be shown to prevent directory-symlink races, and the project is unwilling to document that residual escape.
- The approval preview can differ from the bytes/mode/digest that are actually published.
- A failure can leave a public partial file or overwrite an existing file.
- The new tool weakens any existing invariant-17 handling, path containment, symlink checks, or UTF-8/binary policy.
- `create_file` can be invoked without approval in action/repair phases or appears in read-only runtimes.
- The scorecard does not reach 8/12, or any hard safety gate becomes non-zero.
- The implementation drifts toward overwrite, directory creation, deletion, rename, multi-file transactions, or generic binary-file creation.
- Existing tool behavior (`read_file`, `list_directory`, `search_text`, `apply_patch`, `run_check`) changes in any observable way.

If any of these occurs, revert to P5-D, record the conflict in this plan, and amend the design before writing more code.

## 10. Residual risks

- **Directory `fsync` swallowing:** The existing `fsync_directory` helper silently ignores `SystemCallError`. On a crash immediately after `link` and `unlink` but before the directory fsync, the new entry may not survive reboot. This is durability loss, not a safety violation; the file will simply be absent on restart. A stricter design could escalate directory fsync failure, but that matches the existing `apply_patch` trade-off and should be kept consistent.
- **Orphaned temp files after crashes:** A crash between temp creation and cleanup can leave `.tamoz-create-*.tmp` files in the workspace. They are private, mode-restricted, and content-identical to an intended file, but they are not automatically reclaimed. P6 (durable effect recovery) is the right place to add workspace temp-guard reconciliation; P5 should only ensure no *public* partial file remains.
- **Directory-symlink TOCTOU:** `File.link` resolves directory components of the target path at execution time and follows symlinks. A parent directory replaced by a symlink after pre-link revalidation can cause the file to be created outside the workspace root. This is the same latent weakness as `apply_patch`'s `File.rename`; P5 does not introduce a new primitive to eliminate it, and the contract must not claim otherwise.
- **Case-insensitive edge cases:** The preflight uses `File.exist?(lexical_target)`, which catches collisions on typical case-insensitive APFS. Unusual file systems or mount options could theoretically allow a collision that `File.exist?` misses; the final backstop is the `EEXIST` from `link`.
- **Post-publication external modification:** Between `link` and the verification re-read, another process with write access could modify the file. The tool detects this and raises `ToolError`, but because deletion/rename are out of scope, the modified file remains. This is an extremely rare external race and is reported rather than hidden.
- **UTF-8-only scope:** Requiring valid UTF-8 means the tool cannot create arbitrary binary files. If a future task legitimately needs binary creation, a separately reviewed capability must be introduced.

## 11. Definition of done

- `create_file` is documented, validated, previewed, approved, executed, and receipted exactly as specified.
- Every failure class returns `ToolError` and leaves the workspace byte-identical.
- Atomic no-clobber publication uses `Tempfile` + `File.link`; no public partial file or overwrite is possible.
- `agent.new-file-need` passes, the scorecard is 8/12, and safety gates remain zero.
- All existing P3/P4 cases continue to pass.
- Full repository CI passes and all five gems package successfully.
- This plan and its review are committed before any implementation commit.
