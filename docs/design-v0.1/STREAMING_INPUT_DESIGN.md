# Streaming input and physical-world support

First-class unbounded evidence for Tamoz, without turning an LLM into a safety controller.

## 1. Decision

Streaming input is a distinct Tamoz capability. It ships as `tamoz-stream`, a first-class
runtime gem and the first post-v0.1 product milestone. It is optional for an ordinary CLI
installation, but it is part of the framework's compatibility contract rather than a
surface plugin.

`tamoz-stream` converts authenticated, typed, unbounded observations into immutable,
versioned **Situations**. A persisted admission decision may then start one bounded Tamoz
Agent episode against an exact Situation snapshot. The model never consumes an unbounded
channel directly.

This is deliberately different from three existing concepts:

| Concept | Meaning | Owner |
|---|---|---|
| execution streaming | bounded `StreamPart` progress from one already-started run | `tamoz-core` / `tamoz-graph` |
| scheduled input | a civil-time rule materializes a finite occurrence/request | `tamoz-scheduler` |
| streaming input | an unbounded, event-time-aware evidence source updates Situations | `tamoz-stream` |
| user channel | a CLI, chat, or gateway surface submits requests and renders results | Tamoz Agent |

MCP notifications and progress may be connector inputs, but MCP is not the high-rate data
plane. A skill may teach the agent how to interpret a Situation; it cannot register a
sensor, grant an effector, or change a channel's trust.

## 2. Why a separate runtime exists — five whys

1. **Why not call the agent for every event?** An event stream is faster, longer-lived, and
   noisier than a finite model call.
2. **Why not put events in a queue?** Most events do not deserve cognition, and queued
   reasoning becomes stale while evidence continues to change.
3. **Why not checkpoint the agent graph after each observation?** Graph checkpoints capture
   episodic workflow state. They do not define event time, late evidence, windows, source
   idleness, deduplication, or keyed stream recovery.
4. **Why not ask the model to infer those semantics?** Temporal correctness, overload
   behavior, and duplicate handling must remain deterministic and replayable.
5. **Why Situations?** A Situation is the stable semantic boundary between continuous
   evidence and bounded cognition. It lets Tamoz optimize for fewer, better-timed episodes
   instead of maximum agent activity.

The root problem is therefore not token transport. It is preserving temporal truth and
action safety while converting an unbounded world into finite decisions.

## 3. Architecture: four planes

```text
untrusted physical/digital sources
        │
        ▼
┌─────────────────────────────────────────────────────────────────────┐
│ deterministic stream plane                                          │
│ authenticate → validate → durable append → partition → window/timer │
│ → immutable Situation version                                       │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ persisted admission
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ cognition plane                                                     │
│ frozen SituationSnapshot → plan → review → reason → verify          │
│ → typed Decision + ActionIntent                                     │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ proposal, never direct effect
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ action plane                                                        │
│ current-state revalidation → policy → approval/interlocks           │
│ → idempotent Command → narrow effector → Outcome event              │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ control plane                                                       │
│ SituationSpec promotion · replay/shadow · operations · audit        │
└─────────────────────────────────────────────────────────────────────┘
```

Only the cognition plane starts a `tamoz-graph` run or loads RubyLLM. Connector polling,
stream operators, Situation reduction, and action reconciliation never make model calls.

## 4. Package and trust boundaries

`tamoz-stream` depends on `tamoz-core` values and owns a versioned structural StreamStore
contract; it does not require adapter constants or depend on `tamoz-graph`, `tamoz-agent`,
RubyLLM, MCP, or the scheduler. `tamoz-sqlite` implements the first StreamStore through an
explicitly required optional module. `tamoz-evals` loads both and verifies their declared
contract-version pair. Broker and device adapters are separate gems or application adapters.

| Zone | May receive | Must not receive |
|---|---|---|
| connector | source credential and raw payload | model/tool credentials, effector authority |
| deterministic core | admitted typed envelope | raw instruction authority, arbitrary code |
| cognition | frozen bounded snapshot, narrow evidence readers | broker/database/effector credentials |
| policy | typed intent plus current Situation/device state | prompt authority or stale approval as proof |
| effector | one validated Command and narrow credential | model text, general tool access |
| operator | deployment/replay controls under authenticated role | implicit production effect permission |

Raw observations are evidence, never instructions. Text from a microphone, camera OCR,
email, log, or sensor label remains untrusted data even when it resembles a system prompt.

## 5. Channel and event contracts

A `ChannelDescriptor` is a content-addressed deployed contract:

