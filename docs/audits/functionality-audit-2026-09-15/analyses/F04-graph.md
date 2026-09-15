# F04 `tamoz-graph` — the durability core holds: barriers are atomic and fenced, replay returns recorded outcomes, and record versions are refused before field reads

Row / queue / baseline (commit, date) / analyst / budget
- Row: F04, queue W1A, responsibility "Deterministic checkpointed graph execution and durability contracts".
- Baseline: `/Users/ghassan/my-projects/tamoz`, branch `audit-15-09`, HEAD `582ae55`, worktree clean apart from this audit package.
- Analyst: F04 independent analyst lane (read-only). Budget: ~55 min, hard cap 60.
- Surface: `gems/tamoz-graph` (47 files, 5527 lines) read as the contract owner; `gems/tamoz-sqlite/lib/tamoz/sqlite/**` read as THIS contract's implementer (row F07 owns it; no F07 claim is made).

## Scope and source map

Entry seam: `Tamoz.graph(name:, version:, &definition)` (`gems/tamoz-graph/lib/tamoz/graph.rb:25-29`) → `Builder.build` → `Definition` → `Compiler#compile` (`compiler.rb:26-36`) → `Compiled` (`compiled.rb:11-35`). Constants: `CHECKPOINT_PROTOCOL_VERSION = 1` (`graph.rb:8`), `Tamoz::Graph::VERSION = "0.1.0.alpha.1"` (`version.rb:5`), gemspec depends only on `tamoz-cancellation`, `tamoz-concurrency`, `tamoz-core`, `zeitwerk` (`tamoz-graph.gemspec:8-13`) — invariant 11 (no LLM in the gem) holds by dependency list.

Files read completely (line counts):
- `graph.rb` (29), `version.rb` (7), `tamoz-graph.gemspec`
- `checkpoint_codec.rb` (750) — the record codec, read end to end
- `executor.rb` (616) — the BSP run loop
- `compiled.rb` (250), `compiler.rb` (213), `builder.rb` (146), `definition.rb` (34)
- `checkpoint.rb` (29), `outcome.rb` (62), `frontier.rb` (64), `task.rb` (50), `interrupt.rb` (59), `marker.rb` (23), `snapshot.rb` (22), `run_result.rb` (16), `effect_record.rb` (41)
- `durable_runner.rb` (221), `durable_request_executor.rb` (184), `durable_request_execution.rb` (8), `writer_run_executor.rb` (196), `run_coordinator.rb` (122), `execution_support.rb` (130), `initial_checkpoint_builder.rb` (92), `fork_executor.rb` (170), `lifecycle_executor.rb` (147), `subgraph_runtime.rb` (190)
- `state_operations.rb` (168), `state_manager.rb` (135), `route_planner.rb` (155), `planner.rb` (60), `resume_answers.rb` (117), `request_staleness.rb` (47), `limits.rb` (43), `canonical.rb` (32), `identifier.rb` (62), `channel.rb` (99), `node_spec.rb` (84), `branch.rb` (46), `stream_emitter.rb` (56)
- `memory_checkpointer.rb` (251), `memory_checkpointer/writer.rb` (104), `reducers.rb` (97), `command.rb` (39), `send.rb` (21), `managed.rb` (8)
- Implementer side (cited, not claimed): `checkpoint_writer.rb` (162), `checkpoint_committer.rb` (249), `checkpoint_appender.rb` (183), `checkpoint_queries.rb`, `checkpoint_wire.rb`, `checkpoint_store.rb`, `lease.rb`, `lease_operations.rb`, `wire.rb`, `effect_journal_key.rb`.

Docs read: `documentation/design/graph.md`, `documentation/architecture/invariants.md` (clauses 16–22), `docs/design-v0.1/INVARIANTS.md:38-52`, `documentation/limitations.md:49-70`.

## Behavior path

