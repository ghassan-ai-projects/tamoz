# Observability

A signal plane for Tamoz that explains a turn, measures what it cost, proves what it did
not do, and cannot change what it does.

Status: reviewed proposal, revision 2. Not implemented. The acceptance criteria are in
[`OBSERVABILITY_BAR.md`](OBSERVABILITY_BAR.md); §22 grades this design against all eighteen
of them, honestly, including the two it no longer claims to meet. The implementation plan is
[`OBSERVABILITY_PLAN.md`](OBSERVABILITY_PLAN.md).

**Revision 2** exists because an adversarial review
([`reviews/OBSERVABILITY_DESIGN_REVIEW.md`](reviews/OBSERVABILITY_DESIGN_REVIEW.md)) found
six critical defects in revision 1, four of them in its central idea. What changed:

| Was | Is | Why |
|---|---|---|
| `trace_id` keyed on `(thread_id, request_id)` | keyed on `(thread_id, execution_id)` | A resume after an approval gets a *new* request id, so a paused turn split into two traces |
| `approval.wait` derived from request transitions | derived from checkpoint `status='paused'` | `tamoz_requests` has no paused status; the request completes while the session pauses |
| Every span an interval | **interval spans and ordering-only spans**, separated | `plan`, `review`, `verify`, `step` are records inside the checkpoint payload and carry no timestamps |
| `span_id` from `activation_id`/`attempt_id`/`call_index` | per-kind durable anchors | `attempt_id` is not in scope at emission sites, and four reviews per plan attempt collided |
| Core gains a `Secret` guard | Core already has one; the **bug** is that it can raise with observation disabled | Verified by execution — see §1 |
| Model usage recorded "with no new table" | A named persistence prerequisite with a priced migration | There is no column to write it to, and the alternative changes a durable receipt digest |
| Per-turn tail-sampling buffer | Journal everything, sample only export | The buffer's own retention list led with the case that outlives the process |
| One recorder queue, drop-newest | Reserved lane for safety-bearing signals | Drop-newest discarded safety signals exactly when the system was loudest |

## 1. Decision

Observability ships as **two gems**:

| Gem | Responsibility | Runtime dependencies |
|---|---|---|
| `tamoz-observability` | The closed signal catalog and its schema version, correlation derivation, content/redaction policy, the `Recorder` and `Exporter` seams, trace reconstruction, derived metrics, and the bounded local journal | `tamoz-core` |
| `tamoz-otel` | One conforming exporter: OTLP over HTTP with JSON encoding, and the OpenTelemetry `gen_ai` attribute mapping | `tamoz-observability`, stdlib |

Integration changes, stated precisely:

- **`tamoz-core`** gains one **corrective** change, not a new guard. `Instrumentation.instrument`
  already rejects `Tamoz::Secret` and bounds payloads, because line 12 calls `Immutable.copy`,
  whose defaults are `reject_sensitive: true`, `max_depth: 64`,
  `max_collection_items: 100_000`, `max_string_bytes: 1_048_576`
  ([`immutable.rb:5-31`](../gems/tamoz-core/lib/tamoz/immutable.rb)). Verified by execution:

  ```text
  $ rbenv exec ruby -Igems/tamoz-core/lib -e '…instrument("tamoz.test", {a: Secret.new("x")}, context: nil)…'
  RAISED: Tamoz::SensitiveValueError: $.a: Tamoz::Secret is not permitted
  ```

  The defect is the **ordering**: the copy runs at
  [`instrumentation.rb:12`](../gems/tamoz-core/lib/tamoz/instrumentation.rb), *before* the
  notifier check at line 13. A payload defect therefore raises into a caller that has no
  observability configured at all — which already violates the clause 59 this design
  proposes. v2's core change is to move the copy behind the notifier check and apply
  telemetry-appropriate bounds; a 1 MiB string is a state bound, not a signal bound.
- **`tamoz-graph`, `tamoz-sqlite`, `tamoz-agent`** gain **call sites only** — `Tamoz.instrument`
  with a registered name and a metadata payload carrying its declared correlation keys (§6.2).
  They gain no dependency on `tamoz-observability`: the emitter names, the recorder validates.
- **`tamoz-agent`** loads `tamoz-observability` lazily, only when a runtime directory
  configures observability. An installation without it runs unchanged and reports a typed
  missing-adapter error for `tamoz observe` and `tamoz trace`.
- **`tamoz-sqlite`** implements a **read-only** structural reader contract in an explicitly
  loaded file, without referencing `tamoz-observability` constants — dependency rule 9, the
  same shape as `StreamStore`. It also gains a genuine read-only open path, which does not
  exist today (§6.7).

**The observability gems add no durable table, no migration and no writer.** Revision 1
carved out an exception for model usage; v2 removes the carve-out by moving usage capture to
a named persistence prerequisite that observability *consumes* rather than owns (§10).

## 2. Three planes, and why this is the third

[`design-v0.1/ARCHITECTURE.md`](design-v0.1/ARCHITECTURE.md) §7 already names the split.
This design implements the plane that is currently empty.

| Plane | Meaning | Failure if it is dropped | Owner |
|---|---|---|---|
| **State** | Checkpoints, requests, effects, decisions | Correctness is lost | `tamoz-graph` / `tamoz-sqlite` |
| **Stream** | Bounded `StreamPart` projection of one run, consumer-facing, backpressuring | A consumer sees less progress detail | `tamoz-core` / `tamoz-graph` |
| **Instrumentation** | Observer-only signals: events, spans, measurements | **Nothing** | `tamoz-observability` |

The third row is the definition, not a disclaimer. If dropping every signal can change any
committed byte, the plane has been built wrong.

**Why not just use the stream.** Because it is the wrong shape and the project already said
so: [`CORE_DESIGN.md`](design-v0.1/CORE_DESIGN.md) §3 states that "a surface that wants
lossy telemetry uses instrumentation, not the stream". The stream applies backpressure by
contract (invariant 15), which is correct for a consumer rendering a run and wrong for a log
pipeline — a slow reader of telemetry would slow the agent. Today `--json` renders stream
parts and is the only lifecycle signal an operator gets, so the project is currently running
the failure mode its own design document warns about.

**Why not just read the durable record.** Because it answers "what happened" and cannot
answer "what is happening", and because it records decisions rather than durations. It does
not know that a provider call took nine seconds, that a lease was contended for four hundred
milliseconds, or that the store retried on `SQLITE_BUSY` eleven times.

**So the design uses both, with an explicit authority rule** (§9): the live signal stream is
a projection and may be lossy; the reconstructed trace is derived from the durable record and
is authoritative. Where they disagree, the durable one wins, and the disagreement is itself a
counted signal.

## 3. Why two gems

1. **Why a gem at all, rather than code in `tamoz-agent`?**
   [`ARCHITECTURE.md`](design-v0.1/ARCHITECTURE.md) §1 already assigns the answer:
   "channel, vector-store, and observability adapters — separate gems with their own owners."
   Beyond precedent, the signal catalog spans every gem — `tamoz-graph` emits barrier events,
   `tamoz-sqlite` emits commit latency, `tamoz-agent` emits plan and model events. A catalog
   living in the topmost consumer cannot be the contract for the layers below it.
2. **Why not one gem containing the exporter?** Because then the exporter seam is never tested
   as a seam. `tamoz-stream`'s simulated connector implements exactly the connector contract;
   `tamoz-observability` conformance must likewise run against an in-memory recorder with no
   network at all, and `tamoz-otel` must be one implementation that passes it. It is also what
   keeps rule 5 provable: a minimal boot loads no HTTP client.
3. **Why not a plugin API for exporters?** ADR-014 rejected plugin APIs and the argument is
   unchanged. The exporter list is closed in `tamoz-observability`, like
   `RuntimeDirectory::KNOWN_SOURCES`. Adding a vendor's native protocol means editing that
   list and shipping a gem. The cost — a release per exporter — is accepted.
4. **Why does the exporter depend only on stdlib?** OTLP over HTTP has a specified JSON
   encoding, and `net/http`, `json` and `openssl` cover it. The official `opentelemetry-sdk`
   gem would bring a process-global `TracerProvider`, which is the mutable process-global
   runtime state dependency rule 6 forbids, plus a transitive tree into the process holding
   the model credential. The honest cost is in §25.

The lazy-load shape is modelled on `tamoz-telegram`
([`COMMS_DESIGN.md`](../documentation/design/comms.md) §1). That is a **proposed** package, not a shipped
mechanism — `gems/` contains `tamoz-comms` only — so this design inherits a pattern under
review, not a proven one.

**Rejected shape, and its cost:** one gem with a lazily required `tamoz/observability/otlp`.
One fewer gem to release, legitimate if release overhead becomes the binding constraint. It
gives up the exporter-seam conformance proof and weakens the dependency-isolation test.