```ruby
# Illustrative
ChannelDescriptor.new(
  channel_id: "factory-1.temperature",
  revision: 7,
  transport: "mqtt",
  source_identity: "sensor-ca:device-428",
  schema: "temperature.v2",
  partition_by: %w[tenant_id device_id],
  delivery: :at_least_once,
  max_event_bytes: 16_384,
  queue_capacity: 2_000,
  spool_capacity_bytes: 268_435_456,
  overflow: :spill_then_reject,
  time: { field: "measured_at", max_clock_skew_s: 30 },
  classification: :internal,
  units: { value: "Cel" }
)
```

Every admitted envelope contains:

- stable `event_id`, `event_type`, `schema_id`, digest domain/version, and canonical payload
  hash;
- tenant, source, channel, partition key, and entity identity;
- source event time, source sequence when available, observed time, and ingestion time;
- correlation, causation, and trace identities;
- quality, calibration/status, units, and classification metadata;
- typed data with bounded depth, fields, strings, arrays, and total bytes;
- the exact channel revision and admission result.

Processing time is runtime-owned and never accepted from the payload. Event identity is
scoped by `(tenant_id, channel_id, channel_revision, source_id, event_id)`. Digests use a
stored domain and canonicalization/hash version; migration never silently reinterprets old
bytes. A repeated scoped id with the same canonical hash is an idempotent duplicate. The
same scoped id with a different hash is a security/integrity conflict and is quarantined.

Before durable admission, the connector authenticates the source and the core validates
schema, size, field bounds, units, time/skew, sequence, classification, and tenant binding.
Invalid data receives a durable rejection or quarantine record; it does not silently
disappear.

## 6. Delivery, acknowledgement, and backpressure

The reference delivery contract is at-least-once plus application-level deduplication.
Transport QoS is evidence about one hop, not proof that the complete physical effect or
observation pipeline is exactly-once.

The connector acknowledges an at-least-once source only after the event and its admission
metadata are durably appended. Each channel declares one bounded overflow policy:

- `block` — apply source backpressure when the transport safely supports it;
- `retry` — refuse acknowledgement and let the source retry within a bounded policy;
- `spill_then_reject` — use a bounded durable spool, then reject visibly;
- `sample` — retain a declared statistically meaningful sample;
- `coalesce` — retain a declared latest/aggregate value for a semantic key;
- `reject` — discard with an auditable gap record.

Sampling and coalescing are legal only when the channel schema defines their meaning. No
default may silently drop, reorder, or compress evidence. Queue depth, oldest age, rejected
count, sequence gaps, duplicates, and spool capacity are observable and bounded.

Overload preserves, in order: ingress safety, durable gap evidence, deterministic Situation
state, and action reconciliation. Cognition is the expendable plane: admissions may be
coalesced, deferred, superseded, expired, or rejected with a persisted reason.

## 7. Event time, windows, and timers

Tamoz records event time, observed time, ingestion time, processing time, decision time,
command time, and outcome time as distinct facts.

Watermarks express channel progress in event time. They are monotonic per partition and
may be heuristic. Source idleness is explicit; an idle partition cannot silently freeze
global progress. Every SituationSpec selects a late-data policy:

- `drop_with_audit`;
- `history_only`;
- `correct`;
- `correct_and_reconsider`.

Windows are bounded by time and size. Aggregates retain lineage, quality, completeness, and
the exact input range. No operator accumulates an unbounded Ruby collection.

`tamoz-stream` owns durable event-time and processing-time timers. They are not scheduler
occurrences. Event-time timers follow replayed watermarks; processing-time timers detect
silence, missing heartbeats, and operational deadlines and use a virtual clock during
replay.

## 8. Deterministic partitions and atomicity

The reference runtime is single-node first. A versioned, domain-separated stable hash of
tenant plus partition key maps each event to a virtual partition. Channel revisions persist
the partitioner algorithm, virtual partition count, and assignment-map version. Repartition
is an explicit migration with replay equivalence evidence; a deployment never changes the
mapping in place. State transitions are serial within a partition; partitions may execute
concurrently.

One short storage transaction:

1. records inbox/dedup state;
2. applies deterministic operators and due timers;
3. appends any immutable Situation version;
4. records trigger scores and admission outcome;
5. appends outbox work;
6. advances the partition checkpoint.

No model, network, approval, or effector call occurs inside that transaction. A crash
leaves either the old state or the complete new state. Rescaling or distributed execution
is deferred until replay, partition skew, and single-node throughput prove it necessary.

## 9. SituationSpec and immutable Situations

A `SituationSpec` is deterministic configuration, not user code. It declares:

- input schemas and partitioning;
- time, watermark, late-data, and idle-source policies;
- bounded windows, features, reducers, and timers;
- detectors and Situation lifecycle;
- cognition admission, debounce, cooldown, cost, and deadline policy;
- Decision and ActionIntent schemas;
- risk ceiling, freshness, approval, and replay policy.

