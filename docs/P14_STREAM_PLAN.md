# P14 — streaming input and simulated physical action: implementation plan

Status: accepted for implementation (revision 3 — checkpoint deep-review migration and
behavioral-proof corrections integrated; see
`docs/reviews/DESIGN_CHECKPOINT_6FF0D40_DEEP_REVIEW.md`)
Authoritative inputs: `docs/design-v0.1/STREAMING_INPUT_DESIGN.md` (source of truth for
semantics), `AGENT_DESIGN.md` §16, invariants 44–51, the P14 card in
`docs/PROJECT_HANDOVER_PLAN.md`.

Owner constraint in force (binding for this phase): **no real physical actuators are
connected without explicit owner approval.** P14 v1 therefore proves the full path with
one authenticated **simulated** read-only source and a **simulator-only** effector. The
card's "physical" clause is kept verbatim in the outcome table below and explicitly
deferred: the simulated source implements the same authentication/trust contract a real
adapter will implement, so the swap cannot silently weaken the proven guarantees. Real
adapter discussion (design §16 gate items 6–7) is deferred and requires a separate owner
decision.

Phase activation rule: committed as a design artifact while P10 is active; the handover
ledger's P14 row stays `pending` until P13 closes. No P14 code before that.

## 1. Scope commitment and phase outcome

Handover card outcome, verbatim: "optional `tamoz-stream` converts one authenticated
read-only **physical** source into deterministic immutable Situations; bounded cognition
proposes typed intent; only a simulator receives commands through current-state policy
and an independently controlled interlock."

| Outcome clause | Work package | Proof (test, not claim) |
|---|---|---|
| one authenticated read-only physical source → deterministic Situations | P14-D/A/B | simulated source implements the production `ChannelConnector`/`SourceSession` contract (C4); forged/wrong/replayed credentials → durable rejection; events admit durably; virtual partitions + serial transition produce immutable Situation versions; golden traces byte-deterministic under the virtual clock (C1) |
| bounded cognition proposes typed intent | P14-C | one episode per Situation enforced at the graph layer via namespace mapping (C7); typed Decision + ActionIntent only; supersession/expiry rejection incl. the adversarial window (C10/P2) |
| only a simulator receives commands | P14-P/S | the ONLY effector is the simulator; replay/shadow workers resolve no credentials (C5, poison-resolver test); Command dispatch path named (C2) |
| through current-state policy and an independently controlled interlock | P14-P | production `InterlockReader` is read-only; dependency-direction test proves production code cannot reference the harness or a write API (C6); delivery-window TOCTOU handled (C6) |

Hard stop (card, binding): silent evidence loss, nondeterministic replay, direct
model-to-effector path, stale/superseded dispatch, replay reaching real effects, approval
bypassing current state, ability to disable/heal around an interlock. R4 advisory only.
No raw video-rate cognition, motor control, PLC loop, medical control, or certified
safety function.

## 2. Package boundary and reuse

New gem `tamoz-stream` (design §1/§4): depends on `tamoz-core` values, owns a versioned
structural `StreamStore` contract; no hard dependency on `tamoz-graph`, `tamoz-agent`,
RubyLLM, MCP, or the scheduler. `tamoz-sqlite` implements the first StreamStore in an
explicitly required optional module. `tamoz-evals` loads both and verifies the
contract-version pair. Broker/device adapters are separate application adapters (v1:
simulated fixture only, inside the test tree, implementing the production contract).

Plane ownership (design §3): only the cognition plane starts a `tamoz-graph` run or loads
RubyLLM. Connector polling, stream operators, Situation reduction, and action
reconciliation never make model calls. Reuse: the P7 request inbox + P6 lease/fence for
the bridge request; the effect journal's key/safety/reconcile semantics (C2); the
existing error classes (`LeaseLostError`, `CheckpointConflictError`, `ClockRollbackError`)
(C9). Do NOT reuse MCP as the data plane.

**The single transaction seam (C3):** `process_partition(partition_id, batch)` is the
ONE `adapter.transaction` boundary owning all six §8 steps (inbox/dedup → operators +
timers → Situation append → trigger scores + admission → outbox append → partition
checkpoint). The adapter's `transaction` is non-reentrant (no savepoints), so no nested
transaction is allowed; the graph request-inbox enqueue is OUTSIDE it via the outbox
drain. The drain runs after the transaction with its own lease, and is idempotent by
construction: it calls `CheckpointStore#enqueue_request` with the stable derived request
id — a drained-twice row is a no-op (same request id + input digest → no-op; different
payload → `CheckpointConflictError`, surfaced typed). Crash between outbox append and
drain: the drain retries the same row → one logical episode (invariant 23). Named test:
kill-between-outbox-and-enqueue (C10/P5).

