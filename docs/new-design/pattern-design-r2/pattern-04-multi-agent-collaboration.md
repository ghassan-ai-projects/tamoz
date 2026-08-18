# Pattern 04 — Multi-Agent Collaboration

> **Rev 2 · 2026-08-16.** Symbol names are the authoritative anchor — **line numbers are approximate** (written against tamoz `smarter-tamoz`@`5b07557` / agentic-stream `smarter-agent`@`2e8aa3a`; HEAD `ebf1e23` / `c067127`). **`*.go` refs live in the agentic-stream repo; `*.rb` in tamoz.** See [`README.md`](README.md) · [`00-REVISION-NOTES.md`](00-REVISION-NOTES.md) · [`GLOSSARY.md`](GLOSSARY.md).

Handbook: chapter-04-multi-agent-collaboration.md. Verdict: **Partial — one strong
two-party supervisor/worker collaboration (stream = authority, Tamoz = judgment)
with digest-verified contracts ahead of the handbook's bar; no orchestrator agent,
no debate/consensus gate, and the graph machinery that would enable hierarchy
(SubgraphRuntime, Send, ForkExecutor) is wired but dormant.** Builds on: README
substrate (two-identity split, digest discipline). **Autonomy: 2-party L2-L3; the
machinery for L4 (hierarchy/debate) exists but is dormant.**

## Handbook definition (owner's)

- Start with one agent; add a team only when evaluation shows the simpler design
  fails (Single-Agent-Suffice Rule). Triggers: context isolation, parallelism,
  separation of concerns (distinct tools/permissions/data).
- Recommended topology: **orchestrator** (one agent owns decomposition, routing,
  validation, retry policy, synthesis, trace). Parallel fan-out for independent
  sub-tasks; sequential handoff for pipelines; peer debate only for high-stakes
  decisions (consensus via explicit `vote_accept`, never edit distance).
- Communication contract: structured handoff `from/to/trace_id/task/context/
  acceptance_criteria/expected_output`; "contract in, result out, validation at the
  boundary"; no implicit shared memory, no raw transcripts. Workers advertise
  **capability manifests**; the router matches task requirements against them.
- Failure modes: delegation loop, echo chamber, context leak, orchestrator
  bottleneck, cost explosion, silent failure. Mitigations: budgets, independent
  evidence, least-privilege handoffs, idempotent retries, validation before
  synthesis.
- Cost model: `total = orchestration + Σ(workers) + validation + retries + synthesis`;
  parallelism reduces latency, not token spend.

## How tamoz implements it (HEAD)

**The stream↔worker split — a cross-process supervisor/worker pair.**
- Asymmetric by design: the stream owns authority (decomposition of episodes, all
  state, validation, policy, execution); Tamoz is ONE judgment worker. The worker is
  the gRPC **server**; the stream dials it over UDS (episode_worker.rb:9-15;
  worker_server.rb:58-63). `ProtocolVersion`/`ContractVersion` "1.0" pinned both
  sides; handshake requires `non_interactive` (episode_worker.rb:62-87).
- **Digest-verified handoff:** the stream pushes the full situation (snapshot +
  `snapshot_sha256`, spec, tool catalog, intent catalog, decision schema — presence
  + 32-byte digest length checked in `validateRequest`, server.go:200-249); the
  worker recomputes the snapshot digest with the shared domain rule and compares
  constant-time before any model call (`ReceivedSnapshot.verify`,
  situation_snapshot.rb:7-55) — the digest EQUALITY lives on the Ruby side.
  Decisions return with `decision_sha256` re-verified against the episode identity
  (`streamValidator.emit`, server.go:290-302).
- **Evidence reverse channel (the one peer edge):** the stream hosts `EvidenceTools`
  gRPC on a private UDS socket; the worker dials BACK with an opaque capability
  token, identity-scoped, row/byte-bounded, result digests verified
  (evidence_client.rb:16-130). Bounded P2P data call inside a supervisor/worker
  relationship.
- **Containment:** the worker runs inside the fixed 6-tool read-only
  `EpisodeCapabilityHost` (capability_host.rb:24-40) — no effects/journal/store/
  emitter reachable from the model's tools.

**The MCP supervisor circuit — process-level supervisor/worker.**
- Supervisor owns the child process (pgroup, allowlisted env, SIGTERM→SIGKILL
  teardown — supervisor.rb:312-421); `CircuitStore` duck-typed seam (durable swap is
  mechanical), threshold inside the store's atomic read-modify-write
  (`MemoryCircuitStore#record_failure`, supervisor.rb:43-54).
- **Reset-with-evidence is the recovery primitive:** `reset(evidence:)` is
  caller-initiated; the supervisor augments scope/server_id/conditions_digest and
  records it; the durable gate requires operator identity + command record
  (supervisor.rb:253-281; circuit/evidence.rb:9-76). The right orchestrator-recovery
  pattern already exists.
