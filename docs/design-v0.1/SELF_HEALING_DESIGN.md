# Self-healing — bounded remediation, verification, and escalation

Self-healing is not `rescue` plus retry. It is a reviewed, authorized, bounded state machine
that detects a known condition, proves preconditions, performs one permitted remediation,
verifies the original invariant, compensates where possible, and escalates before
uncertainty spreads.

The design follows
[Self-Healing Agent Systems](https://ghassan-alhamoud.com/articles/self-healing-architecture-feedback-loop.html)
and its
[250-case fault-injection protocol](https://ghassan-alhamoud.com/articles/stress-test-self-healing-250-target.html),
informed by the local OpenClaw rule audit.

## 1. Three reliability mechanisms

| Mechanism | Owner | Purpose | May learn/change behavior? |
|---|---|---|---|
| Deterministic recovery | core/graph/adapter | resume checkpoint, retry proven-safe work, reacquire lease, rebuild derived index | no |
| Bounded remediation | `tamoz-agent` recipe + application policy | repair one classified condition under a versioned rule | no; executes only the rule |
| Systemic improvement | candidate pipeline + `tamoz-evals` | propose and evaluate prevention or a better rule | only through behavior promotion |

Calling all three “retry” hides their different authority and failure semantics. Calling
systemic improvement “healing” would let live failures rewrite behavior without evaluation.

No new gem ships for self-healing in v0.1. The graph already supplies state machines,
interrupts, effects, checkpoints, and circuits. `tamoz-agent` supplies the remediation
recipe; Tamoz Agent owns enabled rules and authority; `tamoz-evals` owns rule promotion and
fault injection.

## 2. State machine

```text
observed
   │
   ▼
classified ── unknown/low confidence ───────────────▶ escalated
   │
   ▼
plan + review ── rejected/needs authority ──────────▶ escalated
   │
   ▼
preflight ── failed/stale/out of scope ─────────────▶ escalated
   │
   ▼
remediating ── timeout/ambiguous effect ─▶ uncertain ─▶ reconcile
   │                                               │
   ▼                                               └─ unresolved ─▶ escalated
verifying ── pass ─────────────────────────────────▶ recovered
   │
   └─ fail ─▶ compensating ── success ─────────────▶ escalated
                           └─ failure ─────────────▶ circuit_open
```

Every transition records failure/rule versions, plan/review digests, trace and effect ids,
attempt, actor, fence, timestamps, evidence, and budgets. `recovered` is valid only for the
named invariant and attempt. Recurrence is new evidence and may create a systemic issue.

## 3. Typed failure contract

A detector consumes structured failure data:

```text
format_version
failure_code and category
operation/tool and target resource
expected and observed state digests
effect state: not_attempted | running | completed | unknown
graph/task/execution ids
policy and behavior versions
retryability evidence
trusted context plus untrusted raw message reference
```

Free-form text is never the sole mutation trigger. Legacy regex adapters may propose a
typed classification with confidence, but low confidence routes to observation/escalation.

Initial categories:

- `transient_pre_dispatch`;
- `stale_precondition`;
- `dependency_unavailable`;
- `malformed_recoverable_output`;
- `resource_exhausted`;
- `policy_denied`;
- `effect_unknown`;
- `verification_failed`;
- `derived_state_corrupt`;
- `durable_state_corrupt`;
- `programmer_error`;
- `unknown`.

Policy denial, durable corruption, programmer error, unknown classification, and capability
absence never trigger automatic mutation. A healer cannot widen policy to heal a denial.

## 4. Rule contract

Each rule is immutable and versioned:

```text
rule_id, version, owner, lifecycle mode
typed trigger plus minimum confidence
risk and effect class
authorized scopes/resources
required plan/review policy
preconditions
remediation steps
idempotency/effect identity
attempt, magnitude, cost, and time budgets
verification oracle
compensation/containment
circuit conditions and reset authority
issue/escalation contract
eval suite and promotion evidence
```

Rules default to disabled/shadow. Generated rules are untrusted candidates. A rule may not
change its own matcher, oracle, budgets, authority, or circuit.

## 5. Plan, review, and preflight

A remediation is an internally generated Tamoz task, so invariants 25–27 apply. The plan
names the original invariant, proposed minimal change, effect class, authorization,
verification, compensation, and stop conditions. The semantic critic tests whether the
remediation is actually equivalent to the original intent.

Preflight proves:

- the original operation was authorized;
- the rule, target, environment, and current behavior version match;
- current state still exhibits the classified condition;
- the intended outcome remains valid after refreshing state;
- external effect state is known or reconciliation is selected;
- resources and locks are resolved canonically;
- the remediation stays within attempts, scope, magnitude, cost, and time;
- compensation or honest containment is defined.

A missing path on read does not imply permission to create a file. A directory listing is
not equivalent to requested file content. A stale patch does not authorize whole-file
replacement. Those OpenClaw audit findings become permanent negative cases in
`tamoz-evals`.

## 6. Permitted remediation forms

From least to most consequential:

1. refresh state and recompute the same minimal read/action;
2. bounded retry after proven pre-dispatch transient failure;
3. renew/reacquire a lease before new work, never to admit a stale result;
4. rebuild a derived cache/index from an authoritative source;
5. restore reversible local state from a verified preimage;
6. run a semantically equivalent, pre-authorized fallback;
7. execute a separately authorized compensating action;
8. contain and escalate.

The fallback cannot be broader or more destructive. “Try another tool” is insufficient; the
rule must prove equivalent semantics, scope, authority, and verification.

## 7. Effects and idempotency

Healing reuses the effect journal. A stable remediation key derives from:

```text
original trace + original tool/effect id + rule id/version + remediation step
```

Read-only/idempotent/transactional/reconcilable safety rules remain unchanged. A timeout
after possible mutation becomes `unknown`; the healer reconciles before any retry. Unsafe
effects never retry automatically. Losing a graph lease cannot erase a truthful attempt
receipt or authorize a stale checkpoint commit.

Self-healing cannot claim exactly-once remote effects. Its promise is narrower: no blind
retry, stable identity, bounded attempts, explicit uncertainty, and evidence-backed terminal
state.

## 8. Verification

Tool success is not recovery. The verifier checks:

- the original named invariant now holds;
- the failure no longer reproduces;
- the changed artifact parses, compiles, or passes its targeted check;
- only authorized state changed;
- effect receipts show no duplicate;
- budgets were respected;
- protected evidence is stored for audit and issue handling.

The verifier is supplied by the rule/eval harness, not invented by the remediation model.
Unavailable or invalid verification yields `escalated` or `circuit_open`, never
`recovered`.

## 9. Compensation and containment

| Effect | Response when verification fails |
|---|---|
| Reversible local state | restore captured preimage and verify restoration |
| Cancellable provider action | cancel with receipt, then reconcile |
| Compensatable business effect | request separate authorization and journal compensation |
| Irreversible effect | contain, notify, preserve evidence; never claim rollback |
| Unknown effect | reconcile or pause for human resolution |

Compensation is a new effect with its own identity, authorization, approval, and receipt.
Failure to compensate opens the circuit.

## 10. Circuit breaker and escalation

The rule/target circuit opens when any configured condition holds, including:

- verification fails twice in the observation window;
- one compensation/rollback fails;
- the same fingerprint recurs three times in one run;
- unknown effects exceed zero for a rule that claims safe retry;
- failure rate, cost, or latency exceeds budget;
- detector precision/confidence falls below its gate;
- evaluator or rule artifact cannot be verified.

An open circuit disables mutation and permits only safe observation, reconciliation, and
notification. Time alone does not reset it. Reset requires owner evidence, a reviewed plan,
and normally a new rule version.

Escalation produces an owned issue containing the failure fingerprint, original and
remediation traces, rule/version, attempts, before/after digests, verification,
compensation, current containment, and recommended next action. The issue system is not
replaced by the runtime loop.

## 11. Rule lifecycle

```text
draft → replay → shadow → fault_injection → canary → active → retired
                    └──────────── reject/quarantine ───────────┘
```

- **Replay:** measure detector precision over labelled failures and healthy traffic.
- **Shadow:** generate reviewed remediation plans without mutation.
- **Fault injection:** run the deterministic matrix in isolated sandboxes.
- **Canary:** enable one narrow target/scope with immediate evidence and rollback.
- **Active:** expand only while safety, recovery, cost, and recurrence gates hold.
- **Retired:** disable when the failure class disappears or the rule regresses.

Human approval is mandatory for rules that add mutation capability, touch external systems,
change policy/security, or lack reversible local scope. `tamoz-evals` controls the lifecycle;
the rule cannot promote itself.

## 12. Evaluation and the 250-case matrix

The reference harness crosses:

```text
10 failure classes × 5 lifecycle stages × 5 deterministic seeds = 250 cases
```

Stages: ingest, plan, execute, verify, persist.

Classes: stale state, missing input, wrong target type, timeout with unknown effect,
duplicate delivery, malformed output, policy denial, exhausted budget, verifier failure,
and corrupted checkpoint.

The controller owns fault injection, invariant, permitted/forbidden actions, deadline, and
oracle. The subject sees only the typed failure and authority granted by the rule.

Metrics:

- detection precision and abstention quality;
- precondition-rejection accuracy;
- verified recovery rate;
- unsafe-action and unauthorized-scope rates;
- duplicate-effect rate;
- compensation success/failure;
- escalation precision and alert volume;
- circuit-open correctness;
- recurrence/change-induced incident rate;
- recovery p50/p95 latency and cost.

Unsafe action, unauthorized mutation, blind ambiguous retry, false recovery, evaluator
tampering, and failed-compensation concealment are hard-zero promotion gates. Reports show
every denominator and terminal state: recovered, compensated, escalated, circuit-open,
unresolved, and infrastructure-invalid.

## 13. v0.1 reference rules

Only narrow rules are candidates:

- bounded retry for a typed pre-dispatch transient provider failure;
- stale file edit: reread and recompute one minimal conditional patch, never replace whole
  file;
- stale lease: discard stale work and reacquire only for a new attempt;
- derived memory/search index: rebuild from immutable source records;
- bounded SQLite busy retry outside long transactions.

No rule begins active. Each must pass replay, shadow, the applicable fault matrix, and canary
evidence. The reference release may ship with observation/shadow mode only if active
promotion evidence is insufficient.

## 14. Explicit non-goals

For streaming/physical deployments, healing may reconnect a connector, rebuild a derived
projection, quarantine a sensor, fail over to a declared redundant source, or open a
circuit. It may not fabricate evidence, mark an uncertain device safe, disable an
interlock, widen actuation, or convert `effect_unknown` into success.

- no generic catch-all healer;
- no retry of programmer errors, policy denial, corruption, or unknown effects;
- no destructive fallback because a precise action failed;
- no code, prompt, evaluator, permission, or policy rewrite during live recovery;
- no success based only on exit code or model explanation;
- no infinite retry, recursive healer, or elapsed-time-only circuit reset;
- no claim that resume after human intervention was autonomous healing.

The honest terminal state is more important than the recovery headline.
