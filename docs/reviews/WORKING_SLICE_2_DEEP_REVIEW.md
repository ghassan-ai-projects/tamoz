# Working slice 2 deep review

Review target: the opt-in reviewed coding change loop built on working slice 1.

## Decision

Accepted for one bounded existing-file repair followed by user-configured verification.
Read-only operation remains the default. This slice is not accepted as crash-durable, as an
arbitrary coding agent, or as Tamoz v0.1.

## Findings and corrections

| Severity | Finding | Correction |
|---|---|---|
| Critical | A single static plan cannot know exact patch text before reading the workspace. It would force the model to guess action arguments. | Change mode now has separately reviewed discovery and action plans. Only read tools exist in discovery; its observations are explicit evidence for action planning and review. |
| Critical | The action planner cannot reliably calculate a file digest from model-visible text. | `read_file` now emits a framework-computed SHA-256 digest beside content. The patch contract requires that digest. |
| Critical | Letting the model emit shell text would turn verification into arbitrary execution. | Checks are user-configured name-to-argv mappings. The model supplies only a validated name; execution uses `Open3.popen3(*argv)` with no shell. |
| High | Approval could become stale if a file changed between preview and execution. | Preview and execution independently resolve the target, recompute its digest, and require one exact `before` occurrence. Stale or ambiguous patches stop. |
| High | An approved relative path could resolve through a symlink to a different target. | Mutation rejects every path whose lexical and canonical forms differ, in addition to the existing root confinement. |
| High | A patch could execute before the runtime discovered that no observation budget remained for its receipt. | Runtime reserves the maximum bounded effect output before requesting approval or dispatching the effect. |
| High | A hanging or noisy configured check could stall the agent or exhaust memory. | Checks have a bounded timeout, process-group TERM/KILL, concurrent pipe draining, UTF-8 scrubbing, and a shared 64 KiB output cap. |
| Medium | Setting target permissions on a temporary file before writing exposed partial replacement content under permissive modes. | Temporary files remain private while written and fsynced; original permission bits are applied only immediately before the second fsync and atomic rename. |
| Medium | Replacing a short region with a large value could grow the file beyond the read/tool budget. | The complete candidate file must remain within the 64 KiB file bound. |
| Medium | Duplicate CLI check names silently selected the last command. | Duplicate names are usage errors. |

## System review

### Correctness

- Both discovery and action plans pass deterministic structural review and isolated semantic
  review before their tools run.
- Action planning receives exact discovery observations, including the framework-computed
  file digest.
- The patch requires a current digest and one exact match; execution returns before/after
  digests.
- A real Ruby subprocess evaluation proves the patched program's behavior, not only its text.
- Non-zero, signaled, and timed-out checks remain explicit evidence; they are never promoted
  to success by the tool layer.

### Security

- Changes require explicit construction/CLI opt-in and per-effect approval. A missing,
  denied, or EOF approval fails closed.
- The approval preview is generated from the same immutable arguments later revalidated at
  execution.
- The model cannot create command text, add arguments, choose environment assignments, use
  pipes/redirections, or invoke an unconfigured check.
- Patch targets are existing, bounded UTF-8 files under the canonical workspace root with no
  symlink component.
- Read-only behavior and its three-tool surface are unchanged when change mode is disabled.

Residual: configured checks are trusted user capabilities and inherit the Tamoz process
environment. They can mutate the workspace or print secrets. The exact argv is displayed and
approved, but v0.1 still needs capability-scoped environment and egress policy.

### Reliability

Atomic replace prevents partial target content on an ordinary process failure. File and
directory fsync reduce loss after an OS crash. Permission bits are preserved. A stale digest
stops rather than rebasing the model's intended change.

There is no durable effect journal. A crash after rename but before the tool receipt reaches
the runtime loses the recorded outcome, although retrying the same patch stops on digest
mismatch. The next slice must reconcile the before/after digests through SQLite rather than
treating that mismatch as an ordinary failure.

### Observability

Events identify discovery versus action phase and include plan drafts, both review layers,
approval request/grant/denial, tool lifecycle, and final verification. Approval requests
carry the exact diff or configured argv. JSON streams contain task data and must remain
protected.

### Maintainability

Tool validation, preview, and execution share one normalized argument contract. Command
configuration is a simple immutable Hash of argv arrays. No shell parser, general diff
engine, subprocess framework, or persistence abstraction was introduced.

The exact-substitution patch is intentionally narrow. Supporting file creation, deletion,
multi-hunk edits, or transactional multi-file changes requires a new reviewed contract, not
flags on this one.

## Evidence

- end-to-end broken-project repair with a real Ruby acceptance subprocess;
- denied approval leaves the target byte-for-byte unchanged;
- stale digest, ambiguous match, symlink target, oversized/binary content, and root escape
  tests;
- atomic replacement content, digest receipt, and permission preservation tests;
- named-command validation, no extra model arguments, output capture, and timeout
  termination tests;
- existing read-only plan/review/action ordering and rejection tests remain green;
- the complete repository design, syntax, packaging, and test gate is required before commit.

## Next slice gate

The next largest gain is SQLite-backed session and effect recovery around the working change
loop. Do not add MCP, scheduling, memory, or generic shell execution before a killed process
can reconcile an approved patch and resume its verification check without guessing.