1. **Compile.** `Compiler#validate!` (`compiler.rb:40-45`) enforces declarations, references, routing modes, and topology. `validate_topology!` (`compiler.rb:78-92`) requires a START edge, rejects unreachable nodes, and rejects nodes with no declared path to END (`trapped`). A declared cycle (`:left → :right → :left`) fails here — proven by `test/graph_definition_test.rb:72-91`. `descriptor` (`compiler.rb:193-208`) is canonically digested under `"tamoz.graph.definition\n"` (`compiler.rb:28`), producing `definition_digest`.
2. **Open the writer.** Public mutation is refused on a durable checkpointer: `ensure_ephemeral_public!` raises `ConfigurationError` unless `durable?` is false (`execution_support.rb:94-99`). Durable callers go through `DurableRunner` (`durable_runner.rb:13-19`), which itself requires `checkpointer.durable?` and `request_protocol_version == 1`. `Compiled#durable_runner = DurableRunner.new(self)` (`compiled.rb:148`).
3. **Claim.** `DurableRunner#run_next` opens a fenced writer (`durable_runner.rb:66-71`), claims the next request with the graph-owned staleness validator (`durable_runner.rb:72`, `212-216`), and dispatches by operation (`durable_request_executor.rb:30-42`).
4. **Initial checkpoint.** `InitialCheckpointBuilder#build` (`initial_checkpoint_builder.rb:18-42`) rejects an existing thread unless `new_execution: true` (`:48-53`), then appends `mode: :start` or `:turn` with `request_transition` in the same commit.
5. **BSP loop.** `Executor#run` (`executor.rb:13-168`): check context/writer fence (`:23-24`), plan tasks (`:33`), subtract already-pending task ids (`:35-36`), enforce task limits (`:37`), execute the remainder on the pool (`:38-45`), classify results (`:49-53`), and either fail (`:60-79`), pause (`:81-114`), or resolve and commit one next checkpoint (`:116-162`).
6. **Per-task durable writes.** Inside a worker, `Parent: `writer.append_writes(task:, outcome:)` (`executor.rb:234`) runs *before* the barrier, in its own transaction.
7. **Barrier commit.** `compiled.append_checkpoint` → `StateOperations#append_checkpoint` (`state_operations.rb:86-111`) → `writer.append_checkpoint` (`checkpoint_writer.rb:79-94`) → `CheckpointCommitter#append_checkpoint` (`checkpoint_committer.rb:24-167`), one fenced transaction.
8. **Replay.** On a resumed run the planner rebuilds the same activation ids (`planner.rb:13-30`), and `Executor` removes any task id already present in `current.pending` from `to_execute` (`executor.rb:35-36`) — the recorded outcome is used, the node is not invoked.

## Lens: correctness

Reviewed. Normal, failure, pause/resume, cancellation, and boundary paths preserve the stated contract.

- **Replay returns recorded results, it does not recompute.** `executor.rb:35-36` filters `to_execute = tasks.reject { |task| pending.key?(task.id) }`; `:56` merges `pending.merge(successes)`; `:116-120` re-derives the ordered outcomes from `all_successes` and validates them with `validate_outcome!` (`:315-324`). Attempt/task/base identity is validated before use, so a stale result cannot be silently accepted.
- **A cyclic *definition* cannot be committed.** `Compiler#validate_topology!` (`compiler.rb:88-91`) refuses. An intentional loop graph via a `branch` is bounded at runtime by `logical_step > limits.max_steps` → `RecursionLimitError` (`executor.rb:27-31`), proven by `test/graph_history_test.rb:150-155`.
- **Failure is typed and durable.** Errors become `NodeError` with graph/node/task/attempt and a stable class name (`executor.rb:304-313`, `:473-484`), and are committed as a `:failed` checkpoint with `retryable: false` (`:382-415`). Non-interactive interrupts become typed terminal failures rather than hanging (`:490-536`).
- **Determinism of commit order.** The pool may complete in any order but outcomes are committed in `tasks.sort_by(&:path)` order (`executor.rb:116`); the next frontier is sorted by path (`route_planner.rb:39-41`). `test/graph_determinism_property_test.rb` passes (2 runs / 480 assertions).
- **Reducer conflict detection.** Two writes to a reducer-less channel raise and name all writers (`state_manager.rb:91-96`).

## Lens: security and authority

Reviewed, with the row's boundary stated precisely.

