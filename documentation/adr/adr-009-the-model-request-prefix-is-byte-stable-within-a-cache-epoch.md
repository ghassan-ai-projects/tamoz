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

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| A style guideline ("keep the system prompt stable") *(retrospective, 2026-10-01)* | Nothing fails when it is broken; the failure is a bill |
| Rebuild the prompt each turn and rely on the provider to cache whatever matches *(retrospective, 2026-10-01)* | Order and locale drift make the prefix differ without anyone changing anything |

## Reopen when

A provider's caching stops being prefix-based, or a measured workload shows the series discipline
costs more in forced re-sends than it saves.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Header bytes are identical across processes and locales | `gems/tamoz-context-engine/lib/tamoz/context_engine/request_header.rb` | `test/context_header_test.rb` — `test_header_bytes_are_identical_across_processes_and_locales` | — |
| A changed header starts a series with a reason | `gems/tamoz-context-engine/lib/tamoz/context_engine/series.rb` | `test/context_header_test.rb` — `test_declared_boundary_and_changed_bytes_start_a_series` | — |
| Every request extends the previous one | work loop | `test/work_loop_test.rb` — `test_the_header_is_frozen_and_every_request_extends_the_previous_one` | Measured cache hit rates are not part of this proof |
