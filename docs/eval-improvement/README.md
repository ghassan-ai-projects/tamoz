# Eval improvement — making the capability eval useful

Date: 2026-09-17

This folder plans and tracks making Tamoz's **capability evaluation** (`agenteval/`) a useful,
recurring, trustworthy measurement rather than a stale one-off.

- [`RESEARCH.md`](RESEARCH.md) — what exists today and where it falls short.
- [`QUALITY_BAR.md`](QUALITY_BAR.md) — what "useful" means, as pass/fail criteria.
- [`PLAN.md`](PLAN.md) — the work, scoped and sequenced, with a research plan the live run answers.

## Running (cadence)

```bash
bundle exec rake agenteval:validate   # prove the corpus (deterministic, no model calls)
export DEEPSEEK_API_KEY=...            # or leave it in .env; the adapter falls back to it
bundle exec rake agenteval:run         # run today's agent; writes agenteval/reports/run-<date>.json
bundle exec rake agenteval:compare     # diff the two newest reports; non-zero on any regression
```

`agenteval:run` overrides via env: `AGENTEVAL_MODIFIERS` (default `all`), `AGENTEVAL_REPEAT`
(default `2`), `AGENTEVAL_BUDGET` seconds (default `240`).

Note: `agenteval/` is git-ignored (a local tool tree), so committed baselines and findings for the
record live here under `docs/eval-improvement/`, not under `agenteval/reports/`.
