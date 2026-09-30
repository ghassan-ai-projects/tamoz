# Tamoz ADR review — 2026-09-29

## Current conclusion

**All 55 ADRs have been reviewed. The corpus is not yet trustworthy as a current architectural decision record.** Many core boundaries are sound, but the documents mix accepted intent, historical implementation, present behavior, and unproven guarantees. The next pass must repair decision reasoning and evidence, not just fill missing template sections.

Round 2 builds on the five first-round reports. It adds decision-quality, product-fit, packaging economics, reliability, scalability, operations, evolution, privacy, and evidence/governance analysis. These lenses were applied by one primary reviewer; this round is **not an independent multi-reviewer sign-off**.

The canonical ADRs and runtime were left unchanged during this review. The documents updated here are the review reports, synthesis, all-ADR disposition, evidence record, and repair program. Current policy was inspected, not changed or re-ratified.

## Read round 2 first

| Document | Purpose |
|---|---|
| [round-2-disposition.md](./round-2-disposition.md) | One linked row for every ADR: priority, keep/reconcile/reopen disposition, and required repair |
| [review-6-decision-quality.md](./review-6-decision-quality.md) | Credible alternatives, package granularity, repository/language choices, proportionality, memory, evaluation, and maintenance cost |
| [review-7-operations-evolution.md](./review-7-operations-evolution.md) | Approval risk, journal loss, durability assumptions, scaling envelope, reconciliation, containment, supply chain, upgrades, and stop semantics |
| [round-2-evidence.md](./round-2-evidence.md) | Evidence levels, executed checks, governance/tooling gaps, and corrections to round-1 conclusions |
| [round-2-repair-plan.md](./round-2-repair-plan.md) | Ordered repair waves, root-cause analysis, acceptance conditions, and delivery gates |

## Highest-priority conclusions

1. **Approval documents misstate current authority.** ADR-049 records an owner-authorized chat-bound approval change but still promises deny-only behavior and zero residual approval risk; ADR-043 carries obsolete zero-grant constraints. The inspected base policy uses a document-level `chat_bound` requirement for asked actions. Repair the current risk argument and its consumers; do not automatically revert the owner's policy.
2. **ADR-047 promises more than the journal guarantees.** “Records everything” and loss-free paused turns conflict with inspected drop/rotation paths and passing tests. No intentional sampling, counted ingestion loss, bounded retention, and reconstruction from durable records are separate properties.
3. **Green ADR tooling does not establish the declared quality bar.** Existing checks pass despite the contradictions. The lifecycle overstates their scope; status/retirement conventions diverge from the validator, and duplicate detection occurs after hash indexing discards collisions.
4. **Some architectural choices have weak option analysis.** ADR-052 mandates a new gem per concern without comparing enforced internal modules. ADR-055 conflates language/repository choice with authority isolation and overstates a real-time rationale. Closed transport/exporter lists need a credible versioned-adapter comparison. Reopen the arguments without assuming the implementation must change.
5. **Verification often proves existence rather than enforcement.** A gem, symbol, fan-in count, or dated audit does not prove every action path, redaction surface, promotion gate, or current cross-repo contract. Strong claims need scoped, adversarial evidence and explicit limitations.

The existing effect-ambiguity, fenced-writer, exact-plan, authorization-before-retrieval, authority-intersection, and external-control rules remain valuable. The review proposes stronger arguments and evidence around them, not their wholesale replacement.

## What round 2 corrected

- `ModelClientFactory` exists in `tamoz-agent-kernel`; withdraw the original missing-symbol suspicion.
- Proposed ADR-050 does not make clause 62 an accepted invariant; retain the active count of 61 until ratified.
- Missing cancellation/domain-data ADRs are important documentation gaps, not demonstrated catastrophic runtime failures.
- General relates-to dependencies need not all be reciprocal; replacement/amendment chains do.
- Rejection-table counts and full-page structure do not establish option quality or safety adequacy.
- Original arithmetic and broad “no contradiction”/“all verification holds” summaries are superseded by the claim-level adjudication and complete disposition matrix.

## Verification and limits

The catalog check, ADR validator, and citation verifier passed. Six test files passed: **76 runs, 2,031 assertions, zero failures/errors/skips**. They cover selected approval, observability, codec, prose-consistency, and documentation scenarios. No real model was called, and these tests do not establish agent intelligence or complete safety coverage.

All ADR text was read; implementation inspection was targeted. No full runtime gate, capacity benchmark, cross-repository audit, or production acceptance exercise was run. The corpus is **reviewed**, not **repaired or accepted-quality**. Exact commands and limitations are in [round-2-evidence.md](./round-2-evidence.md).

## First-round reports retained

These reports describe the first review's observations and its reported independent lenses. Their stronger conclusions must be read with the round-2 corrections; do not aggregate their overlapping severity totals.

| Report | Original lens |
|---|---|
| [review-1-code-truth.md](./review-1-code-truth.md) | Currency and verification |
| [review-2-consistency.md](./review-2-consistency.md) | Consistency and supersession |
| [review-3-safety-authority.md](./review-3-safety-authority.md) | Safety and authority |
| [review-4-simplicity-size.md](./review-4-simplicity-size.md) | Simplicity and size |
| [review-5-clarity-completeness.md](./review-5-clarity-completeness.md) | Clarity and completeness |
