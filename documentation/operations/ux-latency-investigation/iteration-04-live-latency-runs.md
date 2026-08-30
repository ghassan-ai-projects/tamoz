# Iteration 4 — Live latency runs & observability gaps

## What was run

All runs: live DeepSeek (`deepseek-chat`), 2026-08-11, `tmp/ux-probe/`
(workspace: `sample.txt`, `calc.rb`, `notes.md`). No tests were run; these are
the agent itself via the public CLI.

| Run | Input | Mode | Wall time | Model calls | Outcome |
|---|---|---|---|---|---|
| 1 | "What is the capital of France? Answer in one word." | one-shot, `--json` | **16.35 s** | 7 (3 plan + 3 semantic review + 1 verify) | exit 0, correct |
| 2 | same question | one-shot, human | **9.63 s** | ≥5 (attempt 1 lost to `Review (protocol): revise`, attempt 2 semantic revise, attempt 3 accept) | exit 0, correct |
| 3 | "List the files in this workspace and tell me what sample.txt contains." | one-shot, `--json` | **5.10 s** | 3 (plan/review/verify) + 2 tool calls | exit 0, correct |
| 4 | "What is 2+2? Answer with just the number." | durable `ask` | **6.87 s** | ≥3 (human mode; full durable checkpoint path) | exit 0, correct |
| 5 | "Read every file… explain each… suggest one improvement to calc.rb." | one-shot, `--json` | **23.60 s** | 6+ (3 plan + 3 semantic review) | **exit 1, PlanRejectedError, zero tool calls** |

## What the numbers establish

- **Simple chat floor is 3 sequential model calls, and the tail is 7+** —
  5.1–16.4 s for questions a single call would answer in ~2 s.
  **[measured]** Both simple-question runs needed 3 plan attempts; run 1's
  reviewer rejected the plan twice *for overengineering* — the machinery
  detecting the problem it creates.
- **Durability is not the chat bottleneck**: run 4 (full durable path) was
  6.87 s vs run 2's 9.63 s ephemeral — model-call count dominates; the
  benchmarked ~41 ms durable overhead (`docs/benchmark.json`) is noise against
  live model latency. **[measured]** (single runs each; directionally clear,
  not statistically tight)
- **A malformed first plan costs a full attempt** (run 2: `Review (protocol):
  revise`) — protocol robustness directly spends the user's plan budget.
  **[measured]**
- **Complex failure is fast to arrive but useless**: run 5 spent 23.6 s and
  ~6 model calls to produce only an opaque error. **[measured]**
- **Human mode is silent during every model call**: run 2 printed nothing
  until the first review line; there is no spinner, elapsed-time, or stage
  output while blocked. Perceived latency = total latency. **[measured +
  supported]** (`cli.rb:773-794` renders 4 event types; `task_started`,
  `plan_accepted`, `tool_completed`, `repair_started`, `completed` are emitted
  but never rendered in human mode)

## Perceived vs actual latency

All five symptoms reduce to one amplifier: **nothing user-visible happens
between input and terminal output on any surface.** A 10 s task with a 1 s ack
and a progress line feels shorter than a 6 s silent one; tamoz currently has
the silent kind on every path. This is a policy absence, not a transport or
model limit. **[supported]**

## Observability gaps found while measuring

Getting the stage timings above required hand-rolled instrumentation
(`--json` event streams + `time`). The gaps, all **[supported]**:

1. **No durations anywhere**: the observability catalog
   (`gems/tamoz-observability/.../catalog.rb`) defines `tamoz.model.call`,
   `tamoz.tool.call`, `tamoz.turn.duration_ms`, `tamoz.approval.wait_ms`,
   `tamoz.lease.wait_ms`, `tamoz.store.commit_ms` — and **no call site emits
   any of them**. The `ModelCall` wrapper class exists but is never
   instantiated. `Model#generate` returns a bare string and discards usage
   (tokens, latency).
2. Worker lifecycle events carry `ts` but no elapsed fields; stage latency is
   only reconstructable offline by diffing stored timestamps
   (`tamoz_request_transitions`, effect-attempt `prepared/started/completed`
   columns, outbox `created/updated`).
3. CLI stream parts carry no timestamps; `--json` gives order, not timing.
4. Both scorecards are correctness gates and deliberately exclude timing;
   the release benchmark explicitly does not attempt live-provider latency.
   Net: **the repo has no instrument that could have detected symptom 1 or 4
   on its own.**
5. `docs/LIMITATIONS.md:79-94` still claims "The Telegram channel itself does
   not exist yet" — stale relative to the shipped `gems/tamoz-telegram` and
   comms machinery; evidence docs are drifting from the code.

## Five Whys (for "we didn't know this before")

1. Why were slow chat and silent Telegram unmeasured? No stage-timing
   instrumentation on the request path.
2. Why not? The observability catalog's producer slices (graph/agent/sqlite
   producers, model-usage persistence) were never accepted/implemented
   (OBSERVABILITY_PLAN slices C/E outstanding).
3. Why did that pass release gates? Gates measure correctness and durability
   overhead, not live latency or UX; the benchmark's live-provider leg was
   deferred as "not reproducible".
4. Why is there no reproducible live-latency proxy? No seeded/fake-model
   latency harness exists for the *full* path incl. channel stages.
5. Root cause: **latency and user-feedback have no owner in the gate set** —
   what isn't gated isn't measured, and what isn't measured regressed by
   design accretion (review loops, durable-only paths) without any alarm.

## Recommended change (behavior, not code)

- Make the already-catalogued metrics real: emit model/tool/turn durations and
  queue/lease waits at the existing worker + session emit sites; add
  timestamps to CLI stream parts. No new abstractions — fill the producers the
  catalog already reserves.
- Add a live-latency smoke (small fixed prompt set, recorded per-stage timing)
  as a *reported* (not gated) release artifact alongside `benchmark.json`.
- Refresh `docs/LIMITATIONS.md` so shipped-vs-claimed surface stops drifting.

## Validation plan

- `tamoz observe metrics` shows non-zero `tamoz.model.call.duration_ms` and
  `tamoz.turn.duration_ms` after one turn.
- A Telegram round-trip can be decomposed into poll/admit/queue/execution/
  outbox/delivery segments from stored data alone (query or command, no log
  scraping).

## Open questions

None blocking. Cross-provider latency variance remains unmeasured (single
provider used).

## Next iteration

None — proceed to final synthesis.
