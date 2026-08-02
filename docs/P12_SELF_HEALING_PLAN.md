# P12 — bounded self-healing and self-improvement: implementation plan

Status: accepted for implementation (revision 2 — plan-critic corrections C1–C12
integrated; see `docs/reviews/P12_SELF_HEALING_PLAN_REVIEW.md`)
Authoritative inputs: `docs/design-v0.1/SELF_HEALING_DESIGN.md` (source of truth for
semantics), `AGENT_DESIGN.md` §§12–14, invariants 25–28, 32–34, 35, the P12 card in
`docs/PROJECT_HANDOVER_PLAN.md`, and the P6 effect/durable machinery + P11 memory that
this phase rides on.

Phase activation rule: committed as a design artifact while P10 is active; the handover
ledger's P12 row stays `pending` until P11 closes. No P12 code before that.

## 1. Scope commitment and phase outcome

Handover card outcome, verbatim: "one narrow healing rule and one reversible behavior
candidate pass independent evaluation, promotion, monitoring, circuit, and rollback
gates. Neither can approve itself or widen authority."

| Outcome clause | Work package | Proof (test, not claim) |
|---|---|---|
| typed failure/rule/record lifecycle | P12-HD | versioned immutable `HealingRule` + typed `FailureRecord`; every §2 state-machine transition audited; rule immutability asserted (self-edit attempt rejected) |
| classification and abstention | P12-H1 | category matrix over synthetic failures; five never-mutate classes asserted; abstention lands `escalated`; denominators reported; 100%-abstention rule cannot promote |
| exact reviewed remediation | P12-H2 | a full remediation lifecycle test against a sandboxed fault: plan → semantic-critic review → preflight → execute → oracle-verify → recover/escalate; preflight rejection matrix; effect-identity determinism; no-blind-retry |
| compensation, durable circuit, escalation | P12-H3 | each circuit condition triggered individually; open-circuit behavior test; reset-requires-evidence; escalation record completeness (cross-checks compensation receipt digest); concealment test |
| promote at most one narrow reference rule | P12-H4 | full lifecycle trace replay → shadow → fault injection → canary → active with eval evidence at each stage; or observation/shadow-only with disclosure |
| one reversible behavior candidate | P12-I1/I2/I3 | candidate provenance → paired eval → human gates → BehaviorTransition at a turn boundary → cache-epoch bump → regression injection → byte-identical rollback |
| (conditional) bounded delegation | P12-S | only if the candidate or product proof needs it; otherwise documented not-shipped |

Hard-zero gates (fail the phase regardless of value): unsafe/unauthorized action, blind
ambiguous retry, false recovery, hidden compensation failure, evaluator tampering,
self-promotion (a rule or candidate promoting itself), and a regression surviving without
rollback.

## 2. Package boundary and reuse

No new gem for self-healing (design §1). Reuse, do not duplicate:

- graph: state machines, interrupts, effects, checkpoints (DurableRunner/Compiled);
- `tamoz-agent`: the remediation recipe, rule registry, escalation issue record;
- `tamoz-sqlite`: the Store for rule/circuit/escalation records (new namespaced keys via
  the existing Migrator; versioned allowlisted codecs; fenced writes through the same
  lease guard as every other durable write);
- `tamoz-evals`: rule promotion, fault injection, the applicable 250-case matrix —
  reusing its existing `SubprocessRunner`, `TraceRecorder`, `Verifier`, and
  `agent_run_audit` seams; the matrix controller is a *scenario registry extension*, not
  a second harness;
- P11 memory: verification/wisdom evidence feeds candidate pipelines; healing never
  writes memory directly.

