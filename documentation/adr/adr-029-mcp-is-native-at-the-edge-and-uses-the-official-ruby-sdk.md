# ADR-029 — MCP is native at the edge and uses the official Ruby SDK

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete
**Supersedes:** [ADR-012](./adr-012-mcp-deferred-integration.md)
**Relates to:** [ADR-030](./adr-030-one-local-capability-catalog-governs-all-sources.md) (MCP tools enter through the catalog)

`tamoz-mcp` speaks MCP through the official `mcp` gem; Tamoz owns everything about what an MCP tool
may do: catalog snapshots, effect identity, consent, content bounds, and supervision.

## Context

MCP is the standard way to reach external tools, and it moves fast. Reimplementing its wire
protocol would couple Tamoz's correctness to protocol churn. But nothing about MCP decides who may
call a tool, whether a call is safe to retry, or how consent survives a crash — those are Tamoz's.

## Decision

- Protocol, transports, OAuth, and schemas come from the official `mcp` gem.
- Tamoz owns: per-server configuration and protocol range (fail closed outside it), immutable
  digest-pinned catalog snapshots, local effect classes and deterministic effect keys for every call
  (ADR-016), durable elicitation as an interrupt, bounded and control-stripped content, credential
  references that never appear in state or errors, process supervision, and a circuit per server.
- Remote annotations and descriptions are untrusted text; they never set an effect class.
- `tamoz-mcp` loads nothing but `tamoz-core` and the SDK.

## Consequences

Wire compatibility tracks the SDK; safety stays Tamoz's. **Cost:** Tamoz follows the SDK's release
cadence and must keep explicit protocol-version windows.

## Invariants

- 36 — MCP protocol and catalog snapshots are explicit and pinned.
- 37 — MCP calls preserve Tamoz authorization, durability, and uncertainty.

## Threat model

**Asset:** the operator's credentials and the effects MCP tools can cause. **Adversary:** a
malicious or compromised MCP server.

| Threat | Mitigation |
|---|---|
| Server metadata claims a tool is safe | Annotations are untrusted; the application assigns effect class |
| Prompt injection via descriptions | Descriptions are control-stripped and byte-bounded |
| Credential leak via errors | Credential values never appear in errors or stderr metadata |
| Crash mid-call is retried | The call is typed `:unknown` and never retried blindly |
| Output flood or orphan process | Output is bounded; teardown leaves no orphan |

**Residual risk:** an MCP server is arbitrary code running with the host access the operator gave
its process.
