# F07-SEC-01 — effect resolution is not bound to writer thread or namespace

| Field | Assessment |
|---|---|
| Functionality | F07 `tamoz-sqlite` effect journal and fenced writers; affected F22 session resolution and CF04 effect replay |
| Severity | **Critical**: a valid writer for one scope can mark another scope's unknown effect succeeded, creating false completion and weakening unresolved-effect retention |
| Confidence | **High**: direct source trace and a shared-adapter temporary SQLite probe reproduced it |
| Status | **Open, confirmed**; no implementation was made |
| Scanner signal | A thread-B lease/writer can resolve an unknown effect belonging to thread-A |
| Independent judgment | Confirmed. The normal CLI usually isolates each thread in its own database, but the public session/checkpointer API supports a shared adapter and does not enforce row ownership at resolution. |

## Finding and trigger

`Session#resolve_effect` acquires a writer for the caller-supplied `(thread, namespace)` and passes only `effect_key`, status, actor, and evidence to the journal (`gems/tamoz-agent-session/lib/tamoz/agent/session.rb:372-377,422-431`). The writer's lease is therefore B's lease when B calls the method. `EffectReconciler#resolve` looks up the effect globally by key and updates it with `WHERE effect_key = ? AND status = ?`; it never compares the row's `thread_id` or `namespace` with the active writer (`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_reconciler.rb:173-206`). The row lookup itself has no scope predicate (`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_journal_rows.rb:10-23`).

An authorized caller that can read A's key and operate a shared checkpointer can therefore call `resolve_effect(thread: "thread.b", effect_key: key_a, status: :succeeded, ...)`. `actor` is only validated as text and recorded in the transition; it is not a principal or an authorization check (`effect_reconciler.rb:180,208-222`). A key's digest may encode thread and namespace, but that is identity, not authorization: `EffectJournalKey.verify_identity!` exists and checks the lease scope (`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_journal_key.rb:138-179`), yet the resolve path never calls it. It is used during preparation instead (`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_preparation.rb:139-160`).

## Impact across the six audit lenses

| Lens | Finding |
|---|---|
| Correctness | B can change A's `unknown`, `reconcile`, or `failed` head and the transition log records a resolution attributed to the caller payload. A subsequent legitimate A prepare sees `succeeded` and selects `:return` (`effect_preparation.rb:150-154`). |
| Security/authority | A B lease is valid only for B's `(thread_id, namespace)`: lease validation loads that exact scope and checks its owner/fence (`gems/tamoz-sqlite/lib/tamoz/sqlite/lease_operations.rb:164-204`). The resolver accepts B's lease as sufficient for an A row. Tamoz is currently a single-operator, many-session product, so this is a scope/embedding boundary failure rather than a hosted tenant breach (`documentation/overview/product.md:18-24`). |
| Reliability/durability | The transaction and CAS are atomic, so the write is not partial. The protection is applied to the wrong scope. Marking A succeeded clears `requires_reconciliation` (`effect_reconciler.rb:193-204`), and removes A from the unresolved set used by tombstoning (`gems/tamoz-sqlite/lib/tamoz/sqlite/thread_tombstone.rb:159-170`). This can allow unresolved evidence to be treated as settled or later purged. |
| Observability/evidence | The append-only transition is useful evidence, but `actor`/payload do not establish target ownership. The returned record still says A, while the mutation came through B's writer, making audit interpretation misleading. |
| Scalability/resource bounds | No unbounded work is introduced. A shared adapter with multiple active session scopes makes the bad path reachable; per-thread CLI database paths reduce accidental exposure (`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:579-605`). |
| Maintenance/architecture | `CheckpointWriter` describes every mutating method as lease-guarded (`gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_writer.rb:3-7`), but the exposed effect resolver bypasses the row-scope part of that contract. Existing same-thread tests mask the boundary. |

## Probe and test gap

A temporary shared SQLite adapter with A and B namespaces reproduced: A's unsafe effect was driven to `unknown`; B's writer then called `effects.resolve(..., :succeeded, ...)`; the call succeeded and returned a record whose `thread_id` remained A. The full probe output and setup are logged at `/tmp/tamoz-agents/analyze_cross_thread_resolve.log`; no repository scratch was left.

The focused existing regression passed: `ruby -Itest test/sqlite_effect_journal_test.rb -n test_human_resolution_is_audited_and_succeeded_head_is_not_overwritten` — 1 run, 5 assertions, 0 failures. That test resolves on one thread only (`test/sqlite_effect_journal_test.rb:381-437`). The CLI test likewise uses one `thread` throughout (`test/agent_cli_test.rb:245-315`). No cross-thread or cross-namespace rejection test was found. The probe and focused test are bounded evidence, not a full-suite result.

## Five Whys

1. B changes A because the resolver's update predicate is only effect key plus current status.
2. The resolver receives no expected row scope and does not compare the active lease with the row.
3. The existing identity verifier is wired into prepare, not human resolve.
4. The implementation treats an opaque, globally unique effect key as enough to locate a row; key derivation does not confer caller authority.
5. The mutation contract and tests never required every effect mutation to bind `(thread_id, namespace)` to the active writer; the per-thread CLI database layout hid the shared-adapter case.

## Recommendation and disposition

Bind resolution at `EffectReconciler#resolve`, the existing mutation seam. Within the transaction, require the loaded row's `thread_id` and `namespace` to equal `@guard.lease.thread_id` and `@guard.lease.namespace`, and include both columns in the conditional `UPDATE` predicate so the ownership check is atomic. Raise the existing conflict type before appending a transition. This is the smallest fix that preserves the current human-resolution API and its ability to resolve an effect after the original graph attempt is unknown; it does not add a new authorization layer.

Add a shared-adapter test with A and B leases: B resolving A's unknown/reconcile/failed key must raise `CheckpointConflictError`, leave the head unchanged, and append no resolution transition; A must still resolve it. Add the same row-scope assertion to `reconcile` for all dispositions, because that sibling path also globally loads by key and can grant a B-fenced attempt (`effect_reconciler.rb:31-168`, `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_attempt_ledger.rb:44-77`). Treat that as the same seam's follow-up scope rather than assuming a resolve-only patch closes all cross-thread effect mutations.

Historical reviews discuss fencing, effect identity, and `not_applied` authorization (`docs/reviews/P6_DURABLE_SESSION_RECOVERY_PLAN_REVIEW.md:232-240,276-277`; `docs/reviews/M3_DEEP_REVIEW.md:22-30`) but do not identify this row-scope omission. The persistence contract explicitly binds effect identity and leases to thread/namespace (`docs/design-v0.1/PERSISTENCE_DESIGN.md:150-157,183-220`; `documentation/architecture/data-model.md:32,43-45`), so this is a contract violation, not a new product requirement.

**Disposition: critical, confirmed, open.** Blind spots are limited to the shared-adapter in-process path: no cross-process or hosted-auth deployment was tested, and no end-to-end graph unblock was claimed because `resolve` changes journal state rather than the session checkpoint directly.