**Durable circuit — one record type, three scopes (C1; owned by DR-2).** Verified at review: no durable
circuit exists anywhere in the tree today. The first circuit is P10's supervisor
transport circuit (being built in P10 slice 3 per the P10 plan §8 "durable circuit").
The record shape, scope semantics, reset authority, and acceptance tests are defined in
`docs/DR2_DURABLE_CIRCUIT_PLAN.md`; this section summarizes. ONE circuit record type persists in tamoz-sqlite
(Store namespace `tamoz.circuit.<scope>`) with the design §10 fields — scope, state
(`closed`/`open`), threshold, consecutive-failure count, opened_at, next_probe_at,
reset_authority, evidence — and one lifecycle (time alone never resets; reset requires
owner evidence + a reviewed plan + normally a new rule version; open disables mutation,
permits safe observation/reconciliation/notification). P10's supervisor circuit (per-
server transport scope), P12's rule/target circuit (design §10 conditions), and P13's
scheduler circuit (consecutive scheduler/execution failures) are all instantiations of
this one record. P10 may land the record in-memory if the slice-3 scope does not persist
it; then P12 owns the durable generalization — recorded in the progress ledger, not
silent. **No second circuit engine under any resolution.**

Dependency rule (existing dependency-isolation test): remediation recipe code loads
without RubyLLM on non-model paths; `tamoz-evals` stays out of production load paths.

## 3. Typed failure contract and classification (P12-HD/H1)

`FailureRecord` carries the design §3 fields verbatim (format_version, failure_code,
category, operation/tool, target resource, expected/observed state digests, effect
state, graph/task/execution ids, policy/behavior versions, retryability evidence,
trusted context + untrusted raw message reference). Free-form text is never the sole
mutation trigger.

Categories (initial, §3): `transient_pre_dispatch`, `stale_precondition`,
`dependency_unavailable`, `malformed_recoverable_output`, `resource_exhausted`,
`policy_denied`, `effect_unknown`, `verification_failed`, `derived_state_corrupt`,
`durable_state_corrupt`, `programmer_error`, `unknown`.

Classification rules (H1):

- **Five** never-mutate classes (C10, count corrected): `policy_denied`,
  `durable_state_corrupt`, `programmer_error`, `unknown`, and missing capability — none
  ever triggers automatic mutation.
- A classifier that cannot reach the rule's `minimum_confidence` gate abstains;
  **abstention → `escalated`** (design §2), counted with denominators per class in the
  eval. Abstention quality (C9) = correct abstention on never-mutate classes minus
  over-abstention on classes the rule must handle; a rule with 100% abstention cannot be
  promoted to active.
- Legacy regex adapters may propose typed classification with confidence; low confidence
  abstains. No new regex adapter ships without a defined measured precision gate with a
  numeric threshold (design §3); speculative machinery is out of scope.

Proof: classification matrix over synthetic failures (each category → correct action
family or abstention); abstention→escalated test; five never-mutate classes asserted;
denominator reporting in the matrix.

## 4. Rule contract and remediation (P12-H2)

`HealingRule` is immutable and versioned with the design §4 fields (rule_id, version,
owner, lifecycle mode, typed trigger + minimum confidence, risk/effect class,
authorized scopes/resources, required plan/review policy, preconditions, remediation
steps, idempotency/effect identity, attempt/magnitude/cost/time budgets, verification
oracle digest, compensation/containment, circuit conditions + reset authority,
escalation contract, eval suite + promotion evidence). A rule may not change its own
matcher, oracle, budgets, authority, or circuit — **asserted by an immutability test that
executes an attempted self-edit and asserts rejection; a new version requires a reviewed
diff and human approval for mutation-capable rules** (C7/P1).

Remediation protocol (invariants 25–27):

1. classify → 2. plan (named original invariant, minimal change, effect class,
   authorization, verification, compensation, stop conditions) → 3. semantic critic
   review → 4. preflight (design §5 checklist) → 5. execute one permitted form (§6) →
   6. verify → 7. compensate or escalate (§9/§10).

**Verification oracle (C2, invariant 33):** the oracle IS a configured check — the
existing deterministic, model-independent check machinery (`run_check`, child-process,
digest-pinned in the plan/rule) — and its digest is part of the immutable rule record.
`recovered` requires the recorded oracle pass result from that check. A remediation
model narrating "fixed and verified" with the oracle failing or absent terminates
`escalated` or `circuit_open`, never `recovered` — asserted by a DoD test.