**Migration (C8):** stream tables live in the SAME database via the next checksummed
Migrator slot at activation (expected `MIGRATION_4` after P11/P13; `CURRENT_VERSION`
bump). No plan owns a reusable `MIGRATION_2+` placeholder. Migration
never reinterprets old bytes (design §5): digest domains and canonicalization versions
are stored; old payload bytes are never re-decoded under a new scheme.

## 3. Channel, event contracts, and the connector contract (P14-D)

Profile: supervisory (design §12). `ChannelDescriptor` as drafted (channel_id, revision,
transport, source_identity, schema, partition_by, delivery `:at_least_once`, bounded
queue/spool, overflow policy, time field + max_clock_skew_s, classification, units).

**Production `ChannelConnector`/`SourceSession` contract (C4)** — the seam that makes the
real-adapter swap safe:

```ruby
ChannelConnector.authenticate(source_identity, credential) -> SourceSession | raises
SourceSession#read -> EventEnvelope         # bounded, typed
SourceSession#ack(event_id)                 # only after durable admission
# auth failure (wrong key / forged identity / replayed credential) -> durable rejection record
```

The simulated fixture implements this contract; golden-trace cases include wrong key,
forged identity, and replayed credential → durable rejection (never silent drop, never
admission). The connector zone never receives model/tool/effector credentials (design §4
zone table).

Every admitted envelope: stable `event_id`/`event_type`/`schema_id`, digest
domain/version, canonical payload hash, tenant/source/channel/partition/entity identity,
event/observed/ingestion time, correlation/causation/trace ids, quality/calibration/
units/classification, bounded typed data, channel revision, admission result. Processing
time is runtime-owned, never accepted from the payload. Identity scoped by
`(tenant_id, channel_id, channel_revision, source_id, event_id)`; same-id-same-hash
idempotent, same-id-different-hash quarantined (invariant 45). Admission rejects durably.

## 4. Admission, ack, backpressure (P14-A)

At-least-once + application dedup (design §6). Connector acknowledges only after the
event and admission metadata are durably appended. One bounded overflow policy from the
§6 set per channel; sampling/coalescing legal only when the schema defines their meaning;
no default silently drops/reorders/compresses. Queue depth, oldest age, rejected count,
gaps, duplicates, spool capacity observable and bounded. Overload preserves in order:
ingress safety → durable gap evidence → deterministic Situation state → action
reconciliation. Cognition is the expendable plane.

## 5. Deterministic runtime and the virtual clock (P14-B)

**The clock contract (C1):** verified — no virtual clock exists in the repo; the sqlite
adapter records wall time via `backend_time` inside every transaction, guarded by
`guard_backend_clock!`/`ClockRollbackError`. This design therefore specifies:

- a first-class injected clock (`StreamClock` interface: `now_processing`,
  `now_event(watermark)`, `advance(delta)`), provided by the runtime in `live` mode and
  by the harness in `replay` mode;
- stream tables NEVER call `backend_time`/wall time: all timestamps written inside
  `process_partition` come from the injected clock, so replay re-executes the identical
  operator chain under the same virtual clock and produces byte-identical state;
  the interaction with `guard_backend_clock!` is defined: stream transactions bypass the
  wall-clock guard for stream-owned time columns (documented, tested), and
  `ClockRollbackError` still guards the non-stream adapter paths;
- the golden-trace artifact: canonical JSON of (admitted envelopes → partition state →
  Situation versions → admission outcomes → outbox) serialized with the DR-3-style
  canonicalizer; **replay = live determinism test**: run the same virtual-time scenario
  twice and diff bytes (this is the definition of "byte-deterministic"; replay is NOT a
  separate interpreter — it re-executes the identical code path under the injected
  clock).

Watermarks monotonic per partition; source idleness explicit with a named mechanism:
an idle-timeout timer (processing-time, virtual clock) advances the partition watermark
when no events arrive for N virtual-time units (C10/P4). Late-data policies from §7;
windows bounded by time and size with lineage and exact input range; no unbounded Ruby
collections.

Single-node reference runtime: versioned, domain-separated stable hash → virtual
partition; repartition is an explicit migration with replay-equivalence evidence.
Serial transitions within a partition; concurrent across partitions. Durable event-time
and processing-time timers live here (not scheduler occurrences); processing-time timers
use the virtual clock during replay.

