# ADR-060 — Tamoz diagnoses itself read-only, from its durable record, by rules that are data

**Status:** Proposed
**Date:** 2026-10-04
**Tier:** F
**Implementation:** Partial — the durable reader, diagnosis, `explain`, `postmortem` and `self-observe` are built; `tamoz trace` still reads the journal only, and approval decisions in a shared worker database link to a turn by time, not by identity
**Relates to:** [ADR-045](./adr-045-observability-gems-add-no-durable-table-and-no-second-source-of-truth.md) (the durable record is the truth this reads), [ADR-046](./adr-046-content-capture-is-off-by-default-per-class-and-refused-for-restricted.md) (no content leaves through it), [ADR-047](./adr-047-telemetry-is-never-sampled-at-record-time-and-safety-bearing-signals-have-a-reserved-lane.md) (counted loss marks a report degraded), [ADR-050](./adr-050-automated-response-durable-evidence.md) (conditions without an actuator), [ADR-028](./adr-028-self-healing-is-bounded-remediation-not-catch-and-retry.md) (the failure vocabulary findings use)

Tamoz answers "what went wrong" about itself from a read-only view of its durable record, through
rules kept as data; the answer is a value, never an action, and a model that analyses Tamoz cites
the evidence it read.

## Context

An operator, a regulator or the agent itself needs to know what a runtime did and why it failed.
The facts exist — requests, effect attempts with error class and code, approvals with policy
revision and actor evidence, checkpoints — but only a person reading SQLite could see them, and
`tamoz trace` reads only the lossy journal. The tension: an agent that inspects itself could also
change what it inspects (open the database for writing, run a migration, retry an effect, approve
its own pause), could leak content into a report, could trust its own telemetry over the record,
and could let a model invent a cause. A diagnosis that can act is a control plane; one that can be
wrong silently is worse than none.

## Decision

- **One read-only reader.** `Tamoz::SQLite::RecordReader` implements `TelemetryReader` (contract
  v2). It opens the database `readonly` with `PRAGMA query_only = ON`, verifies the schema without
  migrating, pins one read transaction for the reader lifetime, and selects metadata and digests only. Payload, response, result and checkpoint
  content are never selected. A failure blob is decoded for exactly two identifiers, its error class
  and code; its message is never returned, and a value that is not an identifier or is
  secret-shaped is dropped. Schedule completion evidence is excluded; report surfaces redact
  secret-shaped metadata and journal correlation after identity matching.
- **Rules are data.** Every threshold, severity, category and operator-facing sentence lives in
  `gems/tamoz-observability/diagnosis/rules.yaml`, digest-recorded on every report. A rule names
  one detector from a closed set; an unknown detector, record kind, severity or category is refused
  at load, and so is a rule missing a parameter its detector needs. A rule's category is a word from
  the self-healing failure vocabulary naming the rule's concern; it does not classify each failure.
- **Free text never classifies.** Detectors group failures by error class and code; no message text
  reaches them.
- **Loss is stated.** A report is `degraded`, and names why, when the journal's retained health
  files have counted dropped signals (a cumulative count, not a per-window one) or when a read hit
  the row limit. Explanations name every record kind that reached that limit in `truncated`.
- **Time and identity are explicit.** Terminal failure groups use completion time. Request-specific
  explanations filter effects by request identity; checkpoints are labelled as execution context.
- **Diagnosis cannot act.** `Diagnosis`, `Explanation`, `Timeline`, `Postmortem`,
  `SelfObservation` and `SelfObserveServer` reach no writer, enqueue, network client or effect
  dispatch. The only file written is the postmortem in the operator's `--out` directory; opening a
  quiet WAL database read-only may leave SQLite's `-wal`/`-shm` sidecars (mode 0600), and the database
  file itself stays byte-identical. Rules about unknown effects and unsettled schedules report the
  current state, not the state as of a window's end.
- **A model analysis is cited.** A model analyses Tamoz only through `tamoz investigate` over the
  `self-observe` MCP tools declared as operator probes, whose every finding must cite a probe call
  that answered. `postmortem --analysis` embeds a findings report given to it and labels it as not
  verified by the postmortem command.

## Consequences

An operator gets findings, a per-turn decision record and a postmortem from one command, and the
agent can investigate its own failures through the investigation loop it already has. No table,
migration, capability source or model path was added. **Cost:** answers are bounded by what the
record holds — model token and cost usage is journal-only, `trace` still reads only the journal,
failure messages are not shown (only class and code), and a shared worker database can attribute an
approval to a turn only by time — and every threshold change is a reviewed data edit.

## Invariants

- 59 — observation cannot change execution: the reader is read-only and diagnosis has no actuator.
- 60 — no value of a known secret shape (`Tamoz::Core` secret patterns) or `Tamoz::Secret` reaches a
  report, explanation, timeline, postmortem or tool result; a secret of an unrecognised shape inside an
  attached analysis file is not detected.
- 61 — safety-bearing findings derive from the durable record; journal-derived evidence is labelled
  and loss is counted.

## Threat model

**Asset:** the runtime's durable record and the authority to change it. **Adversary:** a buggy or
misled diagnosis path, a model asked to explain a failure, and a reader of the reports.

| Threat | Mitigation |
|---|---|
| Diagnosing changes the database | Read-only open with `query_only`; no write statement in the reader; byte-identical database after every command (tested) |
| A finding triggers an action | No actuator, enqueue or dispatch reachable from the diagnosis files (tested); ADR-050 still governs any response |
| Content or a secret leaks into a report | Content columns never selected; failure blobs yield only class and code identifiers, secret-shaped ones dropped; schedule completion evidence excluded; metadata and journal correlation redacted (tested) |
| A crafted error message steers classification | Messages are never returned; grouping by class and code only (tested) |
| Lost telemetry read as a quiet system | Counted drops and row-limit truncation mark the report degraded (tested) |
| A model invents a root cause | Every finding of the analysing turn cites a probe call that answered; a postmortem labels an attached analysis as unverified by itself |

**Residual risk:** a correct finding can still be read wrongly by a person; in a shared worker
database an approval from any turn that overlapped in time is shown with the turn being explained;
request-specific explanations also link approvals by time in session databases;
a hand-edited analysis file can be attached to a postmortem; a model's analysis can cite real
evidence and still draw a wrong conclusion.
