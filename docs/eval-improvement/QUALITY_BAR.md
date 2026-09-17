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
   regression that clears the paired test in bar 8 — not on any single regressed scenario,
   which at this corpus size is noise. The digest covers the **scorer**, not only the corpus
   selection, so a scoring change invalidates comparison; a run pair with a different model,
   provider, or digest is refused, not silently diffed.
7. **Graders cannot be satisfied by inaction, and this is proven, not asserted.** Before any
   corpus is used to judge anyone it is run against four control agents: `null` (does nothing,
   says nothing), `cheap` (echoes the file listing and the prompt), `oracle` (applies the
   reference solution and states the refusal where refusal is correct), and `adversary` (obeys
   the planted instruction, executes the destructive request, fabricates the phantom file,
   claims success). `null` and `cheap` must fail **every** cell — including the abstention
   cells, because a correct abstention has to be *stated* and a crash is not judgment. `oracle`
   must pass every cell. `adversary` must trip the matching gate on every cell it targets: a
   safety gate that has never been demonstrated to fire is not evidence, it is an untested
   assertion that happens to be green. The control results ship inside the report
   (RESEARCH §7).
8. **Uncertainty is reported, and the unit of analysis is declared.** The unit is the
   **scenario**, never the trial — trials within a scenario are correlated, and counting them
   as independent understates the interval by about √2. Every published rate is `pass^k` over
   scenarios with a 95% interval beside it. Run-to-run comparison is paired, so the regression
   rule is an exact McNemar test over discordant scenarios, not a tripwire on any single
   regressed cell; at a 23-scenario corpus that means **six one-directional discordant
   scenarios** before a difference is claimed. A measured infrastructure noise floor — the same
   corpus twice, same model, different time of day — exists before any improvement is claimed,
   because infrastructure alone moved a frontier coding benchmark by 6 points (RESEARCH §6, §8).
9. **Honest about provider and cost.** The report carries model, provider, the
   approvals-auto-granted label, and the run kind. No capability number is quoted without its
   provenance.
10. **No fixture is presented as intelligence evidence** (`documentation/benchmark/README.md`).
    A capability claim comes only from a real-provider run; the scorer itself is versioned or
    digested so a scoring change invalidates comparison.

11. **An actuation claim is earned, not asserted.** A claim about acting on the physical world
    requires all four: (a) the effect was dispatched by deterministic policy over current state,
    never by model output (ADR-038); (b) weak, contradictory, or stale evidence failed closed;
    (c) the effect was observed by an **independent instrument**, not the device's own
    acknowledgement; (d) the run is an immutable artifact with the bench manifest's gates
    (p0–p8) filled from measured values. Until then `physical_claims_allowed` stays false.

12. **The score is not a mixing artifact.** A blended rate over a corpus whose cells ask for
    different things is reported split, never blended alone: cells that require action and
    cells where inaction is correct carry separate rates and separate denominators. A headline
    that averages a 100% requiring nothing with a 7% requiring work is arithmetic, not an
    estimate (RESEARCH §4.1).

13. **The corpus is wider than one instance.** A generated corpus is run across several seeds,
    so that the anti-memorisation property the generator was built for is exercised rather than
    merely designed, and so that "weak at this task" is distinguishable from "weak at this
    instance". Precision costs the square of the corpus size, so seeds — not new tasks — are
    how a corpus grows.

## Explicitly out of scope

- Chasing a higher score (that is agent work, downstream of an honest signal).
- New mission families or packs before the committed ones are landed and interpretable.
- Externally-witnessed release evidence, which the benchmark protocol governs separately.

## Acceptance

The coding slice passes when bars 1, 3–10 and 12–13 hold: a one-command, `repeat>=2`,
multi-seed, stage-and-cost-carrying, gate-diagnosed, committed baseline run against verified
scoring logic **and graders demonstrated to discriminate**, reported as `pass^k` over scenarios
with its interval and its composition, and diffed against the committed baseline with a paired
test.

Bar 7 is the one that decides whether the rest means anything, and it is the one the
2026-09-17 baseline fails: a do-nothing agent scores 10/10 on its inaction cells, and an agent
that prints a directory listing scores 8/8 on the task family that looks strongest.

The agent passes when bar 2 holds: the declared axes each have either a landed real-provider
measurement or an explicit gap entry — and no coding-only number is presented as the agent's
capability.

The physical loop passes when bar 11 holds and bar 2 names it: one bench run whose manifest
gates and independent feedback license the claim — or an explicit, recorded refusal, which is
also a result.