## 4. Architecture

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ tamoz-core / tamoz-graph / tamoz-sqlite / tamoz-agent                   │
│   Tamoz.instrument("tamoz.model.call", {correlation:, …metadata})       │
│   metadata only · Secret rejected · payload bounded · frozen            │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ Notifier protocol — name + payload, no Context (§6.2)
┌───────────────────────────────▼─────────────────────────────────────────┐
│ Recorder                            OBSERVER ZONE                       │
│ catalog check → correlation validate → content policy → lane select     │
│ reserved lane (safety, never dropped) · bulk lane (drop-newest, counted)│
│ bounded, non-blocking, raises nothing into the caller                   │
└──────┬────────────────────────────────────┬─────────────────────────────┘
       │ always                             │ optional
┌──────▼───────────────────┐   ┌────────────▼────────────────────────────┐
│ journal (NDJSON, rotated)│   │ Exporter thread — bounded queue         │
│ runtime dir, 0700        │   │ OTLP/HTTP+JSON · deadline · backoff     │
│ every signal, unsampled  │   │ self-disables after repeated failure    │
└──────────────────────────┘   └─────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ Reconstruction — `tamoz trace`, `tamoz observe metrics`                 │
│ READ-ONLY open of the durable record; derives the authoritative span    │
│ tree and the derived gauges. Requires a read-only adapter path (§6.7).  │
└─────────────────────────────────────────────────────────────────────────┘
```

Two consumption paths, deliberately asymmetric:

- **Live** signals leave the process as produced. Allowed to be lossy; every loss counted.
- **Reconstructed** traces and derived gauges are computed on demand from storage. Never
  lossy, survive a crash that lost the live stream, reproducible months later from a backup.

### 4.1 Why no durable telemetry tables

1. **Writer contention.** The runtime database has one fenced writer per thread namespace
   (invariant 20) and SQLite has one writer per database. A telemetry writer would contend
   with the commit path for the lock that guards correctness — observation slowing, and under
   load failing, the thing it observes. A P1 violation reachable by construction.
2. **A second source of truth.** Two records of "what happened" diverge, and then an audit has
   to choose. `tamoz status` already establishes the answer: safety facts are derived.
3. **Retention.** Telemetry is high-volume and short-lived; checkpoints are low-volume and
   long-lived. One file makes pruning, backup, deletion receipts and invariant 54's purge
   rules answer to two conflicting policies.
4. **It is largely unnecessary.** The schema carries most of what reconstruction requires.
   `tamoz_checkpoints` carries `sequence`, `execution_id`, `fence`, **`status`** and
   `created_at_ms`; `tamoz_requests` and `tamoz_request_transitions` carry `created_at_ms`;
   `tamoz_effects` carries `created_at_ms`/`updated_at_ms`; and `tamoz_effect_attempts`
   carries `prepared_at_ms`, `started_at_ms` and `completed_at_ms`
   ([`migrator.rb`](../gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb)).

Point 4 is qualified deliberately. §7 shows exactly which spans this does and does not
supply, and revision 1's blanket claim that reconstruction produces a complete interval tree
was wrong.

## 5. Trust boundaries

| Zone | May receive | Must not receive |
|---|---|---|
| emission | ids, names, counts, durations, digests, typed status | `Tamoz::Secret` values — structurally rejected at `instrument` |
| recorder | metadata payloads plus, under a named policy, bounded content | unbounded payloads, unregistered names, high-cardinality labels |
| journal | redacted signals, in the 0700 runtime directory | raw provider payloads, workspace file contents |
| exporter | rendered `Signal` values only | model credential, toolbox, workspace, any file handle |
| collector (remote, untrusted) | whatever the content policy admitted | anything the policy did not admit — the boundary is the policy, not the collector |

**The exporter is an egress from the cognition zone.** It runs in the process holding the
model credential, which this design must not hide. Three mitigations, in order of strength:

1. It receives only immutable `Signal` values — no store handle, no file access, no context.
2. Its destination is fixed configuration under the 0700 runtime directory, with the egress
   rules the websearch capability already uses: exact host, https only, no redirects, no proxy
   environment, TLS verification and SNI, private/loopback rejection unless `allow_local` is
   declared for a sidecar collector, bounded bodies, and connect/write/read deadlines.
3. For deployments that refuse any outbound call from the cognition process, `--offline` is a
   first-class mode: the process writes only the journal, and `tamoz observe export` ships it
   from a separate invocation that never constructs a `Session`.

A code and credential boundary, not an OS security boundary. Production hardening should
sandbox the destination at the network layer.

## 6. Contracts

### 6.1 `SignalCatalog` — the closed, versioned surface

```ruby
# Illustrative
Catalog.event "tamoz.model.call",
  since: 1,
  stability: :stable,
  safety_bearing: false,
  correlation: %i[thread_id execution_id request_id task_id],
  required: {provider: :low_cardinality, model: :low_cardinality, outcome: :enum},
  optional: {
    duration_ms: :integer,
    input_tokens: :integer, output_tokens: :integer,
    cache_read_tokens: :integer, cache_write_tokens: :integer,
    request_digest: :digest, response_digest: :digest
  },
  content: %i[input_messages output_messages system_instructions]
```

`safety_bearing: true` is load-bearing in two places: those signals bypass sampling (§12) and
take the reserved recorder lane (§6.4). `correlation:` declares which spine keys this name
must carry, which is how §6.2's per-layer reduction stays checkable.

The catalog is the compatibility surface. Renaming a name, removing an attribute, or changing
a type requires a schema-version bump. `tamoz-evals` runs the cross-gem gate: every name any
gem passes to `Tamoz.instrument` must be registered, with a matching attribute set.

**Naming.** Framework signals use `tamoz.<area>.<noun>.<verb-or-state>`. Optional packages
keep their own already-specified prefixes — `comms.*` from
[`COMMS_DESIGN.md`](../documentation/design/comms.md) §16, and `stream.*`, `scheduler.*`, `mcp.*` — because
renaming a name another accepted design has already published would be a gratuitous break.
The catalog owns a closed list of permitted prefixes; both forms match the existing
`EVENT_NAME_PATTERN`.

### 6.2 `Correlation` — identity is derived, never generated

Revision 1 keyed traces on the request id. That was wrong, and the way it was wrong is worth
recording: **a resume after an approval decision is a new request**, derived as
`"decision-#{decision_id}"`
([`decision_record.rb:143`](../gems/tamoz-comms/lib/tamoz/comms/decision_record.rb)), so
every paused turn — the case §7 is built around — split into two unrelated traces.

The correct key is the one the architecture already defines as turn identity.
[`ARCHITECTURE.md`](design-v0.1/ARCHITECTURE.md) §8: `execution_id` is "stable across resume,
new across turns/forks". The code agrees: a new run mints one
([`compiled.rb:55`](../gems/tamoz-graph/lib/tamoz/graph/compiled.rb)), a resume reuses the
checkpoint's
([`durable_request_executor.rb:147`](../gems/tamoz-graph/lib/tamoz/graph/durable_request_executor.rb)),
and it is a column on `tamoz_checkpoints` and `tamoz_effects`.

```text
trace_id = sha256("tamoz.trace.v1\n" + canonical([thread_id, execution_id]))[0, 16]
```

Consequences, each a requirement elsewhere:

- **A resumed turn is one trace**, including across an approval that lasted days, because
  resume reuses the execution id.
- **A duplicated delivery is one trace.** Invariant 23 dedups before a run starts, so one
  execution exists and one trace id follows.
- **A fork is a new trace with a parent link.** Invariant 6 mints a new execution id on fork;
  `parent_trace_id` is derived from the parent checkpoint's execution id, so the relationship
  survives without conflating two histories.
- **Effects attribute correctly.** `tamoz_effects.execution_id` joins effects to the turn
  directly. Revision 1 tried to filter effects by request id, which is not a column, and the
  execution→request relation is one-to-many by design.
- **Traces are reproducible offline** from a backup, with no telemetry retained.

**Span identity uses a per-kind durable anchor.** Revision 1's single formula used
`activation_id`, `attempt_id` and `call_index`; `attempt_id` is not in `Context::ATTRIBUTES`
([`context.rb:13`](../gems/tamoz-core/lib/tamoz/context.rb)), `call_index` is an
effect-journal concept undefined for `plan` or `review`, and one plan attempt emits four
review records that would have collided on one id.

```text
span_id = sha256("tamoz.span.v1\n" + canonical([trace_id, kind, anchor]))[0, 8]
```

The anchor per kind is in §7's table. Every anchor is a value both the live emitter and the
reconstruction can compute from durable state, which is precisely what makes §9's
reconciliation possible.

**The spine is per-layer, because the notifier protocol carries no `Context`.**
`Notifier#instrument(name, payload)` takes two arguments
([`notifier.rb:6`](../gems/tamoz-core/lib/tamoz/notifier.rb)), and
`Instrumentation` calls it with exactly those
([`instrumentation.rb:27,52`](../gems/tamoz-core/lib/tamoz/instrumentation.rb)). Correlation
therefore travels **in the payload**, under a reserved `correlation:` key, populated by the
call site from what is actually in scope there:

