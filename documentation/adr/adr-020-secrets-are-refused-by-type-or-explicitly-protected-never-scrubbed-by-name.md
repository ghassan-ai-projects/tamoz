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

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Regex scrubbing by key name | Lossy and incomplete; misses secrets in values |
| `Marshal` as the default serializer *(retrospective, 2026-10-01)* | Remote code execution on a tampered artifact |
| Encrypt the whole database file *(retrospective, 2026-10-01)* | Protects data at rest but not logs, traces, exports, or error text, and every reader needs the key |

## Reopen when

A secret is found on any durable or observable surface, or an operator needs protected store
values and there is no codec to give them (then ship one).

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Secrets are refused on each swept surface, by type | state codec | `test/secret_sweep_test.rb` — `test_the_swept_surface_list_is_complete`, `test_the_refusal_is_by_type_not_by_key_name` | Only the surfaces in the sweep list |
| A secret never renders its value | `Tamoz::Secret` | `test/secret_sweep_test.rb` — `test_a_secret_never_renders_its_value` | — |
| Sensitive store values need a protection codec | `gems/tamoz-sqlite/lib/tamoz/sqlite/store.rb` (`protect`) | `test/sqlite_store_test.rb` — `test_sensitive_values_fail_closed_and_round_trip_only_with_protection` | The codec's cryptographic strength is the operator's |