- **`tamoz-graph` carries no profile authority.** `Checkpoint` (`checkpoint.rb`) and `Snapshot` (`snapshot.rb`) have no profile, authority, egress, or tool-grant field; `grep -rn "authority\|profile" gems/tamoz-graph/lib` returns nothing. The graph's `Context` (`execution_support.rb:52-63`) carries `run_id`, `execution_id`, `request_id`, `thread_id`, `cancellation`, `emitter`, and (via `bind_writer_context`) the writer's `effects` and `store`. **F21-SEC-01 / F25-SEC-01 are therefore not reachable through this row's own state**: the graph neither stores nor re-derives a profile. They remain live findings for F21/F24/F25, and this row does not re-litigate or downgrade them.
- **The graph does bind the effect journal to the writer's storage identity.** `bind_writer_context` (`execution_support.rb:65-77`) rejects a `context.effects` or `context.store` whose `storage_identity` is not the writer's adapter, and otherwise **replaces** the context's effects with `writer.effects`. So a node cannot be handed a foreign journal or store through the durable path.
- **How the graph's thread namespace relates to F07-SEC-01.** The execution-derived effect key is built by `EffectJournalKey.build` (`effect_journal_key.rb:24-45`) from `guard.lease.thread_id` and `guard.lease.namespace` — i.e. from the *active writer's lease*, which the graph supplies through `open_writer(thread_id:, namespace:)` (`execution_support.rb:79-92`, `durable_runner.rb:66-71`, `checkpoint_store.rb:85-90`). The graph's namespace is `context.namespace` extended by task path (`executor.rb:204-216`) and, for subgraphs, a deterministic child namespace (`subgraph_runtime.rb:80-90`). The identity is therefore correctly *derived* from the lease. F07-SEC-01 is that `EffectReconciler#resolve` never compares the loaded row's `thread_id`/`namespace` against the active lease, unlike `EffectJournalKey.verify_identity!` (`effect_journal_key.rb:138-179`) which the prepare path does call. The graph contributes correct lease-scoped keys; the row-scope hole is entirely at F07's resolve seam. Status of F07-SEC-01: **open, unchanged, owned by F07**.
- **Fencing is real and fails closed.** `validate_lease_in_transaction!` (`lease_operations.rb:164-186`) re-reads the namespace row and requires owner, fence, and a live expiry; `acquire_lease` refuses an unexpired lease (`:49-52`) and computes `fence = row.fetch(1) + 1`; the head advance is fenced (`checkpoint_committer.rb:139-155`) and raises `LeaseLostError` when `tx.changes != 1`.

## Lens: reliability and durability

Reviewed — this is the row's core, and the central audit claim is **proven true on this surface**.

**What is committed at a barrier, and is it synchronous.** `CheckpointCommitter#append_checkpoint` performs, in ONE fenced transaction: the base/head mode check (`:68-84`), the checkpoint insert (`:90-108`), consumption of every `consumed_task_ids` activation with `tx.changes == 1` enforced per id (`:109-129`), the optional request transition (`:130-138`), and the head advance (`:139-154`). `Executor` calls it before returning (`executor.rb:143-162`), and only then emits `:checkpoint` (`:164`). The commit is synchronous: `durable_runner.rb` returns only after the writer block closes. `MemoryCheckpointer#durable? = false` (`memory_checkpointer.rb:30`) vs `Adapter#durable? = true` (`adapter.rb:11`) makes the ephemeral/durable distinction explicit rather than implicit, matching `documentation/limitations.md:56-60`.

**Proven: after a real `kill -9`, replay does not re-execute the node.** Probe (scratch in `/tmp/tamoz-agents/probe_killwindow.rb`, nothing written to the repo): a SQLite-backed graph whose node `:a` increments a counter file, with a real `fault_injector` firing `Process.kill("KILL", Process.pid)` at the first data-barrier `checkpoint.commit` — i.e. in the crash window *after* `append_writes` durably recorded the task activation and *before* the barrier commit. The child died with exit 137 (`Killed: 9`). After the 30 s lease TTL elapsed, a second process ran `DurableRunner#recover`. Result: `status=completed state={:log=>["a-exec-1"]} runs=1`. The counter file held `1` both before and after recovery: node `:a` executed exactly once, its pending activation survived the kill, and recovery returned the recorded outcome. This is the "resumes from its last committed barrier and reconciles rather than guessing" claim, reproduced rather than asserted.

**The lease is what makes a `kill -9` safe, and it is enforced.** Recovery immediately after the kill (before TTL expiry) fails closed with `CheckpointConflictError: thread namespace already has an unexpired lease` (`lease_operations.rb:49-52`) — a second writer cannot steal a live fence. This is invariant 20 behaviour.

