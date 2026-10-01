# ADR-001 — The framework is Tamoz; the reference application is Tamoz Agent

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete
**Relates to:** [ADR-059](./adr-059-no-backward-compatibility-before-1-0.md) (the rename shipped with no aliases under the no-compatibility rule)

One name for the framework, its gems, its namespace, and its CLI, fixed before anything shipped.

## Context

A pre-release rename left the framework, CLI, gems, and namespaces with more than one name. A name
becomes load-bearing the moment a gem is published or a user writes a `require`; it had to be
settled while changing it was still free.

## Decision

The Ruby namespace is `Tamoz`, require paths are `tamoz/*`, every gem is named `tamoz-*`, and the
operator CLI is `tamoz`. Tamoz Agent is the reference application built from those gems. No alias
keeps a former name working.

## Consequences

Every public symbol, gem, and path shares one prefix, so ownership is obvious from a name.
**Cost:** a later rename breaks every user; the RubyGems names and trademark are not yet reserved
(tracked in the [roadmap](../roadmap.md), not here).

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Keep the old names as aliases through the rename *(retrospective, 2026-10-01)* | Nothing had shipped, so aliases would protect no user and double the surface to document and test |
| Different names for the framework and the agent gems | Users could not tell which gems form the framework and which the application |

## Reopen when

A published gem name collides with an existing RubyGems package or a trademark claim.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Every gem is `tamoz-*` under `Tamoz` | gem layout | `test/packaging_test.rb` | Name reservation on RubyGems is not checked |
| The CLI is `tamoz` | `gems/tamoz-agent-cli/exe/tamoz` | `test/agent_cli_test.rb` | — |
