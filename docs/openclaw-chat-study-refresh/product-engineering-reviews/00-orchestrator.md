# Product-engineering review orchestrator summary

Date: 2026-08-27

## Execution record

The second-level orchestrator spawned exactly three child reviewers with
disjoint report ownership:

| Lens | Agent | Report | Observed result |
| --- | --- | --- | --- |
| Product usefulness and Tamoz agent vision | 01a04096-bf4f-7353-80b7-59ff74ca01bb | 01-product-agent-vision.md | Materialized; content MEETS BAR WITH GAPS; readiness NEEDS FIXES; 7 unresolved high-severity findings |
| Architecture, security, reliability, and channel boundaries | 01a04097-0b18-7923-bcfc-cbe0c107b485 | 02-architecture-security-reliability.md | Materialized; content MEETS BAR WITH GAPS; readiness NEEDS FIXES; 6 unresolved high-severity findings |
| Implementation and evidence readiness | 01a04097-5933-75b0-9bb4-f0166f5928ac | 03-implementation-evidence.md | Materialized; content MEETS BAR WITH GAPS; readiness NEEDS FIXES; 7 unresolved high-severity findings |

The parent orchestrator failed to materialize its own summary after all child
files existed. It was shut down after bounded correction prompts. This file is
a transparent main-orchestrator reconciliation of the three materialized child
reports. The child reports are the independent review evidence; this summary is
not presented as an independent fourth review.

## Cross-review convergence

All three child reports agree on the following:

1. The clarification/approval collapse is a confirmed production-path defect.
   A clarification descriptor has no decision evidence, yet the worker and sink
   route it through approval semantics.
2. The existing durable model and safety controls are valuable and should be
   extended, not replaced with a second runtime, event bus, narrator, or status
   cache.
3. The default user projection needs state, stable reference, safe current
   action, next action, and delivery certainty. Diagnostics must remain
   explicit.
4. Telegram and durable CLI currently expose divergent handles and control
   semantics. The actual CLI is not exercised by the canonical benchmark leg.
5. Fixture/provider and focused test evidence proves plumbing only. It does not
   prove real Telegram behavior, real-provider answer quality, human
   comprehension, or enjoyment.
6. A future channel should be deferred until Telegram/CLI semantics, identity,
   health, and real evidence gates pass.

## Findings that materially sharpened the package

The architecture child found two high-severity request-truth defects that were
not explicit in the consolidated study:

- CommsStore#conversation_runtime_status accepts a request ID but obtains
  delivery and effect summaries at conversation/thread scope
  (gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:522-529,611-713).
  With two open requests, a request-scoped status can report the other
  request’s delivery/effect state.
- Gateway cancellation is thread-oriented and does not consume a request
  reference
  (gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb:96-121;
  gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:988-994). A two-request
  conversation therefore lacks a proven exact-target cancel contract.

The product child found two additional contract gaps:

- The proposed clarification answer action has no durable comms ingress; plain
  text is currently a new request and the gateway callback path resolves
  approval callbacks only
  (gems/tamoz-comms/lib/tamoz/comms/commands.rb:7-20;
  gems/tamoz-comms/lib/tamoz/comms/admission.rb:36-47,89-121).
- A safe goal label has no deterministic owner or redaction contract; it must
  not be delegated to a model narrator.

The implementation child found that the roadmap needs an explicit dependency
freeze: typed interruption, request-local ownership, reference/health
semantics, and actual CLI evidence must precede any claimable human projection.

## Unresolved high-severity gates

The package is not implementation-ready while any of these remain open:

1. Clarification versus approval projection and same-occurrence answer/resume.
2. Request-local delivery/effect status for multiple open requests.
3. Exact-reference cancellation and redirect targeting.
4. Fail-closed benchmark readiness for required surface, metric, and moment
   cells.
5. Actual CLI subprocess/path parity, including stdout, stderr, exit status, and
   database reopen.
6. Honest worker availability and gateway/worker supervision semantics.
7. Real Telegram/provider receipts plus an independent witness.
8. Durable clarification answer ingress with binding, expiry, replay, and
   wrong-reference rejection.
9. Deterministic safe-goal-label source and redaction rules.

These are corrections to the implementation/evidence bar, not authorization to
weaken the safety model. Unknown delivery, effect journaling, ownership fencing,
policy-bound approval, and confirmed-only history remain hard zeros.

## Required package corrections

Before implementation begins, the main package must:

- add request-local status and exact-target cancel findings to the consolidated
  study, evidence index, correction log, and roadmap;
- reorder the roadmap so Slice 0 includes typed interruption and request/control
  ownership, and the human projection is not claimable until those pass;
- add an explicit clarification command/reply ingress design and tests;
- define worker-health freshness, the queue-versus-refuse decision, and
  rollback/stop behavior;
- keep all real-provider and real-transport claims blocked until artifacts
  include receipts, provenance, and independent trace agreement.

## Final verdict

**Product-engineering content verdict: MEETS BAR WITH GAPS.** The three child
reviews are substantive, evidence-labelled, seam-specific, and aligned on the
smallest safe direction. The parent summary required a transparent fallback
because its orchestrator did not materialize.

**Implementation-readiness verdict: NEEDS FIXES.** The clarification defect,
request-local status aggregation, non-targetable cancellation, missing answer
ingress, roadmap dependency ambiguity, incomplete benchmark admissibility, and
absent real experience evidence prevent a claim that the refresh is ready for
production implementation or that the current agent communicates well.
