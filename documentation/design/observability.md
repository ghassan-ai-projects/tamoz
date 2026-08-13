# Observability

A signal plane for Tamoz that explains a turn, measures what it cost, proves what it did not do, and cannot change what it does. Source: [`docs/OBSERVABILITY_DESIGN.md`](../../docs/OBSERVABILITY_DESIGN.md).

Current version: `0.1.0.alpha.1` (pre-release).

## Two gems

| Gem | Responsibility | Runtime dependencies |
|---|---|---|
| `tamoz-observability` | The closed signal catalog and its schema version, correlation derivation, content/redaction policy, the `Recorder` and `Exporter` seams, trace reconstruction, derived metrics, and the bounded local journal | `tamoz-core` |
| `tamoz-otel` | One conforming exporter: OTLP over HTTP with JSON encoding, and the OpenTelemetry `gen_ai` attribute mapping | `tamoz-observability`, stdlib |

Producers gain call sites only — `Tamoz.instrument` with a registered name and a metadata payload — and no runtime gem depends on the observability package. `tamoz-agent` loads it lazily when a runtime directory configures observability; without it, installations run unchanged and report a typed missing-adapter error for `tamoz observe` and `tamoz trace`.

## The closed, versioned signal catalog

Every signal name is registered in a closed catalog (`SCHEMA_VERSION = 1`) that declares its attributes, required correlation keys, and bounds. Names use `tamoz.<area>.<noun>.<verb-or-state>`; optional packages keep their own prefixes (`comms.*`, `stream.*`, `scheduler.*`, `mcp.*`). Renaming a name, removing an attribute, or changing a type requires a schema-version bump, and the evaluation gate fails on any unregistered name or changed attribute set. `safety_bearing: true` marks signals that are never sampled and take the reserved recorder lane.

## Correlation identity

Trace identity is **derived, never generated**:

```text
trace_id = sha256("tamoz.trace.v1\n" + canonical([thread_id, execution_id]))[0, 16]
```

Because `execution_id` is stable across resume and new across turns/forks: a resumed turn is one trace (including across a multi-day approval pause), a duplicated delivery is one trace, a fork is a new trace with a parent link, and effects attribute to the turn directly. Traces are reproducible offline from a backup with no telemetry retained. Span identity uses a per-kind durable anchor so both the live emitter and the reconstruction compute the same `span_id`. The correlation spine is per-layer: the catalog declares required correlation keys per name and the recorder enforces them (strict in development/CI, drop-and-count in production).

## Immutable signals

A `Signal` is one immutable value with three kinds — `:event`, `:span`, `:measurement` — carrying its registered name, schema version, correlation spine, timing class, timestamps, bounded typed attributes, optional policy-admitted content, the governing content-policy digest, and an outcome (`:ok | :error | :unknown`). The `timing` class exists because not every span has a measured duration: `:interval` spans (turn, pause, model/tool/effect calls, checkpoint commit) are reconstructed from durable records, while `:ordering_only` spans (plan, review, verify, step) have a correct tree position and an upper bound but `duration_ms: nil`. The live plane emits points; reconstruction produces intervals.

## Bounded recorders

The `Recorder` seam is "must not raise, must not block" with two lanes:

| Lane | Holds | On saturation |
|---|---|---|
| reserved | catalog entries with `safety_bearing: true` | never dropped; a bounded synchronous write to the journal |
| bulk | everything else | drop-newest, counted by name and reason |

Three implementations ship (`Null`, `Journal`, `Fanout`), and the guarded instrumentation shape ensures a payload defect never raises into a caller with no observability configured.

## Content and secret policy

Content capture is a decision, not a flag. `ContentPolicy::NONE` is the default: prompts, tool arguments, tool results, and plan/review text are excluded from every signal unless a named, digest-bound, classification-permitted policy admits them per class within byte bounds. Omitted content is represented by a `<class>_digest` and `<class>_bytes` — so two runs can be proven to have sent the same prompt without the prompt leaving the machine. Profiles classified `restricted` cannot enable any class (refused at load). `Tamoz::Secret` is never admissible, above every policy decision.

## The local journal

Newline-delimited JSON in the operator runtime directory, rotated by size with a bounded file count, one file per process role and pid, written with the runtime directory's private-permission assertion, and never written to the runtime database (no contention with the fenced writer). The journal records **everything, unsampled**; it is also the export buffer. The worker's `--json` stdout shape is preserved byte-for-byte by a renderer over the same signals.

## Metrics and trace projection

Two deliberately asymmetric consumption paths:

- **Live** signals leave the process as produced — lossy is allowed, every loss is counted. `tamoz observe tail --follow` watches the journal; `tamoz status --watch` shows the authoritative spine.
- **Reconstructed** traces and derived gauges are computed on demand from the durable record through a read-only reader contract. Never lossy, they survive a crash and reproduce months later from a backup. `tamoz trace` builds the authoritative span tree.

Where the two disagree, the durable record wins, and the disagreement itself is a counted signal (`tamoz.telemetry.divergence`). Derived gauges are the same numbers `tamoz status` reports, moved behind the reader contract so they cannot drift. Metrics declare their label keys in the catalog, reject high-cardinality values, and refuse correlation identifiers as labels; histogram buckets are versioned with the catalog.

## Sampling and export

Sampling applies to **export only**, never to the journal and never to safety-bearing signals. The decision is taken when the exporter reads the journal — the turn's outcome is known by then, so retention is real tail sampling with no in-memory window and no restart hazard — and it is deterministic per turn from `trace_id` and `export_rate`. Interesting turns (paused, failed, denied, unknown-effect, budget-exhausted) are always exported. The exporter seam must not raise and must not retry internally; backoff and self-disable belong to the recorder, and an `:unknown` export is counted and forgotten — the plane is not durable. Optional OTLP export via `tamoz-otel` follows fixed egress rules (exact host, https, TLS verification, no redirects/proxy environment, private-address rejection unless declared for a sidecar); `--offline` mode writes only the journal and exports from a separate invocation that never constructs a session.

## Observability cannot change execution

Committed checkpoint bytes, model-facing message order, control flow, and outcomes are identical with observation enabled, disabled, and failing; an instrumentation call cannot raise into a caller; every signal, buffer, batch, label set, and file is bounded; and every drop is counted and inspectable. Safety-bearing observability is derived from durable evidence, correlated by durable identity, and never overstates what it measured — a cost carries whether it was measured or estimated and from which pricing source, and a span without a durable interval is marked ordering-only rather than given a fabricated duration.

## Next reads

- [`./README.md`](./README.md) — the design index
- [`../operations/observability-ops.md`](../operations/observability-ops.md) — operating the signal plane
- [`../reference/cli.md`](../reference/cli.md) — the `tamoz observe` and `tamoz trace` command surface
- [`../adr/README.md`](../adr/README.md) — ADR-044 through ADR-048, the observability decisions
- [`../../docs/OBSERVABILITY_DESIGN.md`](../../docs/OBSERVABILITY_DESIGN.md) — the authoritative design record
