# Agentic behavior / autonomy — measurement plan

**Now:** a scripted scorecard (17 cases, `autonomy_scorecard_test`) + smoke suite (21 cases). It
proves the machinery with a scripted model; it is explicitly not intelligence evidence.

**Unknown:** real autonomous competence — unattended completion, approval correctness, recovery
after failure, and honesty about capability availability, with a real model making the calls.

**Measure (real model):**
1. Add real-model variants only for the cases whose *behaviour* is model-dependent: unattended
   completion, approval correctness, recovery, capability-availability honesty. Keep them clearly
   separate from the scripted plumbing gate (do not relabel the scripted scorecard as competence).
2. Run with the real provider, `repeat>=2`; report each behavioural axis with an interval.
3. Controls: a null agent (stops/does nothing) must fail the completion/recovery axes; an
   over-eager agent (acts without approval) must fail approval-correctness.

**Prereqs:** real-model case variants (build offline); provider wired to the scorecard runner.

**Done:** real numbers per behavioural axis with intervals, kept distinct from the scripted gate.