Compilation rejects arbitrary scripts, model calls, I/O, nondeterministic iteration, host
timezone dependence, and unbounded state. The canonical compiled form has a digest.
Deployment is a behavior change: candidate → deterministic replay → shadow cognition →
isolated effect simulation → canary → active, with independent approval and rollback.

A Situation version is immutable and contains phase, facts, hypotheses, confidence,
uncertainty, evidence for and against, feature lineage, completeness, prior cognition and
action status, and provenance. Completeness is one of `provisional`, `on_time`,
`corrected`, `final_by_policy`, or `uncertain`.

The mutable “current Situation” is only a projection pointing to the newest immutable
version. Correction appends a version; it never rewrites history.

## 10. Cognition admission and the graph bridge

Every trigger evaluation persists component scores, evidence, reasons, completeness, cost
estimate, freshness, and deadline. Its outcome is one of:

`ignored`, `debounced`, `coalesced`, `deferred`, `admitted`, `superseded`, `expired`, or
`rejected`.

The cognition-admission queue is bounded. There is at most one active episode per
Situation. New evidence may supersede an in-flight episode; its late Decision is rejected
because its snapshot is no longer current.

An admitted `SituationSnapshot` is bounded and content-addressed. It includes the exact
Situation version, delta from the prior considered version, multi-resolution features,
evidence for and against, uncertainty, prior Decisions/Outcomes, permitted read tools,
Decision/Intent schemas, and a canonical hash.

The Tamoz Agent bridge derives a stable request id from tenant, Situation id/version, and
admission id. It then enters the ordinary plan → review → execute → verify graph. The
accepted plan is bound to the snapshot digest. A graph checkpoint is episodic state; the
StreamStore remains the source of stream recovery.

## 11. Decisions, physical actions, and interlocks

The agent returns a typed `Decision` that separates observed facts from inferences, cites
evidence, states uncertainty, carries a validity interval, and proposes zero or more typed
`ActionIntent`s. An intent declares minimum Situation completeness, maximum uncertainty,
required evidence quality/quorum, required source health/calibration, and tolerated gap or
conflict state. It never calls a physical effector directly.

Before dispatch, deterministic policy reloads current Situation and device state, then
checks:

- snapshot freshness and non-supersession;
- required Situation completeness and uncertainty threshold;
- evidence quality, source quorum, source health/calibration, and absence of disallowed
  gaps or unresolved contradictions;
- current preconditions and expected state/version;
- tenant, capability, spatial, device, and time scope;
- risk, quotas, rate, energy/force/position bounds, and command expiry;
- approval and separation-of-duty requirements;
- external safety-controller/interlock readiness;
- idempotency or reconciliation support.

Approval does not freeze reality or bypass freshness. Policy revalidates every check,
including completeness and evidence health, after approval. R2 and R3 fail closed when a
required source is unhealthy, calibration is expired, a disallowed gap/conflict remains,
quorum is missing, or uncertainty exceeds the intent threshold.
An accepted intent becomes a stable `Command`, is journaled through the ordinary effect
boundary, and is delivered to a narrow effector. The resulting receipt and observed
`Outcome` return as evidence. An ambiguous effect becomes `effect_unknown` and is
reconciled; it is never retried blindly.

| Risk | Default physical-world authority |
|---|---|
| R0 | observe, classify, explain |
| R1 | notify, recommend, draft a command |
| R2 | bounded and reversible action; explicit grant, current-state checks, approval/interlocks |
| R3 | consequential action denied unless a deployment-specific deterministic policy and human approval explicitly allow it |
| R4 | life/safety-critical or certified-control function: advisory only |

Emergency stops, guarding, safe speed/force limits, PLC logic, certified communication,
and other functional-safety mechanisms remain external and authoritative. Tamoz cannot
disable, weaken, emulate, or heal around them.

## 12. Physical-world profile

The first profile is supervisory, not robotic motion control:

- equipment health and anomaly Situations;
- environmental monitoring;
- inventory/location Situations;
- human notification and escalation;
- maintenance diagnosis and reviewed work orders;
- bounded commands through an existing safe automation system.

Camera, microphone, radar, and other high-rate media require a trusted edge extractor that
emits bounded typed feature events with model/version/calibration provenance. Raw
video-rate inference, direct motor trajectories, PLC scan-cycle logic, sub-millisecond
control, medical-device control, and certified safety functions are non-goals.

Edge mode may buffer inputs offline, maintain deterministic Situations locally, run a
locally approved model, and queue remote escalation. Loss of cloud/model connectivity
cannot remove external safety. Offline effect authority is separately and narrowly
configured; its default is observe and alert locally.

## 13. Replay and evaluation

Four explicit replay modes prevent tests from becoming production:

