# OpenClaw/Tamoz chat experience refresh

Status: review package complete; implementation readiness NEEDS FIXES.

This package reopens the earlier [OpenClaw communication study](../openclaw-chat-study/)
because the durable lifecycle improvements are not yet producing a sufficiently
interactive, enjoyable, and productive agent conversation. It reviews the
current code and evidence on the refresh branch; it does not assume that the
earlier study's completion label means perceived quality is proven.

Read in this order:

1. [00-review-bar.md](00-review-bar.md) — evidence and completion bar.
2. [specialist-reviews/01-gap-audit.md](specialist-reviews/01-gap-audit.md) —
   stale claims, benchmark gaps, and the confirmed clarification projection
   defect.
3. [specialist-reviews/02-interaction-product.md](specialist-reviews/02-interaction-product.md)
   — human journeys, message cards, noise budget, and usefulness measures.
4. [specialist-reviews/03-chat-telegram-architecture.md](specialist-reviews/03-chat-telegram-architecture.md)
   — durable seam map, channel-neutral contract, capability matrix, and new
   channel decision.
5. [brainstorming/01-facilitator.md](brainstorming/01-facilitator.md) —
   divergent options, tensions, and converged bets.
6. [brainstorming/02-fourier.md](brainstorming/02-fourier.md) — multi-scale and
   feedback-loop challenge.
7. [product-engineering-reviews/00-orchestrator.md](product-engineering-reviews/00-orchestrator.md)
   — cross-review reconciliation and readiness verdict.
8. [product-engineering-reviews/01-product-agent-vision.md](product-engineering-reviews/01-product-agent-vision.md)
   — usefulness and Tamoz agent-vision review.
9. [product-engineering-reviews/02-architecture-security-reliability.md](product-engineering-reviews/02-architecture-security-reliability.md)
   — security, reliability, and channel-boundary review.
10. [product-engineering-reviews/03-implementation-evidence.md](product-engineering-reviews/03-implementation-evidence.md)
    — implementation and evidence-readiness review.
11. [01-consolidated-study.md](01-consolidated-study.md) — findings, target
   interaction model, and decisions.
12. [02-decision-roadmap.md](02-decision-roadmap.md) — bounded implementation
   slices, tests, metrics, and gates.
13. [03-evidence-index.md](03-evidence-index.md) — claim-to-source and
    evidence-state index.
14. [04-correction-log.md](04-correction-log.md) — review findings,
    corrections, orchestration observations, and unresolved gaps.
15. [05-open-findings-ledger.md](05-open-findings-ledger.md) — every reviewer
    finding normalized into one de-duplicated, verification-labelled set with
    an owner seam and target slice; the authoritative implementation to-do.
16. [implementation-plan/](implementation-plan/) — the phased implementation
    plan built from the ledger, its acceptance bar, and the multi-lens review
    loop that iterated the plan until it met the bar:
    [00-plan-bar.md](implementation-plan/00-plan-bar.md),
    [01-plan.md](implementation-plan/01-plan.md),
    [02-plan-review-log.md](implementation-plan/02-plan-review-log.md).

The package is concrete enough to drive bounded implementation slices, but the
current product/evidence verdict remains NEEDS FIXES. A deterministic fixture
proves plumbing and safety invariants; it does not prove that a real model
communicates well. Real Telegram, real-provider, and human-comprehension
evidence remain separate gates.
