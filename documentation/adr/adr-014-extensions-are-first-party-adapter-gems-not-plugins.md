# ADR-014 — Extensions are first-party adapter gems, not plugins

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-030](./adr-030-one-local-capability-catalog-governs-all-sources.md) (capability admission), [ADR-041](./adr-041-communication-channels-are-a-contract-gem-plus-per-transport-adapter-gems.md) (the channel kinds' closed registry, `CHANNEL_KINDS`), [ADR-044](./adr-044-observability-is-a-contract-gem-plus-per-exporter-adapter-gems.md) (channel and telemetry adapters)

Users add skills and external MCP tools. Code loaded into Tamoz as a new adapter must be reviewed,
tested and shipped in a Tamoz release. Writing code does not automatically enable it as a tool.

## Context

An extension loaded into the Tamoz process can access that process's credentials and resources.
Tamoz needs a clear review boundary for this code while still letting users add instructions and
external tools. A general plugin API would also create a compatibility commitment before 1.0.

## Decision

- **Skills provide instructions and resources.** Loading a skill executes no code and grants no
  authority.
- **MCP servers provide external tools.** The operator configures the server, and Tamoz admits its
  tools through the capability catalog. A server's descriptions do not grant permission to use them.
- **In-process adapters ship with Tamoz.** New capability source kinds, channel transports and
  telemetry exporters are reviewed first-party code. Adapter gems must pass the owning contract's
  tests and be added through a Tamoz release. Configuration cannot discover or load arbitrary
  adapter code from a directory or a user-supplied gem name.

Tamoz can create or modify code files through its approved tools. For example, it can write a new
tool implementation, but that file does not become a callable tool for the current turn. The
capability registry is sealed after construction; automatic loading and registration of generated
code is not supported. Running code through an existing approved tool is a separate operation.

Admitting third-party adapters later requires a privilege boundary limited to each adapter's own
credential, an operator-pinned digest for each enabled adapter, and contract tests run by its author.

## Consequences

Tamoz's built-in adapters have a reviewed release path. Users can extend instructions and external
tools without introducing a general in-process plugin loader. **Cost:** a new built-in adapter
requires review, contract tests and a release; a third-party transport or exporter must be accepted
into Tamoz before it can be used through this path.

## Invariants

- 35 — capability authority is local and intersected; content cannot grant.
- 42 — skill content never grants authority.

## Threat model

**Asset:** the worker's and gateway's credentials, workspace and network access.
**Adversary:** an author of extension code or content.

| Threat | Mitigation |
|---|---|
| Unreviewed adapter code accesses Tamoz's credentials | No general in-process plugin loader; built-in adapters follow the reviewed release path |
| An adapter adds a network path | First-party transports and exporters pass their contract tests |
| Skill text or MCP descriptions grant themselves permission | The application assigns authority; catalog content cannot grant it |

**Residual risk:** an MCP server is an external program with the host access the operator gives it.
Running outside Tamoz does not by itself restrict its filesystem, network or credential access.
