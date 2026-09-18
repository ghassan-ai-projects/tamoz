# Measurement plans — one per capability, to remove every "unknown"

The instruments discriminate and are honest; what is missing is real-model evidence. These are the
per-capability recipes to turn each "unknown" into a measured number. Sequencing, spend, and the
owner decisions live in the phased master: [`../MEASUREMENT-PLAN-20260919.md`](../MEASUREMENT-PLAN-20260919.md).

Every plan obeys the same rule: real provider (DeepSeek), `seeds>=4, repeat>=2`, `pass^k` over
scenarios with a 95% interval, against controls that already pass, published with provenance — or
an explicit recorded refusal where a claim cannot yet be earned. Real runs use the real model
(never fake); the eval stays independent (tamoz-only).

| # | Capability | Now | Biggest unknown |
|---|---|---|---|
| 01 | [Coding](01-coding.md) | graded eval, controls pass | real solve-rate (blocked by plan gate) |
| 02 | [Chat](02-chat.md) | graded eval, controls pass | real chat competence |
| 03 | [MCP](03-mcp.md) | tests + 1 mission cell | real external-tool competence |
| 04 | [Skills](04-skills.md) | containment tested | real skill selection/use |
| 05 | [Autonomy](05-autonomy.md) | scripted scorecard | real unattended competence |
| 06 | [Decision](06-decision.md) | eval + property specs | real supervisory judgment |
| 07 | [Planning](07-planning.md) | gate exercised, never graded | real plan quality |
| 08 | [gRPC / wire](08-grpc-wire.md) | integration tests | (protocol — conformance, not competence) |
| 09 | [Intelligence missions](09-intelligence-missions.md) | graded eval, controls pass | governance/recovery/memory/parity/self-knowledge |
| 10 | [Self-healing](10-self-healing.md) | property tests | real recovery rate |
| 11 | [Self-improvement](11-self-improvement.md) | pipeline + controls | does it actually improve |
| 12 | [Physical](12-physical.md) | property spec | recommendation fitness + dispatch safety |
| 13 | [Horizon](13-horizon.md) | axis named, one bucket | competence over long tasks |
| 14 | [Context management](14-context-management.md) | bounded/integrity tests | does compaction keep the *right* info |
| 15 | [Tool calling & permissions](15-tool-calling-and-permissions.md) | strong enforcement, fail-closed | real tool-use success; approval calibration |
| 16 | [Active investigation](16-active-investigation.md) | **NEW** — primitives only (evidence client, request_evidence) | recognize insufficiency → gather → decide (capability not built) |

Prereqs already met for all: discriminating instruments, independent evals, green controls,
`pass^k`/Wilson/McNemar machinery. The gate is spend + two owner decisions (coding plan-gate;
physical evidence-fitness).
