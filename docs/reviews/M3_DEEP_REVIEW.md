# M3 deep review

Review target: uncommitted M3 durable-runtime implementation based on `2472cfe`.

Decision: accepted for the v0.1 alpha foundation after corrections below. This is not a
multi-host or exactly-once-effects claim.

## Method

The review traced each mutation from public API through request ownership, lease validation,
transaction boundary, row constraints, codec verification, recovery, and terminal state.
It separately attacked crash ambiguity, stale ownership, duplicate delivery, effect receipt
races, persisted identifier revival, deletion, file publication, and M2 regression.

The reviewer inspected the complete diff, searched for unsafe deserialization and
unvalidated symbol revival, ran focused fault tests, then ran the complete CI gate.

## Findings closed

| Severity | Finding | Root cause | Correction |
|---|---|---|---|
| Critical | A storage/lease failure could be converted into an ordinary node error. | The worker result algebra had no fatal coordination outcome. | Added `FatalRuntimeFailure` and `TaskResult::Fatal`; the executor re-raises it outside node failure handling. |
| Critical | A successful worker result existed only in process memory until the barrier. | M2 could safely assume process continuity. | Persist each stable activation outcome before coordinator delivery and reuse it after restart. |
| Critical | An effect token could have been started after its graph lease was fenced. | Token ownership and graph ownership had been conflated. | `start` revalidates the current graph fence and deadline; only exact-token completion intentionally survives lease loss. |
| Critical | A newer effect attempt could erase an older truthful late receipt. | One mutable attempt slot was insufficient. | Added immutable effect identity plus append-only attempt rows and reconciliation flags. |
| Critical | Whole-thread purge failed despite deleting the complete tree. | Immediate `RESTRICT` constraints fired before the containing cascade completed. | Use deferred `NO ACTION` for retention links, preserving prune protection and atomic purge. |
| High | Durable public graph methods could bypass the request inbox. | Adapter compatibility did not imply mutation-path authority. | Durable adapters reject public mutation; `DurableRunner` is mandatory. |
| High | Redirect and fork were accepted by the inbox but not executable. | The first request slice implemented only turn/resume/retry/continue. | Implemented historical fork and pinned redirect target/generation with effect-terminal gating. |
| High | Empty-frontier fork left its request running. | Executor returns immediately for an empty frontier. | Commit the completed fork checkpoint and terminal request transition atomically. |
| High | A succeeded effect head could be overwritten by a late conflicting current-attempt receipt. | Completion updated the head without considering a prior human resolution. | Keep succeeded heads immutable and mark conflicts for reconciliation while retaining the receipt. |
| High | Deletion reports had no independent corruption check. | Only final purge receipts had a report digest. | Added a domain-separated tombstone-report digest and verify before materialization or purge. |
| High | Backup timeout applied only to busy waits. | Progressing pages did not recheck the total deadline. | Check the monotonic total deadline before every backup step. |
| High | A persisted deletion status was converted with unrestricted `to_sym`. | Internal JSON had been treated as trusted. | Validate against fixed strings and return fixed symbols only. |
| High | Adding native SQLite removed the portable lock platform. | Bundler resolved only the current machine platform. | Lock both `ruby` and `arm64-darwin-25`, including both checksums. |
| Medium | Sensitive Store values could be written without an explicit encryption boundary. | The Store API exposed a flag before defining key ownership. | Require a named encrypt/decrypt codec with external key ownership; otherwise fail closed. |
| Medium | A raw filesystem copy could be mistaken for a valid WAL backup. | File-level copying ignores uncheckpointed WAL state. | Use `SQLite3::Backup`, verify integrity/schema, then publish a new `0600` file atomically. |
| Medium | Thread deletion risked erasing unrelated application memory. | Graph thread identity and generic Store namespace are different ownership domains. | Thread purge never deletes Store keys. |

## Five Whys: successful task loss

1. Why could restart execute a successful sibling again? Its outcome was only in the worker
   result queue.
2. Why was the queue authoritative? M2 had no process-crash durability boundary.
3. Why not persist only at the barrier? A crash can occur after one sibling succeeds while
   another pauses or fails.
4. Why is node name insufficient for reuse? Parallel activations, attempts, bases, and
   executions can share a node.
5. Why does the fix work? The row is keyed by thread, namespace, execution, and stable task
   identity, binds attempt/base/path/outcome digest, and is consumed only by the exact
   checkpoint commit.

Evidence: the subprocess is killed after `checkpoint.append_writes` commits. Recovery
finishes with one execution and the external node-call marker contains exactly one entry.

## Five Whys: external-effect ambiguity

1. Why can Tamoz not promise exactly-once effects? A process can die between target success
   and local receipt commit.
2. Why does a retry not solve it? An unsafe target may execute twice.
3. Why does one attempt row not solve it? A later retry can replace the token while the old
   target returns a truthful receipt.
4. Why is lease validation wrong for completion? Takeover must not destroy the receipt sink.
5. Why is the implemented boundary safe? Start requires the live graph fence; completion
   requires the exact attempt token; every attempt remains append-only; ambiguity becomes
   `unknown` or `reconcile`, never a hidden automatic retry.

## Evidence

Final local gate:

- design validation: 22 documents, 55 invariants, 40 ADRs;
- CI: all Ruby syntax and packaging checks;
- test suite: recorded by the final clean gate for this review;
- crash evidence: `SIGKILL` on both sides of checkpoint commit and after task-write commit;
- concurrency evidence: two independent Ruby processes race for one namespace and exactly
  one acquires fence 1;
- transaction evidence: every observed Store SQL/commit hook reopens as the complete old or
  complete new state, with integrity intact.

## Residual risks and explicit non-claims

- CI must still reproduce the gate on Ruby 3.4 and Ruby 4.0; the local review used Ruby
  3.3.11 and SQLite 3.53.2.
- The process-kill suite targets the highest-risk checkpoint and task-result boundaries.
  Expanding the same harness to every named SQL hook remains valuable platform evidence.
- Long soak and performance targets require a stable release runner and named storage
  hardware; correctness settings were not weakened to manufacture latency numbers.
- SQLite coordinates processes on one host. It is not a distributed consensus backend.
- Exactly-once requests mean one Tamoz execution binding, not exactly-once target I/O.
- The large persistence classes should be split by capability before the API leaves alpha;
  this is a maintainability improvement, not a correctness bypass.

These residuals are visible because hiding missing evidence would be worse than narrowing
the claim. None changes the enforced v0.1 alpha safety boundary.
