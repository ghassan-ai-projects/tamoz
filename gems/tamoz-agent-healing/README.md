# tamoz-agent-healing

The P12 bounded self-healing vertical for Tamoz agents: the typed failure
contract, classification and abstention, the immutable rule contract, and the
reviewed remediation protocol. Extracted from `tamoz-agent` so healing depends
on the kernel base layer instead of the full runtime.

## Public surface

- **Entry point**: `Healing::Remediation.run` — the reviewed
  classify/preflight/plan/review/execute/verify remediation protocol, returning
  a typed `Remediation::Outcome`; `Healing.load_record!` is the single
  allowlisted entry point for reviving durable healing records.
- **Rules**: `HealingRule` (the frozen, digest-bound rule contract) and
  `RuleRegistry`.
- **Classification**: `Classification` — typed categories, confidence gating,
  and abstention (an uncertain classifier routes to escalation, never to a
  guessed repair).
- **Guards and evidence**: `Preflight`, `Scope`, `EffectIdentity`,
  `FailureRecord`, `PromotionGate` (digest-bound lifecycle promotion).
- **Verification**: `Oracle` — the configured-check oracle reusing
  `Tamoz::Tools::CheckReceipt`; no second tool runner.
- **Seams**: `Healing::Seams::*` — default implementations injected into the
  protocol (circuit store, escalation sink, and friends), so callers swap them
  without touching the engine.
- **Errors**: `HealingError` and its family — `ClassificationAbstention`,
  `PreflightRejection`, `VerificationFailure`, `CircuitOpen`,
  `CompensationFailure`, `SelfModificationError`, `SelfPromotionError`,
  `HealingPolicyError`, `HealingContractError` — all under
  `Tamoz::Agent::Error`, with the raise-vs-return decision encoded in
  `FAILURE_MODEL`.

## Dependencies

`tamoz-agent-kernel` (`EffectDispatcher` and the error taxonomy),
`tamoz-tools` (`Toolbox`, `CheckReceipt`), `tamoz-core`. Nothing above this
layer leaks in: no session, worker, CLI, graph, comms, or approval code. The
semantic critic is an INJECTED callable — nothing here loads RubyLLM or
`tamoz-evals`.

## Versioning

Ships in lockstep with the rest of the monorepo (`0.1.0.alpha.1` literal per
gem, hand-synced like every sibling).
