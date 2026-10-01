# ADR-024 — "Smart" means evidence-based, proportional, and verified

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Partial — the benchmark protocol and its controls exist; no released real-provider result yet meets it
**Relates to:** [ADR-025](./adr-025-evaluation-is-a-first-class-non-runtime-gem.md) (where the measurement lives), [ADR-058](./adr-058-domain-knowledge-is-digest-pinned-data-never-code.md) (the benchmark's domain content)

Tamoz makes no claim of general intelligence. "Smart" is a set of measured behaviors, and only a
run against a real model provider can show them; a fixture or scripted provider shows plumbing.

## Context

"Smart" as a claim rewards confident prose over correct action. An evaluated agent needs a
definition a run can pass or fail — and a rule about which runs count, because a deterministic test
that always passes can be mistaken for a capable agent.

## Decision

- Smart behavior means: reduce consequential uncertainty, keep evidence and inference distinct,
  choose the simplest high-value action within budget, ask when a guess would matter, verify
  material outcomes independently, and stop at the definition of done.
- It is measured as success, calibration, verification, unnecessary actions, corrections, safety,
  latency, and cost, under the frozen benchmark protocol (`BENCHMARK_PROTOCOL.json`): named
  provider and model, holdout lineage, preregistered baselines, stop rules, and alarms.
- Only a real-provider run can be presented as evidence of agent behavior. Tests never call a real
  model, and a fixture, stub, or deterministic provider is never shown or described as evidence
  that the agent reasons.

## Consequences

Claims about the agent are falsifiable and reproducible. **Cost:** a claim needs a paid, witnessed
real-provider run; plumbing tests, however many, do not count.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| "Smart" as an unmeasured product claim | Rewards confident prose over correct, efficient outcomes |
| Count deterministic scenario passes as capability *(retrospective, 2026-10-01)* | They test the harness, not the model's judgment |

## Reopen when

The protocol's metrics stop separating good runs from bad ones (for example, every arm scores the
same), or a provider class appears that the protocol cannot pin.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The protocol is frozen and pinned | `documentation/benchmark/BENCHMARK_PROTOCOL.json` | `test/benchmark_protocol_test.rb` — `test_committed_sha256_pin`, `test_all_eleven_stop_rules_are_frozen` | Pins the protocol; does not produce a result |
| Fixture runs are labeled plumbing, not capability | run-kind boundary in `documentation/benchmark/README.md` | `test/benchmark_report_test.rb` | No mechanical check that prose never overclaims |
