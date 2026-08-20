# OpenClaw intelligence and capability study

Status: study complete; implementation work remains.

This is the second study for improving Tamoz. The first study covered chat
communication and lifecycle projection. This one focuses on why OpenClaw feels
more capable: its intelligence loop, tools, external access, autonomy, self-
inspection, MCP, context, safeguards, and operational recovery.

Read the final study in this order:

1. [00-report-bar.md](00-report-bar.md) — scope, evidence standard, and definition of done.
2. [02-openclaw-capability-report.md](02-openclaw-capability-report.md) — plain-language capability model.
3. [01-openclaw-technical-report.md](01-openclaw-technical-report.md) — implementation and tool architecture.
4. [03-tamoz-current-state.md](03-tamoz-current-state.md) — current Tamoz capability surface and root causes.
5. [04-tamoz-target-architecture.md](04-tamoz-target-architecture.md) — target intelligence architecture.
6. [05-comparison-and-priorities.md](05-comparison-and-priorities.md) — what to adopt and in what order.
7. [06-capability-scenario-matrix.md](06-capability-scenario-matrix.md) — acceptance journeys and evidence gaps.
8. [07-evidence-index.md](07-evidence-index.md) — source, test, runtime, and confidence index.
9. [08-review-log.md](08-review-log.md) — review passes, disagreements, corrections, and final audit.

## Working hypothesis

OpenClaw appears more intelligent because it combines a broad reachable
capability surface with a persistent action/observation loop. It can inspect
the world, choose among tools, preserve context, continue after intermediate
results, and expose operational controls. The important question is not how
many tools it has, but how tools become authorized, useful, durable actions.

Tamoz has stronger foundations for durable effects, evidence, approvals, and
capability authority. The completed five-agent comparison found that its useful
capabilities are narrower, hidden behind durable-session plumbing, or split
across execution models rather than composed into one adaptive agent loop.

## Study status

| Gate | Status |
| --- | --- |
| Intelligence-study quality bar | Complete |
| Five independent OpenClaw reviews | Complete |
| OpenClaw technical and capability reports | Complete for static source/test/doc evidence |
| Five Tamoz capability reviews | Complete |
| Target architecture and priorities | Complete |
| Scenario matrix and evidence index | Complete |
| Final audit | Complete |

The reports will separate static source/test evidence from live model quality,
real MCP/provider behavior, and perceived intelligence. No production code is
changed by this study.
