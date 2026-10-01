# ADR-014 — Extensions are first-party adapter gems, not plugins

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-030](./adr-030-one-local-capability-catalog-governs-all-sources.md) (the closed capability source set); [ADR-041](./adr-041-communication-channels-are-a-contract-gem-plus-per-transport-adapter-gems.md), [ADR-044](./adr-044-observability-is-a-contract-gem-plus-per-exporter-adapter-gems.md) (transports and exporters follow this rule)

Tamoz extends through skills, MCP servers, and first-party adapter gems that pass a contract gem's
conformance suite. There is no plugin API: no dynamic loading, discovery, or registration of code
Tamoz did not ship.

## Context

Every extension point that loads code also hands that code whatever the process holds: model and
channel credentials, the workspace, outbound network. A plugin API is also a compatibility promise
made before the core stops moving. Yet users do need new tools, new channels, and new exporters.

## Decision

- **Content extends freely.** Skills (instructions) and MCP servers (out-of-process tools) are the
  user extension points; both enter through the capability catalog, which grants them nothing by
  itself (ADR-030).
- **Code extends by release.** Capability sources, channel transports, and telemetry exporters are
  closed sets. Each kind has a contract gem with a conformance suite; a new member is a first-party
  adapter gem that passes it, added by a Tamoz release.
- Nothing discovers or loads adapter code at runtime from configuration, a directory, or a gem
  name supplied by a user.

## Consequences

Every piece of code that touches a credential or an egress path is reviewed and released with
Tamoz. **Cost:** a third party cannot ship a transport or exporter without upstreaming it, and each
addition costs a release of the contract gem.

## Invariants

- 35 — capability authority is local and intersected; content cannot grant.
- 42 — skill content never grants authority.

## Threat model

**Asset:** the worker's and gateway's credentials, workspace, and egress. **Adversary:** an author
of extension code the operator installs.

| Threat | Mitigation |
|---|---|
| A plugin reads the model credential or workspace | No in-process third-party code path exists; MCP servers run out of process with granted capabilities only |
| A plugin adds an unreviewed egress path | Transports and exporters are first-party and conformance-tested |
| A skill or MCP server grants itself authority | Catalog descriptors are request-only; the application assigns authority (ADR-030) |

**Residual risk:** an MCP server is arbitrary code the operator chose to run, out of process, with
whatever host access the operator gave it.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| A versioned adapter API: third-party adapter gems that pass the published conformance suite, enabled by the operator *(retrospective, 2026-10-01)* | Conformance proves the interface, not that the adapter does not exfiltrate the credential it is handed; until adapters can run with only their own credential, the reviewer must be us |
| A plugin marketplace with discovery *(retrospective, 2026-10-01)* | Adds a supply-chain surface and a compatibility promise before 1.0 |

## Reopen when

A second party needs to ship an adapter, **and** adapters can run with access to only their own
credential (for example, in their own process). A loosening ADR must show the adapter's privilege
boundary, an operator-pinned digest for each enabled adapter, and the conformance suite run by the
adapter author.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The capability source set is closed | `gems/tamoz-core/lib/tamoz/core/capability/registry.rb` (`BUILT_IN_SOURCES`) | `test/capability_closed_world_test.rb` | — |
| Transports and exporters pass their contract suites | `tamoz-comms`, `tamoz-observability` | `test/comms_seams_test.rb`, `test/otel_test.rb` | No test asserts that nothing loads adapter code dynamically; source inspection only |