- Invocation pipeline = contract-in/result-out, validation at the boundary, pinned
  schema + digest before I/O (invocation.rb:77-91,389-402). Elicitation = typed
  interrupt handoff bound to the deterministic effect_key (elicitation.rb:22-90).

**Graph-level machinery — present but DEAD.**
- `Tamoz::Send` (send.rb:4-19): no production *dispatch* call sites — the checkpoint
codec (de)serializes Send routes (checkpoint_codec.rb:486,509), but no node emits one. `Command` update/goto only (M2
  rejects resume/graph). `SubgraphRuntime` (nested invocation-mode subgraphs) is
  created per task context but **no production node ever calls a child `Compiled`**
  (compiled.rb:142-146 — only self-calls). `ForkExecutor` creates fork lineages but
  is only driven by the redirect operation (a thread redirection, not agent spawning).

**No agent fleet.** Session is one fixed graph; there is no agent registry, no
capability manifests for workers, no per-task agent selection. Delegation is to
TOOLS and PROCESSES, never to agents (every external effect crosses the journal).

## Divergence from the handbook

1. The split is a **degenerate supervisor/worker pair**: two parties, no orchestrator
   (decomposition/synthesis live in the stream's Go code, not on the graph), no
   capability-manifest routing (tool selection, not worker selection).
2. **No debate/consensus gate** for high-stakes episodes — a single `reason` call;
   the deterministic gates (schema, receipt, digests) are preferred by the handbook
   over model self-report where possible, so this is a *correct* deviation, but the
   debate path is unserved.
3. **Contracts are ahead of the handbook** — snapshot/spec/decision/tool-catalog
   digests verified at both boundaries; model events cross the wire only after
   journal-receipt verification. Strongest alignment point.
4. **No unified orchestration trace** — W3C traceparent is validated but not used to
   join goal→episode→decision across processes; the durable request id is an
   identity, not a trace.
5. **No hierarchy/peers** beyond the two fixed layers — the subgraph/Send/fork
   machinery that would enable them is dead.
6. Single-agent-first rule satisfied by construction — the eval never demanded more.

## How it SHOULD be implemented (on existing seams)

1. **A supervisor node pair on a parent graph** — a `supervise` node as a route
   target on `branch :intake` (episode_graph.rb:101-106, mirroring the
   `:recall`/`:judge` route split) decomposes a goal into episode-shaped tasks,
   dispatches each via `DurableRunner.submit` under distinct `request_id`s,
   collects the fenced decision receipts (state `reduce: :append`), then a
   `synthesize` node aggregates — the stream→worker pattern inverted onto the graph.
2. **Reuse the MCP circuit's reset-with-evidence as the fleet-recovery primitive** —
   per-worker `CircuitStore` seam + `conditions_digest` auditability; the single
   most portable multi-agent primitive in the repo.
3. **Extend the digest discipline to the handoff** — a structured handoff
   `{task, acceptance_criteria, expected_output}` canonicalized + digested under a
   `tamoz.agent.handoff.v1` domain, verified at the worker boundary exactly like
   `ReceivedSnapshot.verify` — converts situation integrity into contract integrity.
4. **Hierarchy = wire `SubgraphRuntime`** (already namespaced, shares the
   checkpointer, handles child pause/resume/fail — just has zero callers), or delete
   it to keep the "no rare-case code" directive honest. A `max_subgraph_depth` limit
   must land in `Limits` the moment it is used.
5. **A debate gate = a second `reason`-style node** with an independent critic prompt
   plus a deterministic acceptance rule (structured votes → supermajority or digest
   comparison) appended to `state :judgements` (episode_graph.rb:59) — the dissent
   log state already exists.
6. **Trace spanning = reuse the validated W3C context** as the orchestration trace id,
   each sub-episode a child span (the observability producer already exists,
   worker.rb:62).

## Gap list (priority order)

| # | Gap | Landing spot |
|---|---|---|
| M1 | No orchestrator agent (decompose/route/synthesize on the graph) | `supervise`/`synthesize` node pair (extend Session/EpisodeGraph spine) |
| M2 | No worker capability manifests / routing decision | Agent-catalog analog of `McpCapabilitySource`, digest-pinned |
| M3 | No debate/consensus gate for high-stakes episodes | Second critic node + deterministic acceptance on `state :judgements` |
| M4 | No per-handoff acceptance criteria | `acceptance_criteria` in the episode payload, checked by `validate` |
| M5 | No unified orchestration trace | Carry traceparent into the decision envelope/manifest |
| M6 | Subgraph/Send/Fork machinery dormant (instantiated, never drives a child graph) | Wire `SubgraphRuntime` or delete it; add `max_subgraph_depth` to Limits |
| M7 | No delegation-loop/depth budget | `max_subgraph_depth` + orchestration cost envelope in the supervisor node |
| M8 | Cost multiplication unmeasured across the collaboration | Aggregate `budget_state` across child episodes |

**Tests to update:** a `supervise` route target joins the intake branch — the worker
protocol tests (proto handshake/contract versions) and the session graph tests; a
debate node adds a journaled call covered by the replay tests.
