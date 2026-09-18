# Decision capabilities — measurement plan

**Now:** graded eval + property specs — `stream_decision_builder_test`, `thermal_lab_decision_test`
(governance guarantees: risk is the catalog's, ceiling never escalates, off-catalog fails closed),
the thermal tournament (baseline vs supervisor vs null/adversary controls), and the pending-gap
evidence-fitness family. All fixture-driven.

**Unknown:** real supervisory judgment — with a real model proposing, does the governed decision
beat the fixed-threshold baseline on the conflict cells, and how much regret does it carry.

**Measure (real model):**
1. Run the thermal shadow tournament (WP-T3) with real DeepSeek in place of the fixture proposal —
   the governed decision still comes through the real graph; only the proposer changes.
2. Report the paired comparison (supervisor vs baseline, and vs the null/adversary controls) with
   a cluster-bootstrap interval; report abstention-quality and counterfactual-regret.
3. Go-rule: never worse on the clear cells + at least one conflict win clearing the minimum
   effect; re-run rather than tuning the scorer to the result.

**Prereqs:** real provider in the tournament harness (no hardware). Corpus is balanced (G2 done),
though acting cells sit in one family (O4) — widen if the interval is too soft.

**Done:** a real paired-comparison result with an interval and the regret numbers; the O1
evidence-fitness gaps either closed (design) or recorded as accepted.
