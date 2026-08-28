# ADR-055 — The continuous plane is a separate Go authority (`agentic-stream`); Tamoz is its episode worker

**Status:** Accepted 2026-08-12
**Date:** 2026-08-29 (recording a shipped split; resolves audit open item O1)
**Relates to:** ADR-035 (streaming is a distinct runtime — **revised**: the continuous plane moved out of the Ruby gem), ADR-037 (event time/backpressure/replay contracts — **revised**: now owned by the stream, not Tamoz), ADR-036 (Situation is the boundary — reinforced), ADR-038 (typed intent, never model effect — reinforced), ADR-039 (Tamoz is supervisory — reinforced), ADR-040 (one monorepo — this is the deliberate exception).

The continuous, deterministic streaming plane is not a Ruby Tamoz gem. It is a separate
runtime, **`agentic-stream`** (Go), which owns event time, watermarks, windows, channels, and
replay, is authoritative for budget and Decision disposition, and dials Tamoz's `tamoz-stream`
**episode worker** to run exactly one immutable episode against a sealed Situation snapshot.
This records the two-repo authority split and revises the parts of ADR-035/037 the migration
outdated.

Current version: `0.1.0.alpha.1` (pre-release).

## 1. Context

ADR-035 made streaming a "distinct first-class `tamoz-stream` runtime" that owned channel
admission, temporal/keyed state, immutable Situations, cognition admission, and replay — all in
Ruby. ADR-037 put event-time/watermark/backpressure/replay contracts in that runtime.

The system then diverged from that shape in a way the ADR corpus never recorded. The previous
P14 continuous engine was **retired by forward migration (MIGRATION_13)**. The continuous plane
— event time, watermarks, windows, channels, replay, device I/O, effector control, capability
issuance — moved into a separate Go runtime, `agentic-stream`, which is where hard real-time,
throughput, and deterministic temporal semantics belong. Tamoz kept the part it is uniquely
good at: bounded, evaluated, reviewable **cognition** over a sealed snapshot.

Two forces drove the split:

1. **Different engineering regimes.** The continuous plane is a throughput/latency/temporal
   system; Tamoz is a durable-cognition system. Forcing both into one Ruby runtime (ADR-035's
   original shape) made neither clean. A Go authority is the right tool for the deterministic
   plane; the Ruby worker is the right tool for judgment.
2. **Authority must not sit with cognition.** An LLM-bearing process must never be authoritative
   for budget, Decision acceptance, physical effect, or durable terminal state (ADR-038/039).
   Putting the authority in a separate runtime makes that structural, not a matter of discipline.

## 2. Decision

**The continuous plane is `agentic-stream` (a separate Go repository/runtime). Tamoz's
`tamoz-stream` gem is the `EpisodeWorker` — a gRPC server the stream dials to run exactly one
non-interactive episode against a sealed, digest-verified Situation snapshot.**

- **Contract.** `tamoz-stream` implements `agenticstream.runtime.v1.EpisodeWorker` with two
  RPCs: `Handshake` (protocol/feature compatibility) and `Execute(EpisodeRequest) -> stream
  EpisodeEvent`. Tamoz is the **server**; the `agentic-stream` executor is the **client** and
  remains authoritative for budget consumption, Decision validation, acceptance/rejection, and
  durable terminal state. Worker-originated events are **proposals and telemetry**, never
  commands.
- **The stream owns the deterministic plane.** Event time, watermarks, lateness, and window
  membership are computed by `agentic-stream`. **Tamoz computes none of them.** Tamoz receives
  a sealed snapshot and proposes typed Decisions.
- **Sealed snapshots.** The request carries `snapshot_json` + `snapshot_sha256`; the worker
  recomputes and compares the digest in constant time and terminates a drifted/tampered
  snapshot **before any model call**.
- **Containment.** An episode runs in the episode capability host — a fixed allowlist of
  read-only bounded tools (`features.query`, `evidence.get`, `situations.related`,
  `history.prior_incidents`, `knowledge.search`, `forecast.run`) with no toolbox, effect
  journal, MCP client, filesystem root, or memory write path. The worker never calls a physical
  effector; it proposes typed `ActionIntent`s the runtime disposes of.
- **Reverse channel.** The worker reaches evidence only via short-lived **opaque capability
  tokens** (never logged/persisted) encoding the exact permitted tools, over the runtime's
  reverse RPCs.
- **Transport.** Normally a Unix domain socket (`run-live --worker-socket`), with optional mTLS.

## 3. Consequences

- **ADR-040 gets a deliberate exception.** Tamoz stays one monorepo, but the continuous
  authority is a *second* repository in a different language. This is intentional: the two
  planes have different engineering regimes and a hard authority boundary between them. Repo
  proximity was never the coupling (ADR-040); a process/language boundary makes the
  authority split structural.
