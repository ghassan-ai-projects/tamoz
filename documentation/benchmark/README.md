# Benchmark and rollout evidence

This directory owns Tamoz's machine-readable evaluation contract and the evidence
that supports it. The protocol is frozen by digest; changing its cases, budgets,
baselines, scoring rules, or stop rules creates a new benchmark version.

## Evidence rules

- `BENCHMARK_PROTOCOL.json` is the frozen protocol: budgets, baselines, scoring,
  hard-zero safety rules, and provider/run-kind boundaries.
- `OPENCLAW_MISSIONS.json` is the scenario catalog consumed by the benchmark
  harness.
- [openclaw-chat-study/README.md](openclaw-chat-study/README.md) is the communication
  benchmark protocol and C1–C9 scenario contract.
- [openclaw-intelligence-study/README.md](openclaw-intelligence-study/README.md) is the
  intelligence benchmark protocol and T1–T11 scenario contract.
- `holdout-pin/` contains the committed holdout manifest and truth needed to
  reproduce a pinned evaluation. The leak scan is generated during a holdout run
  and is intentionally not committed.
- Fixture and scripted-provider runs prove harness and safety plumbing only. They
  are not evidence that a model is intelligent or that a live provider works.
- A real-provider claim requires an externally witnessed run, exact artifact
  provenance, the protocol hard-zero gates, and the protocol's baseline and
  statistical rules. An inconclusive or unavailable result stays that way.

## Controlled rollout

Automatic consequential actions require an exact calibration binding for the
domain, prompt, diagnosis catalog, policy, and model revision. A missing or
mismatched binding remains watch-only; it never falls back silently.

See [the evaluation guide](../guides/evaluation.md) for commands and artifact
verification.
