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

Tamoz-owned framework and application gems use the Ruby namespace `Tamoz`, require paths
`tamoz/*`, and gem names `tamoz-*`. Third-party dependencies retain their own names. The
operator CLI is `tamoz`. Tamoz Agent is the reference application built from those gems. No alias
keeps a former name working.

## Consequences

A shared prefix makes the packages recognizable as one family. It does not distinguish reusable
framework components from application components; their documented roles do that.
**Cost:** a later rename breaks dependent imports and commands; the RubyGems names and trademark are not yet reserved
(tracked in the [roadmap](../roadmap.md), not here).