- **ADR-035 is revised, not discarded.** Its core rule — unbounded evidence never enters a
  graph or model directly; it becomes a bounded Situation first — still holds. What changed is
  *where* the continuous runtime lives (Go `agentic-stream`, not the Ruby gem) and what
  `tamoz-stream` is (the episode worker, not the continuous engine).
- **ADR-037 is revised.** Event-time/backpressure/replay contracts are the stream's, not
  Tamoz's. The Ruby side's old channel/backpressure/replay vocabulary
  (`queue_capacity`/`spool_capacity_bytes`/`overflow`) was deleted with MIGRATION_13.
- **ADR-036/038/039 are reinforced.** The sealed snapshot is the Situation boundary; the worker
  proposes typed intents and never actuates; authority (budget, disposition, effect) stays with
  the external runtime, never with the LLM-bearing worker.
- **Cross-repo coordination cost.** The `runtime-v1` proto is a frozen wire contract shared
  across two repos; changing it is a coordinated two-repo release. The Handshake RPC exists
  precisely to refuse incompatible protocol/feature versions at the boundary.

## 4. Invariant linkage

- **ADR-036 / Situation boundary** — the digest-verified snapshot is the exact immutable
  boundary between continuous evidence and episodic cognition.
- **ADR-038 R2/R3** — typed intents proposed, disposed by the authoritative runtime; the worker
  holds no effector credentials.
- **Prompt-cache / ADR-009, sensitive-data / ADR-020** — apply inside the episode as in any
  Tamoz graph run.

## 5. Threat model

**Asset:** physical/operational effect, the evidence the runtime holds, and budget.

| Threat | Vector | Mitigation |
|---|---|---|
| The LLM-bearing worker actuates or over-spends | A compromised/mistaken runner tries to command | The worker only *proposes*; `agentic-stream` is authoritative for budget, acceptance, and effect; the worker holds no effector credentials |
| A drifted or tampered snapshot drives a decision | Snapshot altered in transit | `snapshot_sha256` recomputed and compared in constant time; a mismatch terminates before any model call |
| Injection names a forbidden tool | Prompt injection requests `run_shell` etc. | The episode capability host is a fixed read-only allowlist; unknown keys are refused at construction, not at call time |
| A leaked reverse-channel token is replayed | Capability token reused | Tokens are short-lived, opaque, encode the exact tools, and are never logged or persisted |
| A runner bug spends model budget | Malformed event stream | `Execute` validates identity, fence, kind, budget, and the event stream (started event, sequence gaps, terminal, size) at the worker boundary before spending |

## 6. Rejected alternatives

| Rejected | Why |
|---|---|
| Keep the continuous plane in the Ruby `tamoz-stream` gem (ADR-035's original shape) | A throughput/temporal system and a durable-cognition system in one Ruby runtime served neither; the deterministic plane wants Go |
| One repository for both planes (strict ADR-040) | The two planes have different languages, release cadences, and — critically — an authority boundary; co-locating them would blur exactly the boundary that keeps the LLM out of the authority path |
| Make Tamoz the gRPC client/authority | Authority would then sit in the LLM-bearing process; ADR-038/039 require the reverse — the external runtime disposes, the worker proposes |
| A shared database instead of a sealed snapshot | A live read reintroduces staleness and an ambient trust surface; the digest-verified snapshot is the exact, attributable boundary |

## 7. Verification

Verified against code: 2026-08-29 — `gems/tamoz-stream` implements the `EpisodeWorker` per
[`documentation/design/streaming.md`](../design/streaming.md); the sealed-snapshot, containment
host, and reverse-channel behavior are documented there and exercised by
`test/stream_evidence_client_test.rb` ("the stream's host lives in agentic-stream"). Cross-repo
alignment was verified in `docs/STREAM_WORKER_IMPLEMENTATION_AUDIT_2026-08-12.md` (agentic-stream
`run-live --worker-socket`, native Go executor, per-dispatch opaque capability issuance).
**Boundary caveat:** the Go side (`agentic-stream`) lives in a sibling repository not present in
this tree; its internals are cited from that repo's audited state, not re-verified here.

## Next reads

- [`README.md`](./README.md) — the ADR index
- [`../design/streaming.md`](../design/streaming.md) — the episode-worker design (current)
- [ADR-035 — streaming is a distinct runtime](./adr-035-streaming-input-is-a-distinct-first-class-runtime.md) and [ADR-037 — event-time contracts](./adr-037-event-time-explicit-backpressure-and-effect-disabled-replay-are-contracts.md) — revised by this ADR
- [`../../docs/design-v0.1/STREAMING_INPUT_DESIGN.md`](../../docs/design-v0.1/STREAMING_INPUT_DESIGN.md) — the original architecture record
