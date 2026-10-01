# ADR-009 — The model request prefix is byte-stable within a cache epoch

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete
**Relates to:** [ADR-033](./adr-033-skills-use-the-open-agent-skills-format-and-stay-an-agent-recipe.md) (the skill catalog digest is part of the prefix)

System content, tool schemas, model settings, and the skill catalog render to the same bytes for
every request in a series; any change starts a new series with a recorded reason.

## Context

Provider prompt caching breaks silently when the prompt prefix changes: nothing errors, nothing
logs, and cost multiplies. Common causes are invisible — tool registration order, locale-dependent
sorting, a timestamp in the system prompt, rewriting old history. A guideline cannot catch them; a
check over the rendered bytes can.

## Decision

The request header (system sections and tool schemas) renders in a fixed, locale-independent byte
order. Each request either continues the current series with an identical header digest, or starts
a new one with a logged reason (`initial`, `change`, `series`, compaction). History is append-only;
compaction is the only rewrite and always starts a new series. This is invariant 16.

## Consequences

Every cache miss is attributable to a recorded reason. **Cost:** toolsets cannot change freely
mid-series, and history cannot be edited in place — a correction is a new appended entry.