**State that survives a crash outside a barrier.** The per-task `tamoz_pending_activations`/`tamoz_pending_writes` rows are durable *before* the barrier (`checkpoint_appender.rb:26-140`), but they are not user-visible state: they are read back and merged into the checkpoint only for the active checkpoint (`checkpoint_wire.rb:148-158`), and a disagreement between the checkpoint's declared pending and the durable activations is `CheckpointCorruptionError` (`checkpoint_wire.rb:163-174`). `Executor` treats a pending task id as "do not re-run" (`executor.rb:35-36`). No committed *graph state* was found that exists outside a barrier. On the probe's completed run, history was `[[2, :completed], [1, :running], [0, :running]]` — every state transition is a barrier.

**Fail-closed storage identity.** `checkpoint_wire.rb:182-197` verifies the payload digest **over bytes** (`Wire.verify_digest!`, `wire.rb:81-86`, domain-framed, constant-time compare at `:88-96`) and then cross-checks the decoded payload against the `graph_name`/`graph_version`/`definition_digest`/`status`/`execution_id` columns. A mismatch is corruption, not a silent preference for one side. `Executor` also re-checks graph identity via `compatible!` before resuming (`execution_support.rb:32-38`) — invariant 22.

## Lens: observability and evidence

Reviewed. Signals are a closed set and are correlated.

- `StreamEmitter::PROJECTIONS` (`stream_emitter.rb:5-13`) fixes the vocabulary; `types_for` raises `ConfigurationError` for an unknown mode (`:37-45`). The graph emits `run_start`/`run_end` (`lifecycle_executor.rb:67-83`), `task_start`/`task_end` with graph/node/attempt (`executor.rb:217-233`), `node_update` naming the written channels (`:556-565`), `interrupt` with task id and call index (`:567-578`), `checkpoint` with checkpoint id, sequence, and status (`:580-590`), and `error` with a stable class, category, and safe message (`:592-606`).
- `stream_error_data` (`execution_support.rb:101-116`) deliberately unwraps `NodeError` so the typed category reflects the real cause rather than the wrapper. `SessionEffects`/`EffectDispatcher` provenance stays on the kernel/session side; the graph emits no effect payload and therefore leaks no secret.
- Gap (minor, recorded below): the graph emits **no** `:effect_unknown`-equivalent signal of its own. `grep -rn "effect_unknown" gems/tamoz-graph/lib` is empty. The ambiguity state is visible only through the kernel's dispatcher and the F07 journal, so a graph-only operator watching a stream cannot distinguish "node failed" from "node's effect is ambiguous". That is a real observability gap at this row's seam, though the durable evidence exists in the journal.

## Lens: scalability and resource bounds

Reviewed. Every ceiling named in `documentation/design/graph.md` is present in source.

- Definition-time: `MAX_CHANNELS = 10_000`, `MAX_NODES = 10_000`, `MAX_EDGES = 100_000`, `MAX_BRANCHES = 10_000` (`builder.rb:7-10`, enforced at `:39,67,88,98`).
- Run-time: `max_steps` (default `Tamoz.configuration.recursion_limit` = 200, `configuration.rb:15`), `max_tasks_per_step` 10 000, `max_total_tasks` 100 000, `max_pending_bytes` 4 MiB, `history_limit` 1 000, each bounded again by a hard `MAX_*` (`limits.rb:6-40`). Enforced at `executor.rb:27-31` (super-steps), `:452-461` (tasks per step and total), `:463-471` (pending bytes, measured with `Canonical.json`).
- Codec: `CheckpointCodec` byte ceiling defaults to 16 MiB and caps at 64 MiB (`checkpoint_codec.rb:13-14`), enforced on both dump (`:81`) and load (`validate_input_bytes` → `enforce_size!`, `:314-332`); JSON nesting capped at 512 (`:98`, `:238`).
- Memory checkpointer: `max_threads` default 10 000 / cap 100 000, `max_checkpoints_per_namespace` default 100 000 / cap 1 000 000, `namepace` ≤ 128 parts, each id ≤ 256 bytes (`memory_checkpointer.rb:9-14`, `:131-138`).
- Stream backpressure comes from the bounded `StreamSink` capacity (`lifecycle_executor.rb:116-121`).
- Pool work is bounded by `Pool.for(:inline|:threads, max_tasks: limits.max_tasks_per_step)` (`compiled.rb:190-197`).

## Lens: maintenance and architecture

Reviewed.

