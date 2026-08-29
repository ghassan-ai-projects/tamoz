# ADR-020 — Sensitive-data policy is explicit and lossless

**Status:** Accepted.
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

## Context

Key-name regex scrubbing is lossy and blind to secrets hiding in values, and a durable record plus logs, traces, and `inspect` must apply *one* policy, not several that drift.

## Decision

The serializer never scrubs by key-name regex. It rejects secret wrappers by default, supports
explicit sensitive fields and authenticated encryption, and applies one redaction policy across
checkpoints, streams, logs, traces, errors, and `inspect`.

## Consequences

Secrets are rejected by default or explicitly protected/encrypted, and a single redaction policy spans checkpoints, streams, logs, traces, errors, and `inspect`. **Cost:** callers must mark sensitive fields explicitly — there is no magic key-name redaction.

## Rejected alternatives

- regex-based secret scrubbing — lossy and incomplete.

## Verification

Verified against code: 2026-08-29 — `Tamoz::Core.secret_shaped?` present (11 dependents).

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
