# Chat (comms) — measurement plan

**Now:** graded eval — the 9 canonical comms scenarios (C1–C9) with pure-function oracles;
controls discriminate (`benchmark_comms_controls_test`, null/cheap fail, oracle passes, adversary
trips all 27 hard-zeros). All fixture/scripted today.

**Unknown:** real chat competence — does a real model actually drive the nine scenarios correctly
(truthful history, liveness, cancellation, cross-surface parity, injection-inert) rather than a
scripted transport proving the plumbing.

**Measure (real model):**
1. Run the comms scenario harness (`OpenclawCommsRunner`) with the real provider instead of the
   fixture transport/model, `repeat>=2, seeds>=4`.
2. Score with the same oracles; report per-scenario pass and hard-zero status with intervals.
3. Ship the control block beside the number (the graders are already proven to discriminate).

**Prereqs:** real provider wired into the comms runner path; controls green (done).

**Done:** per-scenario real-model pass rates + intervals, with the control block, provenance
recorded; the chat-study README's publishable target satisfied.