Effect identity: stable key from original trace + original tool/effect id + rule id/
version + remediation step (§7). Read-only/idempotent/transactional/reconcilable safety
rules unchanged; unsafe effects never retry automatically; timeout after possible
mutation → `unknown` → reconcile before retry.

Negative cases (design §5, permanent in tamoz-evals): missing path ≠ permission to
create; directory listing ≠ file content; stale patch does not authorize whole-file
replacement.

Proof: full remediation lifecycle test against a sandboxed fault; preflight rejection
matrix; effect-identity determinism; no-blind-retry; unknown-effect reconcile;
oracle-independence test (C2).

## 5. Compensation, circuit, escalation (P12-H3)

Compensation: new effect with its own identity, authorization, approval, receipt
(design §9 table). Circuit: opens on any §10 condition; open disables mutation; only
safe observation, reconciliation, notification; time alone never resets it; reset
requires owner evidence + reviewed plan + normally a new rule version. Escalation: owned
durable issue record (Store namespace `tamoz.escalations.<id>`) with failure fingerprint,
traces, rule/version, attempts, before/after digests, verification, compensation,
containment, recommended next action.

**Escalation-record completeness (C7/P2):** completeness is defined as cross-checking
the compensation effect's journal receipt digest against the escalation record; a
mismatch (e.g., compensation journaled as succeeded but failed) surfaces the discrepancy
and opens the circuit. Asserted by a concealment test.

Proof: each circuit condition triggered individually; open-circuit behavior test;
reset-requires-evidence; escalation completeness + concealment test.

## 6. Rule lifecycle and promotion (P12-H4)

Lifecycle: `draft → replay → shadow → fault_injection → canary → active → retired`
(design §11). Human approval mandatory for rules that add mutation capability, touch
external systems, change policy/security, or lack reversible local scope.

**No self-promotion (C7, invariant 34):** `lifecycle_mode` transitions are written only
by `tamoz-evals`, digest-bound to eval evidence; the runtime verifies on rule load that
the mode is backed by a matching promotion record and refuses any lifecycle write or
circuit reset attempted from inside a rule/session. Asserted by an adversarial test that
attempts a direct lifecycle write and a circuit reset and asserts refusal.

v1 promotes AT MOST ONE of the §13 reference rules. Preference (C11, reconciled with the
card): the card lists "stale conditional file edit OR bounded pre-dispatch provider
retry"; design §13 lists bounded pre-dispatch retry first. Either is acceptable; the
choice is evidence-driven and recorded in the phase close, not silently dropped.

If active evidence is insufficient after the applicable fault matrix, the phase ships
observation/shadow mode only and discloses it (card allows explicitly).

Proof: the promoted rule's full lifecycle trace with eval evidence at each stage;
no-self-promotion adversarial test; observation-only fallback path.

## 7. Behavior improvement (P12-I)

Candidate pipeline (mirrors design §7 + invariant 28):

- **P12-ID**: candidate provenance record (source trajectories, affected behavior,
  policy/risk, artifact digests, evaluation lineage, activation scope, rollback target).
