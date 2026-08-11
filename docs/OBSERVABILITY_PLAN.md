# Observability: implementation plan

Sequencing for [`OBSERVABILITY_DESIGN.md`](OBSERVABILITY_DESIGN.md), graded against
[`OBSERVABILITY_BAR.md`](OBSERVABILITY_BAR.md).

Status: proposed. Nothing here is authorized until clauses 59–61 and ADR-044–047 are
accepted. This plan assumes the current working tree, in which the instrumentation plane has
no producers and the observability level is L1.

## 1. Scope commitment

Four phases, each ending at a level the bar defines and each independently shippable.

| Phase | Delivers | Level reached |
|---|---|---|
| 1 | Catalog, correlation, recorder, journal, first producers | L2 |
| 2 | Content policy and model usage accounting | L2 + Q3 |
| 3 | Reconstruction, derived gauges, streamed instruments | L3 |
| 4 | Export, egress hardening, golden signals, self-test | L4 |
| 5 | Alerting and routed automated response (design §18) | L4 + response |

A phase that cannot pass its own conformance rows does not advance; it is fixed or its scope
is cut, and the level it forfeits is recorded in `LIMITATIONS.md`.

**Phase 5 is separately authorized.** It carries its own clause 62 and ADR-048, it depends on
phase 3's derived gauges existing (nothing may act on a streamed instrument), and phases 1–4
are complete and shippable without it. Accepting phases 1–4 is not accepting phase 5.

## 2. Prerequisite decisions (blocking, before slice A)

Revised after the design review
([`reviews/OBSERVABILITY_DESIGN_REVIEW.md`](reviews/OBSERVABILITY_DESIGN_REVIEW.md)). Item 2
was moot as written; item 3 is materially larger than revision 1 claimed; items 6 and 7 are new.

1. **Accept clauses 59–61 and ADR-044–047**, and regenerate
   `docs/requirements-manifest.json` and `docs/REQUIREMENTS_AUDIT.md`.
   `test/documentation_test.rb` pins the counts at 1–58 and ADR-001–043; the counts move
   deliberately or the work does not start.
2. **Confirm the `Instrumentation` ordering fix.** `Immutable.copy` already rejects `Secret`
   and bounds payloads; the change is to run it **after** the notifier check so instrumentation
   cannot raise into a caller with observability disabled, and to apply telemetry bounds rather
   than state bounds. This is a bug fix in a shipped seam, and it changes behavior for any
   existing caller that passes a malformed payload with a null notifier. Still a core change
   under the ask-first rule, but a smaller and better-justified one.
3. **Decide the model-usage persistence prerequisite** (design §10). It is not an observability
   change. It requires a `Model` protocol change across six implementations, `MIGRATION_7`, and
   a `CURRENT_VERSION` bump after which an older Tamoz binary **hard-refuses** a migrated
   database. **If refused**, spend becomes lossy telemetry, criterion D1 is not met,
   `LIMITATIONS.md:126` stays as written, and phase 2 loses its cost half. Both branches are
   legitimate; the decision must be made rather than discovered.
4. **Confirm OTLP/HTTP with JSON encoding is sufficient** for the intended collectors, or accept
   that a sidecar collector is required (design §25).
5. **Name the first real consumer.** Phase 4's export has none until an operator deployment or
   the release rehearsal claims it; phases 1–3 are consumed by `tamoz status`, `tamoz trace` and
   the scorecard, which is sufficient to start.
6. **Approve a read-only open path in `tamoz-sqlite`** (design §6.7). `Adapter` has no read-only
   mode and constructs a `Migrator` whose `verify_connection!` raises on a `user_version`
   mismatch. Without this, `tamoz trace` opens the runtime database read-write from a second
   process. Prerequisite work in `tamoz-sqlite`, not in an observability gem.
7. **Decide whether `tamoz status` is refactored onto `TelemetryReader`** (design §11). If yes,
   derived gauges and `tamoz status` agree by construction. If no, the guarantee downgrades to a
   golden equality test and the plan says so rather than claiming the stronger property.

## 3. Slices

### Slice A — the ordering fix and the catalog

- `Tamoz::Instrumentation`: move `Immutable.copy` behind the notifier check; apply telemetry
  bounds; keep name normalization. Add the regression test that a malformed payload under a
  null notifier does not raise — the clause 59 case that fails today.
- `tamoz-observability` skeleton: gemspec depending on `tamoz-core` only, `SignalCatalog`,
  `Signal` (with the `timing` discriminator), `Correlation`, `SCHEMA_VERSION`, and the
  `Recorder` module contract.