- Ownership is honest: `tamoz-graph` depends only on core/cancellation/concurrency/zeitwerk (`tamoz-graph.gemspec:8-13`), and `Compiler#validate_dependencies!` (`compiler.rb:101-121`) checks the checkpointer contract by capability, so the store is a seam rather than a hard dependency. `MemoryCheckpointer` is the in-repo reference implementer and `Tamoz::SQLite::CheckpointStore` the durable one.
- The public surface is narrow: `Compiled` exposes `invoke`, `stream`, `resume`, `retry_failed`, `continue`, `call`, `state`, `history`, `update_state`, `durable_runner` (`compiled.rb:42-166`). `DurableRunner` is required for durable mutation (`execution_support.rb:94-99`) — a good, explicit rule.
- Vocabulary is consistent (`validate`/`verify`/`decode`/`append`) and the checkpoint/outcome/frontier value objects are `Data.define` and frozen.
- Minor debt: `compiled.rb:199-247` is a long wall of one-line `__send__` delegators to `RunCoordinator`, `WriterRunExecutor`, `ExecutionSupport`, `StateOperations`, and `DurableRequestExecutor`. It keeps the boundary narrow, but five collaborators behind private-delegation indirection makes the call graph harder to follow than the seams it hides. This is documentation/readability debt, not a behavior defect.
- `checkpoint_codec.rb` is 750 lines but cohesive; a lenient branch (`decode_frontier(strict:)`, `decode_state(strict:)`) is justified in-source as telemetry-only and is *not* reachable from the run path (see the codec finding below).

## Tests and contracts

All commands are one file per command, focused, run at HEAD `582ae55` with `ruby -Itest test/<file>.rb`.

| Command | Result |
|---|---|
| `ruby -Itest test/graph_checkpoint_codec_test.rb` | 4 runs, 22 assertions, 0 failures |
| `ruby -Itest test/graph_execution_test.rb` | 11 runs, 43 assertions, 0 failures |
| `ruby -Itest test/graph_durable_runner_test.rb` | 19 runs, 39 assertions, 0 failures |
| `ruby -Itest test/graph_durable_request_executor_test.rb` | 2 runs, 5 assertions, 0 failures |
| `ruby -Itest test/graph_resume_answers_test.rb` | 2 runs, 7 assertions, 0 failures |
| `ruby -Itest test/graph_state_manager_test.rb` | 4 runs, 16 assertions, 0 failures |
| `ruby -Itest test/graph_interrupt_test.rb` | 9 runs, 59 assertions, 0 failures |
| `ruby -Itest test/graph_subgraph_test.rb` | 4 runs, 28 assertions, 0 failures |
| `ruby -Itest test/graph_stream_test.rb` | 7 runs, 70 assertions, 0 failures |
| `ruby -Itest test/graph_reducer_test.rb` | 4 runs, 111 assertions, 0 failures |
| `ruby -Itest test/graph_determinism_property_test.rb` | 2 runs, 480 assertions, 0 failures |
| `ruby -Itest test/graph_surface_audit_test.rb` | 4 runs, 46 assertions, 0 failures |
| `ruby -Itest test/dependency_isolation_test.rb` | 22 runs, 221 assertions, 0 failures |
| `ruby -Itest test/sqlite_checkpoint_seams_test.rb` | 7 runs, 14 assertions, 0 failures |
| `ruby -Itest test/sqlite_raw_oracle_test.rb` | 20 runs, 1261 assertions, 0 failures |
| `ruby -Itest test/agent_session_kill_matrix_test.rb` | 6 runs, 67 assertions, 0 failures |

`test/sqlite_store_test.rb` — **not run**: superseded in this checkout by the narrower `sqlite_checkpoint_seams_test.rb` plus `sqlite_raw_oracle_test.rb`, both of which were run above; the store surface belongs to row F07 and was read here only as this contract's implementer. `test/agent_mode_switch_kill_matrix_test.rb` — **not run**: budget; it is a sibling of the kill matrix that *was* run, and the durability seams it exercises were covered by `agent_session_kill_matrix_test.rb`.

The kill matrix is **not** environment-bound in this checkout: all six real-`kill -9` scenarios passed with no skips.

## Findings

### F04-REL-01 — the lease guard's renewal failure is not surfaced to an already-blocked `check!`

