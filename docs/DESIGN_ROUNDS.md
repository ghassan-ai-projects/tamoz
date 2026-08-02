# Design rounds registry

Status: active
Purpose: cross-cutting machinery that more than one phase consumes, or framework
surgery that needs its own design-review cycle, gets a dedicated design round (DR).
A DR produces `docs/DR<n>_<TOPIC>_PLAN.md` + `docs/reviews/DR<n>_<TOPIC>_PLAN_REVIEW.md`
and is committed as a design checkpoint before any consuming phase implements against it.

Source-of-truth order (unchanged): design-v0.1 > phase card > DR > handover plan >
roadmap. A DR may amend a phase plan only in the direction the phase card allows.

| DR | Topic | Origin findings | Consumed by | Status |
|---|---|---|---|---|
| DR-1 | BehaviorTransition + behavior/cache epoch (shared promotion machinery) | P11 plan review C3; P12 plan review C4/C5; deep review REJECTED rev1; re-review ACCEPT-WITH-CORRECTIONS on rev2 | P11-W, P12-I, P16 | **rev3 accepted** — two-phase model, version allocation by CAS, release-ordered-against-finalize, bounded snapshot; P11/P12 synced |
| DR-2 | Durable circuit record (one type, per-owner scopes) | P12 plan review C1; P13 plan review C6; deep review verified: no durable circuit exists | P10 supervisor (in flight), P12-H3, P13-E, P17 | **rev2 accepted** — atomic CAS predicate, per-owner counters, window/rate sub-state, reset(evidence:), CircuitStore seam |
| DR-3 | Memory evaluation substrate (treatment harness) | P11 plan review C2; deep review: CI "attributable reuse" was a scripted tautology | P11-ED/P11-E, P15-F | **rev2 accepted** — decisive metric split (CI = injection correctness, live = attribution); per-cell stores; mandatory expected_delta |
| DR-4 | Stale durable-request framework fix (D-6 + `:retry`) | gauntlet ledger §5.2/§5.7 | P7/P8/P9 runtime, P15-B | **rev2 accepted** — claim-time validation in the claim transaction, StaleRequestError subclass, shared predicate, recover-path coverage |
| DR-5 | P8 §5.3/§5.4 profile machinery completion | gauntlet ledger §5.8; deep review REJECTED rev1 (premises stale — consumption shipped); re-review ACCEPT-WITH-CORRECTIONS on rev2 | P8-F round, P15-B | **rev3 accepted** — post-override profile_roles, flocked consumption recording, credential-ref-name fix, legacy-id reservation |

## Phase-card mapping for the new phases

| Phase | Topic | Source question | Depends on | Status |
|---|---|---|---|---|
| P16 | Tools gem extraction (`tamoz-tools`; D-7 taxonomy to `tamoz-core`) | Q1 (extract tools to a gem?) | P10 close (MCP integration settled), DR-1 | pending |
| P17 | Websearch capability + egress policy (governed, no raw fetch) | Q2 (websearch for the agent?) | P10 close (MCP capability plane), DR-2 (circuit for egress health), P16 descriptor shape | pending |
| P18 | Capability host unification + graph surface audit | Q3 (graph gem usage; growing toolbox special-casing) | P16, P17, P11–P14 close | pending |

Constraint in force for every DR and phase: design and review only until the owning
phase activates; no implementation begins before its design checkpoint is committed and
its phase card is active.
