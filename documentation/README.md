# Tamoz documentation

This directory is the curated, public documentation set for Tamoz — a
Ruby-native durable agent framework for checkpointed, interruptible,
observable, and evaluation-governed AI workflows. `README.md` at the repository
root is the entry point; this folder contains the detailed reference material.

**Current version:** `0.1.0.alpha.1` (pre-release). Read
[limitations.md](limitations.md) before building on it.

> The project's working archive — phase plans, reviews, audits and machine
> evidence — lives in [`../docs/README.md`](../docs/README.md) and is not part
> of this public set.

## Start here

- [overview/product.md](overview/product.md): what Tamoz is, what it is not, and who it is for
- [overview/concepts.md](overview/concepts.md): the core mental model — a graph run, a checkpoint, a review
- [getting-started/quickstart.md](getting-started/quickstart.md): value in ten minutes — install, ask, and an approved change
- [getting-started/install.md](getting-started/install.md): requirements, the 13 gems, and the full install surface
- [getting-started/sessions.md](getting-started/sessions.md): durable multi-turn sessions and crash recovery

## Architecture

- [architecture/overview.md](architecture/overview.md): the layered stack and runtime model
- [architecture/gems.md](architecture/gems.md): the 13-gem map and dependency rules
- [architecture/data-model.md](architecture/data-model.md): checkpoints, inbox, effect journal, leases, migrations
- [architecture/security-model.md](architecture/security-model.md): authority intersection, sealing, secrets, no shell
- [architecture/invariants.md](architecture/invariants.md): the 61-clause executable contract, by theme
- [overview/compatibility.md](overview/compatibility.md): supported Ruby, SQLite, providers, platforms

## Design

- [design/README.md](design/README.md): the design docs and their relationship to the authoritative design record
- [design/graph.md](design/graph.md): the durable graph engine
- [design/memory.md](design/memory.md): three-layer memory
- [design/scheduling.md](design/scheduling.md): durable scheduling
- [design/mcp.md](design/mcp.md): governed MCP and websearch
- [design/streaming.md](design/streaming.md): the supervised episode worker
- [design/self-healing.md](design/self-healing.md): bounded self-healing and the durable circuit
- [design/skills.md](design/skills.md): portable skills and the inert compiler
- [design/observability.md](design/observability.md): the signal plane
- [design/comms.md](design/comms.md): the channel/communications design

## Decisions

- [adr/README.md](adr/README.md): the ADR index — every decision record 001–049
- [adr/adr-049-telegram-approval.md](adr/adr-049-telegram-approval.md): evidence-gated Telegram approval

## Guides

- [guides/agent-operator.md](guides/agent-operator.md): runbook for operating an agent over Tamoz
- [guides/telegram.md](guides/telegram.md): talking to Tamoz over Telegram
- [guides/evaluation.md](guides/evaluation.md): how evaluation, scorecards and release evidence work

## Operations

- [operations/operations.md](operations/operations.md): backup, restore and crash recovery
- [operations/observability-ops.md](operations/observability-ops.md): status, journal, metrics and tracing

## Reference

- [reference/cli.md](reference/cli.md): the full `tamoz` CLI surface
- [reference/config.md](reference/config.md): profiles, the runtime directory, and environment variables
- [reference/public-api.md](reference/public-api.md): the sealed public surface, per package

## Project

- [roadmap.md](roadmap.md): shipped, in progress, planned
- [governance/quality.md](governance/quality.md): the quality bar for contributors
- [limitations.md](limitations.md): what Tamoz does not do — the honest counterpart to the README

## Governance

- [../CONTRIBUTING.md](../CONTRIBUTING.md): how to contribute
- [../SECURITY.md](../SECURITY.md): security policy and vulnerability reporting
- [../CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md): community standards
- [../SUPPORT.md](../SUPPORT.md): where to get help
- [../CHANGELOG.md](../CHANGELOG.md): version history
