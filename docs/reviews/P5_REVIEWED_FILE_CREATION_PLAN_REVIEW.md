# P5 reviewed file creation plan review

Review target: `docs/P5_REVIEWED_FILE_CREATION_PLAN.md` (amended revision)

## Decision

**Accept with corrections.**

All critical and high findings from the previous review have been addressed. The directory-symlink TOCTOU is now honestly scoped with a corrected race analysis, the audit counters include `create_file`, the preview claim is realistic, the read-only rejection test is added, and the success-path cleanup is handled. One remaining correction is required before implementation: the scorecard baseline assumption must be reconciled with the current handover-plan baseline. A few minor pseudocode notes should also be cleaned up but do not block the design.

## Findings from previous review — status

| Severity | Finding | Status | Evidence in amended plan |
|---|---|---|---|
| **Critical** | Directory-symlink TOCTOU breaks path containment. | **Addressed by honest scoping.** | §3 "What `File.link` does *not* guarantee" states that `link(2)` follows symlinks in directory components and that a parent replaced by a symlink after revalidation can escape the workspace. The race table row for this case no longer claims containment. §9 stop/redesign criteria add "the publication primitive cannot prove that directory-symlink races are contained." §10 residual risks repeat the honest contract. The plan also adds a `revalidate_parent!(parent)` call immediately before `link` to narrow the window. |
| **High** | `AgentRunAudit` mutation metrics ignore `create_file`. | **Fixed.** | §6 introduces `MUTATION_TOOLS = %w[apply_patch create_file].freeze` and a `mutation_count(events)` helper, then sets `"mutations" => mutation_count(events)` and `"unnecessary_mutations" => execution.mutation_needed ? 0 : mutation_count(events)`. |
| **High** | Preview/execution "byte-identical" claim is false for large content. | **Fixed.** | §5 Preview now says only path/mode/size/sha256 always match and that displayed content may be truncated. §8 Test matrix replaces the byte-identity claim with "Preview path/mode/size/sha256 match the executed result; truncation is deterministic and reproducible; the full sha256 is present even when content is truncated." |
| Medium | Error messages diverge from existing tools without justification. | **Addressed by documentation.** | §2 Validation order explicitly notes that phrasing follows existing `Toolbox` conventions "where possible" and calls out deliberate divergences (e.g. `parent path must not contain symlinks` vs. `patch path must not contain symlinks`) with a user-facing rationale that the failure concerns the parent directory, not the target file. |
| Medium | `AgentSmokeCorpus::CASE_DEFINITIONS` metadata not updated. | **Fixed.** | §7 lists updates to `allowed`, `prohibited`, `done`, `purpose`, and `tags` in `CASE_DEFINITIONS` for `agent.new-file-need`, matching the proposed case-JSON changes. |
| Medium | No read-only runtime rejection test. | **Fixed.** | §8 Unit tests add: "Read-only runtime (`allow_changes: false`) does not expose `create_file` and rejects it as an unknown tool." |
| Medium | Success-path temporary-file unlink failure not handled. | **Fixed.** | §3 pseudocode wraps `temp&.close!` in the `ensure` block inside `rescue SystemCallError`, swallowing cleanup failures after the effect has committed. This matches the existing `fsync_directory` failure-handling pattern. |

## Remaining correction required before implementation

| Severity | Finding | Correction required |
|---|---|---|
| **Medium** | **Scorecard baseline assumption is still unverified and inconsistent with the handover plan.** | The amended plan still claims the scorecard rises "from 7/12 to 8/12." The current `docs/PROJECT_HANDOVER_PLAN.md` §1 states the baseline is 6/12 task successes and §6 P4 required proof is "at least 7/12." Before implementation, run `rbenv exec bundle exec tamoz-eval scorecard agent-smoke` on the current baseline and record the actual number in `docs/P5_REVIEWED_FILE_CREATION_PLAN.md`. Update either the plan or the handover tracker so the two documents agree. |

## Minor notes (recommended but non-blocking)

