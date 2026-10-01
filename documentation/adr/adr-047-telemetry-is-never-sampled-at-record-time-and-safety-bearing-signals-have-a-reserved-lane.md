# ADR-047 — Telemetry is never sampled at record time, and safety-bearing signals have a reserved lane

**Status:** Accepted 2026-08-10
**Date:** 2026-08-10
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-045](./adr-045-observability-gems-add-no-durable-table-and-no-second-source-of-truth.md) (the journal is lossy; truth is the durable record)

The recorder never samples. If sampling is ever added, it is an export decision and never applies to
safety-bearing signals. Safety-bearing signals ride a reserved lane that is written even when the
bulk queue is full; every drop that does happen is counted.

## Context

Sampling against an in-memory window at record time loses a turn that pauses for days, and drops
evidence exactly when the system is loudest. But a bounded journal can still lose data — to
saturation, a closed or disabled drain, a disk error, or rotation — and calling that "records
everything" would be false.

## Decision

- The recorder has no sampling. Any future sampling happens when an exporter reads the journal.
- The signal catalog marks each signal `safety_bearing`. Those go to a reserved queue; when it is
  full they are written synchronously instead of dropped.
- Input can still be lost: when the drain is closed or disabled, on bulk-queue saturation, or on a
  disk error (which disables the journal). Closed, disabled, and queue-full drops are counted per
  signal, reason, and lane in a health sidecar. A disk or writer failure is counted once, as a
  journal-level entry; the signals in the batch being written are lost without per-signal counts,
  and a failure to write the sidecar itself is swallowed.
- Retained files rotate and expire (ADR-045). What survives a days-long pause is the durable record,
  not the journal.

## Consequences

Loss is visible instead of mistaken for health, and safety-bearing signals are the last to go.
**Cost:** a reserved lane and synchronous fallback writes under pressure.

## Invariants

- 59 — every drop is counted and inspectable.
- 61 — safety-bearing observability is derived from durable evidence.

## Threat model

**Asset:** the evidence an operator or ADR-050 automation would act on. **Adversary:** load and
failure, not an attacker.

| Threat | Mitigation |
|---|---|
| Safety evidence dropped under load | Reserved lane with synchronous fallback |
| Loss read as a quiet system | Drops counted by reason; a disk failure is counted once and disables the journal |
| A paused turn's telemetry rotated away | Safety views reconstruct from the durable record |

**Residual risk:** on a disk error even safety-bearing signals are lost, with one journal-level count
rather than per-signal counts; the durable record remains the source of truth.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Sampling at record time against an in-memory window | A paused turn outlives the window; safety evidence is dropped when loudest |
| Unbounded queues so nothing drops *(retrospective, 2026-10-01)* | Moves the failure to memory exhaustion of the process that runs the agent |

## Reopen when

Export volume forces sampling (then define it at export), or a safety-bearing signal is found
dropped without a counted reason.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Safety-bearing flags are seeded in the catalog | `gems/tamoz-observability/lib/tamoz/observability/catalog.rb` | `test/observability_catalog_test.rb` — `test_seeded_safety_bearing_flags` | — |
| Bulk saturation is counted | `gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb` | `test/observability_runtime_test.rb` — `test_bulk_saturation_is_counted_and_metric_cardinality_is_rejected` | The reserved-lane synchronous fallback is source inspection only |
| No record-time sampling exists | recorder | source inspection (no sampling code in the observability or otel gems) | — |
