# The supervised episode worker (`tamoz-stream`)

`tamoz-stream` is the boundary where continuous, unbounded evidence becomes one bounded, supervised agent episode. Tamoz's part of that boundary is the **episode worker**: a gRPC service the stream runtime dials to run exactly one immutable episode against a sealed Situation snapshot.

Sources: [`docs/design-v0.1/STREAMING_INPUT_DESIGN.md`](../../docs/design-v0.1/STREAMING_INPUT_DESIGN.md) (the architecture the worker implements) and [`../limitations.md`](../limitations.md) (the retirement of the previous engine).

Current version: `0.1.0.alpha.1` (pre-release).

## The EpisodeWorker service

The worker implements the `agenticstream.runtime.v1.EpisodeWorker` gRPC service with two RPCs:

```text
Handshake(HandshakeRequest) -> HandshakeResponse      # protocol compatibility
Execute(EpisodeRequest)     -> stream EpisodeEvent    # one immutable episode
```

- The worker is the **server**: the stream runtime's executor dials it (normally over a Unix domain socket), negotiates the handshake, and streams one episode through `Execute`. Worker-originated events are proposals and telemetry; the runtime remains authoritative for budget consumption, Decision validation, acceptance or rejection, and durable terminal state.
- Only **non-interactive** episodes are served. The worker runs graphs inside the containment host, and an interrupting skill is a typed terminal failure, never a wait.
- The worker owns the wire contract on both RPCs: the handshake refuses unsupported protocol/contract versions and unsupported required features, and `Execute` validates the request (episode/attempt identity, positive fence, supported episode kind, budget) and the event stream itself (started event, sequence gaps, missing terminal, oversized events never reach the wire). A runner bug is refused at the worker boundary before it can spend model budget.
- The request carries the episode identity (episode id, attempt id, fence, cancellation key, kind, lane, risk ceiling, allowed intent types), the evidence time range, an optional reconsideration, and the budget: wall time, max model/tool calls, max input/output tokens, max tool-result bytes, max provider retries, and max cost.

## The containment host

An episode executes inside the **episode capability host**, whose tool surface is a fixed allowlist of read-only, bounded tools — `features.query`, `evidence.get`, `situations.related`, `history.prior_incidents`, `knowledge.search`, `forecast.run` — nothing else can be named, by policy or by injection. The host is constructed from an explicit implementation map and holds no reference to a toolbox, effect journal, MCP client, filesystem root, check runner, or memory write path; the constructor refuses unknown implementation keys, and tool implementations receive a minimal frozen context with no effects, store, emitter, graph runtime, or interrupts.

## Sealed, digest-verified Situation snapshots

An episode never reads a live stream. The request carries the situation `snapshot_json` plus its `snapshot_sha256` (and the decision schema, tool catalog, prompt, and objective digests). The worker recomputes the snapshot digest with the shared rule and compares it in constant time; a tampered or drifted snapshot terminates the episode **before any model call**. A strict scanner refuses malformed documents (duplicate keys, unpaired surrogates, unsafe numbers) at the receive boundary, and the snapshot must carry the required identity fields (situation id/version, tenant, situation type).

## Typed Decisions

The worker proposes typed Decisions through a dedicated builder: a Decision separates observed facts from inferences, cites evidence, states uncertainty, carries a validity interval, and proposes zero or more typed `ActionIntent`s. A proposed Decision is emitted as an event (with its digest) to the runtime, which validates, accepts, or rejects it — the worker never calls a physical effector directly.

## The reverse channel

While the runtime hosts the evidence, the worker reaches evidence only through the reverse channel:

- **evidence client** — the `EvidenceTools` RPC the worker may call, carrying its short-lived opaque capability token (never logged or persisted) and the exact tools encoded in it; results are bounded by rows/bytes caps;
- **outcome subscriber** — observed Outcomes return as evidence;
- **verification store** — verification evidence and artifact records;
- **approval relay** — R2 approval answers;
- **situation memory** — episode-scoped memory keyed by the snapshot identity.

The terminal event carries an **artifact manifest** — prompt, skill-set, tool-catalog, and memory-record digests plus model policy and contract version — so a completed episode is fully attributable. `tamoz-stream` owns the artifact store and retention.

## The old continuous engine is retired

The previous P14 streaming-input engine — the continuous input stream that fed a running agent — was **retired** by forward migration (MIGRATION_13). Tamoz now runs one sealed, digest-verified Situation snapshot per episode; the stream (the agentic-stream runtime) owns the continuous plane — event time, watermarks, windows, channels, replay — and hands Tamoz the snapshot. **Tamoz computes no watermark, no event time, no lateness, and no window membership**; the deterministic plane is the stream's. The old engine's channel vocabulary, backpressure declarations, connector contract, and replay runtime were deleted with it; nothing reads the old `queue_capacity` / `spool_capacity_bytes` / `overflow` vocabulary because the vocabulary is gone.

## Next reads

- [`./README.md`](./README.md) — the design index
- [`../limitations.md`](../limitations.md) — the P14 retirement and current streaming boundaries
- [`../design/scheduling.md`](../design/scheduling.md) — how scheduled occurrences differ from stream evidence
- [`../../docs/design-v0.1/STREAMING_INPUT_DESIGN.md`](../../docs/design-v0.1/STREAMING_INPUT_DESIGN.md) — the authoritative architecture record
- [`../roadmap.md`](../roadmap.md) — the stream milestone plan
