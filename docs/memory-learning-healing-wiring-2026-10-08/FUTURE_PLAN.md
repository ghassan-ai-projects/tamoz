# Automatic learning, remediation and improvement — future plan

Deferred on 2026-10-08 under the "defer complexity" rule. The 2026-10-08 change (`QUALITY_BAR.md` here)
made every channel write reported Experience, share one memory store with the CLI, and classify every
failed turn. What it does not do is below. Each item is a separate slice with its own quality bar.

## 1. Learning without an operator command

**Today:** Experience becomes Knowledge only through `tamoz memory consolidate`
(`CLIMemoryCommands#consolidate_memory` → `Memory::Access#consolidate`).

**Design:** a worker-side consolidation pass, at most once per interval, through the same
`Access#consolidate` and `EffectDispatcher` model call the CLI uses. ADR-031 says schedules materialize
occurrences and never run agents, so this is either a worker maintenance step (not a schedule) or a new
occurrence kind — decide first.

**Tests:** a pass consolidates a group once and skips it the next time; a model failure leaves Experience
untouched; the pass never runs while a turn holds the thread's lease.

**Open decisions:**
- `ExperienceGroups` only groups episodes from *different* sessions, and a Telegram conversation is one
  session (its thread id). One long chat therefore never consolidates on its own — it needs matching
  episodes from other threads or the CLI. That is the ADR-026 guard against repetition becoming fact.
  Keep it, or treat each chat day as a session?
- Interval and per-pass model-call budget.

## 2. Remediation, not only assessment

**Today:** `SelfHealingAssessor` classifies and the worker emits `healing.assessment`; the worker's
`Healing::RuleRegistry` is empty, and `SelfHealingCoordinator#remediate` has no caller.

**Design:** rules as operator data (a `healing` source in `config.yaml`, digest-pinned like policy),
loaded into the registry at boot in `shadow`; promotion past shadow through `Healing::PromotionGate` with
a promotion record. After an assessment routes `:remediate`, the worker calls the coordinator with the
turn's toolbox and the rule's verifier. The first candidate is a non-mutating one: re-enqueue a turn that
failed `model_provider_down` or `model_rate_limited` after a delay — effect state is known, nothing in
the workspace changes.

**Tests:** a rule below `active` never executes; the durable attempt bound refuses the fourth attempt
across worker restarts; a never-mutate category never reaches the coordinator.

**Open decisions:** where rules live; who may promote; whether re-enqueue counts as remediation under
ADR-028 or is plain retry policy (and so belongs in the worker, not healing).

## 3. Improvement candidates from conversations

**Today:** `tamoz improvement` generates, evaluates and promotes heuristic candidates by hand; every
session claims a promoted behavior transition (`SessionMemory#claim_behavior_transition`).

**Gap:** ADR-023 builds candidates from *verified* trajectories. Chat Experience is reported, not
verified, so conversations feed no candidate. A path needs either a verifier for chat outcomes (the
correspondent's own confirmation, captured as evidence) or an owner decision that consolidated Knowledge
may seed a candidate that still faces the holdout and human gate.

## 4. Memory per correspondent

**Today:** every channel and correspondent writes under one owner (`sources.memory.owner`, default
`operator`). Correct for one allowlisted user; with several, each would recall the others' records.

**Design:** derive the memory owner from the admitted correspondent (`telegram:user:<id>`) at binding
time, pinned like the profile digest, never from message text. Needs an owner decision on whether an
operator's CLI identity and their chat identity are the same owner.