## 6. SituationSpec and Situations (P14-C base)

`SituationSpec` is deterministic configuration, not user code (design §9). Compilation
rejects scripts/model calls/I/O/nondeterministic iteration/host-timezone/unbounded
state; the canonical compiled form has a digest — **reusing the P8/P9 artifact-digest
pattern** (canonicalized JSON + domain separator), not a new scheme (C10's
"second compiler" risk). Deployment is a behavior change through candidate → replay →
shadow → isolated simulation → canary → active, with independent approval and rollback.

Situation versions immutable with phase/facts/hypotheses/confidence/uncertainty/
evidence/lineage/completeness/prior cognition+action status/provenance. Current
Situation is only a projection; correction appends a version.

Cognition admission: every trigger evaluation persists scores/evidence/reasons/
completeness/cost/freshness/deadline; outcome one of `ignored`, `debounced`,
`coalesced`, `deferred`, `admitted`, `superseded`, `expired`, `rejected`. Bounded queue.

**One-episode-per-Situation enforced at the graph layer (C7):** the bridge maps the
Situation to a thread namespace — `namespace = ["situation", situation_id]` — so the
graph's existing single-fenced-writer-per-namespace rule (invariant 20,
`validate_lease_in_transaction!`) mechanically enforces "at most one active episode per
Situation"; a superseded episode's late Decision dies at the action plane on the
snapshot-digest mismatch (freshness check). The derived request id must fit
`Wire::MAX_REQUEST_ID_BYTES` (asserted; oversized → `ConfigurationError` at build time,
never at enqueue). The accepted plan binds the snapshot digest (invariant 49).

## 7. Command dispatch — the named path (C2)

Verified: `EffectJournal#prepare` validates the lease AND that the effect's execution id
is the active graph execution, so a stream-side dispatch after the episode run ended
cannot use the ordinary prepare path. Named decision: **Command dispatch happens INSIDE
the episode's graph execution** — the action boundary runs as the terminal node of the
same durable run that produced the Decision, so the journal's active-execution
precondition holds and the Command is journaled through the ordinary effect boundary
(effect key from the intent, `:unknown` on ambiguity, reconcile semantics per invariant
21). A separate stream-side journaling path is explicitly NOT built. The simulator
receives the Command only after: post-approval revalidation (design §11 checklist) AND
interlock ready (below). Ambiguous outcomes → `effect_unknown` → reconcile, never blind
retry.

**Interlock (C6):** production code sees only an `InterlockReader` exposing read-only
methods (`ready?(interlock_id)`, `state(interlock_id)`); the mutable harness lives in
the test tree; a dependency-direction test proves production `tamoz-stream` (and the P12
healing paths) cannot reference the harness or any write API. **Delivery-window TOCTOU:**
the interlock is re-read at the narrowest point — immediately before Command delivery —
and the simulator asserts ready at delivery (rejects a Command delivered after the
interlock tripped); the hard-failure list gains "command dispatched while interlock
tripped". R2/R3 fail closed on unhealthy source, expired calibration, disallowed
gap/conflict, missing quorum, uncertainty over threshold (post-approval revalidation
repeats every check).

Risk table v1: R0 observe/classify/explain (simulated source); R1 notify/recommend;
R2/R3 bounded reversible action through the SIMULATOR only with explicit grant +
current-state checks + approval + interlock; R4 advisory-only, asserted never dispatched.

## 8. Simulator proof and replay credentials (P14-S)

Four replay modes (`deterministic`, `recorded_cognition`, `shadow`, `counterfactual`).

**Credential isolation (C5) — mechanisms, not claims:** enumerate credential kinds —
source (connector auth), model (provider), tool (skill/MCP), effector (simulator).
Per mode: `deterministic` and `recorded_cognition` resolve NO credentials; `shadow`
runs a candidate model via a fixture/reference model (the P13 pattern) and resolves NO
effector or source credentials; `counterfactual` routes commands to the simulator only
and resolves no production credentials. Two tests: (a) behavioral — a poisoned
credential resolver that raises on ANY resolution, run under each replay mode, must
never raise and never resolve (if a code path tries, the test fails); (b) type-level —
the replay runtime constructor accepts no credential argument (asserted by API shape).
Real-effector calls during replay are impossible by construction (no effector
credentials exist in replay scopes) and asserted by the same poison test. Enabling the
simulator never enables a real effector.

