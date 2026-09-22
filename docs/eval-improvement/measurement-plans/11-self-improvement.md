# Self-improvement (ADR-023) — measurement plan

**Now:** pipeline + lifecycle tests + discrimination controls (`heuristic_promotion_controls_test`:
overfit rejected on holdout, forged report → tamper, self-promoter rejected, ungated refused,
rollback byte-identical). Fixture only. Recorded finding **O3**: the holdout bar is "no
regression", not "improvement" — a neutral-holdout candidate still promotes.

**Unknown:** does self-improvement actually make the agent better — do the heuristics it generates
from real trajectories improve real behaviour on a **distinct holdout**, and does rollback restore
cleanly when they don't (C7).

**Measure (real model):**
1. Generate candidates from real agent trajectories (real model).
2. Evaluate each on a distinct holdout corpus (never the development set); promote only past the
   gate; measure the **holdout improvement delta** with an interval.
3. Measure rollback: after a promotion that regresses on later telemetry, roll back and confirm
   behaviour returns to the prior epoch — measured, not asserted.
4. Decide O3: require a positive holdout margin, or record acceptance of "no regression".

**Prereqs:** a real-trajectory source + a held-out eval corpus; real provider; the promotion
controls (done) guard the gate throughout.

**Done:** a real holdout-improvement delta + interval, a measured rollback, and O3 resolved
(tightened or accepted) — i.e. evidence that self-improvement improves, not just that it is gated.