1. `deterministic` — operators/Situations only; no model and no effects;
2. `recorded_cognition` — reuse recorded Decisions; no model and no effects;
3. `shadow` — run a candidate model/spec; effects disabled;
4. `counterfactual` — route commands only to an explicit simulator/outcome model.

Replay is effect-disabled by construction. Enabling a simulator does not enable a real
effector, and production credentials are unavailable to replay workers.

Release evidence includes:

- golden event-time traces with duplicates, reordering, late data, idleness, clock skew,
  gaps, corrupt payloads, restart, and partition races;
- deterministic Situation and admission artifacts under virtual time;
- event absorption, lag, state size, queue bounds, and recovery objectives;
- Situation precision/recall, time-to-detection, false/stale admission, and missed-event
  analysis;
- agent correctness and calibration using identical snapshots;
- superseded/expired decision rate and cognition cost per useful outcome;
- policy-denial, approval, duplicate command, `effect_unknown`, reconciliation, and
  unsafe-action rates;
- comparative ablations: raw-event prompt, window dump, and Situation-grounded episode;
- protected physical-world scenarios whose safety gates are not visible to improvement
  candidates.

Any unsafe real-effector call during replay, direct model-to-effector path, silent evidence
loss, stale approved command, or bypassed interlock is a hard failure with a score of zero.

## 14. Memory, learning, and healing boundaries

The event log, features, and Situations are operational evidence, not Experience,
Knowledge, or Wisdom. Only a completed episode plus independently observed Outcome may
propose an Experience record. Normal authorization, provenance, consolidation, evaluation,
and promotion rules still apply.

Self-improvement may propose a SituationSpec, detector threshold, channel binding, or
policy candidate. It cannot activate its own candidate, expose the protected set, or widen
physical authority.

Self-healing may reconnect a connector, rebuild a derived projection, quarantine a sensor,
fail over to a declared redundant source, or open a circuit. It cannot fabricate missing
evidence, mark an uncertain device safe, disable an interlock, widen actuation, or turn an
ambiguous effect into success.

## 15. Storage contract

The StreamStore persists:

- channel revisions, source sessions, admissions/rejections, event log, and inbox dedup;
- partition checkpoints, bounded operator state, watermarks, timers, and gap records;
- Situation specs, immutable versions, current projections, and lineage;
- trigger evaluations, cognition admissions, snapshot digests, and bridge request ids;
- Decisions, Intents, approvals, Commands, outbox records, receipts, and Outcomes;
- replay jobs, isolated artifacts, promotion decisions, and audit events.

Retention may compact raw payloads only after policy permits and lineage remains sufficient
to explain every active Situation and action. Deletion propagates through derived state and
produces a receipt. Backups, restore drills, integrity checks, and schema migrations are
part of the adapter's release gate.

## 16. Promotion gate

`tamoz-stream` is promoted only when one real read-only physical source and one simulated
effector prove the full path. The gate requires:

1. clauses 44–51 pass under restart, overload, replay, and adversarial input;
2. one adapter acknowledges only after durable admission and reports every gap;
3. event-time golden traces are byte-deterministic;
4. the Situation-grounded approach beats raw-event/window baselines on protected cases;
5. replay and shadow workers cannot obtain production effector credentials;
6. every physical command is typed, fresh, policy-checked, interlocked, journaled, bounded,
   and reconciled;
7. an independent safety review accepts the deployment profile and explicit non-goals.

## 17. External design evidence

- [Apache Flink's event-time model](https://nightlies.apache.org/flink/flink-docs-stable/docs/concepts/time/)
  distinguishes processing time, event time, watermarks, idleness, and late evidence.
  Tamoz adopts those semantics, not its API.
- [MQTT 5](https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html) defines transport
  QoS levels. Tamoz still requires application event identity and effect reconciliation
  because broker delivery is not end-to-end physical exactly-once.
- OPC UA separates ordinary
  [PubSub](https://reference.opcfoundation.org/specs/OPC-10000-14/1) from its
  [functional-safety communication layer](https://reference.opcfoundation.org/specs/OPC-10000-15/4).
  Tamoz is an observer/client of independently safe automation, not a substitute safety
  layer.
- [ISO 10218-1:2025](https://www.iso.org/standard/73933.html) and ISO 10218-2:2025 separate
  robot safety from system integration. Any industrial deployment requires the applicable
  domain standards and qualified integrators beyond this software design.
- [NIST AI RMF](https://nvlpubs.nist.gov/nistpubs/ai/nist.ai.100-1.pdf) motivates explicit
  governance, measurement, human oversight, and testing for systems that can cause
  physical or environmental harm.

This document defines framework architecture, not a safety certification or permission to
deploy Tamoz in a consequential physical system.
