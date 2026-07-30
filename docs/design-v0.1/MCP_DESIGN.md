# MCP-native support

How Tamoz consumes and exposes Model Context Protocol capabilities without allowing a
remote server to redefine local policy, durability, or trust.

## 1. Decision

MCP is a first-class Tamoz capability boundary and ships as the optional `tamoz-mcp` gem.
It is native at the agent edge, not embedded in `tamoz-core` or `tamoz-graph`.

`tamoz-mcp` uses the official `mcp` Ruby SDK for wire compatibility. Tamoz does not
reimplement JSON-RPC, transports, OAuth, or protocol schemas. It adds the behavior the
protocol intentionally leaves to the host:

- local authorization and effect classification;
- immutable capability snapshots;
- durable tool-call identity, interruption, and reconciliation;
- bounded output, redaction, and content attribution;
- supervision, health, audit, and evaluation.

Client/host mode is the first release requirement. Server mode is a later profile in the
same gem and may expose explicitly selected Tamoz capabilities; it never exports the whole
agent or tool registry by default.

## 2. Standards baseline

The current target is the authoritative MCP `2026-07-28` stateless specification. The
initial interoperability baseline also supports `2025-11-25`, because the official Ruby
SDK's 2026 multi-round-trip flow is not yet complete enough for Tamoz's durability contract.
Tamoz advertises 2026 only after the selected SDK version implements the required features
and its conformance passes. Each server configuration pins an allowed protocol range;
silent negotiation outside it fails closed.

Tamoz follows:

- the [MCP architecture](https://modelcontextprotocol.io/docs/learn/architecture);
- the [current MCP specification](https://modelcontextprotocol.io/specification/2026-07-28)
  and [2025 compatibility specification](https://modelcontextprotocol.io/specification/2025-11-25);
- the [MCP security guidance](https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/security_best_practices);
- the [official Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk).

The 2026 protocol removes transport sessions and introduces stateless discovery and
multi-round-trip input. Tamoz therefore persists application identity and call state in its
own checkpoints rather than depending on an MCP transport session. Sampling and roots are
deprecated in that protocol line, so new Tamoz behavior does not depend on either.

## 3. Package boundary

```text
Tamoz Agent
  │ authorized capability catalog
  ▼
tamoz-mcp
  ├─ host policy adapter
  ├─ protocol profile
  ├─ connection supervisor
  ├─ schema/content normalizer
  └─ official mcp gem
       ├─ stdio
       └─ Streamable HTTP
```

`tamoz-mcp` depends on `tamoz-core` and the official SDK. Integration with durable calls is
provided to `tamoz-agent` through ordinary tool/effect contracts. It does not depend on
RubyLLM, mutate graph state, own credentials, or create a second scheduler.

## 4. One locally governed capability catalog

MCP, local tools, and skills share a content-addressed descriptor:

```ruby
CapabilityDescriptor = Data.define(
  :id,                 # "mcp:github/issues.create"
  :kind,               # :tool, :resource, :resource_template, :prompt
  :source_id,          # configured server identity, never server self-description
  :source_digest,
  :definition_digest,  # canonical schema/content metadata
  :input_schema,
  :output_schema,
  :trust,
  :effect_class,
  :requested_scopes,
  :availability,
  :protocol_profile
)
```

The server supplies protocol data. The application supplies `source_id`, trust,
effect class, allowed scopes, credentials, and policy. Tool annotations, descriptions,
icons, prompt text, resource annotations, and structured results are untrusted input.
They can narrow a decision or inform display; they cannot reduce risk or grant authority.

Names are always source-qualified. A server tool named `delete` becomes
`mcp:<configured-server-id>/delete`; it cannot shadow a local tool or another server.

## 5. Primitive mapping

| MCP primitive | Tamoz representation | Default treatment |
|---|---|---|
| Tools | ordinary agent tools behind policy/effect wrapper | visible only after local classification |
| Resources | attributed, on-demand context reads | never auto-trusted or auto-injected |
| Resource templates | validated URI templates | expansion and read are separately authorized |
| Prompts | reusable user-level templates | untrusted content, never system policy |
| Elicitation/input required | durable graph interrupt tied to the originating call | unattended runs deny or escalate |
| Progress/logging | bounded `StreamPart` events and telemetry | cannot affect execution |
| List-change notification/cache TTL | candidate catalog epoch | never mutates an in-flight epoch |
| Optional MCP Tasks extension | remote effect handle in the effect journal | opt-in per server and protocol profile |
| Sampling | unsupported by default | deprecated dependency; explicit compatibility only |
| Roots | unsupported by default | pass an authorized URI/path argument instead |

Resources and prompts do not become memories merely because a server returned them.
Admission to Experience or Knowledge follows [MEMORY_DESIGN.md](MEMORY_DESIGN.md).

## 6. Server admission

A server is not contacted until its immutable configuration passes:

1. configured identity and owner are present;
2. transport is one of `stdio` or Streamable HTTP;
3. stdio command, arguments, environment names, working directory, and sandbox profile are
   shown exactly and approved;
4. remote endpoint and every OAuth discovery/redirect hop pass egress and SSRF policy;
5. protocol range and supported primitives are explicit;
6. credential references resolve through the application credential provider;
7. resource/output size, concurrency, rate, and time budgets are finite;
8. local capability policy names every visible primitive or applies a fail-closed default.

Credentials never enter prompts, graph state, tool results, checkpoints, command arguments,
or logs. HTTP tokens are audience-bound. Tamoz never passes an MCP access token through to
another service. Stdio servers receive an allowlisted environment and run with the minimum
filesystem/network authority available.

## 7. Discovery and catalog epochs

Discovery produces a canonical server snapshot containing:

- configured server id and configuration digest;
- negotiated protocol and capabilities;
- tool/resource/prompt names, schemas, and metadata digests;
- local risk/effect/policy decisions;
- discovery time, expiry/cache scope, and health evidence.

The catalog compiler validates JSON Schema, rejects duplicate names, bounds descriptions,
and computes a snapshot digest. Invalid entries quarantine individually only when their
absence cannot change the meaning of another entry; otherwise the server snapshot fails.

A catalog epoch is immutable for a turn. List-change notifications, TTL expiry, reconnects,
or configuration edits create a candidate next epoch. Adoption occurs at an explicit turn
boundary, records the old/new digest and reason, and starts a prompt-cache epoch if visible
schemas or descriptions changed. Resume uses the checkpointed epoch or stops with a typed
`capability_snapshot_unavailable`; it never substitutes current schemas silently.

## 8. Tool execution

```text
model proposes source-qualified tool call
  → validate arguments against snapshotted schema
  → local policy + accepted-plan capability check
  → classify effect and prepare deterministic effect key
  → invoke through bounded MCP client
  → validate protocol result and optional output schema
  → bound/redact/attribute content
  → complete, reconcile, or mark effect unknown
```

The accepted plan binds the exact capability id and definition digest. A call fails before
network or process I/O if the current descriptor differs.

MCP errors are translated into Tamoz's typed taxonomy. Invalid arguments, denial, declared
remote failure, timeout before an effect may have started, and bounded unavailability may
become recoverable tool results. Protocol corruption, policy violation, storage failure,
ambiguous non-idempotent outcome, and credential compromise propagate or interrupt.

An MCP request id is not evidence of exactly-once execution. Automatic retry is permitted
only when the local effect contract proves the call read-only, idempotent under the Tamoz
effect key, or reconcilable through a separately authorized operation.

## 9. Elicitation and long-running work

An MCP server cannot prompt the user independently. Elicitation or a 2026
`input_required` result is bound to the originating tool call, persisted as an interrupt,
and rendered with the configured server identity, requested fields/URL, and affected
action. Returned input is schema-validated and recorded without leaking unrelated context.

Headless scheduled runs use their stored unattended policy: deny, cancel, or route to an
explicit approval destination. They never fabricate consent.

MCP Tasks extension handles are persisted with authorization context, server id,
operation digest, TTL, and effect key. Poll, result, and cancellation calls use the same
identity and budgets. An expired, inaccessible, or ambiguous task is reconciled or
escalated; it is not recreated blindly.

## 10. Supervision and health

Each server has a bounded supervisor:

- connect/start timeout, request timeout, idle timeout, and maximum lifetime;
- concurrency and pending-request limits;
- exponential restart backoff with jitter and a durable circuit;
- stdio process-tree termination and bounded stderr capture;
- heartbeat/probe only when supported and useful;
- health states `disabled`, `starting`, `ready`, `degraded`, `open`, and `retired`.

Failure changes availability, not the current catalog. A tool may return typed unavailable
for the pinned epoch; the next turn may adopt a catalog without it. Repeated fast crashes,
protocol violations, schema churn, auth failures, or output-limit violations open the
circuit and require policy-defined recovery.

## 11. Tamoz as an MCP server

Server mode exposes an explicit export manifest. Each exported primitive has a stable
external name, schema, authorization policy, rate limit, and Tamoz capability mapping.
Inbound calls receive stable request ids and enter the request/effect ledgers like any other
surface. Client identity is authenticated before thread or memory scope is resolved.

No endpoint exposes raw checkpoints, credentials, private memory, approval APIs, arbitrary
tools, or unrestricted agent turns by default. Exporting a capability is a policy change
and requires human approval plus `tamoz-evals` evidence.

## 12. Evaluation and release gates

MCP is not `tamoz-stream`'s high-rate evidence plane. A connector may normalize bounded MCP
notifications into an authenticated channel, and MCP may expose low-rate channel
management/query capabilities, but remote metadata cannot become sensor identity,
temporal-completeness policy, or physical effector authority.

`tamoz-mcp` ships only when:

- official protocol conformance passes for every advertised stable profile;
- schema/property fuzzing cannot bypass argument or output validation;
- malicious names, annotations, prompts, resources, and results cannot alter local policy;
- OAuth tests cover audience binding, PKCE/state, redirect validation, token isolation,
  SSRF, refresh rotation, revocation, and redaction;
- crash tests cover server exit, malformed frames, hanging calls, list churn, disconnect,
  restart, and ambiguous effects;
- elicitation survives restart and cannot self-approve in headless mode;
- catalog epochs remain immutable during turns and replay pins exact digests;
- stdio teardown leaves no child process and HTTP teardown leaks no session or credential;
- the first real MCP-backed Tamoz Agent capability passes behavioral and security gates.

MCP support is not “native” until the failure path is as durable and governed as a local
tool call.