| Layer | Spine available | Why |
|---|---|---|
| `tamoz-agent` node code, `tamoz-graph` | thread, execution, request, namespace, task | `RunCoordinator#invocation_context` builds the run context with the execution id ([`run_coordinator.rb:101`](../gems/tamoz-graph/lib/tamoz/graph/run_coordinator.rb)) and the executor propagates it per task |
| `tamoz-sqlite` | thread, namespace, fence, sequence | The adapter holds a bare `@notifier` and never receives a `Context` ([`adapter.rb:64`](../gems/tamoz-sqlite/lib/tamoz/sqlite/adapter.rb)) |
| `tamoz-core` self-observation | process and recorder identity only | No run in scope |

So A2 is a **validated** property, not a structural one: the catalog declares required
correlation keys per name and the recorder enforces them at runtime — strict (typed error) in
development and CI, drop-and-count in production. Store and lease signals join a trace by
`(thread_id, namespace, sequence)` at reconstruction time rather than by carrying an
execution id they do not have. Revision 1 claimed a structural guarantee it could not deliver
without changing the notifier protocol, which §1 promises not to do.

### 6.3 `Signal` — one immutable value, three kinds

```text
Signal
  kind           :event | :span | :measurement
  name           registered catalog name
  schema_version integer
  correlation    the per-layer spine above
  timing         :interval | :ordering_only | :point       ← new in v2
  time           started_at_ms, ended_at_ms (intervals only), observed_at_ms
  attributes     metadata only; bounded count, bounded value size, typed
  content        nil unless a policy admitted it; each field bounded and classed
  policy_digest  the content policy that governed this signal
  outcome        :ok | :error | :unknown, plus a typed error class when not :ok
```

`timing` exists because §7 cannot honestly produce durations for every span, and a consumer
must be able to tell "this took 0 ms" from "this has no measured duration".

### 6.4 `Recorder` — the seam every producer talks to

```ruby
module Tamoz
  module Observability
    module Recorder
      # Record one signal. MUST NOT raise. MUST NOT block beyond the declared
      # hand-off bound. Returns :recorded | :dropped.
      def record(signal) = raise NotImplementedError

      # Bounded snapshot: per-lane depth, drops by reason, export state, policy digest.
      def health = raise NotImplementedError

      # Flush within a deadline; returns what remains unflushed.
      def flush(deadline_ms:) = raise NotImplementedError
    end
  end
end
```

**Two lanes, not one.** Revision 1 specified a single bounded queue with drop-newest, which
discards safety-bearing signals exactly when the system is loudest — while §12 simultaneously
promised they are never sampled. v2:

| Lane | Holds | On saturation |
|---|---|---|
| reserved | catalog entries with `safety_bearing: true` | **never dropped**; the producer's hand-off blocks for a bounded microsecond budget, then the signal is written synchronously to the journal |
| bulk | everything else | drop-newest, counted by name and reason |

The reserved lane is small and its occupancy is bounded by the number of safety-bearing
events a turn can produce, which the catalog fixes. C4's bounded-memory proof covers both
lanes. The synchronous fallback is the one place a producer can wait, it is bounded, and it
writes to a local file rather than a network — a deliberate, priced exception to "never
block", because a dropped `tamoz.effect.unknown` is a false statement about safety.

Three implementations ship: `Null`, `Journal`, `Fanout`. Conformance drives all three against
a fixture that saturates both lanes, raises from the exporter, hangs the exporter, and emits
unregistered names.

**"MUST NOT raise" is enforced, not requested**, using the guarded shape
`Instrumentation.notify_with_guarded_block` already implements. LangChain's callback manager
is the precedent to avoid: its handlers carry a `raise_error` flag, and its own comments
record that async handler errors escape regardless
(`libs/core/langchain_core/callbacks/manager.py`).

### 6.5 `ContentPolicy` — capture is a decision, not a flag

```ruby
# Illustrative
ContentPolicy.new(
  name: "debug-tools",
  system_instructions: false,
  input_messages:      false,
  output_messages:     false,
  tool_arguments:      {enabled: true, max_bytes: 4_096},
  tool_results:        {enabled: true, max_bytes: 4_096},
  plan_text:           false,
  review_text:         false,
  error_detail:        {enabled: true, max_bytes: 2_048},
  max_classification:  :internal
)
```

- **Every class is off by default.** `ContentPolicy::NONE` is what an unconfigured runtime
  directory gets.
- **The policy is content-addressed**, and its digest is recorded on every signal it governed.
  A trace from last week states the policy that produced it.
- **Classification gates capture.** A profile classified `restricted` cannot enable any class;
  the configuration is refused at load, not ignored at emit.
- **Omission is represented.** Where a class is off, the signal carries `<class>_digest` and
  `<class>_bytes`. The default becomes a comparison tool rather than a blind spot: two runs can
  be proven to have sent the same prompt without the prompt leaving the machine, which is also
  how invariant 16's cache-epoch stability becomes observable.
- **`Tamoz::Secret` is never admissible.** No policy value enables it; the guard is in
  `tamoz-core`, above every policy decision.

### 6.6 `Exporter` — the adapter seam

```ruby
module Tamoz
  module Observability
    module Exporter
      def open(descriptor, credential) = raise NotImplementedError
      # @return [Result] :delivered | :rejected | :throttled(retry_after) | :unknown
      # MUST NOT raise; MUST NOT retry internally.
      def export(batch, deadline_ms:) = raise NotImplementedError
      def close(deadline_ms:) = raise NotImplementedError
    end
  end
end
```

Retry, backoff and self-disable belong to the recorder, so every exporter inherits one bounded
policy — the reason [`COMMS_DESIGN.md`](../documentation/design/comms.md) §10 refuses a second retry lifecycle
beside the effect journal.

An `:unknown` export result is **not** an incident. Unlike a channel delivery, a lost or
duplicated telemetry batch has no external consequence, so it is counted and forgotten. This
asymmetry is the clearest statement that the plane is not durable.

### 6.7 `TelemetryReader` — the read-only structural contract

Owned by `tamoz-observability`, implemented by `tamoz-sqlite` in an explicitly loaded file,
versioned, no reverse dependency — dependency rule 9.

```text
CONTRACT_VERSION = 1

  checkpoint_records(thread:, namespace:, execution: nil)
    → id, sequence, execution_id, parent_id, fence, status, created_at_ms
      status ∈ (running, paused, failed, completed)      ← the pause interval source

  turn_records(thread:, execution: nil)
    → request rows and transitions, ordered, with created_at_ms

  effect_records(thread:, execution: nil)
    → effects joined to attempts: effect_key, operation, safety, status,
      attempt_number, prepared_at_ms, started_at_ms, completed_at_ms

  decision_records(thread:, occurrence: nil)
    → actor kind/id, direction, interrupt digest, timing

  store_records(namespace:, limit:)
    → the Store-backed operator records: open occurrences, budget exhaustions, circuits

  census
    → open occurrences, blocked effects, lease state, inbox depth
```

Four corrections against revision 1:

1. **`checkpoint_records` returns `status`.** Without it there is no pause interval, because
   `tamoz_requests.status` is `('queued','claimed','running','redirecting','completed','failed')`
   — no paused state — and the worker documents why: the request *completed*; the session is
   paused ([`worker.rb:190`](../gems/tamoz-agent/lib/tamoz/agent/worker.rb)).
2. **Effects filter by execution, not request.** `tamoz_effects` has no `request_id`, and one
   execution legitimately spans several request rows.
3. **`store_records` exists** because several derived gauges are Store records, not tables:
   open occurrences live under `["tamoz","worker","occurrence"]`
   ([`worker_runtime.rb:163`](../gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb)) and
   circuits under `tamoz.circuit.<scope>`.
4. **A read-only open path is a prerequisite, not an assumption.** `Tamoz::SQLite::Adapter`
   has no read-only mode; `#initialize` prepares the database file and constructs a `Migrator`,
   and `Migrator.verify_connection!` raises unless `PRAGMA user_version` matches. A separate
   `tamoz trace` process would therefore open the runtime database read-write and run
   migration verification. v2 requires `SQLITE_OPEN_READONLY` with verification made read-only,
   and the plan lists it as blocking work in `tamoz-sqlite`.

Every method takes bounded pages and adds no table and no migration.

**Which database.** Reconstruction targets the worker's shared `runtime.sqlite3`. The
interactive CLI writes one database per thread at `<session_dir>/<thread_id>.sqlite3`
([`cli.rb:514`](../gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb)), so `tamoz trace` takes an
explicit `--session-dir` for that layout and refuses to guess. `tamoz observe metrics`
computes thread-wide gauges only for the shared layout, and says so rather than reporting a
partial census as a whole one.

## 7. The span tree

This section is the one revision 1 got most wrong, and the correction is the design's most
important honesty. **Not every span has a duration, and pretending otherwise would make the
reconstruction lie.**

`plan`, `review`, `verify` and `step` are not tables. They are `SessionRecords` inside the
checkpoint payload BLOB, and their schemas carry **no timestamps** — of the record types, only
`session` (`created_at_ms`) and `accepted_plan` (`accepted_at_ms`) carry time at all
([`session_records.rb`](../gems/tamoz-agent-session/lib/tamoz/agent/session_records.rb)). So spans
divide into three timing classes:

| Span | Anchor (feeds `span_id`) | Timing | Interval source |
|---|---|---|---|
| `turn` | `execution_id` | interval | first → last checkpoint `created_at_ms` for the execution |
| `pause` | paused checkpoint `sequence` | interval | paused checkpoint `created_at_ms` → next checkpoint `created_at_ms` |
| `model.call` | `(effect_key, attempt_number)` | interval | `prepared_at_ms` / `started_at_ms` / `completed_at_ms` |
| `tool.call` | `(effect_key, attempt_number)` | interval | same |
| `effect` | `(effect_key, attempt_number)` | interval | same |
| `checkpoint.commit` | checkpoint `sequence` | point | `created_at_ms` |
| `plan` | `(checkpoint sequence, plan_id)` | **ordering-only** | none; bounded by the committing checkpoint |
| `review` | `(checkpoint sequence, review_id)` | **ordering-only** | none |
| `verify` | `(checkpoint sequence, record index)` | **ordering-only** | none |
| `step` | `(checkpoint sequence, step_id)` | **ordering-only** | none |
| `memory.retrieve` | `(checkpoint sequence, record index)` | **ordering-only** | none |

An **ordering-only** span has a correct position in the tree, a correct parent, and a
`timing: :ordering_only` marker with `duration_ms: nil`. It is bounded above by the
`created_at_ms` of the checkpoint that committed it, and that bound is emitted as
`committed_at_ms` — a fact, not an interpolation.

**Is that enough?** For Q2 — "what happened in this turn, in order, and why" — yes: ordering,
parentage and outcome are what the question asks for, and every decision-bearing record has
them. For latency analysis of deliberation it is not, and the design does not claim it. What
is fully measured is exactly what costs money and time: every model call, every tool call,
every effect attempt, and every approval pause.

**Long-lived spans are reconstructed, never held.** An approval pause can last days and
outlive the process; holding an open span across it is how tracing agents leak memory and lose
traces on restart. `pause` exists only in the reconstructed tree, from the paused checkpoint
and its successor. The live plane emits a `tamoz.approval.requested` event and a
`tamoz.approval.decided` event and holds nothing.

That rule generalizes: **the live plane emits points; the reconstruction produces intervals.**
It is why C4's bounded memory is satisfied by construction — and why v2 deletes revision 1's
per-turn span buffer, which contradicted it (§12).

Note that `plan`, `review`, `verify` and `step` live inside the checkpoint payload, which
`checkpoint_records` deliberately does not return — exposing `tamoz-agent`'s record schema
inside `tamoz-sqlite` would invert the dependency. Reconstruction of those spans therefore
happens in `tamoz-agent`, which already owns the codec, and `tamoz trace` composes the two:
`tamoz-observability` builds the interval skeleton from the reader, `tamoz-agent` decorates it
with ordering-only spans from the payload it can decode. Stated here because it is the one
place the layering is non-obvious.

## 8. What each layer emits

| Layer | Signals | Spine |
|---|---|---|
| `tamoz-graph` | `tamoz.graph.run.*`, `tamoz.task.*`, `tamoz.barrier.commit`, `tamoz.interrupt.*`, `tamoz.resume.*` | full |
| `tamoz-sqlite` | `tamoz.store.commit`, `tamoz.store.busy_retry`, `tamoz.lease.acquired\|waited\|lost`, `tamoz.migration.*` | reduced (thread, namespace, fence, sequence) |
| `tamoz-agent` | `tamoz.turn.*`, `tamoz.plan.*`, `tamoz.review.*`, `tamoz.approval.*`, `tamoz.model.call`, `tamoz.tool.call`, `tamoz.effect.*`, `tamoz.verify.*`, `tamoz.memory.*`, `tamoz.stop.*` | full |
| `tamoz-core` | `tamoz.stream.sink.*`, `tamoz.telemetry.*` | process only |
| optional gems | `comms.*`, `stream.*`, `scheduler.*`, `mcp.*` | as their designs specify |

The worker's existing `request.completed|failed|paused`
([`worker.rb:515`](../gems/tamoz-agent/lib/tamoz/agent/worker.rb)) become registered names.
Their `request_id` field carries the **occurrence id** — the head request id at claim time
([`worker.rb:221`](../gems/tamoz-agent/lib/tamoz/agent/worker.rb)) — so the catalog names that
attribute `occurrence_id` and keeps `request_id` for the inbox row. Revision 1 would have put
an occurrence id in a field named `request_id`, which is the kind of thing that is discovered
two years later during an incident.

## 9. Live and reconstructed: the authority rule

| | Live signals | Reconstructed trace |
|---|---|---|
| Source | `Tamoz.instrument` call sites | the durable record |
| Latency | immediate | on demand |
| Lossy | bulk lane yes, reserved lane no | no |
| Survives crash | partially | fully |
| Survives backup/restore | no | yes |
| **Authority** | **projection** | **authoritative** |

`tamoz trace THREAD` produces the authoritative tree; `tamoz observe tail` shows the
projection. Reconciliation is possible precisely because both sides compute the same
`span_id` from the same durable anchors (§6.2). A span present in one and absent in the other,
or disagreeing on outcome, increments `tamoz.telemetry.divergence` with a reason class.

Divergence is expected and benign in one case — bulk-lane drops under load — and a defect in
every other, which is why it is measured rather than assumed away.

## 10. Cost and token accounting

[`LIMITATIONS.md:126`](../documentation/limitations.md) records that only `model_calls` and
`wall_clock_seconds` are enforced, because `WorkerRuntime#budget_usage` can compute only those
two ([`worker_runtime.rb:213`](../gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb)) while
`Profile::BUDGET_KEYS` also declares `cost_usd`, `input_tokens`, `output_tokens` and `steps`.
Closing that gap is the largest concrete win available here.

Revision 3 records the accepted model-call boundary. The kernel-owned
`ModelClientFactory` constructs the single `EpisodeModelTransport`, whose response is
projected into `{request_digest, content, response_digest, usage, settings_digest,
provider_configuration_digest}` before it enters a session or episode effect journal.
Usage therefore travels with the authoritative effect result and survives replay without a
second telemetry writer or a separate migration. Providers that do not report usage remain
unmeasured; the projection never fabricates zero values.

**What observability owns regardless:**

- Providers reporting no usage produce `tokens: nil` — never zero, never an estimate. A missing
  measurement is `unmeasured`, and a budget cannot be enforced from `unmeasured`.
- **Cost is always labeled** `{value, currency, basis: :estimated | :measured, pricing_source,
  pricing_version}`. Estimates come from an operator-supplied table pinned by digest; there is
  no bundled price list, because a stale one is a confidently wrong number. Hermes Agent's
  session store carries the same discriminator (`cost_status`, `cost_source`,
  `estimated_cost_usd`, `actual_cost_usd` in `agent/insights.py`) — comparative evidence that
  the distinction is needed in practice.

**Time to first token is dropped.** `.ask` is a single non-streaming call, so `ttft` would
equal `duration` and mean nothing. Revision 1 listed it in the catalog example, the span tree,
the metric set and D1's exact-match conformance. Obtaining a real TTFT requires streaming on
the model path — a change to the cognition hot path, which is a far larger claim than
"observability is observer-only". It is a non-goal until a streaming adapter exists.

## 11. Metrics

**Derived gauges** are computed from the durable record. They are the same numbers
`tamoz status` reports, and revision 1 promised they would "share the code path so the two can
never disagree" — which is impossible as stated, because `build_status` lives in `tamoz-agent`
([`cli_worker_commands.rb:261`](../gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb))
and `tamoz-observability` depends on `tamoz-core` only. v2's answer: **the census derivation
moves down into `tamoz-sqlite` behind `TelemetryReader`, and `tamoz status` is refactored onto
it in the same slice.** If that refactor is not done, "by construction" becomes "by a golden
test asserting equality", and the plan says which.

```text
tamoz.inbox.depth{status}                 tamoz.occurrence.oldest_age_ms{status}
tamoz.effect.blocked{operation}           tamoz.effect.unknown{operation}
tamoz.approval.pending{}                  tamoz.lease.held{}
tamoz.budget.exhaustions{budget}          tamoz.thread.tombstoned{}
```

**Streamed instruments** are updated from live signals and are lossy under saturation.

```text
tamoz.turn.duration_ms{outcome,profile,surface}      histogram
tamoz.plan.attempts{kind,outcome}                    counter
tamoz.review.rejected{reason_class}                  counter
tamoz.approval.wait_ms{outcome}                      histogram
tamoz.model.call.duration_ms{provider,model,outcome} histogram
tamoz.model.tokens{provider,model,kind}              counter
tamoz.model.cache.epoch_changed{reason}              counter
tamoz.tool.call.duration_ms{tool,source,outcome}     histogram
tamoz.tool.denied{tool,source,reason_class}          counter
tamoz.effect.attempts{operation,safety,outcome}      counter
tamoz.store.commit_ms{namespace_kind}                histogram
tamoz.store.busy_retries{}                           counter
tamoz.lease.wait_ms{}                                histogram
tamoz.lease.lost{}                                   counter
tamoz.verify.outcome{result}                         counter
tamoz.repair.attempts{outcome}                       counter
tamoz.stop.safe{reason_class}                        counter
tamoz.telemetry.dropped{signal,reason,lane}          counter
tamoz.telemetry.divergence{reason_class}             counter
tamoz.telemetry.export{outcome}                      counter
```

