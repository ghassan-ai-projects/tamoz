# CF02 durable graph checkpoint, crash recovery, and replay — IMPROVE

Row / queue / baseline (commit, date) / analyst / budget

- Row: **CF02** — durable graph checkpoint, crash recovery, and replay.
- Queue: cross-gem flow inventory in `COVERAGE.md`.
- Baseline: branch `audit-15-09`, code commit `582ae55`, 2026-09-15.
- Analyst: coordinator direct read-only review after the standalone cross-flow scan.
- Budget: bounded source review and focused tests; no implementation.

## Scope and source map

| Source | Lines | Boundary role |
|---|---:|---|
| `gems/tamoz-agent-session/lib/tamoz/agent/session.rb` | 516 | session start/resume/recover façade |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_graph.rb` | 180 | graph definition and state reducers |
| `gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb` | 221 | durable request submit/claim/run/recover |
| `gems/tamoz-graph/lib/tamoz/graph/executor.rb` | 616 | checkpointed super-step execution and terminal transitions |
| `gems/tamoz-graph/lib/tamoz/graph/execution_support.rb` | 130 | graph identity and writer binding |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_writer.rb` | 162 | fenced public writer seam |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_committer.rb` | 249 | atomic checkpoint transaction |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_claimer.rb` | 276 | request ordering, staleness, and claim limit |
| `gems/tamoz-graph/lib/tamoz/graph/request_staleness.rb` | 45 | operation-specific applicability predicate |
| `gems/tamoz-cancellation/lib/tamoz/cancellation_token.rb` | 113 | cancellation state and wait boundary |
| `test/sqlite_crash_recovery_test.rb` | — | crash/recovery contract |
| `test/graph_history_test.rb` | — | graph history and checkpoint contract |

The entry seams are `Session#start`/`#resume` and `DurableRunner#run_next` or
`#recover`. The runner opens a writer, claims one request through the graph's
staleness validator, executes the compiled graph, and returns the durable request
(`gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb:56-101,104-152`). SQLite
provides the lease, request inbox, checkpoint append, and transaction boundaries.

## Behavior path

1. A session builds a versioned graph and binds a durable checkpointer. The
   runner refuses a non-durable checkpointer or a mismatched request protocol
   (`gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb:12-19`).
2. `submit` writes a request keyed by thread, namespace, and request id
   (`durable_runner.rb:25-41`). `run_next` opens a fenced writer and asks the
   SQLite inbox to claim the next applicable request (`:66-83`).
3. The inbox evaluates `RequestStaleness` inside the transaction. Turns behind a
   non-terminal checkpoint are deliberately deferred; other stale requests are
   terminal-failed (`gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_claimer.rb:160-203`,
   `gems/tamoz-graph/lib/tamoz/graph/request_staleness.rb:14-40`).
4. `Executor#run` checks cancellation and the writer fence before each
   super-step, excludes already-persisted pending task activations, executes the
   remainder, and chooses failure, pause, cancellation, or the next frontier
   (`gems/tamoz-graph/lib/tamoz/graph/executor.rb:13-58,60-114`).
5. A normal step appends the next checkpoint and optional request transition in
   one writer transaction, then emits the committed checkpoint
   (`executor.rb:116-165`; `gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_committer.rb:24-167`).
6. After a worker crash, `recover` reacquires a writer, recovers the claimed
   request, and re-enters the same execution path (`durable_runner.rb:104-152`).
   Pending task activations are treated as recorded and are not executed again
   (`executor.rb:33-37`).

## Lens: correctness

Reviewed. Graph identity is checked against name, version, and definition digest
before a checkpoint is resumed (`gems/tamoz-graph/lib/tamoz/graph/execution_support.rb:20-38`).
The executor orders task outcomes deterministically, validates each outcome, and
only advances the frontier after all writes are ready (`executor.rb:116-162`).
The focused history contract passed **7 runs / 30 assertions / 0 failures**.

The claim boundary has a material liveness defect carried from `F07-REL-01`:
`candidate_rows` returns only eight non-terminal rows (`gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_claimer.rb:216-231`),
while every early `:turn` is skipped without changing state (`:160-180,183-190`).
Nine deferred turns can therefore keep a valid later resume out of every claim
window. The behavior is source-grounded and reproduced in the existing bounded
probe; it is not counted as a new CF02 finding.

## Lens: security and authority

Reviewed. Writer acquisition and every checkpoint mutation are lease-scoped:
the runner passes `(thread, namespace)` to `open_writer` (`durable_runner.rb:66-71`),
and the execution support binds the writer's effect/store handles only after
acceptance checks (`execution_support.rb:65-77`). Graph compatibility rejects a
checkpoint from another graph definition (`execution_support.rb:32-38`).

