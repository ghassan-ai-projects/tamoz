# ADR-055 — The continuous plane is a separate Go authority (`agentic-stream`); Tamoz is its episode worker

**Status:** Accepted 2026-08-12
**Date:** 2026-08-12
**Tier:** F
**Implementation:** Partial — the worker has no transport authentication: both transports bind insecure gRPC ports, the socket's permissions are left to the process umask, and TCP mode listens on all interfaces
**Amends:** [ADR-040](./adr-040-one-monorepo-multiple-independently-publishable-gems.md) (a second repository, in Go)
**Supersedes:** [ADR-035](./adr-035-streaming-input-is-a-distinct-first-class-runtime.md), [ADR-037](./adr-037-event-time-explicit-backpressure-and-effect-disabled-replay-are-contracts.md)
**Relates to:** [ADR-036](./adr-036-cognition-sees-only-a-sealed-situation-snapshot-never-raw-evidence.md), [ADR-038](./adr-038-physical-action-is-typed-intent-plus-current-state-policy-never-model-effect.md), [ADR-039](./adr-039-tamoz-is-supervisory-certified-safety-and-real-time-control-stay-external.md)

The continuous plane — event time, watermarks, windows, channels, replay, device I/O, capability
issuance — is `agentic-stream`, a separate Go runtime and repository. It is authoritative for budget
and Decision disposition and dials Tamoz's `tamoz-stream` episode worker to run one episode against
one sealed snapshot. Tamoz proposes; the stream disposes.

## Context

ADR-035 originally put the continuous plane in Ruby. The P14 engine was then retired by forward
migration (MIGRATION_13) and the plane moved to Go. Three separate choices were bundled in that move,
and they have different justifications:

1. **Authority boundary (the load-bearing one).** An LLM-bearing process must never be authoritative
   for budget, Decision acceptance, physical effect, or terminal state (ADR-038/039). A process
   boundary with separate credentials enforces that.
2. **Language.** The continuous plane is a throughput and temporal-semantics system; the team judged
   Go a better fit. This is engineering judgment, not a measured requirement, and Go gives no
   hard real-time guarantee (ADR-039 keeps real-time control external anyway).
3. **Repository.** A different language, toolchain, and release cadence made a separate repository
   simpler to own. Repository placement enforces nothing at runtime (ADR-040).

## Decision

- **Roles.** `tamoz-stream` implements `agenticstream.runtime.v1.EpisodeWorker` (`Handshake`,
  `Execute(EpisodeRequest) -> stream EpisodeEvent`) as the gRPC server; the Go executor is the
  client and authority. Worker events are proposals and telemetry, never commands.
- **Tamoz computes no stream-plane concept:** no event time, watermark, lateness, window membership,
  backpressure, or replay policy. Those are `agentic-stream`'s contracts (formerly ADR-037).
- **Sealed snapshot** per ADR-036.
- **Containment.** Episode tools are a fixed read-only allowlist (`features.query`, `evidence.get`,
  `situations.related`, `history.prior_incidents`, `knowledge.search`, `forecast.run`) plus
  operator-declared read-only `probe_*` tools. The tool context carries no effect journal, store,
  toolbox, MCP client, filesystem root, or memory write path. The episode's own model calls still go
  through the effect journal (ADR-016).
- **Reverse channel.** Evidence is reached through short-lived opaque capability tokens issued by
  the stream, never persisted or logged.
- **Transport.** Production binds a Unix domain socket; the permissions of the socket and its
  directory are the only authentication, and the worker does not set them (umask decides). TCP mode
  binds `0.0.0.0` unauthenticated; it is meant for development, but nothing stops `--port` in
  production.

## Consequences

The authority split is structural: the worker has no credential that could accept a Decision or
move equipment. **Cost:** the `runtime-v1` proto is a frozen contract across two repositories;
changing it is a coordinated two-repo release, and the Handshake refuses incompatible versions.

## Invariants

- 49, 50, 51 — snapshot-bound cognition, typed intents, safety authority outside cognition.

## Threat model

**Asset:** physical and operational effect, the stream's evidence, and budget. **Adversary:** a
compromised or mistaken worker; a process that reaches the worker socket.

| Threat | Mitigation |
|---|---|
| The worker actuates or overspends | It only proposes; the stream disposes and owns budget; no effector credential |
| A tampered snapshot drives a decision | Digest recomputed; mismatch ends the episode before any model call |
| Injection names a forbidden tool | Allowlist fixed at construction; unknown names are refused |
| A leaked reverse-channel token is replayed | Short-lived, opaque, scoped to exact tools, never persisted |
| Another local process drives the worker | Only socket and directory permissions stop it; the worker does not set them |
| A network peer drives the worker in TCP mode | **Not mitigated:** TCP binds all interfaces with no authentication |

**Residual risk:** the snapshot digest proves consistency, not origin; anyone who can reach the socket — or,
in TCP mode, the port from any network — can submit an episode and spend model budget. A compromised bound adapter is trusted by the host (it guarantees the
call surface, not adapter internals).

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Keep the continuous plane in Ruby `tamoz-stream` | A throughput/temporal system and a durable-cognition system in one runtime served neither |
| Two processes, two languages, one monorepo *(retrospective, 2026-10-01)* | Credible: it keeps the authority boundary; lost on toolchain and release-cadence ownership, not on safety |
| Make Tamoz the client and authority | Puts authority in the LLM-bearing process |
| A shared database instead of a sealed snapshot | A live read reintroduces staleness and an ambient trust surface |

## Reopen when

The proto changes faster than coordinated releases can follow, or the worker must accept episodes
from more than one local caller (then add real transport authentication first).

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Tool surface is exactly the allowlist; injection cannot bind a denied tool | `gems/tamoz-stream/lib/tamoz/stream/capability_host.rb` | `test/stream_episode_capability_host_test.rb` — `test_the_surface_is_exactly_the_permitted_allowlist`, `test_an_injected_instruction_cannot_bind_a_denied_capability` | Adapter internals are trusted |
| Tool context never carries effects or store | same | `test/stream_episode_capability_host_test.rb` — `test_the_context_passed_to_a_tool_never_carries_effects_or_store` | — |
| Tokens never persist or cross the wire | worker | `test/stream_token_custody_test.rb` — `test_the_token_never_enters_the_durable_payload`, `test_the_token_never_crosses_in_a_wire_event` | — |
| Serves over Unix socket or TCP, not both | `gems/tamoz-stream/lib/tamoz/stream/worker_server.rb` | `test/stream_worker_server_test.rb` — `test_the_server_refuses_both_or_neither_transport` | Both bind insecure ports; no TLS |
| Shared contract vectors reproduce exactly | `tamoz-stream` | `test/stream_invariants_test.rb` — `test_invariant_9_every_shared_contract_vector_reproduces_exactly` | The Go side is in a sibling repository and not checked here |
