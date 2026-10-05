# ADR-060 — Tamoz diagnoses itself read-only, from its durable record, by rules that are data

**Status:** Proposed
**Date:** 2026-10-04
**Tier:** F
**Implementation:** Partial — `tamoz trace` still reads only the journal; approvals in a shared worker database link to a turn by time, not by identity
**Relates to:** [ADR-045](./adr-045-observability-gems-add-no-durable-table-and-no-second-source-of-truth.md) (the durable record is the truth this reads), [ADR-046](./adr-046-content-capture-is-off-by-default-per-class-and-refused-for-restricted.md) (no content leaves through it), [ADR-047](./adr-047-telemetry-is-never-sampled-at-record-time-and-safety-bearing-signals-have-a-reserved-lane.md) (counted loss marks a report degraded), [ADR-050](./adr-050-automated-response-durable-evidence.md) (findings have no actuator), [ADR-028](./adr-028-self-healing-is-bounded-remediation-not-catch-and-retry.md) (the failure vocabulary findings use)

Tamoz answers "what went wrong" about itself by reading its durable record read-only and applying
rules kept as data; the answer is a report, never an action.

## Context

Operators need to know what a runtime did and why it failed. The facts are in SQLite — requests,
effect attempts with error class and code, approvals, checkpoints — but the only tool, `tamoz
trace`, reads the lossy journal. A diagnosis that can write may change what it inspects; one that
reads content may leak it; one that trusts free text or a model may invent a cause; one that hides
lost telemetry reports a quiet system that is not quiet.

## Decision

- **Read-only.** `Tamoz::SQLite::RecordReader` opens the database `readonly` with
  `query_only`, verifies the schema without migrating, and selects metadata and digests only. From
  a failure it returns the error class and code, never the message.
- **Rules are data.** Thresholds, severities, categories and operator text live in
  `gems/tamoz-observability/diagnosis/rules.yaml`, whose digest is on every report. Each rule names
  one detector from a closed set; an unknown or incomplete rule is refused at load.
- **Identifiers classify, text does not.** Detectors group failures by error class and code.
- **Loss is reported.** A report is `degraded`, with the reason, when the journal counted dropped
  signals, a journal health file or a database cannot be read (the database is skipped), or a read
  hit the row limit.
- **No actuator.** Diagnosis code reaches no writer, queue, network client or effect dispatch. The
  only file written is the postmortem in the operator's `--out` directory.
- **A model analysis cites evidence.** A model analyses Tamoz only through `tamoz investigate`
  over probes on the `tamoz mcp` observe tools, and every finding cites a probe call that answered. A
  postmortem labels an attached analysis as not verified by it.

## Consequences

`tamoz diagnose`, `explain` and `postmortem` give findings, a per-turn decision record and a
postmortem without reading SQLite by hand, and the agent investigates its own failures through the
loop it already has. No table, migration or model path was added. **Cost:** answers are bounded by
the record — token usage is journal-only, failure messages are never shown, rules about unknown
effects and unsettled schedules report the current state rather than the window's end — and every
threshold change is a reviewed data edit.

## Invariants

- 59 — observation cannot change execution.
- 60 — no value of a known secret shape or `Tamoz::Secret` reaches a report, explanation,
  timeline, postmortem or tool result.
- 61 — safety-bearing findings derive from the durable record; journal evidence is labelled and
  loss is counted.

## Threat model

**Asset:** the durable record and the authority to change it. **Adversary:** a buggy diagnosis
path, a model asked to explain a failure, a reader of the reports.

| Threat | Mitigation |
|---|---|
| Diagnosis changes the database | Read-only open with `query_only`; the database file is byte-identical afterwards (SQLite may leave `-wal`/`-shm` sidecars) |
| A finding triggers an action | No actuator is reachable from diagnosis code; ADR-050 governs any response |
| Content or a secret leaks | Content columns are never selected; failures yield class and code only; secret-shaped values are redacted |
| A crafted error message steers grouping | Detectors never see message text |
| Lost telemetry reads as a quiet system | Counted drops, unreadable health files or databases, and row-limit hits mark the report degraded |
| A model invents a cause | Every finding cites a probe call that answered |

**Residual risk:** a model can cite real evidence and still conclude wrongly; where approvals link
by time, an overlapping turn's approval appears in an explanation; an attached analysis file can be
hand-edited, and a secret of an unrecognised shape inside it is not detected.