**Cardinality is bounded by construction.** Each metric declares its label keys in the catalog;
values must match a low-cardinality pattern; and the correlation spine — thread, execution,
request, occurrence, task, effect key — is on a denylist the recorder refuses as a label and
counts as a violation. OpenClaw's OTel extension needs exactly this: an explicit
`DROPPED_OTEL_ATTRIBUTE_KEYS` set covering session, run, chat, message, tool-call and span
ids, plus a `LOW_CARDINALITY_VALUE_RE` bound
(`extensions/diagnostics-otel/src/service-constants.ts`). Adopting it as a contract is cheaper
than adopting it as a cleanup.

Histogram bucket boundaries are declared in the catalog and versioned with it, because
changing buckets silently breaks an operator's dashboards.

## 12. Sampling

Head-based per-span sampling would defeat Q2: half a turn is not an explanation. Revision 1
answered with a bounded per-turn buffer that finalized a retention decision at the terminal
transition — tail sampling in miniature. That was self-contradictory, and the contradiction
was not subtle: §7 forbids holding intervals because a turn "may span days and outlive the
process", while the buffer's own retention list led with *"a turn that pauses for approval"*.
The interesting turn was the one guaranteed to be lost on restart.

**v2 deletes the buffer. The journal is the buffer.**

- **The journal records everything, unsampled.** There is no journal sampling rate to
  configure — §15 exposes `export_rate` only. Local disk is cheap, the journal is already
  bounded by rotation (§14), and it already survives restart.
- **Only export samples**, and the decision is made **when the exporter reads the journal**,
  not when the signal is produced. At that point the turn's outcome is known, so retention is
  real tail sampling with no in-memory window and no restart hazard.
- **The decision is per turn and deterministic** from `trace_id` and `export_rate`, so every
  process that observes the turn agrees.
- **Interesting turns are always exported**: paused for approval, stopped safely, failed,
  denied a tool, produced an `:unknown` effect, exhausted a budget, or triggered a repair.
- **Safety-bearing signals are never sampled** at any rate, in either destination. A sampled
  safety counter is a false statement about safety.

The cost of this shape is that export lags production by the journal's flush interval. That is
acceptable: nothing downstream of the exporter is in a decision path, and §18 forbids acting
on a streamed instrument anyway.

## 13. Bounds and backpressure

| Bound | Applies to | On exceed |
|---|---|---|
| attribute count / value bytes | every signal | truncate with an explicit marker, count |
| content bytes per class | policy-admitted content | truncate at a grapheme boundary, count |
| reserved lane depth | safety-bearing signals | bounded synchronous write to the journal — never dropped |
| bulk lane depth | everything else | drop-newest, counted by name and reason |
| journal file size, file count | local journal | rotate, then delete oldest, count |
| export batch size, in-flight batches | exporter | drop oldest batch, count |
| export deadline, consecutive failures | exporter | back off; self-disable after N; visible in `tamoz status` |

The bulk-lane rule is the one that matters: **the caller is never blocked and never raises.**
A turn's latency must not depend on a collector's health. This is where the stream plane's
contract and this plane's contract deliberately differ — invariant 15 requires the stream to
apply backpressure, and this design requires the instrumentation plane not to, with the one
bounded reserved-lane exception §6.4 prices explicitly.

Hermes Agent's logging is comparative evidence for the shape: it routes every record through a
`QueueHandler`/`QueueListener` pair so formatting and file I/O leave the producing thread
(`hermes_logging.py`), with redaction on the listener side. The queue exists because
synchronous observation on a hot path is a latency bug waiting for load.

## 14. The local journal

Newline-delimited JSON in the 0700 runtime directory, rotated by size with a bounded file
count. It is why E1 holds: an operator with no collector, no network and no third-party
account still gets Q1–Q4. In v2 it is also the export buffer (§12).

- **The journal is `Signal`-shaped**, not worker-shaped. Revision 1 claimed both that the
  journal keeps the worker's current NDJSON shape and that it carries the full `Signal`; those
  are incompatible. The compatibility guarantee applies to **stdout**: the worker's `--json`
  output is preserved byte-for-byte by a renderer over the same signals, so existing consumers
  do not break, while the journal carries the richer record.
- **One file per process role and pid** — `worker-<pid>.ndjson`, `gateway-<pid>.ndjson`,
  `cli-<pid>.ndjson` — so two processes never race one file's rotation. A follower globs the
  role prefix and merges by `observed_at_ms` (§16.3).
- Written with the private-permission assertion the runtime directory already enforces.
- **Never written to the runtime database**, so E2's "no contention with the fenced writer" is
  structural.
- Rotation and deletion are ordinary file operations with no deletion receipt: the journal is
  not evidence of an external effect. Anything that is such evidence lives in the effect
  journal, where invariant 54 governs it.

## 15. Configuration and CLI surface

```yaml
runtime:
  schema_version: 2
observability:
  enabled: true
  journal:
    max_file_bytes: 33554432
    max_files: 8
    flush_interval_ms: 200    # the upper bound on `--follow` latency
  sampling:
    export_rate: 1.0          # the journal is never sampled; see §12
  content_policy: none
  export:
    kind: otlp_http
    endpoint: https://collector.internal.example:4318
    allow_local: false
    credential_ref: {kind: env, name: TAMOZ_OTLP_HEADERS}
    timeout_ms: 2000
    max_batch: 256
    max_in_flight: 2
    offline: false
```

| Command | Does |
|---|---|
| `tamoz observe tail [--follow] [--thread ID] [--kind K] [--since T] [--json]` | Watch the live journal — §16 |
| `tamoz status [--watch]` | The authoritative spine: open occurrences, paused approvals, blocked effects, recorder health |
| `tamoz trace THREAD [--execution ID] [--session-dir DIR] [--follow] [--format tree\|ndjson\|otlp]` | Reconstruct the authoritative span tree |
| `tamoz observe metrics [--format prometheus\|json]` | Derived gauges plus streamed instruments |
| `tamoz observe export [--since T]` | Offline export of the journal; no `Session` constructed |
| `tamoz observe doctor` | Endpoint reachability, TLS, policy digest, cardinality report, drop counters, redaction self-test |

`tamoz status` gains an `observability` section: per-lane depth, drops by reason, journal size,
export state and last successful export age, and the content policy digest.

`tamoz observe doctor`'s **redaction self-test** is a shipped command, not only a test: it
pushes a synthetic `Tamoz::Secret` and a token-shaped string through the whole pipeline —
recorder, journal, metric labels, rendered export body — and asserts neither appears. An
operator who changes a content policy can verify the result rather than trusting a document.

## 16. Watching a live agent

A recording that can only be read afterwards is half a system. Three distinct live questions,
with different answers; conflating them gives a view either too coarse to debug or too lossy
to trust.

| Question | Command | Latency | Complete? |
|---|---|---|---|
| "What is it doing right now, step by step?" | `tamoz observe tail --follow` | ≤ `flush_interval_ms` | bulk lane lossy, **counted**; reserved lane complete |
| "Where does every thread stand?" | `tamoz status --watch` | poll interval | authoritative |
| "Show this turn's structure as it grows" | `tamoz trace THREAD --follow` | poll interval | authoritative |

### 16.1 Why tailing a file is the right mechanism

**It already works across processes, with no IPC to build.** The journal is a file in the
shared 0700 runtime directory. A headless worker writes there; a gateway writes there; a second
terminal reads there. No socket, no port, no subscriber registry, no authentication surface
beyond the directory permission the runtime already asserts.

**A follower changes nothing.** There is no subscribe call, nothing is retained because someone
is watching, and nothing is dropped because nobody is. If the reader is slow, the reader falls
behind — the agent does not. This is exactly the difference from the stream plane, where the
consumer applies backpressure by contract and a slow reader really does slow the run.

**It composes with tools operators already have** — `tail -f`, `jq`, `grep`, a log shipper.
`tamoz observe tail` is a convenience with filters and a readable renderer, not a gatekeeper.

### 16.2 What "live" means, precisely

The recorder hands off asynchronously, so tail latency is a flush policy, not an accident:

- **Ordinary signals batch** up to `flush_interval_ms` (default 200 ms), keeping per-signal
  `fsync` off the hot path.
- **Reserved-lane signals flush immediately**: turn terminal transitions, approval requested,
  safe stop, budget exhaustion, `:unknown` effect. These are the same signals §6.4 never drops,
  so the immediate-flush set and the never-dropped set are one list in the catalog rather than
  two policies that can drift apart.

### 16.3 Following across rotation and across files

A follower globs the role prefix, tracks each file by inode, reopens on rotation, and merges
by `observed_at_ms`. If rotation outruns a paused reader, it emits an **explicit gap marker**
naming the missed line count and increments
`tamoz.telemetry.dropped{reason: "reader_lag"}`. It never silently skips: P4 applies to the
terminal exactly as to the exporter, because an operator draws conclusions from silence.

### 16.4 The combined view

