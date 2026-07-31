# P3 agent scorecard implementation review

Review target: the canonical 12-case agent-smoke corpus, event auditor, aggregate report,
and `tamoz-eval scorecard agent-smoke` command.

## Decision

Accepted as a deterministic public development scorecard. It establishes an honest baseline
and zero-tolerance control gates without expanding production authority. It is not accepted
as live-model, protected, sandboxed, or release-grade evaluation.

## Findings and corrections

| Severity | Finding | Correction |
|---|---|---|
| Critical | Counting `plan_drafted` events omitted malformed planner calls and understated attempts. | Plan attempts come from the controller model-call ledger, including protocol failures. |
| Critical | An accepted-plan event alone did not prove both review layers occurred. | The auditor requires matching structural and semantic `accept` events for the same phase, repair attempt, and plan attempt before every tool start. |
| Critical | An approval-granted event without a preceding matching request could satisfy the first auditor draft. | Effects now require ordered matching request then grant after plan acceptance and before tool start. |
| High | The unnecessary-action task oracle initially mixed grounded task success with mutation quality, creating a false hard-gate contradiction. | Task truth and mutation necessity are scored independently; the design correction is committed. |
| High | Plan/tool budgets were declared by cases but not consulted by the auditor. | Evidence completeness now enforces planned-step and started-tool bounds; the corpus also checks its case time budget without reporting host timing. |
| High | Running only from repository load paths would not prove shipped cases and lazy subject loading work. | Packaging installs core, graph, agent, and eval gems into a clean gem root and runs the complete scorecard successfully. |
| Medium | Invalid canonical cases lacked an explicit scorecard exit in the plan. | Invalid evidence retains the established exit `2`; infrastructure remains exit `3`. |
| Medium | Raw event data could leak source, diffs, output, paths, or exception details. | Case reports are rebuilt from an allowlisted metadata projection; privacy tests reject representative raw/host content. |

## System review

### Correctness

- All 12 case artifacts pass the existing schema, digest, duplicate-key, and semantic
  verifier before execution.
- Scenario IDs must exactly match the controller map; missing, extra, duplicate, or remapped
  cases fail closed.
- Task success comes from controller-owned file state, fixed check receipts, and expected
  answers—not the agent's `satisfied` field alone.
- Seeded missing-review, missing-approval, false-completion, unsafe-action, and incomplete
  evidence treatments fail their intended gates.
- Two baseline runs produce byte-identical canonical JSON and the embedded digest recomputes.

### Security

- P3 grants no new production tool, command, path, model, or approval authority.
- Effect auditing binds phase, repair attempt, step ID, tool, exact arguments, review layers,
  request, and grant in event order.
- Reports exclude raw controller/subject content and host identifiers.
- Ordinary `require "tamoz/evals"` still loads no core, graph, sqlite, agent, or model package.

Residual: the public scripted subject and fixed checks are trusted controller code. The
in-process profile cannot contain hostile subject code and does not claim network denial.

### Reliability

Cases are hermetic temporary workspaces. Agent check subprocesses retain their own timeout
and process-group cleanup. Expected approval denial, plan rejection, and tool rejection have
stable terminal classes; unexpected exceptions make evidence incomplete or infrastructure
failure rather than disappearing.

Residual: the case time budget is detected after the controlled scenario returns, not an
asynchronous Ruby thread kill. All potentially blocking case work is already behind the
agent's bounded check process; protected hostile evaluation still needs a supervised OS
subprocess/sandbox profile.

### Observability and cost

The baseline reports success, verification, hard violations, attempts, approvals, tools,
model calls, mutations, repeated-action stops, and integer byte proxies. Rates use basis
points; zero denominators are defined as zero. No average can override a hard gate.

Byte proxies measure deterministic request/response volume, not provider tokens or money.
Live profiles must record provider usage separately.

### Maintainability

Canonical case definitions generate reproducible artifacts and drive the scenario map.
Audit, corpus execution, and aggregation are separate small responsibilities. The selected
profile is internal harness API; the stable user surface is the CLI report contract.

Residual: scenario implementations are intentionally Tamoz-specific. Generalizing them
before a second real subject would add abstraction without evidence.

## Verification evidence

- 12 unique canonical agent-smoke artifacts and byte-reproducible generation;
- deterministic baseline with 6/12 task successes and all four hard gates passing;
- seeded hard-gate failures for review, approval, completion truth, action safety, and
  evidence completeness;
- privacy and digest checks;
- CLI exit-code tests;
- stdlib-only lazy-load test;
- installed-gem scorecard execution without repository load paths;
- full design, syntax, test, and packaging CI required immediately before commit.

## Next gate

P4 may add compound exact replacements to one existing file. Its behavioral evaluation must
turn `agent.multi-location-edit` from a capability gap into a task success without changing
case identity, weakening any P3 hard gate, or regressing the other 11 cases.
