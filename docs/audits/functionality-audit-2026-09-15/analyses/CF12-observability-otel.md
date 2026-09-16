# CF12 signal recording, metrics/traces, bounded drains, and OTLP export — IMPROVE

Row / queue / baseline (commit, date) / analyst / budget
- Row: **CF12** — signal recording, metrics/traces, bounded drains, and OTLP export
- Queue: W4B (`COVERAGE.md`, observability / OTLP)
- Baseline: branch `audit-15-09`, commit `582ae55`, 2026-09-15
- Analyst: coordinator direct review; delegation was paused by the owner
- Budget: one bounded source, test, and probe pass

## Scope and source map

The source path was read end to end across the producer, durable worker, journal,
projection, and exporter boundaries. The principal files and line counts were:

| Area | Files read | Lines |
|---|---|---:|
| Signal plane | `gems/tamoz-observability/lib/tamoz/observability.rb` (34), `signal.rb` (225), `signal_catalog.rb` (252), `catalog.rb` (191), `producer.rb` (93), `content_policy.rb` (230), `recorders.rb` (127), `recorder.rb` (19), `recorder_drop_ledger.rb` (59), `recorder_journal.rb` (340), `metrics.rb` (276), `trace.rb` (168), `model_call.rb` (50), `notifier.rb` (45), `correlation.rb` (32), `usage.rb` (125), `telemetry_reader.rb` (16), `exporter.rb` (11) | 2,293 |
| Shared drain | `gems/tamoz-concurrency/lib/tamoz/concurrency/drain.rb` | 224 |
| OTLP adapter | `gems/tamoz-otel/lib/tamoz/otel.rb` (13), `egress_policy.rb` (85), `async_exporter.rb` (113), `http_exporter.rb` (170) | 381 |
| Agent and CLI callers | `gems/tamoz-agent/lib/tamoz/agent/worker.rb` (1,377), `runtime.rb` (796), `worker_runtime.rb` (1,249), `durable_recorder.rb` (34), `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb` (919), `cli_session_commands.rb` (360), `cli_worker_commands.rb` (749) | 5,484 |
| Contracts and operations | `documentation/design/observability.md` (76), `documentation/operations/observability-ops.md` (107), `documentation/limitations.md` (261) | 444 |

