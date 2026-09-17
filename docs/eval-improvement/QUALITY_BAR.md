# Quality bar — when is the evaluation "useful"?

"Useful" is not a good score. A useful evaluation is one a maintainer can **run on demand,
trust the result of, and act on** — over the agent, not over one of its slices. These are the
pass/fail criteria.

## The bar

1. **Runnable in one command, repeatably.** A documented entry point runs a suite and writes
   a report; the corpus is validated without spending money. The interpreter is pinned by the
   harness, not inherited from `PATH`. No remembered flags.
2. **The scope is the agent, not a slice.** The eval set states which of the canonical axes
   (RESEARCH §2) it covers. A coding-only score is labelled a slice, never "the agent". The
   declared surface with no coverage is listed as a gap, not left implicit.
3. **Trustworthy — every gate hit is diagnosed to agent or harness, with a repro.** An
   undiagnosed red gate means the eval is measuring itself. A diagnosis that is not
   reproducible is a guess.
4. **Reliability, not luck.** Every suite runs with `repeat >= 2`, and the report names the
   *reliable* (pass on every trial) and *flaky* (pass on some) scenarios. One sample does not
   count.
5. **Every trial carries a stage and a cost.** Terminal stage (never acted / rejected at
   plan review / acted and failed / verified) plus turns, tool calls, tokens, and wall clock.
   No capability number is quoted without them. "Never acted" and "wrote wrong code" are
   never the same row.
6. **A current, committed baseline; regression against it.** The baseline is committed with
   its corpus digest; `compare` diffs the newest run against it and exits non-zero on a
   regressed scenario. A run pair with a different model, provider, or corpus digest is
   refused, not silently diffed.
7. **Graders cannot be satisfied by inaction.** A correct-abstention cell requires the agent
   to state the conflict or the absence. Doing nothing — or crashing — is not judgment.
8. **Uncertainty is reported.** Point estimates carry their trial count and spread; small
   deltas are treated as noise, and runs are repeated across times/days before a difference
   is claimed. (Infrastructure alone moved a frontier coding benchmark by 6 points:
   RESEARCH §6.)
9. **Honest about provider and cost.** The report carries model, provider, the
   approvals-auto-granted label, and the run kind. No capability number is quoted without its
   provenance.
10. **No fixture is presented as intelligence evidence** (`documentation/benchmark/README.md`).
    A capability claim comes only from a real-provider run; the scorer itself is versioned or
    digested so a scoring change invalidates comparison.

## Explicitly out of scope

- Chasing a higher score (that is agent work, downstream of an honest signal).
- New mission families or packs before the committed ones are landed and interpretable.
- Externally-witnessed release evidence, which the benchmark protocol governs separately.

## Acceptance

The coding slice passes when bars 1, 3–6, and 9–10 hold: a one-command, `repeat>=2`,
stage-and-cost-carrying, gate-diagnosed, committed baseline run against verified scoring logic,
diffed against that baseline.

The agent passes when bar 2 holds: the declared axes each have either a landed real-provider
measurement or an explicit gap entry — and no coding-only number is presented as the agent's
capability.