`tamoz observe tail --follow --with-status` interleaves journal lines with a periodic derived
gauge snapshot — the fine grain from the lossy plane, the spine from the authoritative one, and
the divergence counter telling the operator when the two disagree.

```text
14:22:07  turn.started        thread=tg.ops.9f3c  execution=e-4c81  occurrence=r-8821
14:22:07  plan.accepted       kind=action  version=1  digest=8f2a91c4…
14:22:09  model.call          provider=openai model=gpt-5-mini  1.9s  in=2841 out=214 cache_read=2560
14:22:09  tool.call           read_file  source=local  ok  12ms
14:22:11  tool.call           apply_patch  source=local  → approval_required
14:22:11  approval.requested  interrupts=1  digest=c17b…      ← reserved lane, flushed now
          ── status ──────────────────────────────────────────────────────────
          open=3  paused=1  blocked_effects=0  unknown=0  lease=held  drops=0
14:24:40  approval.decided    direction=deny  actor=os_user:501  source=cli
14:24:40  turn.stopped        reason_class=denied  duration=153s
```

Three things there are load-bearing: the turn line carries `execution` (the trace key) and
`occurrence` (the operator-facing request id) as distinct fields; the approval line arrives
immediately because it is reserved-lane; and `drops=0` appears on every status line, so an
operator can see whether what they are reading is complete.

### 16.5 What v1 does not build, and what would justify it

**No attach-to-a-running-turn socket.** Deferred, for three reasons: it is a new authentication
surface in the directory holding operator authority, for a read-only convenience the file
already provides; a subscriber protocol needs its own backpressure policy whose only acceptable
answer ("drop the subscriber, never the agent") is what a file gives free; and it would deliver
the same bytes. What would justify it: a consumer needing **guaranteed** in-order delivery of
every signal — a live compliance monitor — which needs a property this plane deliberately
refuses, making it a fourth-plane conversation.

**No TUI and no remote tail.** `--with-status` is interleaved text; watching a Tamoz on another
machine is what the exporter is for.

### 16.6 The interactive CLI is unchanged

`tamoz ask` already shows a live run through the stream plane. §16 is for the case with no
answer today: a worker running headless, watched from another terminal. The stream is the run
talking to its caller; the journal is the system talking to its operator.

## 17. Golden signals

| Alert | Condition | Detects |
|---|---|---|
| Worker stalled | `tamoz.occurrence.oldest_age_ms{status="claimed"}` exceeds the lease TTL by 2× | A wedged or dead worker holding work |
| Unresolved ambiguity | `tamoz.effect.unknown` > 0 beyond the operator's resolution SLA | Invariant 21's `:unknown` effects awaiting a human |
| Approval starvation | `tamoz.approval.pending` > 0 beyond the prompt TTL | Work paused with nobody answering |
| Lease thrash | `tamoz.lease.lost` rate above zero over a window | Two owners, clock skew, or an over-short TTL |
| Store contention | `tamoz.store.busy_retries` rising with `tamoz.store.commit_ms` p99 | SQLite writer contention before it becomes commit failure |
| Verification collapse | `tamoz.verify.outcome{result="unverifiable"}` share rising | Invariant 27's "cannot verify" path becoming the norm |
| Cache-epoch churn | `tamoz.model.cache.epoch_changed` rate above baseline | Invariant 16's prompt-prefix instability, and its cost |
| Spend anomaly | `tamoz.model.tokens` rate per profile above baseline | The budget breach that budgets cannot yet stop |
| Telemetry lying | `tamoz.telemetry.dropped` or `tamoz.telemetry.divergence` above zero | The observability system failing, said out loud |

The last row is the one most systems omit. A stack that cannot report its own loss will
eventually be believed when it is wrong.

## 18. Alerting and automated response

§17 ships *conditions*. This section decides who may act on them, and it is a **phase 5**
addition: phases 1–4 ship the conditions and leave acting to the operator.

> **Observability computes conditions. It never actuates.** Every automated response is handed
> to a subsystem that already owns the governance for that class of action.

A threshold-triggered actuator would be the only component in Tamoz that acts on evidence
without a plan, a review or an approval — on evidence this design permits to be lossy.

### 18.1 The evidence rule

| Number | Source | May notify | May act |
|---|---|---|---|
| Derived gauge | the durable record | yes | **yes** |
| Streamed instrument | the live, lossy plane | yes, labeled | **no** |

Every alert carries `window_start`, `window_end`, and the `dropped` and `divergence` counts for
that window. **A window with either is `degraded`: it may notify, it may not act.** "A lot of
errors" over a window with drops is not a fact; it is a lower bound.

### 18.2 Four tiers, four existing owners

| Tier | Example | Mechanism | New machinery |
|---|---|---|---|
| **Notify** | unknown effects > 0 for 30 minutes | rendered alert → stderr, file, exit code, or a `comms` `:control` delivery | rule evaluation only |
| **Gate** | provider failing → stop admitting turns | the existing durable `Tamoz::Circuit` | a condition source |
| **Ask** | error spike → have the agent investigate | the request inbox, as a surface | a surface binding |
| **Remediate** | restart the stuck thing, raise an issue | a healing rule under invariants 32–34 | a typed failure source |

**Notify** composes with work in flight: an alert is a `:control` delivery on an existing comms
surface, which [`COMMS_DESIGN.md`](../documentation/design/comms.md) §10 already classifies as ephemeral and
unjournaled because losing or duplicating one is harmless. Bounded outbox, rate limiting and a
redaction path for free; no new egress surface. Without a channel: stderr, a file, and a
non-zero exit from `tamoz observe watch --once`, making cron or CI the delivery mechanism.

**Gate** is a reframing, not a feature. "A lot of errors → stop" is an existing durable circuit
whose condition nothing could measure until now.
[`circuit.rb`](../gems/tamoz-core/lib/tamoz/circuit.rb) provides one record type, one set of
transition rules, four scopes (`server`, `rule_target`, `schedule`, `egress`), a format
version, digest-only context, a bounded evidence ring and operator-evidence reset.
Observability supplies the number; the circuit owns the decision, its durability and its reset
authority. **Refusing to do more work is categorically different from doing something**, which
is why this tier may be automatic and the two below may not.

**Ask** is where "the agent investigates itself" belongs. An alert that enqueues an ordinary
request is a fourth entry in [`COMMS_DESIGN.md`](../documentation/design/comms.md) §2's user-surface table,
beside the CLI, the scheduler and the chat channel. The alert text is a task string naming no
profile, tool, root, model or budget — invariant 56 unchanged. The request id is derived from
the rule identity and the window, so flapping or a restart cannot produce fifty turns. The
agent then plans, reviews and requests approvals as it would for a human.

**Remediate** is fully governed by invariants 32–34, and
[`SELF_HEALING_DESIGN.md`](design-v0.1/SELF_HEALING_DESIGN.md) §4's rule contract already
includes an `issue/escalation contract` field — so "raise an issue" is an anticipated escalation
output, not a new mechanism. Observability contributes exactly one thing: **a new typed failure
source**, a derived gauge crossing a declared threshold, classified into the existing list
(`resource_exhausted`, `dependency_unavailable`, `verification_failed`). The categories that
never trigger mutation stay closed: `policy_denied`, `durable_state_corrupt`,
`programmer_error`, `unknown`. Below-confidence classifications route to observation or
escalation.

### 18.3 "Raise an issue", analysed properly

Creating an issue is an **external side effect**, not a notification. Under invariant 21 it
needs a stable effect key, a safety class, an attempt token and a journal entry. It is
non-idempotent, so `:unsafe`, so an ambiguous create becomes `:unknown` and is never blindly
retried. The key derives from **the alert's identity, not the moment of firing**:

```text
effect_key = H("tamoz.alert.effect.v1", rule_id, rule_version, window_start, subject)
```

A flapping condition then cannot file four hundred issues and a restarted watcher cannot
duplicate one — the same trick as the derived trace id, applied to actions.

The consequence is architectural: **a "raise an issue" action is a journaled effect performed by
the worker under a healing rule — not an HTTP call from a metrics callback.** Fire-and-forget is
precisely the shape that files a duplicate on every restart and loses one on every crash.

### 18.4 The evaluator process and its state

`tamoz observe watch [--once]`, in the connector-zone shape the comms gateway established: it
polls derived gauges, tails the journal, evaluates rules, and emits notifications — or, where a
rule declares it, feeds a circuit condition or enqueues a request. It holds no model credential,
no toolbox and no workspace root, and constructs no `Session`. It is in no turn's hot path.

**Phase 5 has durable state, and ADR-045 must not be read as forbidding it.** Silences, rule
revisions and alert history live in the **Store**, alongside the operator records that already
live there — circuits under `tamoz.circuit.<scope>` and open occurrences under
`["tamoz","worker","occurrence"]`. That makes the evaluator a **writer**, so E2's "no additional
writer on the runtime database" is scoped to phases 1–4 and explicitly relaxed here, with the
evaluator taking the same fenced-lease discipline any other writer takes. ADR-045 forbids a
*telemetry* store that duplicates the durable record; it does not forbid operator authority
records, which is what a silence is.

### 18.5 Rule quality

