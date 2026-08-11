# UX & Latency Investigation — tamoz

Staff+-level investigation into five symptoms:

1. Simple conversations are slower than they should be.
2. Complex tasks frequently fail to finish.
3. Complex tasks are not consistently decomposed, planned, tracked, and verified.
4. The Telegram experience feels slow or unsmooth.
5. Users receive insufficient acknowledgement, progress, recovery, or completion feedback.

## Method

Investigation-only loop (no code changes were made). Per iteration: pick one user
journey, state the expected experience, trace the full lifecycle in code, confirm
claims with runtime evidence where possible, classify the request path, run
Five Whys to a controllable cause, and record findings with severity / frequency /
confidence. Every conclusion is labeled:

- **[measured]** — observed at runtime with a live model, or counted in committed artifacts.
- **[supported]** — directly evidenced in source code / tests (file:line cited), behavior certain.
- **[hypothesis]** — plausible, not yet falsified.

## Evidence sources

- Live CLI runs against DeepSeek (`deepseek-chat`), 2026-08-11, raw logs in `tmp/ux-probe/`
  (`run1.jsonl`, `run2.out`, `run3.jsonl`, `run4.out`, `run5.jsonl`, `*.time`).
- Committed evaluation artifacts: `docs/autonomy-scorecard.json`, `docs/benchmark.json`,
  `agenteval/reports/baseline-20260805.json`.
- Source traces over `gems/tamoz-agent`, `gems/tamoz-comms`, `gems/tamoz-telegram`,
  `gems/tamoz-sqlite`, `gems/tamoz-observability` (file:line citations inline).

## Iterations

| # | Journey | Report |
|---|---|---|
| 1 | Simple CLI conversation | [iteration-01-simple-cli-chat.md](iteration-01-simple-cli-chat.md) |
| 2 | Simple Telegram message | [iteration-02-telegram-message.md](iteration-02-telegram-message.md) |
| 3 | Complex multi-step task (completion failure) | [iteration-03-complex-task-completion.md](iteration-03-complex-task-completion.md) |
| 4 | Runtime latency experiments (live model) | [iteration-04-live-latency-runs.md](iteration-04-live-latency-runs.md) |

Final implementation plan: [FINAL_PLAN.md](FINAL_PLAN.md)

Code-level review and corrections: [PLAN_REVIEW.md](PLAN_REVIEW.md)