1. **Pseudocode initialization.** In §3, the `atomic_create` pseudocode uses `published = true` only after `File.link` succeeds. If an exception is raised before that assignment, the `ensure` block evaluates `if published` and will raise `NameError`. Initialize `published = false` before the `begin` block.
2. **Mode type in pseudocode.** The schema defines `mode` as an octal string (e.g. `"0644"`), but the pseudocode calls `temp.chmod(mode)` directly. `File#chmod` requires an integer mode. State that `create_file` converts the normalized string to an integer with `mode.to_i(8)` before applying it.
3. **Message consistency.** While the documented divergences are acceptable, consider whether `path must name a file` can be aligned with the existing `resolve` message `path is not a file` without losing clarity. If the implementer prefers the new wording, keep the documented rationale.

## Detailed assessment

### 1. Atomic publication and containment

The amended plan correctly distinguishes three different guarantees:

- **No overwrite / no partial public file:** guaranteed by `File.link` to a fully-fsynced inode. This is correct.
- **Static symlink containment:** guaranteed by the `lexical.realpath` check in `validate_create_path!`.
- **Dynamic directory-symlink race:** explicitly acknowledged as a residual risk. The plan adds a pre-link `revalidate_parent!(parent)` step to narrow the window, but does not falsely claim it closes the race.

This is the honest contract the previous review demanded. The stop/redesign criteria in §9 now include the publication primitive's inability to prove containment, and the residual risks in §10 are accurate.

### 2. Validation and failure taxonomy

The validation order in §2 is sound: argument shape before filesystem access, cheap checks before expensive ones, content/digest/mode before parent state. The failure taxonomy in §4 correctly maps every validation and environment failure to a typed `ToolError`, preserving Invariant 17. The post-publication verification re-read is a useful backstop, and the plan honestly documents the extremely rare external-modification race as a residual risk.

### 3. Approval, audit, and runtime integration

- `approval_required?("create_file")` returns `true` (§5).
- `AgentRunAudit::EFFECT_TOOLS` is updated to include `create_file` (§6).
- `AgentRunAudit` mutation counters now include `create_file` completions in both `mutations` and `unnecessary_mutations` (§6).
- `Runtime#structural_issues` treats `create_file` as a mutation step and prevents it after the final configured check (§7).
- `action_signature` recursively canonicalizes the new tool's arguments without special casing (§7).

These integration points are coherent and do not weaken existing P3/P4 behavior.

### 4. Scorecard case

The rewrite of `run_new_file_need` in §7 is internally consistent: two plans (discovery + action), two reviews, an approval that always grants, a configured check, and an oracle that asserts exact file content. The `CASE_DEFINITIONS` updates and the case-JSON updates are mutually consistent. The only unresolved item is the numeric baseline.

### 5. Test matrix

The §8 test matrix now covers the key adversarial cases: concurrent creators, target appearing after validation, missing/changed parent, symlink parent, case-insensitive collision, mode preservation, process failure at each seam, and read-only runtime rejection. The directory-symlink TOCTOU is documented as a residual risk rather than claimed to be tested away, which matches the honest scoping.

## Residual risks

- **Directory-symlink TOCTOU:** acknowledged and scoped; not eliminated.
- **Directory `fsync` swallowing:** acknowledged; durability loss, not safety loss.
- **Orphaned temp files after crashes:** acknowledged; belongs to P6.
- **Case-insensitive collisions:** `File.exist?(lexical_target)` plus atomic `link` backstop is reasonable.
- **External post-link modification:** acknowledged; detected and reported.
- **UTF-8-only scope:** acknowledged; defers arbitrary binary creation.

## Implementation gate

Implementation may proceed **after** the following correction is made:

1. Verify the current `agent-smoke` scorecard baseline and reconcile the number between `docs/P5_REVIEWED_FILE_CREATION_PLAN.md` and `docs/PROJECT_HANDOVER_PLAN.md`.

Strongly recommended before coding:

- Initialize `published = false` in the §3 pseudocode.
- Document the `mode.to_i(8)` conversion in the publication algorithm.