- **Hysteresis is mandatory.** Every rule declares `for:` — N consecutive evaluations — and a
  separate clear threshold. A rule with neither is refused at load.
- **Deduplication is by derived identity**, never by an in-memory "have I seen this lately".
- **Silences are explicit, durable and expiring**, carrying an actor, a reason and a TTL.
- **Rules are content-addressed and versioned**; changing a threshold is a new revision recorded
  on the alerts it produced, so "why did this not fire in March" is answerable.
- **No rule may reference model output or policy-captured content.** An alert whose condition can
  be rewritten by the thing it watches is not an alert — the rule
  [`COMMS_DESIGN.md`](../documentation/design/comms.md) §11 applies to approval prompts.

### 18.6 What this refuses

- **No arbitrary command hook on a threshold** — an unreviewed actuator with the operator's full
  authority, fired by a number from a lossy stream.
- **No auto-restart of a worker from the evaluator.** Lease expiry and the supervisor own that; a
  second restarter is a split-brain source.
- **No auto-approval under any threshold, ever.** `headless_auto_approvals` stays 0.
- **No threshold that widens a budget, profile, allowlist or capability.**
- **No alert-driven behavior-version rollback** outside invariant 28's evaluation and approval.

## 19. Evidence and evaluation

| Clause / criterion | Test shape |
|---|---|
| C1 | One fixture turn observed, unobserved, and with a raising recorder; byte-identical final checkpoints and identical model-facing message order. **Also with a malformed payload**, proving `instrument` no longer raises into a caller that configured no notifier |
| C2 | Export to a collector that accepts and never responds; turn latency within noise of baseline, drops counted |
| C3 | A recorder that raises on every call; the turn completes and the failure is visible in `health` |
| C4 | Maximum emission rate with no consumer over a sustained window; bounded RSS across **both** lanes, monotonic bulk drops, zero reserved-lane drops |
| B1 | Property-test `Tamoz::Secret` and credential shapes across events, spans, metric labels, journal lines, exception text and the rendered export body |
| B2, B3, B4 | Enable each content class in turn; assert a `restricted` profile refuses at load; assert digest and size present and stable when a class is off |
| B5 | Redirect to a loopback address, a hanging server, an oversized response, an untrusted certificate — each refused, counted, no hot retry loop |
| A1 | Enumerate every name passed to `Tamoz.instrument` in every gem; fail on an unregistered name, a changed attribute set without a version bump, an undeclared metric label, or a missing declared correlation key |
| A2 | Assert each layer emits its declared spine and that the recorder rejects a signal missing a required correlation key in strict mode |
| A4 | Deliver a duplicate request, `kill -9` mid-turn, resume **through an approval decision**, and restore from backup; assert one trace id throughout, and that `tamoz trace` recomputes identical ids offline |
| A3 | Reconstruct a thread that paused across a process restart; assert one root, no orphans, a `pause` interval from checkpoint status, and that every ordering-only span is marked as such rather than reporting a fabricated duration |
| D1, D2 | **Gated on the §10 prerequisite.** Scripted provider fixture; exact accounting, `nil` when unreported, basis and pricing source on every cost |
| D3 | Fuzz metric label values; assert rejection plus a counted violation |
| D4 | Benchmark the reference workflow observed and unobserved; publish the delta in `docs/BENCHMARK.md` |
| E4 | `tamoz observe doctor` against a synthetic secret; absence in every output surface |

Proposed autonomy-scorecard cases:

| Case | Proves |
|---|---|
| 17 | A completed turn is explainable from `tamoz trace` alone: plan, review, every tool call, verification, outcome, in order |
| 18 | `kill -9` mid-turn, resume **and an approval decision** yield one trace with no orphan spans |
| 19 | A hostile collector changes neither turn outcome nor latency, and every loss is counted |
| 20 | Under the default policy, no prompt, tool argument, tool result or plan text appears in the journal or export body, while content digests still prove two runs saw identical input |

## 20. Failure model

| Failure | Behavior |
|---|---|
| Collector unreachable | Bounded backoff with jitter; batches dropped and counted; self-disable after N failures; visible in `tamoz status`; the turn is unaffected |
| Collector hangs mid-export | Deadline fires, batch counted `:unknown`, no retry of a non-idempotent batch, exporter backs off |
| Recorder raises | Isolated, counted, the turn proceeds; a repeatedly raising recorder is disabled |
| Bulk lane saturated | Newest dropped and counted; the caller never blocks |
| Reserved lane saturated | Bounded synchronous journal write; if that fails, the failure itself is recorded and surfaced by `tamoz status` |
| Journal disk full | Rotation deletes oldest first; on continued failure the journal disables itself and counts |
| Runtime database unreadable | Derived gauges and `tamoz trace` report unavailable; never a live estimate substituted for a durable fact |
| Unregistered event name | Dropped and counted in permissive mode; typed error in strict mode (development and CI default) |
| Missing correlation key | Same as unregistered: strict in CI, counted in production |
| Clock moves backward | Durations clamp at zero and are flagged; durable `created_at_ms` remains the reconstruction basis |
| Content policy changed mid-run | Each signal names the digest that governed it |

## 21. Contract changes this requires

The repository pins the counts: `test/documentation_test.rb` asserts clauses 1–58 and
ADR-001–043, and `script/generate_requirements_manifest` regenerates the manifest and audit.

**Proposed clauses 59–61:**

| # | Invariant | Required behavior | Failure prevented |
|---|---|---|---|
| 59 | **Observation cannot change execution, and its surface is bounded and versioned** | Committed checkpoint bytes, model-facing message order, control flow and outcomes are identical with observation enabled, disabled, and failing, and an instrumentation call cannot raise into a caller regardless of payload or notifier; every signal, buffer, batch, label set and file is bounded, signal names and attributes form a closed versioned catalog whose change requires a version bump, no correlation identifier is admitted as a metric label, and every drop is counted and inspectable | Telemetry-induced behavior change, a hung collector stalling a turn, unbounded memory or cardinality, silent schema drift, and loss mistaken for health |
| 60 | **Telemetry is redacted by construction and content capture is an explicit named policy** | No `Tamoz::Secret` reaches any signal, label, journal line or export body — with no policy exemption, which is narrower than invariant 24's "unless a named policy protects them"; prompts, tool arguments, tool results, plan and review text are excluded unless a named, digest-bound, classification-permitted policy admits them per class within byte bounds; every signal records the governing policy digest, and omitted content is represented by a digest and size | Credential leakage, invisible content capture, and a trace whose emptiness cannot be distinguished from an empty run |
| 61 | **Safety-bearing observability is derived from durable evidence, correlated by durable identity, and never overstates what it measured** | Counters and states asserting a safety property are computed from the durable record rather than reported by the component they describe; trace identity is a pure function of thread and execution identity and span identity of a durable per-kind anchor, so a resumed, retried, approved or duplicated turn is one reproducible trace; a span without a durable interval is marked as ordering-only rather than given a fabricated duration; a cost value carries whether it was measured or estimated and from which pricing source; divergence between live and reconstructed views is counted and reported | A component vouching for itself, traces split by resume or approval, fabricated durations, estimates read as measurements, and unreported telemetry loss |

Conformance rows for the `INVARIANTS.md` table:

| Clauses | Test shape |
|---|---|
| 59 | Run one fixture observed, unobserved, with a raising recorder, with a hanging collector, and with a malformed payload under a null notifier; assert identical committed bytes and message order, unchanged latency, bounded memory in both lanes, no raise into the caller, and that the registry gate fails on an unregistered name or an identifier used as a metric label |
| 60 | Property-test secrets and credential shapes across every signal surface; enable each content class in turn; assert restricted classifications refuse capture at load and that omitted content yields a stable digest and size |
| 61 | Duplicate a request, `kill -9` mid-turn, resume through an approval decision, fork, and restore from backup; assert one reproducible trace id per execution with a parent link across the fork, ordering-only spans marked as such, derived counters equal to `tamoz status`, cost values carrying their basis, and a counted divergence when the bulk lane drops |

**Proposed ADRs 044–047:**

- **ADR-044 — Observability is a contract gem plus per-exporter adapter gems.** The exporter
  list is closed; this is not a plugin API (ADR-014 stands).
- **ADR-045 — The observability gems add no durable table and no second source of truth.**
  History is the existing durable record plus a bounded rotating journal; authoritative traces
  are reconstructed. A telemetry writer would contend with the fenced writer that guards
  correctness. Model usage capture is **not** an exception to this: it is a separately
  authorized persistence change (§10) that observability consumes. Operator authority records
  created by phase 5 (silences, rule revisions) are not telemetry and are out of scope for this
  ADR (§18.4).
- **ADR-046 — Content capture is off by default, per class, and refused for restricted
  classifications.**
- **ADR-047 — Sampling applies to export only and never to safety-bearing signals.** The journal
  records everything; the export retention decision is taken when the exporter reads the
  journal, so a turn that pauses for days cannot be lost to an in-memory window.

Phase 5 adds **clause 62** and **ADR-048**, stated in revision 1's §18.7 and unchanged: an
automated response is triggered only by durable evidence over a non-degraded window and executed
only by a subsystem that governs it.

