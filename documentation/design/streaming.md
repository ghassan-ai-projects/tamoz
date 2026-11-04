# The supervised episode worker (`tamoz-stream`)

`tamoz-stream` is the boundary where continuous, unbounded evidence becomes one bounded, supervised agent episode. Tamoz's part of that boundary is the **episode worker**: a gRPC service the stream runtime dials to run exactly one immutable episode against a sealed Situation snapshot.

Sources: [`docs/design-v0.1/STREAMING_INPUT_DESIGN.md`](../../docs/design-v0.1/STREAMING_INPUT_DESIGN.md) (the architecture the worker implements) and [`../limitations.md`](../limitations.md) (the retirement of the previous engine).

Current version: `0.1.0.alpha.1` (pre-release).

## The EpisodeWorker service

The worker implements the `agenticstream.runtime.v1.EpisodeWorker` gRPC service with two RPCs, and a third when the operator names a drafting model role:

```text
Handshake(HandshakeRequest)       -> HandshakeResponse      # protocol compatibility
Execute(EpisodeRequest)           -> stream EpisodeEvent    # one immutable episode
DraftPlaybookRule(DraftRequest)   -> stream DraftEvent      # optional: draft one playbook rule
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

Every DIAGNOSE decision carries the `diagnosis_code` Tamoz derived (`selected_code`, `unknown` included), so the stream can group recurring cases. A model call the provider refuses with 429 or 503 is resent within the episode's `max_provider_retries` budget (none when unset), pausing for `Retry-After` (whole seconds, at most 30 s) or else 2 s, then 6 s for each further retry (drafts get no retries); the retries ride in the journaled call, so a replay reproduces them without calling the provider. A failed model or tool call ends the episode with a diagnostic naming the error class, code and HTTP status (never the provider body).

## Drafting a playbook rule

`DraftPlaybookRule` lets the stream turn recurring, verified cases into a deterministic playbook rule. The worker announces the handshake feature `draft_playbook_rule` only when started with `--draft-model-policy ROLE` (a profile `model_roles` entry; the episode policy still arrives on the wire, so the profile needs that role too).

- **Input.** One key (diagnosis code, intent, preset), 1 to 20 cases that carry that key and the verdict `verified`, the current rules, and the feature names a condition may read. A case of another key, an unverified case, the `unknown` code, a duplicate case id, or a request for another tenant is refused with `InvalidArgument` before any model call.
- **Output.** A `PlaybookProposal` — a `when` condition over `features.<name>` in a restricted CEL subset that Tamoz parses and must hold on every cited case, a rationale, and the cited episode ids — or a `NoProposal` with a reason from a closed list (for example `too_few_cases`, `self_resolving`, `insufficient_evidence`). The model's document is parsed strictly, bounded (16 KiB), and given one repair.
- **Authority.** A proposal carries no mode, envelope or activation field and Tamoz writes no stream state. The stream checks and replays the rule, and only a human approval there lets it run (ADR-055). Case summaries are framed as untrusted data.
- **Durability.** The draft runs on the episode graph's draft route under the id `draft.<draft_id>`; a repeated id returns the recorded result and is refused if the cases changed.

The drafting step is graded on its own by the rule-proposal scorecard ([`../guides/evaluation.md`](../guides/evaluation.md)). Its first real-model results are in [`../limitations.md`](../limitations.md).

## The reverse channel

While the runtime hosts the evidence, the worker reaches evidence only through the reverse channel:

- **evidence client** — the `EvidenceTools` RPC the worker may call, carrying its short-lived opaque capability token (never logged or persisted) and the exact tools encoded in it; results are bounded by rows/bytes caps;
- **outcome subscriber** — observed Outcomes return as evidence;
- **verification store** — verification evidence and artifact records;
- **approval relay** — R2 approval answers;
- **situation memory** — episode-scoped memory keyed by the snapshot identity.

The terminal event carries an **artifact manifest** — prompt, skill-set, tool-catalog, and memory-record digests plus model policy and contract version — so a completed episode is fully attributable. `tamoz-stream` owns the artifact store and retention.

## The old continuous engine is retired

The previous P14 streaming-input engine — the continuous input stream that fed a running agent — was **retired**. Tamoz now runs one sealed, digest-verified Situation snapshot per episode; the stream (the agentic-stream runtime) owns the continuous plane — event time, watermarks, windows, channels, replay — and hands Tamoz the snapshot. **Tamoz computes no watermark, no event time, no lateness, and no window membership**; the deterministic plane is the stream's. The old engine's channel vocabulary, backpressure declarations, connector contract, and replay runtime were deleted with it; nothing reads the old `queue_capacity` / `spool_capacity_bytes` / `overflow` vocabulary because the vocabulary is gone.

## Next reads

- [`./README.md`](./README.md) — the design index
- [`../limitations.md`](../limitations.md) — the P14 retirement and current streaming boundaries
- [`../design/scheduling.md`](../design/scheduling.md) — how scheduled occurrences differ from stream evidence
- [`../../docs/design-v0.1/STREAMING_INPUT_DESIGN.md`](../../docs/design-v0.1/STREAMING_INPUT_DESIGN.md) — the authoritative architecture record
- [`../roadmap.md`](../roadmap.md) — the stream milestone plan
