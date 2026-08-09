# Codebase Review — gems/tamoz-graph

*12-agent codebase review, 2026-08. See [INDEX.md](INDEX.md). Scope: `gems/tamoz-graph/lib/**` (37 files, ~4,950 lines), judged against `docs/CODING_STANDARD.md`.*

## Overall assessment

The gem's durable core (codec canonicality checks, checkpoint fencing, planner digests) is genuinely careful — the byte-level contract work in `checkpoint_codec.rb` is the strongest part. The structural debt concentrates in exactly three places: `Compiled` (1,152 lines, private API reached externally), the triple-duplicated `*_with_writer`/`run_next`/`recover` bodies, and `Executor#run`. Nearly every complexity finding is already known to the repo — the files sit in `.rubocop_todo.yml` — so these are ratchet-shrink targets, not new discoveries. The two findings most likely to bite in production are H4 (hardcoded codec bypassing a custom codec) and L4 (silent key collision in digest canonicalization).

## High

### H1 — `Compiled` is a god class, 4.6× the class ceiling

`gems/tamoz-graph/lib/tamoz/graph/compiled.rb:7` (1,152 lines vs. 250 max, §2/§6; excluded in `.rubocop_todo.yml` under `Metrics/ClassLength`). It owns the public run API, durable-request execution (`execute_durable_request`, 155 lines, L689–843), staleness predicates, resume merging, context building, writer leasing, and checkpoint appending.

**Fix:** extract `DurableRequestExecutor` (L689–947) and `ResumeAnswers` (L990–1064) into collaborators; the standard's Q3 remediation already did this for `tamoz-agent`.

### H2 — Private-API reach across objects via `__send__`

`durable_runner.rb:77`, `durable_runner.rb:128` call `compiled.__send__(:execute_durable_request, …)`; `subgraph_runtime.rb:22,60,73,77,87,96` call `child.__send__(:with_checkpointer/:invoke_at/:compatible!/:resume_at/:retry_failed_at/:continue_at, …)`. Encapsulation is fictional; the internal contract between `DurableRunner`/`SubgraphRuntime` and `Compiled` is implicit and untestable at the boundary.

**Fix:** declare an explicit internal interface (e.g. `Compiled::Internal` module, marked `:nodoc:`) instead of reaching through `private`.

### H3 — Boolean parameters throughout, §4 violation

`compiled.rb:56,82` (`new_execution:`), and `mark_request_running: true` at `compiled.rb:567,621,658` controlling two behaviors inside each `*_with_writer` method; `resume_with_writer`/`retry_failed_with_writer`/`continue_with_writer` (L558–687) are three ~50-line copies of the same body differing only in the status guard.

**Fix:** collapse to one `run_from_checkpoint` parameterized by the required status, and split the mark-running branch into the callers.

### H4 — Hardcoded `StateCodec.new` bypasses the compiled graph's custom codec

`frontier.rb:31`, `interrupt.rb:13,36`, `command.rb:6,9`, `send.rb:7` normalize values with the default codec even when `Compiler` was given a custom one (`compiler.rb:10`). A graph compiled with a custom codec will normalize frontier inputs/interrupts/commands through a different codec than its state — silent inconsistency at the durability boundary.

**Fix:** thread the codec through, or document that these value types are codec-pinned to `StateCodec`.

### H5 — Duplicated resume-answer validation with two error channels

`stale_resume_reason` (`compiled.rb:990–1026`) re-implements the shape/index/duplicate checks of `merge_resume_values` (`compiled.rb:1028–1064`), ~35 lines, once returning reason strings and once raising. The DR-4 comment at L986 admits it was "refactored from" the merge. Any rule change must be made twice; they will drift.

**Fix:** extract one validator producing typed reasons; `merge_resume_values` raises from it.

## Medium

### M1 — `CheckpointCodec` is 712 lines mixing four codecs

`checkpoint_codec.rb:7`: checkpoint envelope, pending-outcome rows, request payloads, resume values (each `encode_*`/`decode_*` pair). Excluded under `Metrics/ClassLength`/`AbcSize` in `.rubocop_todo.yml`.

**Fix:** extract `OutcomeRowCodec` and `RequestPayloadCodec`; keep envelope + value canonicality checks here.

### M2 — `DurableRunner#run_next` and `#recover` are near-identical

`durable_runner.rb:56–102` vs `104–153`: same writer-open, claim/validate, `__send__` execute, stale-capture, refetch, terminal-fail backstop (~45 lines duplicated, only `claim_next_request` vs `recover_request` differs).

**Fix:** one private `run_claimed(thread:, …) { |writer| … }` taking the claim operation.

### M3 — `invoke` builds the run context twice and validates `new_execution` twice

`compiled.rb:64–71` builds a context, then `invoke_at` rebuilds it (L433–440) via `base.with(...)`; the `new_execution` check at L60–62 is repeated verbatim at L429–431. Dead work plus duplicated policy.