## 22. Grading against the bar

| # | Mechanism | Phase | Met? |
|---|---|---|---|
| A1 | `SignalCatalog`, schema version, cross-gem registry gate | 1 | yes |
| A2 | Per-layer declared spine, validated by the recorder | 1 | **partial** — validated, not structural; `tamoz-sqlite` carries a reduced spine (§6.2) |
| A3 | Reconstructed tree: interval spans plus marked ordering-only spans | 3 | **partial** — 5 of 11 span kinds carry durations (§7) |
| A4 | Trace id derived from `(thread_id, execution_id)` | 1 | yes |
| B1 | `Secret` rejection in `tamoz-core`, ordering corrected | 1 | yes |
| B2 | `ContentPolicy`, off by default, classification-gated | 2 | yes |
| B3 | Content digest and size when a class is off | 2 | yes |
| B4 | Policy digest recorded on every signal | 2 | yes |
| B5 | Exporter egress rules reusing the websearch precedent | 4 | yes |
| C1 | Observer-only seam; four-way byte-identity test | 1 | yes |
| C2 | Bounded queue, deadline, backoff, self-disable | 4 | yes |
| C3 | Guarded recorder; nothing raises into the caller | 1 | yes |
| C4 | Points live, intervals reconstructed; two bounded lanes | 1, 3 | yes |
| D1 | Model usage on the effect record | 2 | **conditional** — requires the §10 persistence prerequisite; TTFT dropped |
| D2 | `basis`, `pricing_source`, `pricing_version` on every cost | 2 | yes |
| D3 | Declared label keys, low-cardinality pattern, identifier denylist | 3 | yes |
| D4 | Observed/unobserved benchmark in `BENCHMARK.md` | 4 | yes |
| E1 | Journal, `observe tail --follow`, `status --watch`, `trace` | 1, 3 | yes |
| E2 | Journal rotation; no second writer on the runtime database | 1 | yes for phases 1–4; **relaxed in phase 5** (§18.4) |
| E3 | The golden-signal table in §17 with fault-injection tests | 4 | yes |
| E4 | `tamoz observe doctor` with the redaction self-test | 4 | yes |

**14 met, 3 partial, 1 conditional, and the levels claimed are lower than revision 1's.**
Phase 1 → L2. Phases 2–3 → L3 for everything except deliberation latency, which the durable
record does not carry. Phase 4 → L4 for export, evidence and operability.

Revision 1 graded 18/18 and claimed L4. That grade rested on a reconstruction that could not
produce the tree it described. Recording the reduced grade is the point of having a bar.

## 23. Non-goals

Log aggregation or a shipped log format beyond the journal; a UI; distributed tracing across
machines beyond propagating a derived trace id; profiling or flame graphs; a bundled model
price list; per-token streaming as telemetry; **time to first token** until a streaming model
adapter exists (§10); anomaly detection or evaluation scoring — that is `tamoz-evals`; sampling
strategies beyond per-turn export sampling; and any durable telemetry store.

Alerting is a **phase 5** addition governed by §18, not a non-goal. What remains a permanent
non-goal at every phase is a threshold-action engine inside observability: a general command
hook, an auto-restart, an auto-approval, or any condition that grants authority.

## 24. Rejected alternatives

| Rejected | Why |
|---|---|
| Reuse the stream plane as telemetry | It backpressures by contract, so a slow log consumer would slow the agent |
| Durable telemetry tables in the runtime database | Contends with the single fenced writer that guards correctness, creates a second source of truth, forces one retention policy onto two lifetimes |
| Keying the trace on the request id | A resume after an approval is a new request (`decision-<id>`), so every paused turn split into two traces |
| Keying the trace on the worker's occurrence id | It exists only for worker-claimed work; the interactive CLI has no occurrence record, and a fork would reuse one |
| Deriving `approval.wait` from request transitions | `tamoz_requests` has no paused status; the request completes while the session pauses |
| Giving every span a duration | `plan`, `review`, `verify` and `step` live in the checkpoint payload with no timestamps; a fabricated duration is worse than a marked absence |
| A per-turn in-memory tail-sampling buffer | Its own retention list led with the approval pause — the case that outlives the process, so the interesting turn was the one guaranteed to be lost |
| One recorder queue with drop-newest | Discards safety-bearing signals exactly when the system is loudest |
| Usage in the effect attempt `result` blob | Changes the durable receipt's `result_digest` — observation altering the record, which clause 59 forbids |
| The official `opentelemetry-sdk` gem as a runtime dependency | A process-global `TracerProvider` is the mutable process-global state dependency rule 6 forbids |
| Random OTel trace and span ids | Orphans a trace at every crash, resume and approval, and reports a deduplicated request as two turns |
| Holding a span open across an approval pause | It may last days and outlive the process |
| Per-span head sampling | Half a turn does not answer "why did it do that" |
| Content capture behind a single `debug: true` flag | One flag captures prompts, arguments, results and errors together, and a flag left on in production is the default in practice |
| A bundled price table | A stale price list produces a confidently wrong number |
| Callbacks that may raise into the run | LangChain's `raise_error` flag and its own note that async handler errors escape it regardless |
| Emitting only from the model adapter (`M4_PLAN` §13 alone) | Misses the graph, the store and the effect journal, where the operational failures are |
| A plugin API for exporters | ADR-014's argument is unchanged |

## 25. Known costs and open risks

- **Deliberation latency is not measured**, and cannot be without adding timestamps to
  `SessionRecords` — a `tamoz-agent` record-schema change with its own codec migration. §7 marks
  the affected spans rather than hiding the gap. If deliberation latency becomes a real
  question, that migration is the answer and it should be priced then.
- **Usage capture is a real cross-gem change**, not a call-site addition: a `Model` protocol
  change across six implementations plus `MIGRATION_7` and a `CURRENT_VERSION` bump that makes
  older Tamoz binaries refuse a migrated database. §10 prices it; the plan makes it a blocking
  prerequisite with an explicit refuse branch.
- **A read-only adapter path does not exist** and is prerequisite work in `tamoz-sqlite`
  (§6.7). Without it, `tamoz trace` opens the runtime database read-write from a second process.
- **Two durable layouts.** The worker's shared `runtime.sqlite3` and the interactive CLI's
  per-thread databases are both real; reconstruction targets the former and takes an explicit
  flag for the latter rather than guessing.
- **OTLP JSON is not universally accepted.** The OpenTelemetry Collector's HTTP receiver supports
  it; some vendor endpoints accept protobuf only, so those operators run a sidecar. A separate
  `tamoz-otel-sdk` remains available if a real consumer appears.
- **The exporter shares a process with the model credential.** §5 states the mitigations and
  their limit. A deployment that cannot accept it uses `--offline`.
- **The catalog is a compatibility surface from day one**, now pinned by clause 59. Every name
  shipped needs a version bump to change. That is the cost of A1, deliberately taken.
- **The lazy-load pattern is inherited from a proposal.** `tamoz-telegram` does not exist yet
  (§3).

## 26. External design evidence

- **[OpenClaw's `diagnostics-otel` extension](https://github.com/openclaw/openclaw/tree/main/extensions/diagnostics-otel)**
  — the high-cardinality attribute denylist and low-cardinality value pattern in
  `service-constants.ts`, the per-class content-capture policy with a no-capture default in
  `service-content-normalization.ts`, the trusted/untrusted trace-context split in
  `service-trace-context.ts`, and a dedicated dropped-signal counter. Adopted as contracts
  rather than operational cleanups. Its span-per-message model and process metrics are not
  adopted.
- **[Hermes Agent](https://github.com/NousResearch/hermes-agent)** — `hermes_logging.py` routes
  records through a `QueueHandler`/`QueueListener` so formatting and I/O leave the producing
  thread, with redaction on the listener side; `agent/insights.py` carries `cost_status`,
  `cost_source`, `estimated_cost_usd` and `actual_cost_usd` separately. Both adopted:
  observation is asynchronous by construction, and an estimate is never a measurement.
- **[LangChain](https://github.com/langchain-ai/langchain)** —
  `libs/core/langchain_core/callbacks/manager.py` is the cautionary precedent: rich enough to
  observe everything, with a `raise_error` flag whose own comments record that async handler
  errors escape regardless. Its `on_*` decomposition and `UsageMetadataCallbackHandler` are
  useful; its ability to fail the run it observes is what clause 59 forbids.
- **[`design-v0.1/ARCHITECTURE.md`](design-v0.1/ARCHITECTURE.md) §7–8 and
  [`CORE_DESIGN.md`](design-v0.1/CORE_DESIGN.md) §3–4** — the three-plane split, the
  observer-only definition, and the definition of `execution_id` as turn identity that v2's
  correlation now rests on.
- **[`design-v0.1/EVALUATION_DESIGN.md`](design-v0.1/EVALUATION_DESIGN.md) §7** — the
  already-specified OTel integration test is the acceptance test this design is built to pass.

This document defines architecture. It authorizes no implementation on its own: the clauses in
§21 must be accepted, and the plan in [`OBSERVABILITY_PLAN.md`](OBSERVABILITY_PLAN.md) sequences
the work.
