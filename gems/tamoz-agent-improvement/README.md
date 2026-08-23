# tamoz-agent-improvement

The bounded self-improvement vertical for Tamoz agents: candidate provenance,
one heuristic generated from verified trajectories, paired baseline/holdout
evaluation, human-gated candidate lifecycle, and promotion/rollback over the
memory behavior-transition seam. Extracted from `tamoz-agent`; the namespace
stays `Tamoz::Agent::Improvement`.

## Public surface

- **`CandidateLifecycle`** — the profile/skill/config candidate lifecycle:
  `propose`, `approval_digest`, `validate!`, `approval_request`, `approve!`,
  then the state-changing phases `apply!`, `restart_health_verify!`,
  `activate!`, `rollback!`. The candidate is immutable and powerless until a
  human approval binds its exact digest; every state change runs through
  `EffectDispatcher`.
- **`Promotion`** — records (never activates) a `kind: :heuristic_promotion`
  behavior transition through the memory-owned `Memory::TransitionRegistry`,
  with `promote`, `rollback`, `assert_rolled_back_byte_identical!`, and the
  injection-region digest helpers.
- **`Generator`** — produces at most one bounded heuristic from verified
  trajectories behind a read-only toolbox grant rooted at the train partition;
  refuses to exist if the grant overlaps a protected partition.
- **`Heuristic`** — the one bounded planning/routing/verification candidate:
  insert-only plan steps, read-only precursor tools, bounded statement,
  secret-shape checked via `Memory::Surface`.
- **`EvaluationReport`** — the seal (`seal`/`sealed`/`verify!`), the hard-zero
  gates (evaluator tampering, self-promotion, blind pairing), the human-gate
  classes, and `decide`. The report RUNNER lives in `tamoz-evals`; the seal and
  gates live here so they hold in any process that never loaded the harness.
- **`Provenance`** — the eight-axis provenance record; incomplete at any depth
  means unpromotable.
- **`Monitor`** — re-runs the exact promotion gates against post-activation
  reports; observes only, never rolls back.
- **`CandidateProposal`**, **`CandidatePolicy`** — the immutable proposal value
  and its fail-closed validation (authority may only narrow).
- **Errors**: `ImprovementError < Tamoz::Agent::Error` and its family
  (`ImprovementPolicyError`, `ProvenanceIncompleteError`,
  `HoldoutIsolationError`, `EvaluatorTamperError`, `SelfPromotionError`,
  `UngatedActivationError`, `RollbackIntegrityError`, `CandidateUnknownError`,
  `ApprovalDigestError`).

## Dependencies

`tamoz-agent-kernel` (`EffectDispatcher`, the `Tamoz::Agent::Error` base) and
`tamoz-agent-memory` (`Memory::Surface.secret_shaped?`,
`Memory::BehaviorTransition`) — the one deliberate cross-vertical edge in the
gem topology. Profile-shaped candidates bind to the `Tamoz::Agent::Profile`
facade (`Profile.from_authority`, `Profile::Transition`); that binding belongs
to the runtime cluster (`tamoz-agent` requires both), not to this gem's
declared dependencies. No sqlite, session, worker, or CLI reach-up.

Consumers: the runtime wiring and the eval harness
(`heuristic_paired_evaluation`) bind to these constants; nothing reaches past
them.
