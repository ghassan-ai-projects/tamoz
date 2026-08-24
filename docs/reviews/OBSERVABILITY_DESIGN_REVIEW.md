# Observability design review

Review target: [`docs/OBSERVABILITY_DESIGN.md`](../OBSERVABILITY_DESIGN.md) revision 1, its
bar ([`OBSERVABILITY_BAR.md`](../OBSERVABILITY_BAR.md)) and plan
([`OBSERVABILITY_PLAN.md`](../OBSERVABILITY_PLAN.md)).

Method: adversarial review against the codebase rather than against the documents. Every
load-bearing claim about existing code, schema and invariants was checked at source; one was
checked by execution.

## Decision

**Revision 1 rejected.** Six critical defects, four of them in the correlation and
reconstruction machinery that the whole design rests on. Revision 2 corrects all six, accepts
eight major findings, and lowers the design's own grade from 18/18 to 14 met, 3 partial, 1
conditional.

The safety architecture survived unchanged: the three-plane split, the observer-only contract,
the content-capture policy, the egress rules and the §18 alerting routing were not challenged.
The damage was concentrated in identity, reconstruction and cost accounting.

## Critical findings and corrections

| # | Finding | Evidence | Correction in revision 2 |
|---|---|---|---|
| 1 | `trace_id` keyed on `(thread_id, request_id)` split every paused turn into two traces: the resume after a decision is a **new** request id | [`decision_record.rb:143`](../../gems/tamoz-comms/lib/tamoz/comms/decision_record.rb) `resume_request_id = "decision-#{decision_id}"`; [`worker.rb:383`](../../gems/tamoz-agent/lib/tamoz/agent/worker.rb) reports against the occurrence, not the inbox request | Trace keyed on `(thread_id, execution_id)` — the identity `ARCHITECTURE.md` §8 already defines as "stable across resume, new across turns/forks". §6.2 |
| 2 | `approval.wait` was to be derived from request transitions, but `tamoz_requests` has no paused status — the request *completes* while the session pauses | [`migrator.rb:155`](../../gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb) CHECK is `('queued','claimed','running','redirecting','completed','failed')`; [`worker.rb:190`](../../gems/tamoz-agent/lib/tamoz/agent/worker.rb) documents why | Derived from `tamoz_checkpoints.status='paused'`, which does exist, with `created_at_ms` giving both interval ends. `TelemetryReader#checkpoint_records` now returns `status`. §6.7, §7 |
| 3 | Most of the span tree has no durable timestamp: `plan`, `review`, `verify`, `step` are `SessionRecords` inside the checkpoint payload BLOB and carry no time at all | [`session_records.rb:105-200`](../../gems/tamoz-agent-session/lib/tamoz/agent/session_records.rb) — only `session` and `accepted_plan` carry timestamps | Spans split into **interval**, **point** and **ordering-only** classes with a per-kind anchor table; ordering-only spans carry `duration_ms: nil` and a `committed_at_ms` bound. A3 re-graded to partial. §7 |
| 4 | The design's single core change — a `Secret` guard in `Instrumentation` — **already exists**, making a blocking plan prerequisite moot; and it missed the real defect at that line | Verified by execution: `Tamoz.instrument(…, {a: Secret.new("x")}, context: nil)` raises `SensitiveValueError`. [`immutable.rb:11-31`](../../gems/tamoz-core/lib/tamoz/immutable.rb) defaults `reject_sensitive: true` | Core change restated: `Immutable.copy` runs at [`instrumentation.rb:12`](../../gems/tamoz-core/lib/tamoz/instrumentation.rb) **before** the notifier check at 13, so instrumentation can raise into a caller with observability disabled — already a clause 59 violation. v2 moves the copy behind the check and applies telemetry bounds. §1 |
| 5 | The `Notifier` protocol receives no `Context`, so correlation cannot be derived in the recorder; `tamoz-sqlite` never sees a `Context` at all | [`notifier.rb:6`](../../gems/tamoz-core/lib/tamoz/notifier.rb) `instrument(_name, _payload = {})`; [`adapter.rb:64`](../../gems/tamoz-sqlite/lib/tamoz/sqlite/adapter.rb) holds a bare `@notifier` | Correlation travels in the payload under a reserved key; the catalog declares required keys per name and the recorder validates at runtime. A **per-layer spine table** replaces the uniform claim, and A2 is re-graded to partial. §6.2 |
| 6 | `effect_records(thread:, request:)` is not implementable: `tamoz_effects` has no `request_id`, and resume stamps the new request row with the existing execution id, so the relation is one-to-many | [`migrator.rb:207`](../../gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb); [`writer_run_executor.rb:164`](../../gems/tamoz-graph/lib/tamoz/graph/writer_run_executor.rb) | Effects filter by `execution`, which *is* a column — and which is also the trace key, so finding 1's fix resolves this one. §6.7 |

## Major findings and corrections

