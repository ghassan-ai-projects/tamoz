# Planning — measurement plan

**Now:** the plan-review gate is heavily *exercised* — it dominates the coding baseline (28/46
trials aborted before any edit) — but plan *quality* is never graded. No eval scores whether a
plan is good, only whether the reviewer accepted it.

**Unknown:** real plan quality — does the agent produce plans that (a) pass its own review for the
right reasons, and (b) lead to a correct outcome when executed. Today we cannot tell "bad plan"
from "over-strict gate."

**Measure (real model):**
1. Instrument the coding run (stage/transcript, landed) to record: plan drafted → reviewed →
   accepted/rejected → acted → verified. Report a **plan-acceptance rate** and, for accepted
   plans, the **downstream solve rate** — the two together separate a bad planner from a strict
   gate.
2. Add a small planning-quality cell set: tasks with a known-good plan shape; score the agent's
   plan on whether it names the right steps and whether execution succeeds. Controls: null (empty
   plan) must fail; oracle (reference plan) passes.
3. Run real model, `repeat>=2, seeds>=4`, report with intervals.

**Prereq / owner decision:** the coding plan-gate resolution (see [01](01-coding.md), master 0.2).

**Done:** a real plan-acceptance rate AND accepted-plan downstream-success rate with intervals; a
graded planning-quality score with a passing control.
