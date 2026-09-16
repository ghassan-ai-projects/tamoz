# Quality bar — when is the capability eval "useful"?

"Useful" is not a good score. A useful eval is one a maintainer can **run on demand, trust the
result of, and act on**. These are the pass/fail criteria for this work.

## The bar

1. **Runnable in one command, repeatably.** A single documented entry point runs the corpus and
   writes a report; a second validates the corpus without spending money. No remembering flags.
2. **Trustworthy — every gate hit is diagnosed.** A `false_success`, `unsafe`, or `harness_error`
   in the current baseline is traced to *agent* or *harness* and written down. An undiagnosed red
   gate is a bar failure, because the eval is then measuring itself, not the agent.
3. **Reliability, not luck.** The baseline is run with `repeat >= 2`, and the report distinguishes
   *reliable* (pass on every trial) from *flaky* (pass on some). A one-sample score does not count.
4. **A current, committed baseline.** `agenteval/reports/baseline-<date>.json` reflects today's
   agent, with its corpus digest, and is committed so the next run has something to diff against.
5. **Regression is detectable.** `agenteval compare OLD NEW` is wired into the cadence and exits
   non-zero on any regressed scenario; the corpus digest guards against comparing unlike runs.
6. **Honest about cost and provider.** The report keeps the approvals-auto-granted label, the model
   and provider, and the wall-clock/turn cost — no capability number is quoted without them.
7. **No fixture is presented as intelligence evidence** (`documentation/benchmark/README.md`); a
   capability claim comes only from a real-provider run recorded with its provenance.

## Explicitly out of scope for this pass

- Chasing a *higher* solve rate (that is agent work, downstream of a trustworthy signal).
- New task packs, languages, or difficulty sweeps (coverage expansion is a follow-up once the
  cadence and a trusted baseline exist).
- Externally-witnessed release evidence (the benchmark protocol governs that separately).

## Acceptance

The pass condition for this work is bars 1–6 met: a one-command, `repeat>=2`, gate-diagnosed,
committed baseline against today's agent, with a wired regression compare — plus the research
questions in [`RESEARCH.md`](RESEARCH.md) answered from that run.
