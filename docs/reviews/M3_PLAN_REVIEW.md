# M3 plan deep review

Review target: proposed `docs/M3_PLAN.md` on clean M2 commit `1fbf77d`

Date: 2026-07-30

Outcome: accepted for implementation after corrections. The review found four critical,
six high, and five medium design defects before code. All are resolved in the accepted
plan. Final M3 acceptance still requires a separate post-implementation deep review and
clean-revision evidence.

## Method

The review traced invariants 18–24 and 52–54 through the complete failure lifecycle:

- task success, interruption, failure, crash, retry, resume, fork, and lease takeover;
- request enqueue, FIFO claim, execution binding, redirect, recovery, and terminal commit;
- effect prepare, start, remote ambiguity, attempt supersession, late completion,
  reconciliation, tombstone, and purge;
- checkpoint encode, compatibility check, migration, corruption, history, and prune;
- connection checkout, writer contention, transaction retry, fork, backup, WAL, close, and
  early cursor termination;
- Store compare-and-set, sensitive values, capability honesty, and deletion ownership;
- public API paths that could bypass the inbox, fence, effect journal, or fatal-error
  boundary.

The plan was compared with the M2 implementation rather than only with design prose. The
review also inspected the installed `sqlite3` 2.9.5 API and the project's Ruby 3.3 runtime.
The official gem metadata confirms the current 2.9.5 release supports Ruby `>= 3.2`;
sqlite3-ruby documents that writable connections must not survive `fork`.

## Resolved findings

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| critical | Releasing/deleting the illustrative lease row could reset fencing to its initial value. | Ownership and monotonic generation were modeled as one disposable row. | Move owner/expiry/fence to the persistent namespace head; release clears ownership but never fence; every new ownership increments. |
| critical | An effect attempt token could have authorized starting remote I/O after graph lease loss. | The first draft treated the token as both start and completion authority. | `prepare` and `start` validate the current fence; `start` also validates deadline. Only exact truthful `complete` intentionally survives lease loss. |
| critical | A worker-side SQLite/lease/corruption failure could be wrapped as an ordinary `NodeError` and followed by a failed-node checkpoint. | M2's pool has only success/interrupt/failure/cancel paths because storage was coordinator-only. | Add a fatal pool result path; storage, codec, corruption, and lease failures abort runtime coordination and cannot become node/tool values. |
| critical | One mutable effect row would discard the truthful receipt of an old attempt after a newer token replaced it. | Effect identity and attempt history were conflated. | Use one immutable effect head plus append-only attempt and transition rows; old tokens update only their own receipt and may force reconciliation, never overwrite the head. |
| high | Public `invoke(... new_execution: true)` could bypass durable request deduplication. | Queue semantics were being retrofitted into an API that returns only `RunResult`. | Add a distinct `DurableRunner` and `RequestRecord`; public mutating Compiled methods reject durable adapters and private writer-bound methods are runner-only. |
| high | A generic adapter decoder could intern attacker-controlled node/channel symbols before checking graph compatibility. | Persistence was incorrectly assumed to own graph value revival. | `tamoz-graph` owns a definition-bound `CheckpointCodec`; compatibility and digest checks precede lookup of existing identifiers and no persisted value reaches `to_sym`. |
| high | Successful sibling outcomes existed only in the later pause/failure checkpoint, so a crash between task return and that checkpoint lost them. | M2 persistence happens only at coordinator barriers. | Each worker appends a complete normalized activation outcome before returning; checkpoint commit later consumes the selected activation set atomically. |
| high | Backward wall-clock movement could extend an old lease while a naive recovery path granted a new one. | “Use backend time” did not define discontinuity behavior. | Persist greatest accepted backend time; backward movement beyond tolerance fails acquisition/renew/write closed; forward jumps may lose availability but not fencing safety. |
| high | Caller-supplied `Context#effects` could replace the durable journal and evade receipt/unknown handling. | Dependency injection was treated as automatically safe. | Durable execution accepts only adapter-minted scoped Store/effect capabilities; arbitrary replacement journals are rejected. |
| high | Request idempotency did not initially bind operation and delivery mode. | Only the application payload was considered input. | Canonical request digest includes operation, delivery mode, and payload; same id with any semantic change conflicts. |
| medium | Busy handler, pool checkout, and outer retries could multiply into an unbounded effective wait. | Independent timeout knobs lacked one deadline. | All contention layers share one monotonic total deadline and bounded jitter budget. |
| medium | Rebuilding an inherited pool after `fork` could touch a locked inherited Ruby mutex or writable SQLite connection. | PID detection was mistaken for safe recovery. | Inherited adapters fail closed; callers close before fork and construct a new adapter in the child. |
| medium | Thread tombstoning claimed it could delete generic Store records. | Cross-thread Store namespaces have no intrinsic graph-thread ownership. | Remove that claim; M5b memory deletion uses explicit provenance and receipts. |
| medium | WAL growth had observability but no explicit bound/maintenance contract. | WAL was treated only as a concurrency mode. | Configure/observe auto-checkpointing and explicitly checkpoint during safe backup/integrity/close/soak boundaries. |
| medium | `sensitive: true` Store values could have become plaintext metadata only. | Sensitivity marking was specified without failure behavior when encryption is absent. | Require a named authenticated-encryption codec with an external key provider; otherwise reject the write. |