| Field | Content |
|---|---|
| Severity | `minor` |
| Confidence | `high` — source-verified; the runtime consequence is bounded and the window is narrow |
| Status | `open` |
| Source evidence | `gems/tamoz-sqlite/lib/tamoz/sqlite/lease.rb:41-54` (`check!` reads `@error`, then calls `validate_lease`), `:77-96` (`renewal_loop` sets `@error` and stops on `FatalRuntimeFailure`) |
| Test/contract evidence | `ruby -Itest test/agent_session_kill_matrix_test.rb` → 6 runs / 67 assertions / 0 failures. No test covers a renewal failure concurrent with an in-flight commit. **not found**. |
| Scanner signal | none — found by reading the fence path while auditing barrier atomicity |
| Independent judgment | Confirmed as a real ordering gap: `check!` is only effective at the points the executor calls it (`executor.rb:24,133`; `checkpoint_writer.rb:32`). Between those points, a renewal failure observed by the background thread does not abort the in-flight transaction; the *store-side* fence check still protects the commit (`checkpoint_committer.rb:139-155` raises `LeaseLostError` when `tx.changes != 1`, and `checkpoint_appender.rb:56-64` re-validates the lease), so correctness is preserved by the second line of defence. There is no false completion and no torn barrier. |
| Root cause | The fence has two enforcement points with different latencies — an in-process flag read at `check!` and a store-side row comparison inside every transaction. The store-side check is authoritative; the in-process flag is only a fast-fail. That is a sound design, but the two are not documented as "the store check is the guarantee, `check!` is an optimization", so a reader can mistake `check!` for the fence itself. |
| Recommendation | No code change required — the store-side fenced commit already delivers invariant 20. The smallest credible action is one line at `lease.rb:41-44` stating that the store-side transaction check is the authoritative fence and `check!` is an early abort, so future readers do not try to "fix" the ordering. |

### F04-OBS-01 — no graph-level signal distinguishes an ambiguous effect from a node failure

| Field | Content |
|---|---|
| Severity | `minor` |
| Confidence | `high` for the absence; `medium` for impact, because the durable journal does retain the ambiguity |
| Status | `open` |
| Source evidence | `gems/tamoz-graph/lib/tamoz/graph/stream_emitter.rb:5-13` (closed projection set), `gems/tamoz-graph/lib/tamoz/graph/executor.rb:592-606` (the only `:error` shape), `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:102-103` (`:unknown`/`:wait` produce a `recorded_outcome` with no stream emission) |
| Test/contract evidence | `grep -rn "effect_unknown" gems/tamoz-graph/lib` → empty. `ruby -Itest test/graph_stream_test.rb` → 7 runs / 70 assertions / 0 failures; it asserts the projection set, not an effect-ambiguity signal. **not found**. |
| Scanner signal | none — found by matching the design doc's `:effect_unknown` claim (`documentation/design/graph.md`, "External effects") against the emitter's closed vocabulary |
| Independent judgment | Confirmed. The design doc says an unsafe or ambiguous effect "emit[s] `:effect_unknown` and interrupt[s] for resolution"; that emission is not produced by any file in `tamoz-graph`. It is not a durability defect — the journal, the `:unknown` attempt status, and `requires_reconciliation` all persist — but a graph-only observer reading the stream cannot tell "this node's effect is ambiguous" from "this node raised". |
| Root cause | Effect semantics live in `tamoz-agent-kernel`/`tamoz-sqlite`, while the graph owns the stream vocabulary. The graph never learned to project the kernel's ambiguity state, and the design doc describes the composite system in the graph's own section. |
| Recommendation | At the existing `StreamEmitter::PROJECTIONS` seam (`stream_emitter.rb:5-13`), either add an `effects` projection fed by the kernel's dispatch outcome, or correct `documentation/design/graph.md` to say the ambiguity signal is emitted by the dispatcher, not the graph. The doc correction is the smaller of the two and is sufficient if the stream is documented as the graph's own vocabulary. |

### Carried forward (verified against current source, not re-litigated)