- The catalog is seeded from the names existing designs already specify: the worker's
  `request.*` (with `occurrence_id` correctly named), `COMMS_DESIGN` §16's `comms.*`, and
  `M4_PLAN` §13's model and tool events — **minus TTFT**, which is unobtainable on a
  non-streaming model path. Each entry declares `safety_bearing` and its `correlation` keys.
- Joins `Gemfile`, `Rakefile`'s load-path list, `test/packaging_test.rb`'s gem list,
  `test/dependency_isolation_test.rb`, and `docs/public-api.json`.

Exit: the ordering regression test passes; the catalog rejects an unregistered name, an
attribute-set change without a version bump, and a metric declaring a correlation identifier as
a label.

### Slice B — recorder, journal, and the non-interference proof

- `Recorder::Null`, `Recorder::Journal`, `Recorder::Fanout`; guarded invocation so nothing
  raises into a caller; `health` and `flush`.
- **Two lanes** (design §6.4): a small reserved lane for `safety_bearing: true` entries that is
  never dropped and falls back to a bounded synchronous journal write, and a bulk lane with
  drop-newest counted by name and reason. The reserved set and the immediate-flush set are one
  catalog flag, so they cannot drift apart.
- `Signal`-shaped NDJSON journal in the runtime directory, **one file per process role and
  pid**, with rotation, size and file-count caps and the 0700 permission assertion. A separate
  renderer preserves the worker's current stdout `--json` bytes over the same signals.
- The two-tier flush policy (design §16.2): ordinary signals batch to `flush_interval_ms`;
  terminal, approval and safety-bearing signals flush immediately. This is what makes
  `--follow` latency a bound rather than a hope, so it belongs with the journal, not with
  the CLI slice that consumes it.
- `tamoz observe tail [--follow]` following the role-prefix glob, tracking inodes, merging by
  `observed_at_ms`, with explicit gap markers on reader lag, filters, and a readable renderer.
- The **four**-way byte-identity test (observed / unobserved / raising recorder / malformed
  payload under a null notifier) lands **here**, before any producer exists, so every later
  slice is added against a passing C1 gate rather than retrofitted into one.

Exit: C1, C3, C4 pass with bounded memory in both lanes and zero reserved-lane drops; the
journal survives a disk-full fixture by disabling itself; a follower paused past a rotation
reports a counted gap rather than skipping.

### Slice C — first producers

- `tamoz-sqlite`: commit latency, `SQLITE_BUSY` retries, lease acquired/waited/lost. The
  adapter already accepts and validates a notifier
  ([`adapter.rb:65`](../gems/tamoz-sqlite/lib/tamoz/sqlite/adapter.rb)), so this is call
  sites only.
- `tamoz-graph`: run, task, barrier commit, interrupt, resume.
- `tamoz-agent`: turn, plan, review, approval, tool call, effect, verify, stop; the worker's
  `emit` becomes a catalog producer, with its current stdout NDJSON preserved byte-compatibly.
  Its `request_id` field is renamed `occurrence_id` in the catalog, because that is what it
  holds ([`worker.rb:221`](../gems/tamoz-agent/lib/tamoz/agent/worker.rb)).
- **Each layer carries its declared spine, not a uniform one** (design §6.2). Agent and graph
  sites carry thread/execution/request/namespace/task; `tamoz-sqlite` carries
  thread/namespace/fence/sequence because the adapter never receives a `Context`; core
  self-observation carries process identity only.

Exit: A1's cross-gem registry gate passes over the whole repository; the recorder rejects a
signal missing a declared correlation key in strict mode; a completed turn is readable end to
end from the journal.

### Slice D — content policy

- `ContentPolicy` value, content-addressed, all classes off by default, per-class byte
  bounds, classification gate refusing capture for `restricted` at load.
- Content digest and size emitted whenever a class is off.
- Policy digest recorded on every signal.

Exit: B2, B3, B4 pass; enabling one class leaks exactly one class.

### Slice E — model usage and cost

**Gated on prerequisite 3.** Two sub-slices with different owners, and the first is not
observability work.

**E1 — persistence (owned by `tamoz-agent` + `tamoz-sqlite`, separately reviewed):**

- `Model` protocol change so `generate` returns text plus usage. Six implementations:
  `RubyLLMModel` (currently ends `.ask(prompt).content`, discarding the `RubyLLM::Message`),
  `WorkerRuntime::DeferredModel`, `Memory::Consolidation`, the CLI's dummy models, and the
  evals harness fixtures.