## 9. Evaluation (P14-E)

Golden traces under virtual time: duplicates, reordering, late data, idleness, clock
skew, gaps, corrupt payloads, restart, partition races — INCLUDING the sequence case
good-event-then-same-id-different-hash (quarantine record asserted) (C10/P1) and the
kill-between-outbox-and-enqueue case (P5). Treatments: raw-event prompt vs window dump
vs Situation-grounded episode. Metrics: Situation precision/recall, time-to-detection,
false/stale admission, missed events, superseded/expired decision rate, cognition cost
per useful outcome, policy-denial/approval/duplicate-command/`effect_unknown`/
reconciliation/unsafe-action rates, event absorption/lag/state size/queue bounds/
recovery. Hard failures (score zero): unsafe real-effector call during replay, direct
model-to-effector path, silent evidence loss, stale approved command, bypassed
interlock, command dispatched while interlock tripped.

**Protected scenarios (C10):** the safety-gated scenarios are structurally separated
from the ablation corpus (separate directory/namespace the ablation runner's corpus
access cannot reach — the P12-I2 candidate-blindness pattern), so improvement
candidates can never see the safety gates.

## 10. Failure model (C9)

| Situation | Type | Behavior |
|---|---|---|
| admission rejection/quarantine | durable records (outcome values) | never raised; never silent |
| storage corruption / lease loss | `CheckpointCorruptionError` / `LeaseLostError` (reuse) | propagate (invariant 17) |
| clock rollback detected (non-stream path) | `ClockRollbackError` (reuse) | unchanged guard |
| interlock read failure | `InterlockUnavailableError` (new) | FAIL CLOSED: no dispatch |
| watermark regression | `WatermarkRegressionError` (new) | partition halts; typed; operator-visible |
| quarantine overflow | `QuarantineOverflowError` (new) | bounded; gap record; never silent drop |
| oversized derived request id | `ConfigurationError` (reuse) | at build time, never at enqueue |

## 11. Deferrals (explicit, with entry conditions)

- **Real adapters** — entry: owner approval + independent safety review (design §16
  items 6–7). The simulated fixture implements the production connector contract so the
  swap is contract-bound, never silent.
- **Edge mode** (offline buffering, local model) — entry: a real adapter + owner decision.
- **Distributed/partitioned execution** — entry: replay, partition skew, single-node
  throughput evidence.
- **Situation→memory coupling** — completed-episode + independently-observed-Outcome
  seam feeds P11 Experience via a documented adapter, not inside tamoz-stream.

## 12. Stop / redesign criteria

Any of: silent evidence loss; nondeterministic replay (the determinism test fails);
a direct model-to-effector path; stale/superseded Decision reaching dispatch (incl. the
adversarial window); replay/shadow resolving any credential or reaching a real effect;
approval bypassing post-approval revalidation; the stream (or a healing rule) able to
disable/heal around the interlock; a Command dispatched while the interlock tripped;
R4 or a life-safety role dispatched.

## 13. Definition of done (v1)

- [ ] P14-D simulated supervisory profile + production connector contract + golden
      auth-failure cases (C4).
- [ ] P14-A StreamStore admission with durable ack, dedup, quarantine, bounded
      backpressure outcomes.
- [ ] P14-B `process_partition` single-transaction boundary + injected `StreamClock` +
      replay-equals-live determinism test (C1) + idle-watermark mechanism (P4).
- [ ] P14-C cognition bridge with namespace-mapped one-episode-per-Situation (C7),
      snapshot-bound plan, supersession/expiry rejection incl. the adversarial window.
- [ ] P14-P action boundary as the episode-run terminal node (C2) with post-approval
      revalidation, read-only `InterlockReader` + dependency-direction test, delivery-
      window handling (C6).
- [ ] P14-S simulator-only effector with poison-resolver + constructor-absence tests
      (C5) across the four replay modes.
- [ ] P14-E golden traces byte-deterministic incl. the sequence and outbox-drain cases;
      ablation comparison; all hard-failure gates zero; protected scenarios
      structurally separated (C10).
- [ ] Migration via the existing Migrator (C8); typed failure taxonomy (C9).
- [ ] `rake ci` green under both locales; every scorecard case present at P14 start is
      unchanged with safety counters zero; mandatory fixed `agent.situation-...` case
      proves the new capability without weakening any hard gate (handover §7).
- [ ] Trackers updated; deferrals recorded incl. the real-adapter owner gate.
