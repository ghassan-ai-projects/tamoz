# Bounded self-healing

Self-healing in Tamoz is not `rescue` plus retry. It is a reviewed, authorized, bounded state machine that detects a known condition, proves preconditions, performs one permitted remediation, verifies the original invariant, compensates where possible, and escalates before uncertainty spreads. Source: [`docs/design-v0.1/SELF_HEALING_DESIGN.md`](../../docs/design-v0.1/SELF_HEALING_DESIGN.md).

Current version: `0.1.0.alpha.1` (pre-release).

## Three reliability mechanisms

| Mechanism | Owner | Purpose | May learn/change behavior? |
|---|---|---|---|
| Deterministic recovery | core/graph/adapter | resume checkpoint, retry proven-safe work, reacquire lease, rebuild derived index | no |
| Bounded remediation | agent recipe + application policy | repair one classified condition under a versioned rule | no; executes only the rule |
| Systemic improvement | candidate pipeline + evaluation | propose and evaluate prevention or a better rule | only through behavior promotion |

Calling all three "retry" hides their different authority and failure semantics. No new gem ships for self-healing in v0.1: the graph already supplies state machines, interrupts, effects, checkpoints, and circuits.

## Typed failure contract

A detector consumes structured failure data: format version, failure code and category, the operation/tool and target resource, expected and observed state digests, effect state (`not_attempted | running | completed | unknown`), graph/task/execution ids, policy and behavior versions, and retryability evidence. Free-form text is never the sole mutation trigger. Initial categories include `transient_pre_dispatch`, `stale_precondition`, `dependency_unavailable`, `malformed_recoverable_output`, `resource_exhausted`, `policy_denied`, `effect_unknown`, `verification_failed`, `derived_state_corrupt`, `durable_state_corrupt`, `programmer_error`, and `unknown`.

Policy denial, durable corruption, programmer error, unknown classification, and capability absence never trigger automatic mutation; a healer cannot widen policy to heal a denial.

## The state machine

```text
observed → classified → plan + review → preflight → remediating → verifying → recovered
   (unknown / rejected / stale → escalated)
   (timeout / ambiguous effect → uncertain → reconcile → unresolved → escalated)
   (verification fail → compensating → success → escalated; failure → circuit_open)
```

Every transition records failure/rule versions, plan/review digests, trace and effect ids, attempt, actor, fence, evidence, and budgets. `recovered` is valid only for the named invariant and attempt.

## Rules and the remediation matrix

Each rule is immutable and versioned: typed trigger plus minimum confidence, risk and effect class, authorized scopes/resources, required plan/review policy, preconditions, remediation steps, idempotency/effect identity, budgets, a verification oracle, compensation/containment, circuit conditions and reset authority, and evaluation evidence. Rules default to disabled/shadow; generated rules are untrusted candidates; a rule cannot change its own matcher, oracle, budgets, authority, or circuit.

Permitted remediation forms, least to most consequential:

1. refresh state and recompute the same minimal read/action;
2. bounded retry after proven pre-dispatch transient failure;
3. renew/reacquire a lease before new work — never to admit a stale result;
4. rebuild a derived cache/index from an authoritative source;
5. restore reversible local state from a verified preimage;
6. run a semantically equivalent, pre-authorized fallback;
7. execute a separately authorized compensating action;
8. contain and escalate.

The fallback cannot be broader or more destructive. "Try another tool" is insufficient; the rule must prove equivalent semantics, scope, authority, and verification.

## Plan, review, and preflight

A remediation is an internally generated Tamoz task, so the ordinary task rules apply — every remediation drafts and reviews a plan naming the original invariant, the minimal proposed change, effect class, authorization, verification, compensation, and stop conditions. Preflight proves the original operation was authorized, the rule/target/environment/behavior version match, current state still exhibits the condition, the intended outcome remains valid, external effect state is known or reconciliation is selected, and the remediation stays within its budgets. The OpenClaw audit findings are permanent negative cases: a missing path on read does not imply permission to create a file; a directory listing is not equivalent to requested file content; a stale patch does not authorize whole-file replacement.

## Verification and compensation

Tool success is not recovery. The verifier (supplied by the rule/eval harness, never invented by the remediation model) checks the original invariant now holds, the failure no longer reproduces, the changed artifact parses/compiles/passes its targeted check, only authorized state changed, effect receipts show no duplicate, budgets were respected, and protected evidence is stored. Unavailable or invalid verification yields `escalated` or `circuit_open`, never `recovered`.

When verification fails: reversible local state is restored from its captured preimage; cancellable provider actions are cancelled with a receipt then reconciled; compensatable business effects request separate authorization and journal compensation; irreversible effects are contained, notified, and preserved as evidence — never claimed as rolled back; unknown effects are reconciled or paused. Compensation is a new effect with its own identity, authorization, approval, and receipt; failure to compensate opens the circuit.

## The DR-2 durable circuit

One circuit engine serves four scopes: `server`, `rule_target`, `schedule`, and `egress`. A circuit records scope, reason, threshold evidence, next probe time, and reset authority; it opens when configured conditions hold — verification fails twice in the observation window, one compensation/rollback fails, the same fingerprint recurs three times, an unknown effect appears for a rule claiming safe retry, or failure rate/cost/latency/precision exceeds its gate. An open circuit disables mutation and permits only safe observation, reconciliation, and notification. Time alone does not reset it; reset requires owner evidence, a reviewed plan, and normally a new rule version.

## Promotion gates and rule lifecycle

```text
draft → replay → shadow → fault_injection → canary → active → retired
                    └──────────── reject/quarantine ───────────┘
```

Rules earn authority through replay (detector precision over labelled failures and healthy traffic), shadow (reviewed plans without mutation), fault injection (the deterministic matrix in isolated sandboxes), canary (one narrow target with immediate evidence and rollback), and active stages. Human approval is mandatory for rules that add mutation capability, touch external systems, change policy/security, or lack reversible local scope. Evaluation controls the lifecycle; the rule cannot promote itself. Unsafe action, unauthorized mutation, blind ambiguous retry, false recovery, evaluator tampering, and failed-compensation concealment are hard-zero promotion gates.

## Next reads

- [`./README.md`](./README.md) — the design index
- [`../architecture/invariants.md`](../architecture/invariants.md) — the invariant contract
- [`../operations/operations.md`](../operations/operations.md) — operating recovery and circuits
- [`../../docs/design-v0.1/SELF_HEALING_DESIGN.md`](../../docs/design-v0.1/SELF_HEALING_DESIGN.md) — the authoritative design record
