# ADR-020 — Secrets are refused by type or explicitly protected, never scrubbed by name

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Partial — the protection seam exists, but Tamoz ships no encryption codec; sensitive values fail closed unless the operator supplies one
**Relates to:** [ADR-046](./adr-046-content-capture-is-off-by-default-per-class-and-refused-for-restricted.md) (the telemetry side of the same rule)

A secret is a `Tamoz::Secret` value. Every durable or observable surface refuses it by type; a
store value marked sensitive is written only through a named protection codec. Nothing is scrubbed
by key-name pattern, and nothing is serialized with `Marshal`.

## Context

Key-name regex scrubbing (`/password|token/`) is lossy and blind: it misses a secret under an
innocent key and corrupts data under a suspicious one. A durable agent writes state to many places —
checkpoints, session records, request payloads, effect requests, schedules, telemetry, stream parts,
error messages — and one missed surface leaks a credential to disk. `Marshal.load` on a stored
artifact is code execution waiting for a bad file.

## Decision

- Secrets are typed (`Tamoz::Secret`); the state codec refuses them, so no checkpoint, record,
  payload, schedule, stream part, or signal can contain one. The refusal is by type, never by key.
- `Tamoz::Secret` renders as redacted under `to_s` and `inspect`.
- A store value explicitly marked sensitive is written only through a named protection codec
  (`encrypt`/`decrypt` bound to the value's address); with no codec configured, the write fails.
- Durable bytes use the allowlisted JSON state codec only; `Marshal` is never used.

## Consequences

A credential typed as `Tamoz::Secret` cannot reach disk or telemetry by accident. **Cost:** callers must type secrets
explicitly — there is no magic redaction; protecting sensitive store values needs an operator-
supplied codec, which Tamoz does not ship.

## Invariants

- 24 — sensitive data is explicit.
- 18 — versioned, allowlisted records.
- 60 — telemetry is redacted by construction.

## Threat model

**Asset:** model, channel, and tool credentials. **Adversary:** anyone who later reads the database,
logs, traces, or exports.

| Threat | Mitigation |
|---|---|
| A secret lands in a checkpoint or record | Codec refuses `Tamoz::Secret` on every swept surface |
| A secret appears in an error or `inspect` | `Tamoz::Secret` redacts its own rendering |
| A tampered stored blob executes code on load | No `Marshal`; only registered JSON codecs revive types |
| A sensitive store value is written in clear | Fails without a protection codec |

**Residual risk:** a secret passed as a plain `String` is not a secret to Tamoz and is not refused.