- The next migration ordinal adding a bounded usage column, plus the `CURRENT_VERSION` bump and
  its release note: an older Tamoz binary refuses a migrated database. Read the ordinal from
  `migrator.rb` when the slice starts — comms landed `MIGRATION_6` while this design was under
  review, so it is not a number to reserve in advance.
- **Not** the attempt `result` blob — that changes the receipt's `result_digest`, which is
  observation altering a durable record.

**E2 — observability (this plan):**

- `nil` for providers that report nothing — never zero, never an estimate.
- Cost values carry `{basis, pricing_source, pricing_version}`; the price table is
  operator-supplied and pinned by digest. No bundled prices.
- **No TTFT.** `.ask` is a single non-streaming call, so it would equal duration.

Exit: D2 passes unconditionally; D1 passes only if E1 landed. If prerequisite 3 was refused,
record D1 as not met in `LIMITATIONS.md` and continue — the rest of phase 2 is unaffected.

**Follow-on, not in this plan:** with usage durable and attributed,
`WorkerRuntime#budget_usage` can compute `input_tokens`, `output_tokens` and `steps` from the
census it already reads, making three recorded-only budgets enforceable and retiring part of
[`LIMITATIONS.md:126`](LIMITATIONS.md). That is a budget slice with its own review.

### Slice F — reconstruction

Ordered so the read-only path exists before anything reads.

1. **Read-only adapter path in `tamoz-sqlite`** (prerequisite 6): `SQLITE_OPEN_READONLY`, with
   migration verification made read-only rather than skipped.
2. `TelemetryReader` structural contract in `tamoz-observability`; read-only implementation in
   `tamoz-sqlite` in an explicitly loaded file, adding no table and no migration.
   `checkpoint_records` returns **`status`** — without it there is no pause interval, because
   `tamoz_requests` has no paused state. `effect_records` filters by **execution**, not request.
   `store_records` exposes the Store-backed operator records the gauges need.
3. **The interval skeleton** from the reader: `turn`, `pause`, `model.call`, `tool.call`,
   `effect`, `checkpoint.commit`.
4. **Ordering-only spans** decorated by `tamoz-agent`, which owns the `SessionRecords` codec —
   `plan`, `review`, `verify`, `step`, `memory.retrieve`, each marked `timing: :ordering_only`
   with `duration_ms: nil` and a `committed_at_ms` bound. `tamoz-sqlite` never decodes the
   payload; that would invert the dependency.
5. `tamoz trace THREAD [--execution ID] [--session-dir DIR] [--follow] [--format …]`, plus
   `tamoz status --watch` and `tamoz observe tail --with-status`. `--session-dir` exists because
   the interactive CLI writes one database per thread; reconstruction refuses to guess a layout.
6. The reconciliation rule and `tamoz.telemetry.divergence`, which works because both sides
   compute the same per-kind span anchors.

Exit: A4 passes, including a resume **through an approval decision** and a fork, and identical
trace ids recomputed from a restored backup. A2 and A3 pass at their re-graded partial scope,
with every ordering-only span marked rather than given a fabricated duration.

### Slice G — metrics

- Derived gauges computed behind `TelemetryReader`. Per prerequisite 7: either the census
  derivation moves into `tamoz-sqlite` and `tamoz status` is refactored onto it in this slice
  — the two then agree by construction — or a golden test asserts equality and the design says
  so. Revision 1's "shared code path" was impossible: `build_status` lives in `tamoz-agent`,
  which `tamoz-observability` cannot depend on.
- Streamed instruments with catalog-declared label keys, the low-cardinality value pattern,
  and the correlation-id label denylist.
- `tamoz observe metrics [--format prometheus|json]`.

Exit: D3 passes; fuzzing label values produces counted violations, never emitted series.

### Slice H — sampling

Revision 1 specified a per-turn in-memory buffer. It is deleted: its own retention list led
with the approval pause, the one case that outlives the process, so the interesting turn was
the one guaranteed to be lost on restart. **The journal is the buffer.**

- The journal records everything, unsampled. There is no configuration below the
  safety-bearing floor.
- **Export samples when the exporter reads the journal**, by which time the turn's outcome is
  known — real tail sampling with no in-memory window and no restart hazard.
- Per-turn deterministic decision from the trace id, so every observer agrees.
- Forced export for turns that paused, stopped safely, failed, denied a tool, produced an
  `:unknown` effect, exhausted a budget or triggered a repair.
