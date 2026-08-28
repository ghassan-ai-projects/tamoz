# ADR-010 — Ruby 3.3 floor; 3.4 and 4.0 primary targets

**Status:** Accepted (revised after support-status review).

## Context

Ruby 3.2 reached end-of-support before the design date, so a floor and a supported-version test matrix had to be chosen deliberately.

## Decision

Ruby 3.2 reached end-of-support before the design date. CI covers MRI 3.3, 3.4, 4.0; 3.3 may be
dropped after its EOL while pre-1.0. JRuby enters CI only after the SQLite/concurrency adapters
pass without conditional semantics.

## Consequences

CI covers MRI 3.3, 3.4, and 4.0, and 3.3 can be dropped after its EOL while Tamoz is pre-1.0. **Cost:** a three-version CI matrix to maintain, and JRuby waits until the SQLite/concurrency adapters pass without conditional semantics.

## Verification

Verified against code: 2026-08-29 — `.ruby-version` = `3.3.11`; CI matrix = `["3.3", "3.4", "4.0"]` (`.github/workflows/ci.yml`), matching this ADR exactly.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
