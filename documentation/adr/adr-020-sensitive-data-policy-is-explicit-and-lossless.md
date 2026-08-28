# ADR-020 — Sensitive-data policy is explicit and lossless

**Status:** Accepted. *(Tier F — the redaction boundary.)*

## Decision

The serializer never scrubs by key-name regex. It rejects secret wrappers by default, supports
explicit sensitive fields and authenticated encryption, and applies one redaction policy across
checkpoints, streams, logs, traces, errors, and `inspect`.

## Rejected alternatives

- regex-based secret scrubbing — lossy and incomplete.

## Verification

Verified against code: 2026-08-29 — `Tamoz::Core.secret_shaped?` present (11 dependents).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