The cross-thread effect-resolution authority defect `F07-SEC-01` is adjacent to
this flow's writer boundary but is owned by `tamoz-sqlite`'s resolver, which is
outside graph checkpoint execution. It remains open and is not re-counted here.

## Lens: reliability and durability

Reviewed. `CheckpointCommitter#append_checkpoint` performs the checkpoint insert,
pending activation consumption, request transition, and head advance in one
fenced transaction (`gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_committer.rb:24-167`).
The crash-recovery contract passed **3 runs / 30 assertions / 0 failures**. The
existing kill-window evidence in the graph analyst report also records one node
execution before and after recovery, with the pending activation reused rather
than re-executed (`analyses/F04-graph.md:62-66`).

The reliability weakness is the carried `F07-REL-01` starvation: the request is
durable and safe, but a valid control resume can remain queued indefinitely when
the first eight rows are early turns. The worker's open-occurrence priority
(`gems/tamoz-agent/lib/tamoz/agent/worker.rb:227-255`) does not change the inbox
limit once it calls `run_next`.

## Lens: observability and evidence

Reviewed. The graph emits typed task, checkpoint, interrupt, and error parts only
after the corresponding state decision (`gems/tamoz-graph/lib/tamoz/graph/executor.rb:556-606`).
Stale requests are durably failed with a typed payload and transition evidence
(`gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_claimer.rb:72-121`).

The starvation path has no distinct deferred-age, skipped-candidate, or control-
request-wait signal in the claim seam; `run_next` simply returns `nil` when no
row is returned (`gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb:71-74`).
This evidence gap is part of `F07-REL-01`'s existing disposition and keeps the
flow IMPROVE even though normal checkpoints are observable.

## Lens: scalability and resource bounds

Reviewed. Graph super-steps are capped by `limits.max_steps` and pending task
activations are bounded before a commit (`gems/tamoz-graph/lib/tamoz/graph/executor.rb:27-31,56-58`).
SQLite history and checkpoint payloads also have explicit limits in their stores.
The request claimer's `LIMIT 8` is a deliberate work bound, but it is not paired
with a fairness or age escape for deferred control requests (`gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_claimer.rb:216-231`).
That is the resource/liveness tradeoff behind `F07-REL-01`; no separate load or
soak measurement was run for this flow.

## Lens: maintenance and architecture

Reviewed. Session, graph, and SQLite each own a narrow seam: session builds the
graph, graph decides applicability and execution, and SQLite owns durable writes.
The writer contract exposes only fenced mutation methods (`gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_writer.rb:17-154`).
The early-turn rule is documented at both the staleness and claimer sites, which
makes the intended safety behavior discoverable (`request_staleness.rb:34-40`,
`request_inbox_claimer.rb:183-190`).

The remaining architectural gap is the split between a bounded candidate query
and a fairness contract. The smallest seam is the request claimer/validator;
no graph rewrite is indicated.

## Tests and contracts

- `ruby -Itest test/sqlite_crash_recovery_test.rb` → **3 runs / 30 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/graph_history_test.rb` → **7 runs / 30 assertions / 0 failures / 0 errors / 0 skips**.
- `test/agent_session_kill_matrix_test.rb` → not run to completion in this bounded pass; no result is claimed.
- Starvation probe → existing bounded probe recorded in `analyses/request-claim-starvation.md`; no repository scratch was created.
- Full CI and long-running crash/load matrix → not run under the audit brief.

## Findings

### Carried finding — F07-REL-01

`F07-REL-01` is an open **major/high** finding at
`RequestInboxClaimer#candidate_rows` (`gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_claimer.rb:216-231`).
Its source trace, five-whys chain, reproduction, and independent challenge are
already recorded in `analyses/request-claim-starvation.md` and
`analyses/challenge-queue-comms-schedule.md`. CF02 confirms the downstream graph
effect: `DurableRunner#run_next` returns `nil` while the valid resume remains
queued (`durable_runner.rb:71-74`); it does not mint a second finding.

`CF04-REL-01` (late-success/failed-effect replay) and `F07-SEC-01`
(cross-thread effect resolution) are adjacent journal findings with separate
owners. They are carried by name only and are not counted in CF02.

## Blind spots

- The full session kill matrix did not finish in this bounded pass, so no result
  is claimed for it.
- No production worker soak or multi-process claim-fairness load was run.
- Effect-journal replay and cross-thread resolution were read as adjacent owned
  findings, not re-litigated as part of this graph checkpoint row.
- The in-memory graph checkpointer is not the durable path and was not used as
  evidence for crash behavior.

## Verdict

**IMPROVE** under `BAR.md`: the complete source trace and six lenses are present,
but the accepted major `F07-REL-01` starvation defect crosses this flow's claim
boundary. It is carried under the SQLite owner and is not double-counted in the
CF02 machine counters. CF02 remains open until the coordinator's cross-flow
closure gates are complete.