**Fix:** validate and build once in `invoke`; make `invoke_at` trust its (internal) callers.

### M4 — Eager dual pools per compiled graph, with no lifecycle

`compiled.rb:38–41` constructs both `:inline` and `:threads` pools at compile time even when only one concurrency is ever used, and nothing shuts a pool down (§4 "state that can be added can be removed"). `Pool.for` caches globally in core, so repeated compiles also share/contend implicitly.

**Fix:** lazily create the requested pool in `pool_for`.

### M5 — `Executor#run` is a 155-line loop method

`executor.rb:13–170` (in `.rubocop_todo.yml` under `Metrics/MethodLength`/`AbcSize`/`CyclomaticComplexity`); failure/pause/advance branches repeat the append-then-emit-then-return shape three times.

**Fix:** extract `handle_errors`, `handle_interruptions`, `advance` step methods returning `RunResult` or nil.

### M6 — Cross-gem implicit contract on `throw :tamoz_interrupt`

Thrown by graph (`interrupt.rb:37–44`), caught by core's `Pool` (`gems/tamoz-core/lib/tamoz/pool.rb:82`). The tag is a bare symbol literal on both sides; nothing names the contract.

**Fix:** one shared constant in core (`Tamoz::Pool::INTERRUPT_TAG`) referenced by graph, with the reason comment §6.1 requires.

### M7 — `Tamoz.configuration` as ambient default in 9 places

`compiled.rb:55,94,98,172,189,205`, `durable_runner.rb:60,109,185`, `limits.rb:16`. §5 bans hidden global state; a default that reads global config at call time makes `Limits`/`Compiled` behavior depend on when they're constructed vs invoked.

**Fix:** resolve config once at compile time, or require explicit args.

### M8 — `update_state`/`fork_with_writer` attribute manual outcomes to `definition.nodes.keys.first`

`compiled.rb:324,891`. The recorded `node` for a manual/fork update is whatever node sorts first; reordering node declarations changes durable outcome attribution.

**Fix:** use a dedicated sentinel node name (e.g. `:__manual__`) validated as not-a-graph-node.

### M9 — `EventStream#join!` leaks a live coordinator thread

`event_stream.rb:88–98`: after `join_grace` expires it records a `PoolWorkerError` but leaves the runner thread alive and unsupervised.

**Fix:** kill/close the sink-bound coordinator or document the abandonment (and why it's safe).

### M10 — `DurableRunner` has no graph-gem unit tests

It is exercised only through tamoz-sqlite integration tests (`test/sqlite_stale_request_test.rb`, `test/sqlite_crash_recovery_test.rb`, `test/sqlite_request_inbox_test.rb`). The graph gem's own durability orchestration is untested at its own boundary (§9: test through the narrowest stable boundary).

**Fix:** add a `test/graph_durable_runner_test.rb` against a fake durable checkpointer.

## Low

- **L1 — No class-level documentation on public classes.** §11 requires it; `compiled.rb:7`, `checkpoint_codec.rb:7`, `durable_runner.rb:7`, `memory_checkpointer.rb:7`, `limits.rb:5`, `definition.rb:5`, `snapshot.rb:5`, `builder.rb:5`, `reducers.rb:4` and most others have none (all excluded under `Style/Documentation` in `.rubocop_todo.yml:2813–2838`). **Fix:** one-line "what it is" docs plus contract on `Compiled#invoke/#stream/#resume` and `MemoryCheckpointer`.
- **L2 — Zeitwerk-dodge `const_get` obscures dependencies.** `reducers.rb:10–11`, `command.rb:10`, `send.rb:6`, `graph.rb:25` use `Graph.const_get(:Identifier/:Builder, false)` instead of plain constant references. Unsearchable and hides the wiring the architecture tests are supposed to pin. **Fix:** require/refer directly, or move these types under `Tamoz::Graph` where Zeitwerk resolves them.
- **L3 — `Reducers::UNION` is O(n²).** `reducers.rb:51–53` uses `result.include?` per element. **Fix:** `require "set"` and dedupe via `Set` (or `(current + writes.flatten(1)).uniq`, noting `uniq` uses `eql?` semantics like `include?`).
- **L4 — `Canonical.sort` silently collapses string/symbol key collisions.** `canonical.rb:25–27`: `{ "a" => 1, a: 2 }` sorts to one key and keeps the string-keyed value, silently dropping the other — in the digest path that feeds checkpoint identity. **Fix:** raise on duplicate normalized key.
- **L5 — Marker/`StreamEmitter` micro-issues.** `marker.rb:14` `alias to_s inspect` (in todo under `Style/Alias`; `to_s` returning `"Tamoz::START"` is also surprising for a wire marker); `stream_emitter.rb:24` reaches its own private class method via `self.class.__send__(:types_for, …)` — just call `types_for` after making it a module_function or public-on-self helper. `compiled.rb:102` `sink = nil` is a dead assignment (todo `Lint/UselessAssignment`).
