# ADR-044 — Observability is a contract gem plus per-exporter adapter gems

**Status:** Accepted 2026-08-10
**Date:** 2026-08-10
**Tier:** C
**Implementation:** Complete
**Relates to:** [ADR-014](./adr-014-extensions-are-first-party-adapter-gems-not-plugins.md) (why exporters are a closed set), [ADR-045](./adr-045-observability-gems-add-no-durable-table-and-no-second-source-of-truth.md)

`tamoz-observability` owns the signal catalog, recorder, journal, and exporter seam. Each exporter
(`tamoz-otel` today) is its own gem that passes the contract and owns its egress policy.

## Context

The exporter is the one seam that carries telemetry out of the process. As a plugin point it would be
an unversioned egress path with no conformance gate.

## Decision

- The contract gem owns a closed, versioned signal catalog (a changed attribute set needs a version
  bump), the recorder (which does not raise into its caller over a malformed payload), the bounded journal, and the
  exporter-adapter seam.
- Each exporter is a separate gem depending on the contract gem, with its own egress policy:
  trusted destinations only, local endpoints by explicit opt-in, credentials as references, no
  redirects or proxy environment.

## Consequences

Telemetry egress is reviewed code with tested destination rules. **Cost:** each exporter is a Tamoz
release (ADR-014).

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| An exporter plugin API | Unversioned egress with no conformance gate |
| Fold the OTLP exporter into the contract gem | Puts HTTP in the load graph of every gem that records a signal |

## Reopen when

ADR-014 opens adapter registration.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The recorder does not raise over a malformed payload | `tamoz-core` instrumentation | `test/core_instrumentation_test.rb` — `test_malformed_payload_under_a_null_notifier_does_not_raise` | With a notifier attached it does raise (`test_malformed_payload_with_a_notifier_still_raises`) |
| The catalog is closed and versioned | `tamoz-observability` catalog | `test/observability_catalog_test.rb` — `test_attribute_set_change_without_a_version_bump_raises` | — |
| Exporter egress rejects untrusted destinations and redirects | `tamoz-otel` | `test/otel_test.rb` — `test_egress_policy_rejects_untrusted_destinations`, `test_http_exporter_does_not_follow_redirects_or_use_proxy_environment` | — |