## Five Whys: late effect receipt loss

1. Why could a truthful late receipt disappear? A retry replaced the effect row's current
   attempt token.
2. Why could the old worker not complete? Compare-and-set correctly rejected a token that
   was no longer current.
3. Why was rejection insufficient? It prevented overwrite but also discarded evidence that
   the earlier remote call had actually succeeded.
4. Why does that matter after a “safe” retry? Read-only calls may differ over time,
   idempotency can be misconfigured, and reconciliation needs every observed target result.
5. Why did the first schema miss it? It modeled the effect decision head, not the append-only
   history of independently authorized attempts.

The accepted schema separates the immutable effect identity/head from attempt rows. A late
token can complete only its own row. If its receipt conflicts with a newer attempt, the head
requires reconciliation; no receipt or graph commit is fabricated.

## Five Whys: durable error misclassification

1. Why could disk-full become a node failure? The durable outcome append happens inside the
   worker after user code.
2. Why would the executor see it as a node failure? M2 maps every worker `StandardError` to
   `TaskResult::Failed`.
3. Why is that unsafe? The coordinator could append a failed-node checkpoint or later retry
   user code even though storage truth is unknown/unavailable.
4. Why did M2 not need a separate path? Its in-memory writes happened at the coordinator and
   could not fail with external durability errors.
5. Why must the path be structural? Error-message or class-name matching in the coordinator
   would be brittle and could be swallowed by user rescue.

M3 adds an explicit fatal task-result category for framework ownership, storage, codec, and
corruption failures. It is not a recoverable node/tool result.

## Accepted decisions

- SQLite remains suitable only if real multi-process kill/race evidence proves the plan.
- `synchronous=FULL` is the correctness default; performance may not weaken it silently.
- One adapter and its migrations own request/checkpoint atomicity.
- Namespace heads allocate checkpoint/request sequences and retain lease generations.
- Worker task writes may contend briefly but never hold a transaction during user code.
- Effect attempts are append-only; terminal truth outranks a simplified current-status row.
- Backward clock discontinuity sacrifices availability rather than guessing ownership.
- Direct durable mutation is deliberately narrower than the M2 in-memory convenience API.
- Store exact/prefix/CAS support ships in M3; semantic search, tenant memory policy, and
  thread-owned Store deletion do not.
- Schedule, MCP, stream, and memory-specific tables are excluded from migration 1.

## Residual risks to prove in implementation

- SQLite writer contention may make worker-side outcome persistence too expensive. Measure
  it under fan-out; if it misses budgets, batch only with an equally crash-safe completion
  channel, not by weakening sibling durability.
- Ruby cooperative cancellation cannot stop arbitrary code after lease loss. Its late graph
  write must fail; remote receipts still follow effect rules.
- Filesystem permission and crash guarantees vary by platform. Record exact environment and
  skip no correctness assertion silently.
- Online backup API availability is confirmed in the selected gem, but cleanup and
  destination publication still need kill tests.
- Clock recovery is intentionally operationally conservative. The offline reset procedure
  must prove there is no current owner and append audit evidence.
- Authenticated encryption key rotation is not a general key-management system. M3 needs the
  codec boundary and rejection behavior; production key lifecycle remains deployment-owned.

## Gate

Implementation is allowed because every question in `M3_PLAN.md` now has a defensible yes
at the contract level. Acceptance is not evidence of implementation correctness. M3 may be
committed only after:

- all conformance, model, kill, race, fault, backup, corruption, security, and soak gates
  pass;
- the complete M0–M3 suite passes on the supported Ruby matrix;
- package and dependency isolation remain correct;
- a post-implementation deep review closes every critical/high finding;
- public M3 evidence is reproduced from the exact clean revision under OS-denied network;
- `git diff --check` and the worktree are clean after the phase commit.