| # | Finding | Correction |
|---|---|---|
| 7 | `span_id` used `activation_id`/`attempt_id`/`call_index`: `attempt_id` is not in `Context::ATTRIBUTES`, `call_index` is undefined for non-effect spans, and four review records per plan attempt collided on one id | Per-kind durable anchors — `(effect_key, attempt_number)`, `(checkpoint sequence, review_id)`, checkpoint `sequence`, `execution_id` — tabulated in §7. Both the emitter and the reconstruction compute the same anchor, which is what makes §9 reconciliation work |
| 8 | §12's per-turn tail-sampling buffer contradicted §7's "the live plane never holds intervals", and its retention list led with the approval pause — the case that outlives the process, so the interesting turn was the one certain to be lost on restart | Buffer deleted. The journal records everything unsampled and **is** the buffer; export sampling decides when the exporter reads the journal, by which time the outcome is known. §12, ADR-047 |
| 9 | A single drop-newest queue discards safety-bearing signals exactly when the system is loudest, while §12 promised they are never sampled | Two lanes: a reserved never-dropped lane for `safety_bearing: true` catalog entries with a bounded synchronous journal fallback, and a bulk drop-newest lane. C4 covers both. §6.4, §13 |
| 10 | "No new durable tables" was stated absolutely and then carved out for model usage — and there is no column to write usage to. A new column means `MIGRATION_7` and a `CURRENT_VERSION` bump, after which older binaries hard-refuse the database; the alternative changes a durable receipt digest | Usage capture reclassified as a **persistence prerequisite** that observability consumes, with the migration and compatibility break priced and an explicit refuse branch. ADR-045's carve-out removed. §10 |
| 11 | Usage and TTFT are not obtainable from the current `Model` contract: `generate(stage:, system:, prompt:) → String` discards the `RubyLLM::Message` at `.content`, and `.ask` is non-streaming so TTFT ≡ duration | The protocol change is named as a real cross-gem change across six implementations. **TTFT dropped** from the catalog, span tree, metrics and D1. §10, §23 |
| 12 | Derived gauges cannot "share the code path `tamoz status` uses": `build_status` is in `tamoz-agent`, and `tamoz-observability` depends on `tamoz-core` only | Census derivation moves into `tamoz-sqlite` behind `TelemetryReader` with `tamoz status` refactored onto it in the same slice; otherwise the guarantee downgrades to a golden equality test. `store_records` added for Store-backed gauges. §6.7, §11 |
| 13 | `tamoz trace` cannot be read-only — the adapter has no read-only mode and constructs a `Migrator` — and there is no single "runtime database": the CLI writes one per thread | A read-only open path is named as prerequisite work; reconstruction targets the worker's shared database and takes `--session-dir` for the CLI layout rather than guessing. §6.7, §25 |
| 14 | Phase 5 needs durable state (silences, rule revisions) that ADR-045 appeared to forbid, written by a second process that E2 said would not exist | Phase-5 state lives in the Store beside circuits and open occurrences; ADR-045 scoped to *telemetry* stores; E2 explicitly relaxed for phase 5 with the same fenced-lease discipline. §18.4 |

## Minor findings and corrections

| # | Finding | Correction |
|---|---|---|
| 15 | Clauses 59–61 covered neither A1 (versioned catalog), D3 (cardinality) nor D2 (cost basis), despite each having a conformance test | Catalog versioning and cardinality folded into clause 59; cost basis folded into clause 61. §21 |
| 16 | Two naming conventions: §6.1 mandated a `tamoz.` prefix while §8 registered `comms.*`, `stream.*`, `scheduler.*` | Framework names use `tamoz.*`; optional packages keep prefixes their own accepted designs already published. The catalog owns a closed prefix list. §6.1 |
| 17 | The journal could not be both `Signal`-shaped and byte-compatible with the worker's NDJSON | The compatibility guarantee applies to **stdout**, via a renderer over the same signals; the journal carries the full `Signal`. §14 |
| 18 | §4.1 claimed six tables "all carry `created_at_ms`"; `tamoz_effect_attempts` carries `prepared_at_ms`/`started_at_ms`/`completed_at_ms` | Corrected, and the claim is now qualified by §7 rather than blanket. §4.1 |
| 19 | Multi-writer journal rotation was unspecified: a worker and a gateway share the directory, and §16.3 described following a single file | One file per process role **and pid**; the follower globs the role prefix and merges by `observed_at_ms`. §14, §16.3 |
| 20 | `tamoz-telegram` was cited as an existing precedent for lazy loading; it is itself a proposal | Stated as an inherited pattern under review, not a proven mechanism. §3, §25 |

## Not accepted as findings

- **The magnitude argument against ordering-only spans.** The review argued that a tree where
  most spans lack durations fails A3 outright. Bar §2's Q2 asks "what happened in this turn, in
  order, and why" — ordering, parentage and outcome, not durations. Revision 2 therefore keeps
  reconstruction, marks the affected spans honestly, and re-grades A3 to partial rather than
  abandoning it. What is fully measured is what costs money and time: every model call, tool
  call, effect attempt and approval pause.

## Unverified

Carried into revision 2 §25 as open risks rather than silently assumed:

- Whether committing usage into `tamoz_effect_attempts.result` would change any checkpoint
  byte. The `effect_receipt` session record does not carry it, but `Outcome#value` flows back
  into node code and not every consumer was traced. Revision 2 rejects that approach anyway.
- The OpenClaw and Hermes Agent citations in §26 were not re-fetched during this review.
- Whether the cross-gem registry gate can be enumerated statically depends on no call site
  computing its event name. Revision 2's catalog requires literal names; the gate must enforce
  that rather than assume it.
