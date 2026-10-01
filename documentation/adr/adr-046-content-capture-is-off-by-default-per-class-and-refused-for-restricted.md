# ADR-046 — Content capture is off by default, per class, and refused for restricted classes

**Status:** Accepted 2026-08-10
**Date:** 2026-08-10
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-020](./adr-020-secrets-are-refused-by-type-or-explicitly-protected-never-scrubbed-by-name.md) (secrets never reach a signal at all)

Prompts, tool arguments, tool results, and plan and review text appear in no signal unless a named,
digest-bound policy admits them for a classification at or below its ceiling, within byte bounds.
Omitted content is recorded as digest plus size. Restricted content can never be admitted.

## Context

Capturing content by default and scrubbing at export cannot prove what never reached the journal,
and default-on capture is one misconfiguration away from invisible leakage. But a trace with no
content is useless for debugging, and an empty trace must be distinguishable from an empty run.

## Decision

- The default content policy (`none`) captures no content; signals carry a digest and byte size
  instead.
- A named policy may admit content classes up to a maximum classification
  (`public < internal < confidential < restricted`) within byte bounds. A policy that would admit
  `restricted` content is refused when it loads.
- Every signal records the digest of the governing policy.
- `Tamoz::Secret` values are refused before reaching any signal, whatever the policy.

## Consequences

Seeing content in telemetry is an explicit, auditable choice. **Cost:** debugging needs a deliberate
policy switch.

## Invariants

- 60 — telemetry is redacted by construction; capture is an explicit named policy.

## Threat model

**Asset:** user content and plan text. **Adversary:** whoever can read the journal or the export
destination.

| Threat | Mitigation |
|---|---|
| Content captured by default | Default policy captures none |
| A policy captures restricted data | Refused at load |
| An oversized payload | Byte bounds; oversized hashes rejected before serializing |
| A secret in a signal | Refused before the signal is built |

**Residual risk:** content correctly classified as `confidential` and admitted by policy is exported
in full to the configured destination.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Capture by default, scrub at export | Cannot prove what never reached the journal |
| No content capture ever *(retrospective, 2026-10-01)* | Makes production debugging impossible |

## Reopen when

A content class is found that the classification ranks cannot express.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Default emits digest and size only | `gems/tamoz-observability/lib/tamoz/observability/content_policy.rb` | `test/observability_runtime_test.rb` — `test_default_policy_emits_digest_and_size_without_content` | — |
| Restricted capture is refused at load | same | `test/observability_runtime_test.rb` — `test_restricted_policy_refuses_capture_at_load` | — |
| Enabled content is bounded; policy recorded | same | `test/observability_runtime_test.rb` — `test_enabled_content_is_bounded_and_policy_is_recorded` | — |
| A secret never reaches a signal | producer | `test/observability_runtime_test.rb` — `test_secret_is_rejected_before_it_can_reach_a_signal` | — |