- **P12-I1**: generate at most one bounded planning/routing/verification heuristic
  candidate from verified trajectories. Never activate live prompt/code changes during
  the generating task. **Holdout isolation (C7/P3):** the generator task's tool roots
  exclude the holdout corpus and evaluator output — enforced as a capability/root
  restriction, asserted by a test that attempts the read and is refused (mirrors
  P11-W's data-flow-level assertion).
- **P12-I2**: paired baseline/holdout evaluation on identical sandboxed tasks; the
  candidate cannot see its holdout or evaluator. Human gates for: prompt hierarchy,
  tools, roots, credentials, policy, evaluator, skills/scripts, code. Evaluator
  tampering is a hard-zero gate.
- **P12-I3**: activate as a new behavior/cache epoch at a turn boundary; in-flight
  sessions pin the old epoch; monitor the same gates promotion used; inject a regression;
  prove rollback restores the previous epoch byte-identically.
- **P12-S** (conditional): bounded subagent/delegation only if needed: child
  graph/version/namespace, narrower grant, typed return, budgets, ordered fan-in.

**BehaviorTransition ownership (C4, aligned with P11-W):** P11-W owns the
`BehaviorTransition` record and its activation mechanics (DR-1 revision 3: two-phase
claim→apply→finalize; FIRST-INTAKE-OF-THREAD only — existing threads are pinned and
resume is `boundary: false`; one shared behavior-version record allocated by CAS at
record time; in-flight authority never mutated). P12 reuses that seam for its
heuristic candidate (`kind: :heuristic_promotion`); it does not build a second one. Candidate provenance divides cleanly: P11-W = memory-derived strategy;
P12-I = trajectory-derived heuristic. Both candidates share one behavior-version record
and cannot independently bump it.

**Epoch seams (C5, invariant 16/28):** the session record's `behavior_version`
(currently the static constant `tamoz.agent.session/1`) becomes a dynamically pinned
value; the cache epoch bumps through the existing prompt-prefix digest seam
(`prompt_surface_digest`, already an optional session-record field). I3 decomposes into:
(a) pin `behavior_version`, (b) bump the cache epoch with a recorded reason, (c) a
defined turn boundary — between turns; in-flight sessions pin the old value; rollback
restores byte-identically.

Proof: provenance completeness test; candidate-blindness (holdout isolation) test;
human-gate enforcement; epoch-pinning test (in-flight unchanged); rollback test
(regression injected → rollback → byte-identical previous epoch); P12-S gating test.

## 8. Evaluation — the applicable 250-case matrix

Before any ACTIVE healing claim, the applicable portion of the design §12 matrix runs:
10 failure classes × 5 lifecycle stages × 5 deterministic seeds, with the controller
owning fault injection, invariants, permitted/forbidden actions, deadline, oracle; the
subject sees only the typed failure + granted authority.

**Applicability contract (C6):** a cell is NOT applicable only if the fault class cannot
occur at that stage within the rule's authorized scope; every exclusion is stated and
cross-referenced to another work package's proof. The fault-class → FailureRecord
category mapping:

| Matrix fault class | FailureRecord category |
|---|---|
| stale state | `stale_precondition` |
| missing input | `malformed_recoverable_output` / abstention |
| wrong target type | abstention (not misfire) |
| timeout with unknown effect | `effect_unknown` |
| duplicate delivery | `resource_exhausted`-adjacent / effect reconciliation |
| malformed output | `malformed_recoverable_output` |
| policy denial | `policy_denied` (never mutate) |
| exhausted budget | `resource_exhausted` |
| verifier failure | `verification_failed` |
| corrupted checkpoint | `derived_state_corrupt` / `durable_state_corrupt` (→ H3 durability proofs) |

Mandatory cells for the v1 reference rule (bounded pre-dispatch retry): timeout-with-
unknown-effect × {ingest, plan, execute}; duplicate-delivery × execute; verifier-failure
× verify; policy-denial × {ingest, plan}; exhausted-budget × {plan, execute};
stale-state × plan; missing-input × plan; wrong-target-type × ingest. Never-mutate and
verify-stage cells are mandatory for any active claim.

Metrics reported with every denominator and terminal state (recovered, compensated,
escalated, circuit_open, unresolved, infrastructure-invalid): detection precision and
abstention quality; precondition-rejection accuracy; verified recovery rate;
unsafe-action and unauthorized-scope rates; duplicate-effect rate; compensation
success/failure; escalation precision and alert volume; circuit-open correctness;
recurrence/change-induced incident rate; recovery p50/p95 latency and cost.

Hard-zero promotion gates (design §12): unsafe action, unauthorized mutation, blind
ambiguous retry, false recovery, evaluator tampering, failed-compensation concealment.

Scope note: the matrix is sandboxed and deterministic (the controller is a test harness,
not a live policy); no real physical actuator or external system is involved (owner
constraint; P14 is where physical simulation starts, and P12 never touches it).

## 9. Non-goals (design §14, restated verbatim so the builder cannot drift)

No generic catch-all healer; no retry of programmer errors, policy denial, corruption,
or unknown effects; no destructive fallback because a precise action failed; no code,
prompt, evaluator, permission, or policy rewrite during live recovery; no success based
only on exit code or model explanation; no infinite retry, recursive healer, or
elapsed-time-only circuit reset; no claim that resume after human intervention was
autonomous healing. The honest terminal state is more important than the recovery
headline.

## 10. Deferrals (explicit, with entry conditions)

- **Second active rule.** v1 promotes at most one; additional rules wait for a follow-up
  round after the first rule has active telemetry.
- **Streaming/physical healing forms** (reconnect connector, quarantine sensor, fail
  over) — entry: P14 stream/effector machinery exists.
- **Automated rule synthesis.** Generated rules stay untrusted candidates; a generator
  that writes rules directly is out of scope (self-modification gate).
- **Delegation beyond P12-S's narrow grant** — entry: measured need + separate design.
- **Durable-circuit generalization** — if P10 lands the supervisor circuit in-memory,
  P12 owns the durable record (contract in §2); entry: P10 slice-3 close records the
  resolution.

## 11. Failure model (C8)

| Situation | Type | D-7 mapping / behavior |
|---|---|---|
| classification abstention | `ClassificationAbstention` (typed result value) | routes `escalated`; never an exception; counted |
| preflight rejection | `PreflightRejection` (typed result value) | escalates with the failed precondition named |
| verification failure | `VerificationFailure` (terminal for the attempt) | → compensate or escalate; never `recovered` |
| circuit open | `CircuitOpen` (terminal) | every call fails typed; observation only |
| compensation failure | `CompensationFailure` (terminal) | opens the circuit; escalation record marks it |
| direct self-promotion/self-edit attempt | propagates as a policy violation | runtime refuses; adversarial test asserts |

All under `Tamoz::Agent::Error`; repairable (value) vs terminal (propagate) follows
invariant 17 exactly as the D-7 merge: planner-repairable inputs become values, policy
violations and integrity breaks propagate.

## 12. Stop / redesign criteria

- Any remediation executes without an accepted plan/review for the original invariant
  (invariants 25–26 violated).
- Any rule/verifier/compensation can be modified by the rule itself, or promotion can be
  self-granted (invariant 34).
- An unknown/policy-denied/corruption/programmer-error failure is ever retried blindly
  (invariant 32/33).
- Verification can be satisfied by the remediation model's own explanation instead of
  the rule-supplied oracle (invariant 33).
- A behavior candidate activates outside a turn-boundary epoch transition, or rollback
  cannot be proven (invariant 28).
- The matrix shows an unsafe/unauthorized/duplicate/false-recovery rate above zero for
  an active claim, or any hard-zero gate trips.

## 13. Definition of done (v1)

- [ ] P12-HD/H1 typed failure contract, five never-mutate classes, abstention→escalated,
      denominators.
- [ ] P12-H2 remediation protocol with preflight, effect identity, §6 forms, §7
      idempotency, oracle-as-configured-check with the independence test.
- [ ] P12-H3 compensation, circuit, escalation records, each condition testable,
      concealment test; circuit seam resolved per §2 (one record type, three scopes).
- [ ] P12-H4 at most one §13 rule promoted through the full lifecycle, or
      observation/shadow-only with disclosure; no-self-promotion adversarial test.
- [ ] P12-ID/I1/I2/I3 one reversible behavior candidate through provenance → eval →
      human gates → BehaviorTransition (P11-W-owned seam) → epoch bump → regression →
      rollback.
- [ ] P12-S only if needed; otherwise documented as not-shipped.
- [ ] Applicable 250-case matrix with the §8 mapping + applicability contract; all
      hard-zero gates zero.
- [ ] Migration test: pre-P12 sessions resume with legacy behavior; absent new fields →
      legacy semantics, never a partial load.
- [ ] **Mandatory** scorecard case `agent.self-healing-...` (handover §7: every new
      capability adds a fixed behavioral case); if the rule ships observation/shadow-only,
      the case proves the observation path and the active claim is disclosed as absent.
- [ ] `rake ci` green under both locales; scorecard (existing 16 cases) unchanged with
      safety counters zero; the new case adds without weakening any hard gate.
- [ ] Trackers updated; deferrals + circuit resolution recorded.
