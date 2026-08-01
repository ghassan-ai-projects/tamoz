# Tamoz project handover plan review

Review target: `docs/PROJECT_HANDOVER_PLAN.md`

## Decision

Accepted as the trackable continuation plan from P3. It preserves the full requested scope,
keeps product value ahead of optional infrastructure, and gives the next agent explicit
proof and stop conditions instead of a list of features.

## Findings and corrections incorporated

| Severity | Finding | Correction in the handover plan |
|---|---|---|
| Critical | “Finish Tamoz” could be redefined as the already usable P8 foundation while memory, healing, MCP, scheduling, and physical streaming remain absent. | Stable completion is reserved for P15; the completion matrix keeps every named requirement open until direct evidence exists. |
| Critical | Physical-world support could be interpreted as permission to connect a real actuator after basic streaming works. | P14 requires P6/P8/P10/P12, simulator-first execution, current-state policy, independent interlocks/review, and hard stop criteria. No real adapter is authorized. |
| Critical | Durable resume could replay an ambiguous check or model/tool effect. | P6 distinguishes filesystem digest reconciliation from unknown check/provider/effect outcomes and forbids blind retry. |
| High | Large P6/P12/P14 phases would create unreviewable all-or-nothing diffs. | Each is split into separately reviewed, fully gated work packages while retaining one phase-level exit. |
| High | Existing graph/SQLite durability could be bypassed by a second agent-specific workflow store. | P6 begins with an explicit seam map and stops if it cannot use the existing runner/checkpoint/request/effect contracts. |
| High | Skills, MCP, memory, or schedules could become alternate authority paths. | P8 establishes trusted local profiles first; all later grants intersect local content-addressed policy and still require normal plan/review/effects. |
| High | An average task score could conceal a safety regression. | Every phase retains hard-zero gates and adds a fixed behavioral case; scores cannot offset violations. |
| High | Updating generated expectations could normalize regressions. | The restart runbook requires diagnosis before baseline changes and forbids changing expected values merely to restore green. |
| Medium | Roadmap/release labels are inconsistent about “v0.1 foundation” versus the complete product vision. | P8 is named a usable foundation checkpoint only; stable version/publication waits for P15 evidence and owner approval. |
| Medium | P5's “atomic create” could be implemented with ordinary rename, which overwrites races. | P5 design must prove portable atomic no-clobber semantics or stop/redesign. |
| Medium | Scheduler scope could start with unattended mutation and conflate enqueue success with task success. | P13's first consumer is read-only; delivery and execution remain separate, with hard false-green and authority gates. |
| Medium | Handing over only phase names would force the next agent to reconstruct tests, commits, and non-goals. | Every phase now has inputs, work-package IDs, product proof, hard gates, and stop conditions. |

## Dependency review

- P4/P5 expand useful coding behavior before durability integration.
- P6 precedes interaction, external capabilities, automation, memory promotion, and physical
  work because crash ambiguity otherwise contaminates all of them.
- P8 precedes skills/MCP so configuration and grants remain operator-owned.
- P9/P10 precede memory/healing so later evaluation can observe realistic capability use.
- P11 precedes P12 so improvement/healing evidence has attributable memory boundaries.
- P13 precedes P14 in execution order, while the design explicitly keeps civil-time and
  event-time runtimes separate.
- P15 audits every promoted conditional invariant and can defer only through a documented
  decision that still satisfies the original objective.

## Residual planning risks

- Exact APIs for compound edits, atomic no-clobber publication, durable agent graph shape,
  and package adapters intentionally remain decisions for their phase plans.
- MCP, Agent Skills, RubyLLM, `fugit`, safety standards, and platform behavior may change;
  implementation must verify current primary sources and record profile versions.
- Protected holdouts, code signing, and publishing credentials are external assets. Their
  absence cannot be hidden as a pass; P15 reports insufficient evidence or requests owner
  action.
- Estimates are deliberately omitted. Evidence and dependency order control progress,
  avoiding false scheduling precision for one maintainer and agent-assisted implementation.

## Handover gate

The next agent should begin only P4 design. It must not start code from the summary table,
skip the P4 plan/review commit, push the existing unpushed commits, or treat this planning
checkpoint as implementation progress.
