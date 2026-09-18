# agenteval — running it

The capability eval. Design and rationale: [`DESIGN.md`](DESIGN.md). This is the runbook.

## Prove the instrument before spending money

Nothing is measured until the graders are known to discriminate. This gate is offline,
deterministic, and free, and `agenteval:run` depends on it:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"

bundle exec rake agenteval:prove   # tests + controls + corpus validation, no model calls
```

It runs three things, each of which has caught a real defect:

| Stage | What it proves |
|---|---|
| `agenteval:test` | the grader properties the reviews demanded stay true |
| `agenteval:controls` | five synthetic agents (null, cheap, parrot, oracle, adversary) run through the real judge; a disagreement is a scoring bug |
| `agenteval:validate` | every scenario is reachable, non-trivial, and not satisfiable by an echo |

`ruby docs/eval-improvement/repro/verify_defects.rb` reproduces the framework defects from the
review offline. It exits non-zero once they are all fixed. Keep it: it caught a defect that the
control suite, the validator, and the unit tests all missed.

## Run

```bash
export DEEPSEEK_API_KEY=...            # or leave it in .env; the adapter falls back to it
bundle exec rake agenteval:run         # writes agenteval/reports/run-<date>.json
bundle exec rake agenteval:compare     # newest run against the committed baseline
bundle exec rake agenteval:baseline    # promote the newest run to the committed baseline
```

`agenteval:run` env overrides: `AGENTEVAL_MODIFIERS` (default `all`), `AGENTEVAL_REPEAT` (default
`2`), `AGENTEVAL_SEEDS` (default `1`), `AGENTEVAL_BUDGET` seconds (default `240`), `AGENTEVAL_OUT`
(default a dated path). A UTF-8 locale is set for you.

Trials write to `agenteval/sessions/`, never to your live session store.

## Reading a report

**Read the floor first.** `do_nothing_ceiling` is how much of this corpus an agent that does
nothing wins — on the committed corpus, 0 of 18 acting cells and all 6 inaction cells. A headline
rate means nothing without that split; the summary prints them together.

- `decision` is `pass` only when every gate passes. A higher solve rate never buys back a gate —
  including `graders_discriminate`, which fails when the controls did not run or disagreed.
- The headline is `pass^k` over **scenarios** with its 95% interval (`interval`), never a trial
  count: trials within a scenario are correlated, and counting them as independent understates
  the interval by about √2.
- `by_stage` says where trials ended — `plan_rejected`, `never_acted`, `timed_out`,
  `acted_unverified`, `acted_verified` — and `acted_rate` is the fraction that changed anything.
  "Never acted" and "acted and wrote the wrong code" are different findings.
- `composition` splits acting from inaction cells. A blended rate across them is arithmetic, not
  an estimate.
- `cost` carries tool calls, approvals requested, and duration percentiles.
- `aggregate.false_success` is claimed-done-while-verification-disagrees. `unsafe` includes
  injection captures, which is a recorded fact about what the trial did rather than a status.
- The approvals label (`auto-granted`) is a measurement artifact: the run measures the agent with
  its approval gate disabled, on purpose, and says so.

`compare` refuses a pair whose corpus digest or model/provider differs, and exits non-zero on a
regression that clears the exact McNemar test — or on any newly-added failing scenario. A split
smaller than six one-directional discordant scenarios is noise at this corpus size and is
reported as such.

Fixture/scripted runs prove plumbing only; a capability claim needs a real-provider run recorded
with its provenance (`documentation/benchmark/README.md`).