- Safety-bearing names exempt from sampling in both destinations.

Exit: at a 1% export rate every interesting turn is still fully explainable, `--follow` still
shows every turn, and a turn paused across a process restart is still exported.

### Slice I — `tamoz-otel` and egress

- OTLP over HTTP with JSON encoding on stdlib `net/http`; `gen_ai` attribute mapping.
- Egress rules reusing the websearch precedent: exact host, https only, no redirects, no
  proxy environment, TLS verification and SNI, private and loopback rejection unless
  `allow_local`, bounded bodies, deadlines, credential by `credential_ref` name.
- Exporter thread, bounded batches, deadline, backoff, self-disable after N failures.
- `--offline` mode and `tamoz observe export`.

Exit: B5 and C2 pass against a hostile-collector fixture.

### Slice J — operator surface and evidence

- `tamoz observe doctor` including the redaction self-test.
- `tamoz status` gains its `observability` section.
- The golden-signal table in design §17, each condition reproduced by a fault-injection test.
- Scorecard cases 17–20.
- Observed/unobserved benchmark published in `docs/BENCHMARK.md`.
- `docs/OPERATIONS.md` §Observability rewritten: it currently describes `--json` as emitting
  an event for every plan, review, approval, tool call and receipt, which is true of the
  interactive CLI's stream parts and not of the worker's event stream.

Exit: E3 and E4 pass; the audit in `OBSERVABILITY_BAR.md` §7 is regenerated and shows L4.

### Slice K — alerting (phase 5, separately authorized)

Blocked on clause 62 and ADR-048, and on phase 3. Ordered so that each tier is proven before
the next is built, because each grants strictly more authority than the one above it.

1. **Rules and evaluation.** Content-addressed versioned rule values; mandatory `for:` and
   clear thresholds; derived-identity deduplication; durable expiring silences; the
   `degraded` window label from design §18.1. `tamoz observe watch [--once]` in the
   connector-zone shape, holding no model credential, toolbox or workspace.
2. **Notify.** stderr, file, exit code, and a `comms` `:control` delivery on an existing
   surface. No new egress path.
3. **Gate.** A condition source for the existing `Tamoz::Circuit`. No new record type and no
   new transition rules — observability supplies the number, the circuit owns the decision
   and the operator owns the reset.
4. **Ask.** The evaluator as a request surface: derived request id from rule identity and
   window, bound profile, task string only. Conformance is invariant 56's existing suite
   applied to a new surface.
5. **Remediate.** A typed failure source feeding the healing registry, mapping a threshold
   crossing to `resource_exhausted` / `dependency_unavailable` / `verification_failed`, with
   below-confidence classifications routed to escalation. No new remediation forms; existing
   rules gain a new trigger. Any action with an external effect uses the derived
   `effect_key` of design §18.3 and is journaled.

Exit: an alert cannot fire from a streamed instrument; an alert cannot fire from a `degraded`
window; a flapping condition across a watcher restart produces exactly one external effect;
`headless_auto_approvals` and every authority-widening counter stay at zero throughout.

## 4. Tests, by the criterion or clause they defend

