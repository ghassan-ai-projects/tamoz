# Governed MCP client/host (`tamoz-mcp`)

`tamoz-mcp` is the Model Context Protocol capability boundary: a first-class client/host that consumes remote capabilities without letting a remote server redefine local policy, durability, or trust. Source: [`docs/design-v0.1/MCP_DESIGN.md`](../../docs/design-v0.1/MCP_DESIGN.md).

Current version: `0.1.0.alpha.1` (pre-release).

## Native at the edge, SDK for the wire

MCP is a first-class Tamoz capability boundary shipped as the optional `tamoz-mcp` gem — native at the agent edge, not embedded in `tamoz-core` or `tamoz-graph`. It uses the official `mcp` Ruby SDK for wire compatibility and does not reimplement JSON-RPC, transports, OAuth, or protocol schemas. Tamoz adds what the protocol leaves to the host: local authorization and effect classification, immutable capability snapshots, durable tool-call identity and reconciliation, bounded output and redaction, and supervision, health, audit, and evaluation.

The current protocol target is the authoritative `2026-07-28` stateless specification; the `2025-11-25` line is the initial interoperability baseline. Each server configuration pins an allowed protocol range; silent negotiation outside it fails closed. Because the 2026 line removes transport sessions, Tamoz persists application identity and call state in its own checkpoints rather than depending on a transport session.

## No privilege widening

The server supplies protocol data; the application supplies source identity, trust, effect class, allowed scopes, credentials, and policy. Tool annotations, descriptions, icons, prompts, resource annotations, and structured results are untrusted input: they can narrow a decision or inform display, they cannot reduce risk or grant authority.

- Capabilities use source-qualified names — a server tool named `delete` becomes `mcp:<configured-server-id>/delete` and cannot shadow a local tool or another server.
- Resources and prompts are never auto-trusted or auto-injected, and never become memory records merely because a server returned them.
- An MCP request id is not evidence of exactly-once execution. Automatic retry is permitted only when the local effect contract proves the call read-only, idempotent under the Tamoz effect key, or reconcilable through a separately authorized operation.
- A server cannot prompt the user independently: elicitation or an `input_required` result is bound to the originating call, persisted as an interrupt, and rendered with the configured server identity. Headless scheduled runs use their stored unattended policy — deny, cancel, or route to an explicit approval destination — and never fabricate consent.

## Immutable server admission

A server is not contacted until its immutable configuration passes admission: configured identity and owner, transport (`stdio` or Streamable HTTP), exact stdio command/arguments/environment/working-directory shown and approved, remote endpoint and every OAuth discovery/redirect hop passing egress and SSRF policy, explicit protocol range and primitives, credential references resolving through the application credential provider, finite resource/output/concurrency/rate/time budgets, and a local capability policy naming every visible primitive or a fail-closed default. Credentials never enter prompts, graph state, tool results, checkpoints, command arguments, or logs; HTTP tokens are audience-bound and never passed through to another service.

## The catalog and catalog epochs

Discovery produces a canonical server snapshot: configured server id and configuration digest, negotiated protocol and capabilities, tool/resource/prompt names and schema digests, local risk/effect/policy decisions, and health evidence. The catalog compiler validates JSON Schema, rejects duplicate names, bounds descriptions, and computes a snapshot digest.

A catalog epoch is **immutable for a turn**. List-change notifications, TTL expiry, reconnects, or configuration edits create a candidate next epoch; adoption happens at an explicit turn boundary, records the old/new digest and reason, and starts a prompt-cache epoch when visible schemas changed. Resume uses the checkpointed epoch or stops with a typed `capability_snapshot_unavailable`; it never substitutes current schemas silently.

## Invocation

The accepted plan binds the exact capability id and definition digest; a call fails before network or process I/O if the current descriptor differs. Invocation then validates arguments against the snapshotted schema, checks local policy and the accepted-plan capability, classifies the effect and prepares a deterministic effect key, invokes through a bounded client, validates the protocol result and optional output schema, and bounds/redacts/attributes content. MCP errors translate into Tamoz's typed taxonomy: invalid arguments, denial, declared remote failure, and bounded unavailability may be recoverable tool results; protocol corruption, policy violation, storage failure, ambiguous non-idempotent outcome, and credential compromise propagate or interrupt.

## Supervision

Each server has a bounded supervisor: connect/request/idle timeouts and maximum lifetime, concurrency and pending-request limits, exponential restart backoff with jitter and a durable circuit, stdio process-tree termination with bounded stderr capture, and health states `disabled`, `starting`, `ready`, `degraded`, `open`, and `retired`. Failure changes availability, not the current catalog — a tool may return typed unavailable for the pinned epoch, and the next turn may adopt a catalog without it.

## Tamoz as an MCP server

Server mode exposes an explicit export manifest: each primitive has a stable external name, schema, authorization policy, rate limit, and Tamoz capability mapping; inbound calls receive stable request ids and enter the request/effect ledgers like any other surface. No endpoint exposes raw checkpoints, credentials, private memory, approval APIs, arbitrary tools, or unrestricted agent turns by default; exporting a capability is a policy change requiring human approval plus evaluation evidence.

## Governed websearch

`tamoz-mcp` also carries the governed websearch capability: a `websearch` server capability admitted through the normal server configuration whose server owns the HTTP stack. **Tamoz itself never makes an outbound call** — the network-capable process is operator-supplied, and its egress is enforced outside Tamoz by an operator-declared `EgressPolicy` applied per hop. The policy allowlists hosts, allows `https` only on the default port, rejects IP literals and private/loopback/link-local ranges (including after DNS resolution), bounds request/response bodies and redirect hops, and refuses credential-shaped query values before a call is issued. Repeated violations open an `egress`-scope durable circuit. Search result content is treated as adversarial by construction and scrubbed of credential-shaped values before it can reach state, the journal, or a prompt.

## Next reads

- [`./README.md`](./README.md) — the design index
- [`./skills.md`](./skills.md) — the sibling capability surface (skills)
- [`../architecture/security-model.md`](../architecture/security-model.md) — the security model
- [`../reference/public-api.md`](../reference/public-api.md) — the public `tamoz-mcp` surface
- [`../../docs/design-v0.1/MCP_DESIGN.md`](../../docs/design-v0.1/MCP_DESIGN.md) — the authoritative design record
