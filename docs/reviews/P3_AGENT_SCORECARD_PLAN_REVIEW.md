# P3 agent scorecard plan review

Review target: `docs/P3_AGENT_SCORECARD_PLAN.md`

## Decision

Accepted. The plan creates a useful deterministic baseline without expanding agent
authority or turning `tamoz-evals` into an unconditional production dependency.

## Findings and corrections incorporated

| Severity | Finding | Plan correction |
|---|---|---|
| Critical | Treating agent self-report as task success would make the scorecard circular. | Each scenario has a controller-owned state/check oracle. Runtime `satisfied` is reported separately and contradiction is a hard failure. |
| Critical | An average score could hide action before review or missing approval. | Exact event reconstruction produces zero-tolerance hard gates, reported separately from competence and efficiency. |
| Critical | Claiming network denial for an in-process runner would be false without an OS sandbox. | The deterministic profile makes no network call and explicitly reports `network_enforcement: not_claimed`; it is not protected evaluation. |
| High | Adding `tamoz-agent` as an unconditional eval-gem dependency would violate the stdlib verifier boundary. | Only explicit subject selection lazily loads the agent. Ordinary eval loading and artifact verification remain isolated. |
| High | Emitting raw prompts, diffs, output, or exception messages could leak source or secrets. | Reports retain counts, stable codes, digests, and byte totals only. Content and host paths are prohibited and tested. |
| High | A scorecard authored entirely in Ruby would leave case identity mutable and unauditable. | The public corpus is canonical case artifacts with verified unique digests; the runner fails closed on case/map mismatch. |
| High | Host timing and executable paths would make the supposedly deterministic baseline drift. | The canonical report excludes timestamps, durations, temporary roots, PIDs, and rendered command previews. |
| Medium | Unsupported P4/P5 tasks could be mislabeled as harness failures or removed to raise the score. | They remain honest task failures with complete safe evidence and pinned case identities. |
| Medium | Expected approval denial and tool rejection could be confused with infrastructure errors. | Cases declare allowed terminal classes; unexpected exceptions fail evidence completeness with safe error codes. |
| Medium | Unnecessary action is broader than unnecessary mutation. | P3 reports mutation precisely and retains tool/approval counts; a later scorer may add unnecessary read/check judgment without changing this lineage. |

## Residual risks

- Scripted responses validate framework control behavior, not real-model intelligence.
- In-process execution is appropriate only because inputs, checks, and responses are public
  controller-owned fixtures. It provides no containment against hostile subject code.
- Byte proxies are deterministic cost indicators, not provider token or monetary cost.
- The aggregate report is not yet a durable v1 result artifact. It cannot be used alone for
  release promotion.
- Auto-approval in positive cases measures approval plumbing, not human decision quality.

These limits are explicit in the report and documentation. Live/recorded model profiles,
protected holdouts, subprocess sandboxing, case-level result artifacts, and baseline
comparison remain later evaluation work; they are not prerequisites for the P3 product
signal.

## Implementation gate

Implementation may begin only after this plan/review checkpoint is committed. The phase
must stop and revise the plan if the 12-case runner requires new production tools, arbitrary
shell execution, a production dependency on evals, raw-content reports, or weakened case
verification.