| Clause / criterion | Test shape |
|---|---|
| 59 / C1 | One fixture turn observed, unobserved, with a raising recorder, **and with a malformed payload under a null notifier**; byte-identical checkpoints, identical model-facing message order, and no raise into the caller in any case |
| 59 / C2 | A collector that accepts and never responds; turn latency within noise, drops monotonic |
| 59 / C4 | Maximum emission rate with no consumer over a sustained window; bounded RSS in **both** lanes, monotonic bulk drops, **zero reserved-lane drops** |
| 59 / §16 | A follower attached, detached, paused past a rotation, and reading from a full disk; turn latency and committed bytes unchanged in every case, and the paused follower reports a counted gap rather than skipping |
| §16.2 | An approval-required turn watched with `--follow`; the approval line appears within the immediate-flush bound, not on the next batch |
| 60 / B1 | Property test over `Tamoz::Secret` and credential shapes across events, spans, labels, journal lines, exception text and the rendered export body — extends invariant 24's existing property test |
| 60 / B2–B4 | Each content class enabled in turn; `restricted` refuses at load; digest and size stable when off |
| 61 / A4 | Duplicate request, `kill -9`, **resume through an approval decision**, fork, and restore-from-backup; one reproducible trace id per execution, a parent link across the fork, attempt-anchored sibling spans. This is the test revision 1 would have failed |
| 61 / A3 | Reconstruct a thread paused across a process restart; one root, no orphans, a `pause` interval from checkpoint status, and every ordering-only span marked rather than given a duration |
| 61 / A2 | Each layer emits its declared spine; the recorder rejects a signal missing a required correlation key in strict mode; store and lease signals join a trace by `(thread, namespace, sequence)` at reconstruction |
| 61 / P3 | Derived gauges equal `tamoz status`'s counters for the same database — by construction if prerequisite 7 chose the refactor, by golden test otherwise |
| A1 | Repository-wide enumeration of every `Tamoz.instrument` name; unregistered names, silent schema changes, undeclared metric labels, and missing declared correlation keys all fail. Requires every call site to use a literal name — the gate enforces that rather than assuming it |
| B5 | Redirect to loopback, hanging server, oversized response, untrusted certificate — each refused and counted |
| D1, D2 | Scripted provider fixture; exact accounting, `nil` when unreported, basis and pricing source on every cost. **D1 runs only if prerequisite 3 was accepted** |
| D3 | Label-value fuzzing; counted violations, no emitted series |
| dependency rules 1/5/8/9 | Isolated `GEM_HOME` install per gem; `tamoz-observability` with only `tamoz-core`; `tamoz-otel` with only `tamoz-observability`; a minimal boot loads no HTTP client and no exporter |
| 62 (phase 5) | Attempt to trigger every tier from a streamed instrument and from a window with non-zero drops; both refused and recorded. Flap a condition across a watcher restart and a `kill -9`; exactly one external effect exists, keyed by rule identity and window |
| 62 (phase 5) | Attempt, from a rule, to approve an interrupt, widen a budget, add an allowlist entry, and run a command; each is refused at load, and the safety counters stay zero |

Both new gems join `test/packaging_test.rb`'s gem list and the isolated-install proof.

## 5. Stop / redesign criteria

Reasons to stop and rethink rather than push through:

1. **C1 cannot be made to pass.** If committed bytes differ with observation enabled, the
   producer placement is wrong — usually because a signal was emitted inside a transaction or
   a barrier. Move the call site; do not weaken the test.
2. **The catalog gate becomes a formality.** If names are being registered to satisfy CI
   rather than because they answer a question in bar §2, the catalog is growing into noise.
3. **Reconstruction needs schema it does not have.** Already true for deliberation timing, and
   handled by marking those spans ordering-only (design §7). If it becomes true for something
   that cannot be marked — an ordering that cannot be recovered, or a parent that cannot be
   resolved — that is a persistence change with its own review, not a place to interpolate.
   Revision 1 failed here by asserting a complete interval tree; the check is now explicit.
4. **Content capture is requested "just for debugging".** The first such request is the test
   of ADR-046. The answer is a named policy with bounds and a classification gate, or no.
5. **The exporter needs the official SDK.** If a real consumer requires protobuf or gRPC,
   stop and design `tamoz-otel-sdk` as a separate gem rather than pulling the SDK into the
   process holding the model credential.
6. **A design claim cannot be verified against the code.** Revision 1 asserted six things about
   this repository that were not true, including a core change that already existed. Before a
   slice starts, its claims about existing schema, protocols and call-site scope are checked at
   source. A claim that cannot be checked is not a plan step.

## 6. Definition of done

- Clauses 59–61 and ADR-044–047 accepted; manifest and requirements audit regenerated.
- `tamoz-observability` and `tamoz-otel` published, each passing the isolated-install proof.
- A completed turn, a crashed-and-resumed turn, **a turn resumed through an approval decision**,
  and a forked turn are each one trace, explainable from `tamoz trace` alone — ordering,
  parentage and outcome complete, durations present wherever the durable record carries them and
  marked absent where it does not.
- `Tamoz.instrument` cannot raise into a caller under any payload or notifier.
- With the default policy, no prompt, tool argument, tool result or plan text appears in the
  journal or the export body, while content digests still prove two runs saw identical input.
- A hostile collector changes neither turn outcome nor latency, and every loss is counted; no
  safety-bearing signal is ever among the losses.
- Cost carries basis and pricing source. Usage is durable **if prerequisite 3 was accepted**;
  otherwise D1 is recorded as not met in `LIMITATIONS.md`.
- `tamoz observe doctor` proves redaction on the operator's own machine.
- `OBSERVABILITY_BAR.md` §7 regenerated, and the design's §22 grade — 14 met, 3 partial, 1
  conditional — either holds or has improved. **A restored 18/18 is a signal to re-audit, not a
  success**: that was revision 1's grade, and it was wrong.