Entry seams are `Worker#emit` → `Observability::Producer#emit` →
`Recorder#record` (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:1223-1249`,
`gems/tamoz-observability/lib/tamoz/observability/producer.rb:14-24`), and the
optional `AsyncExporter#record` → `HTTPExporter#export`
(`gems/tamoz-otel/lib/tamoz/otel/async_exporter.rb:34-47`,
`http_exporter.rb:36-83`).

## Behavior path

1. `tamoz worker` opens `WorkerRuntime`, creates a `Journal` wrapped by
   `DurableRecorder`, and passes it to `Worker` (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:270-293,704-713`).
   The wrapper flushes a recorded signal before returning and flushes again on
   close (`gems/tamoz-agent/lib/tamoz/agent/durable_recorder.rb:6-29`).
2. Worker lifecycle fields are converted to registered signal names, correlated
   with thread/occurrence/execution identifiers, and reduced to catalogued
   attributes (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:1223-1271`).
   `Producer` applies the content policy, builds the immutable bounded `Signal`,
   and hands it to the recorder (`gems/tamoz-observability/lib/tamoz/observability/producer.rb:14-24,46-64`).
3. `Journal#record` validates against the closed catalog, routes safety-bearing
   signals to the reserved lane, and drop-counts bulk saturation, closure, and
   writer failures (`gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb:57-121`).
   `Concurrency::Drain` batches, flushes with a deadline, and joins on close
   (`gems/tamoz-concurrency/lib/tamoz/concurrency/drain.rb:31-73,145-187`).
4. A durable session writes model effects to the SQLite effect journal. During
   worker settlement, `Worker#settle` checks the two enforced budgets before it
   projects successful model effects into `tamoz.model.call`
   (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:635-649,1274-1347`).
5. The CLI reads journal documents for `observe tail`, `observe metrics`, and
   `trace`; these are pure projections over the remaining journal files
   (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:69-145`,
   `gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb:246-305`).
6. The optional exporter is a separate path: an operator would open an
   `HTTPExporter` under `EgressPolicy`, enqueue signals in `AsyncExporter`, and
   let the drain call `HTTPExporter#export`; the repository currently has no
   production construction caller (`gems/tamoz-otel/lib/tamoz/otel/async_exporter.rb:9-103`,
   `http_exporter.rb:10-87`).

## Lens: correctness

The closed signal catalog and immutable value checks hold. `Signal.build` bounds
attributes/content and rejects unsupported nested values and `Tamoz::Secret`
objects (`gems/tamoz-observability/lib/tamoz/observability/signal.rb:13-16,136-222`).
`Producer` refuses unregistered names and converts instrumentation failures to
`:dropped` (`producer.rb:17-24`); the worker only emits names that the catalog
registers (`worker.rb:1232-1245`). Correlation is derived from durable identity
and the journal sorts documents deterministically (`correlation.rb:17-29`,
`recorder_journal.rb:250-254`).

The cross-boundary weakness is the settlement ordering recorded in
**CF12-OBS-01** below: an effect can be durably present while its model-call
signal is absent. This does not alter checkpoint or effect state, but it means a
projection is not a complete account of the model work that just happened.

## Lens: security and authority

The signal boundary refuses a `Tamoz::Secret` object and the default policy keeps
prompt/tool content in digest-and-size form (`signal.rb:193-200`,
`content_policy.rb:35-51,169-172`). Plain strings remain shape-checked rather
than secret-scanned; the live `reason` path is the accepted **F15-SEC-01** major
finding (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:137,1032`). No new CF12
authority bypass was found.

The OTel path has explicit HTTPS, credential-reference, proxy, redirect, and
resolved-address checks (`gems/tamoz-otel/lib/tamoz/otel/egress_policy.rb:14-82`,
`http_exporter.rb:47-83`). The missing enable path and absent content-policy
digest at that exporter remain **F16-SEC-01** (demoted minor) and
**F16-SEC-02** (major), already dispositioned in `FINDINGS.md`; they are carried
here without a second count.

## Lens: reliability and durability

The journal and shared drain are bounded and fail soft. Queue refusal is counted,
the reserved lane uses a bounded synchronous fallback, rotation caps files and
bytes, and writer failures disable the journal rather than raising into the
worker (`recorder_journal.rb:16-19,90-121,150-218`). `DurableRecorder` supplies
the process-loss flush boundary used by the worker (`durable_recorder.rb:9-29`).
The direct suites and the durability test below passed these behaviors.

The durable effect journal remains the source of truth for model-call receipts.
However, `settle` returns from the budget branch before `emit_durable_model_calls`
(`worker.rb:635-649`), and that projector itself selects only effect-census rows
whose status and latest attempt are both `:succeeded` (`worker.rb:1278-1288,
1301-1320`). The missing projection is therefore bounded evidence loss, not
durable state loss; it is recorded as the local observability finding below.

## Lens: observability and evidence

Normal worker events are catalogued, correlated, and written through the durable
recorder. `tamoz trace` and `observe metrics` are read-only projections, and the
doctor command exercises the class-level secret refusal (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:80-184`).
The design/operations limitation that the trace is journal-only is accurate
(`documentation/limitations.md:121-126`).

**CF12-OBS-01 is confirmed.** A real `AutonomyCase` run with
`budgets: {'model_calls' => 2}` produced six successful model effects but the
worker journal contained only `tamoz.worker.started`,
`tamoz.worker.request.claimed`, `tamoz.worker.request.stopped`, and
`tamoz.worker.stopped`; `tamoz.model.call` count was zero. The stopped event
correctly records `reason=budget_exhausted`, so the missing model-call span is a
projection gap rather than a hidden safety action. Failed or unknown model
effects are also excluded by the source filter. The result undercounts model
usage and hides the model outcome from the local trace/metrics projection.

The component findings **F15-OBS-01/F15-OBS-02** and **F16-OBS-01** remain open
and cover, respectively, lossy metric/flat trace projection and the later OTel
export path. CF12's finding is upstream at the durable worker projection seam,
so it is not a duplicate.

## Lens: scalability and resource bounds

Signal attributes, content, journal lanes, rotation, metric series, and exporter
queues all have explicit caps (`signal.rb:13-16`, `recorder_journal.rb:16-19`,
`metrics.rb:10-11`, `async_exporter.rb:10-23`). The effect census used by both
the budget gate and model projection is capped at 10,000 rows
(`worker.rb:1278`, `worker_runtime.rb:400-403`), so the CF12 path does not create
an unbounded scan. The reserved-lane disk write under the journal mutex and
low-cardinality regex remain **F15-SCAL-01/F15-SCAL-02**; the async deadline and
OTLP typing remain **F16-REL-01/F16-COR-01**. No additional scale defect was
separable from those component findings.

No sustained-load or real collector measurement was run. The source bounds are
reviewed; deployment-level throughput evidence remains an explicit gap.

## Lens: maintenance and architecture

`tamoz-observability` owns the signal contract and journal, `tamoz-concurrency`
owns the drain skeleton, and `tamoz-otel` owns transport policy. The dependency
direction is acyclic, and the worker reuses those seams rather than implementing
a second queue (`tamoz-observability.gemspec:16-19`, `tamoz-otel/tamoz-otel.gemspec:9-14`).
The worker's `DurableRecorder` is private and is constructed at one CLI worker
boundary, which makes ownership clear (`gems/tamoz-agent/lib/tamoz/agent/durable_recorder.rb:6-32`).

The design documents still describe an optional OTel enable path and `gen_ai`
mapping that have no production caller (`documentation/design/observability.md:11-14`,
`gems/tamoz-otel/lib/tamoz/otel/http_exporter.rb:10-135`). Those are carried
under F16. The new CF12 issue is a small ordering mismatch inside an otherwise
well-separated path, with a one-seam recommendation.

## Tests and contracts

Focused commands were run one file per command from the repository root:

| Command | Result |
|---|---|
| `ruby -Itest test/observability_catalog_test.rb` | 10 runs, 26 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/observability_runtime_test.rb` | 13 runs, 53 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/observability_correlation_test.rb` | 6 runs, 16 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/observability_signal_test.rb` | 10 runs, 26 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/concurrency_drain_test.rb` | 7 runs, 36 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/otel_test.rb` | 6 runs, 17 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/observability_cli_test.rb` | 2 runs, 11 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest gems/tamoz-evals/test/agent_observability_durability_test.rb` | 2 runs, 5 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_budget_test.rb` | 7 runs, 20 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_worker_test.rb` | 25 runs, 122 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_worker_fail_closed_test.rb` | 5 runs, 10 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_worker_failure_reason_test.rb` | 6 runs, 14 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_worker_mcp_test.rb` | 11 runs, 32 assertions, 0 failures, 1 `Errno::EPERM` on loopback fixture bind; environment-known red |
| `ruby -Itest test/agent_cli_mcp_test.rb` | 6 runs, 28 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_runtime_effects_test.rb` | 10 runs, 44 assertions, 0 failures, 0 errors, 0 skips |

The direct budget probe used the real CLI/worker fixture path and printed:

```text
events=["tamoz.worker.started", "tamoz.worker.request.claimed", "tamoz.worker.request.stopped", "tamoz.worker.stopped"]
model_calls=0
stops=[{"duration_ms"=>817, "reason"=>"budget_exhausted"}]
```

No real model, collector, network service, or full `rake ci`/`rake ci_full` run
was used. The loopback error is the sandbox restriction already recorded in the
audit checkpoint, not a product assertion.

## Findings

### CF12-OBS-01 — durable model-call signals disappear when settlement stops early or the effect is not successful

- **Severity:** minor
- **Confidence:** high
- **Status:** open
- **Source evidence:** `gems/tamoz-agent/lib/tamoz/agent/worker.rb:635-649` returns from the budget branch before `emit_durable_model_calls`; `worker.rb:1278-1288` selects only `:succeeded` effect-census rows; `worker.rb:1301-1320` requires a succeeded attempt before emitting `tamoz.model.call`; `gems/tamoz-observability/lib/tamoz/observability/catalog.rb:30-42` requires a model-call outcome and duration-capable signal.
- **Test/contract evidence:** the real CLI/worker probe above produced six successful model effects and zero `tamoz.model.call` journal entries when the model-call budget stopped settlement. `test/agent_observability_durability_test.rb` covers only a successful model-call projection; there is **not found** a worker test for a budget-stopped, failed, or unknown model effect projection.
- **Scanner signal:** source trace of `settle` ordering; no static scanner finding was required.
- **Independent judgment:** confirmed at the worker boundary. Durable receipts and the `request.stopped` event remain present, but `tamoz trace` and `observe metrics` cannot see the model work or its outcome for the stopped turn. The same filter excludes failed and unknown model effects by construction. This is bounded local evidence debt with limited immediate impact because the SQLite effect journal remains authoritative.
- **Root cause:** model-call projection was placed after the budget gate and was implemented as a success-only census projection; the worker has no shared terminal-outcome projection for all model effect states.
- **Recommendation:** at `Worker#settle`/`emit_durable_model_calls`, project the already committed model effect before returning from the budget branch and carry the terminal attempt outcome (including failed/unknown) into the existing `tamoz.model.call` signal. Reuse the effect record and current de-duplication set; do not add a second journal.
- **Disposition:** accepted as a new CF12 minor; F15/F16 exporter and projection findings remain separate owners.

### Carried-forward findings and overlap decisions

| Finding | Current status | CF12 treatment |
|---|---|---|
| F15-SEC-01 | major / open | Carries the plain-string secret path in worker error reasons; no duplicate count. |
| F15-OBS-01, F15-OBS-02 | minor / open | Carry metrics loss and flat/divergence-empty trace projection; CF12-OBS-01 is the upstream durable-worker omission. |
| F15-COR-01, F15-SCAL-01, F15-SCAL-02 | minor / open | Carry recorder key, cardinality, and mutex-boundary defects; no new count. |
| F16-SEC-01 | minor / open | Carries the unwired adapter/documentation gap. |
| F16-SEC-02, F16-OBS-01 | major / open | Carry exporter policy-digest/content and export-outcome omissions at the OTel seam; no duplicate count. |
| F16-REL-01, F16-COR-01, F16-MNT-01, F16-COR-02 | minor/info / open | Carry async deadline, OTLP typing, conformance, and `gen_ai` documentation gaps. |

## Blind spots

- No real OTLP collector or TLS endpoint was contacted. The adapter's direct
  tests and source policy were reviewed, but the production enable path remains
  absent as recorded under F16.
- A failed/unknown model-effect worker run was not constructed end to end in
  this pass; the exclusion is directly visible in the source filter, while the
  budget-stop omission was reproduced through the real CLI fixture path.
- The interactive durable `ask --session` and one-shot `tamoz TASK` paths do not
  construct the worker's journal recorder (`cli.rb:171-190`,
  `cli.rb:579-614`). Whether those surfaces should produce the same journal is an
  owner contract question; this report does not promote it without a stated
  requirement and a dedicated probe.
- No sustained-load measurement was taken for the reserved lane, exporter
  queue, or 10,000-row census. The component reports retain those evidence gaps.
- Full `rake ci` and `rake ci_full` were not run; the loopback fixture error is
  environment-bound and remains known red.

## Verdict

**IMPROVE.** The six lenses and the end-to-end source trace are complete. CF12
adds one accepted minor finding (`CF12-OBS-01`); the flow also carries the open
F15/F16 major findings at their existing seams, so it cannot be called PASS.
Machine counts for this flow are `critical=0`, `major=0`, `minor=1`, `info=0`;
carried findings are excluded from those counts to avoid double-counting.
