# Correction and orchestration log

Date: 2026-08-27

## Review controls

The main orchestrator created the review bar before delegation. Each delegated
lane had one owned report path, one progress log under /tmp/tamoz-agents, no
production write permission in scope, no commit authority, explicit evidence
labels, and a separate content/readiness verdict. Reports were inspected after
completion; a timeout was treated as incomplete evidence.

## Specialist loop

### Lane A — gap audit

- Initial report: 17 gaps, stale/contradictory claim ledger, four root-cause
  chains, closure observations, priorities, and a NEEDS FIXES verdict.
- Correction requested: separate report completeness from current-system
  readiness and verify the clarification-interrupt path.
- Correction result: report/content bar MEETS BAR; current system/evidence
  readiness NEEDS FIXES. G18 was added as a confirmed production-path defect:
  clarify descriptors reach approval-only decision_evidence and can raise
  before channel delivery.

### Lane B — interaction/product

- Result: MEETS BAR WITH GAPS.
- Strengths: maps first contact through return-after-time-away, provides
  Telegram/CLI message cards, defines a noise budget, measures comprehension,
  trust, recovery, attention, and answer usefulness separately, and maps bets
  to existing seams.
- Remaining gaps are intentionally product/evidence gaps: no real provider,
  real Telegram, or human comprehension run.

### Lane C — chat/Telegram architecture

- First delegated lane synthesized but failed to materialize its owned report
  after bounded waits.
- Replacement lane also failed to materialize after a tighter brief and
  bounded deadline.
- Both stalled lanes were shut down; neither result was treated as evidence.
- The main orchestrator wrote a transparent fallback architecture report from
  verified source evidence and Lane A/B findings. It is marked
  MEETS BAR WITH GAPS, with the independent-agent materialization gap explicit.
- This is the principal process limitation of this refresh and is carried
  forward to the product-engineering challenge round.

## Brainstorming loop

- Facilitator generated 14 options, clustered them, exposed assumptions and
  tensions, challenged the strongest typed-projection option, and converged to
  five ordered bets. Content bar MEETS BAR; current readiness NEEDS FIXES.
- Fourier covered turn, conversation, work session, operator, channel,
  organization, and long-term measurement scales. It identified frequency
  aliasing, resend/notification feedback loops, worker-health silence, and
  proxy-readiness failure. Content bar MEETS BAR; current readiness NEEDS FIXES.
- Both reports rejected a new channel before the shared interaction contract
  and real evidence gates pass.

## What worked

- Disjoint report paths avoided file contention.
- Front-loaded bars kept specialist outputs evidence-labelled and prevented
  fixture tests from being described as intelligence.
- Lane A’s explicit verdict correction prevented a strong audit from being
  misread as a claim that the current product is ready.
- The completed reports converged independently on interruption typing,
  worker-health truth, portable references, bounded human cards, and
  admissibility-first evidence.
- Pinned Ruby was used for focused tests, avoiding false failures from the
  system Ruby mismatch.

## What did not work and the optimization

- Broad architecture briefs led to two non-materializing agents. The response
  was to cap scope, require early materialization, and then take a transparent
  fallback rather than waiting indefinitely.
- The system Ruby is 2.6.10 although .ruby-version pins 3.3.11. This produced
  misleading syntax failures until the pinned executable was used.
- Existing study metadata is stale in places: implementation-plan prose says
  implementation has not started while current code exists; benchmark scenario
  prose, index, and runner readiness disagree. The refresh treats this as a
  measurement-governance defect and makes reconciliation a P0.
- The current repository has no live Telegram/provider credentialed evidence
  in scope. The refresh therefore defines the gate and does not fabricate a
  run.

## Monitoring observation

The orchestration was checked in bounded intervals using agent completion
status, owned-file existence, and progress-log tails. A lack of progress was
not interpreted as success. The same principle is a product finding: a human
should not have to infer whether Tamoz is alive from silence.

## Product-engineering review loop

The second-level orchestrator spawned three child reviewers with disjoint
ownership. All three child reports materialized and were independently
inspected:

- Product/agent vision: product-engineering-reviews/01-product-agent-vision.md
  — content MEETS BAR WITH GAPS; readiness NEEDS FIXES; seven unresolved
  high-severity findings.
- Architecture/security/reliability:
  product-engineering-reviews/02-architecture-security-reliability.md —
  content MEETS BAR WITH GAPS; readiness NEEDS FIXES; six unresolved
  high-severity findings.
- Implementation/evidence:
  product-engineering-reviews/03-implementation-evidence.md — content MEETS
  BAR WITH GAPS; readiness NEEDS FIXES; seven unresolved high-severity
  findings.

The parent orchestrator did not materialize its summary after the children
completed. It was shut down after bounded correction prompts; the
main-orchestrator fallback is
product-engineering-reviews/00-orchestrator.md. The fallback explicitly
preserves the child reports as the independent evidence and records the parent
materialization failure.

The review loop added four corrections to the package:

1. request-local status must not aggregate delivery/effect state across open
   requests;
2. cancellation must consume an exact request reference rather than canceling
   a whole thread;
3. clarification requires a durable comms answer ingress with expiry,
   occurrence, caller, and replay binding;
4. the roadmap must freeze ownership/handles/health before claimable human
   projection, and a safe goal label needs a deterministic owner/redaction
   contract.

Final product-engineering conclusion: content is sufficient for bounded
implementation planning, but implementation readiness remains NEEDS FIXES.

## Final package verification

- git diff --check passed.
- test/documentation_tree_test.rb passed with 7 runs and 1089 assertions.
- test/documentation_surface_test.rb passed with 9 runs and 95 assertions.
- test/documentation_test.rb remains red on unrelated baseline conditions:
  the repository currently exposes ADRs 001–048 while the test expects 001–047,
  and an older gem-boundary audit contains a broken link to
  gems/tamoz-agent/lib/tamoz/agent/ruby_llm_model.rb. No unrelated baseline
  files were changed.
- Focused product/comms plumbing tests used by the reports passed under the
  pinned Ruby executable; those results remain plumbing evidence only.
