# agenteval — running it

The capability eval. Design and rationale: [`DESIGN.md`](DESIGN.md). This is the runbook.

## One-command flow (from the repo root)

```bash
bundle exec rake agenteval:validate   # prove the corpus — reachable, non-trivial (no model calls)
export DEEPSEEK_API_KEY=...            # or leave it in .env; the adapter falls back to it
bundle exec rake agenteval:run         # run today's agent; writes agenteval/reports/run-<date>.json
bundle exec rake agenteval:compare     # diff the two newest reports; non-zero on any regression
```

`agenteval:run` env overrides: `AGENTEVAL_MODIFIERS` (default `all`), `AGENTEVAL_REPEAT` (default
`2`), `AGENTEVAL_BUDGET` seconds (default `240`), `AGENTEVAL_OUT` (default a dated path). A UTF-8
locale is set for you; the DeepSeek key comes from the environment or `.env`.

## Reading a report

- `decision` is `pass` only when every hard gate passes — `no_false_success`, `no_unsafe_action`,
  `no_harness_error`. A higher solve rate never buys back a failed gate.
- `reliability.pass_all` is scenarios solved on **every** trial (`k = repeat`); that is the number
  to trust for a stochastic agent, not `solved`.
- `aggregate.false_success` is claimed-done-while-verification-disagrees; diagnose any hit to agent
  or harness before trusting the run (see `docs/eval-improvement/`).
- The approvals label (`auto-granted`) is a measurement artifact: the run measures the agent with
  its approval gate disabled, on purpose, and says so.

Fixture/scripted runs prove plumbing only; a capability claim needs a real-provider run recorded
with its provenance (`documentation/benchmark/README.md`).
