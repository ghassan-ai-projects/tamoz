# P12 self-healing plan review

Verdict: accept-with-required-corrections (revision 2 integrated C1–C12).
Reviewer: fresh-context plan critic (general-purpose subagent, 2026-08-02).
Scope reviewed: `docs/P12_SELF_HEALING_PLAN.md` revision 1 against
`SELF_HEALING_DESIGN.md`, INVARIANTS.md 25–28/32–34/35, the P12 card, and the
P6/P10 effect/circuit machinery.

## Findings and dispositions

| # | Sev | Section | Finding | Disposition (rev 2) |
|---|---|---|---|---|
| C1 | Critical | §2 | "Existing durable circuit from P6/P10" is false — no durable circuit exists anywhere; P10's supervisor circuit is in-memory and not yet implemented | Circuit seam resolved in DR-2 (one record type, per-owner scopes; P10 re-home contract); P12 references DR-2 as authoritative |
| C2 | Critical | §10/§7 | Invariant-33 oracle independence is a stop criterion, not a mechanism/test | Oracle IS a configured check (digest-pinned in the immutable rule); `recovered` requires the recorded oracle pass; model-narrated recovery with oracle failing/absent → escalated/circuit_open (DoD test) |
| C3 | Critical | — | No migration/compatibility section | Store namespaces for rule/circuit/escalation records; RECORD_VERSION policy; pre-P12 session resume test |
| C4 | High | §7 | BehaviorTransition ownership collides with P11-W | P11-W owns the record + turn-boundary mechanics (DR-1); P12 reuses; candidates divided by provenance; one shared behavior-version record |
| C5 | High | §7 I3 | "Behavior/cache epoch at a turn boundary" not implementable (behavior_version is a static constant; no epoch engine) | Decomposed into (a) dynamically pinned behavior_version, (b) cache epoch via the prompt-surface digest seam, (c) defined turn boundary (DR-1's two-phase model supersedes the inline description) |
| C6 | High | §8 | "Applicable portion" of the 250-case matrix undefined and shrinkable | Fault-class → FailureRecord mapping table; per-cell applicability contract; mandatory cells for the v1 rule |
| C7 | High | §6 | Self-promotion asserted, not designed | Promotion records written only by tamoz-evals, digest-bound, verified at rule load; adversarial self-promotion/reset test |
| C8 | Medium | — | No typed failure classes | Failure-model table added (ClassificationAbstention, PreflightRejection, VerificationFailure, CircuitOpen, CompensationFailure) over the D-7 taxonomy |
| C9 | Medium | §3 | Abstention under-defined | Confidence < minimum → abstention → escalated; denominators; abstention-quality definition; 100% abstention cannot promote |
| C10 | Medium | §3 | "Four never-mutate classes" but five listed | Count corrected to five (policy_denied, durable_state_corrupt, programmer_error, unknown, missing capability) |
| C11 | Low | §6 | Preference order reversed vs the card | Reconciled: either reference rule acceptable, evidence-driven, recorded at close |
| C12 | Low | DoD | Scorecard case optional — contradicts handover §7 | `agent.self-healing-...` case MANDATORY |

## Held-out probes

Budget/authority self-widening (immutability test); concealed compensation failure
(escalation-record completeness cross-checks the compensation receipt digest);
candidate-sees-holdout (capability/root restriction); recovery-by-narration (oracle
independence test).

## Status

Corrections integrated in `docs/P12_SELF_HEALING_PLAN.md` revision 2. The circuit
seam, BehaviorTransition ownership, and epoch mechanics are owned by DR-2/DR-1; the
P12 plan cites them as authoritative.