- **CF04-REL-01** (major, open) — `EffectDispatcher` status-specific terminal receipt selection (`gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:91-101` with `terminal_attempt` at `:280-283`). **How the graph's replay path reaches it:** `Executor#run` treats a task id present in `current.pending` as already recorded and removes it from `to_execute` (`executor.rb:35-36`), so a *successfully recorded* node never replays. The dispatcher is reached on the *node* replay path, not the graph's: a node that was invoked re-enters `EffectDispatcher.run` (`effect_dispatcher.rb:33-67`), which consults `effects.prepare` and takes the `:failed` branch. The graph does not participate in receipt selection — it commits whatever `NodeError`/update the node returns. Status **open, unchanged; owner is `tamoz-agent-kernel` (F17)**, consistent with `analyses/failed-effect-resolution-replay.md`.
- **F07-SEC-01** (critical, open) — see the security lens above. The graph derives lease-scoped effect keys correctly (`effect_journal_key.rb:24-45`); the missing row-scope comparison is entirely at `EffectReconciler#resolve`. Status **open, unchanged; owner is `tamoz-sqlite` (F07)**.
- **F21-SEC-01 / F25-SEC-01** (critical, open) — **not reachable through this row.** `tamoz-graph` stores and re-derives no profile or authority state (verified: no `profile`/`authority` field on `Checkpoint` or `Snapshot`; no reference in `gems/tamoz-graph/lib`). Status **open, unchanged; owners are F21/F24/F25.** This row neither confirms nor weakens them.

## Blind spots

- **Row F07's store internals** were read only to the depth needed to verify THIS contract (committer, appender, writer, queries, wire, lease, effect key). Journal preparation/reconciliation internals (`effect_preparation.rb`, `effect_reconciler.rb`, `effect_completion.rb`, `effect_attempt_ledger.rb`) were **not** read here beyond the call sites the graph reaches; they belong to F07.
- **Cross-process concurrency** was probed only as two sequential processes (kill, then recover). Two genuinely simultaneous writers contending for one namespace were not exercised beyond the `acquire_lease` guard read at `lease_operations.rb:45-52`; `documentation/limitations.md:64-70` still records a failing takeover evidence gate, and this row did not reproduce or disprove it.
- **`agent_mode_switch_kill_matrix_test.rb`** was not run (budget), so "kill survives at every declared seam" is proven for the session matrix, not for the mode-switch matrix.
- **`test/sqlite_store_test.rb`** was not run; its coverage is partially substituted by `sqlite_checkpoint_seams_test.rb` and `sqlite_raw_oracle_test.rb`, which were run.
- **`stream_emitter.rb`'s downstream projection** into `tamoz-observability` was not traced; whether the emitted `:checkpoint` event reaches metrics/traces intact is row F15's question.
- **The `fault_injector` seam** used in the crash probe is a documented test seam (`fault_hook.rb`, `adapter.rb:85-95`), not a production crash. The kill was a real `SIGKILL` (exit 137); the *timing* was test-controlled. A production crash at an arbitrary instruction is not proven equivalent, though the barrier atomicity argument does not depend on the crash point.
- **No `kill -9` was delivered during the `checkpoint.commit` transaction itself** (inside SQLite). The probe killed at the transaction *boundary* for the first data barrier. SQLite WAL recovery is relied upon but was not independently tested here; `test/sqlite_raw_oracle_test.rb` (20 runs / 1261 assertions, passing) is the closest available evidence.

## Verdict

**PASS** — 0 critical, 0 major, 2 minor, 0 info.

All six lenses were reviewed with source citations. No critical or major finding was accepted, and the minor count (2) is below BAR.md's threshold of three. Two previously-recorded findings that touch this row (CF04-REL-01, F07-SEC-01) were carried forward by name, verified against current source, and confirmed to be owned by other rows; F21-SEC-01/F25-SEC-01 were shown not to be reachable through `tamoz-graph`'s own state.

The row's central claim is **true on this surface and was reproduced, not merely read**: a real `SIGKILL` in the window between a task's durable pending activation and the barrier commit, followed by recovery, produced `status=completed state={:log=>["a-exec-1"]} runs=1` — the node executed exactly once, and replay returned the recorded outcome. Barriers are atomic and fenced (`checkpoint_committer.rb:59-156`), the payload digest is verified over bytes on read (`checkpoint_wire.rb:182-188`, `wire.rb:81-86`), an unsupported checkpoint record version is refused before any field is read (`checkpoint_codec.rb:102-104` shape, then `:334-347` identity/version, before `decoded_attributes` at `:215-312` — probe-confirmed), and the decode is strict rather than lenient.

Remaining limitations are the two minors above and the standing repository-level gaps recorded in `documentation/limitations.md:56-70` (durable barrier *timing* evidence and single-writer *takeover* evidence remain partial), which this row did not re-litigate.
