# Iteration 1 — Simple CLI conversation

## Journey analyzed

Input: `tamoz --root <dir> "What is the capital of France? Answer in one word."`
(one-shot, read-only default, live `deepseek-chat`).

Expected experience: acknowledge/answer within one model round-trip (~2–4 s).
A conversational question has no workspace risk, needs no plan, no review, no
verification machinery.

Observed outcome **[measured]**: 16.35 s wall clock, exit 0, correct answer —
after **7 sequential model calls**: 3 × plan, 3 × semantic review (two `revise`
verdicts), 1 × verify/synthesis. Raw log: `tmp/ux-probe/run1.jsonl`.

## Latency breakdown

| Stage | Time | Evidence |
|---|---|---|
| Process start, option parse, model construction | ~0.5–1 s (Ruby boot + `ruby_llm` require) | `user 0.42 sys 0.15` in `run1.stderr`; no network before first `generate` (`ruby_llm_model.rb:37-45`) |
| Turn classification | 0 — **does not exist** | `runtime.rb:40` branches only on `toolbox.action_capable?`, i.e. the operator's `--allow-changes` flag, never on message content |
| Plan attempt 1 (plan call + structural review + semantic review call) | ~3–5 s (2 model calls) | `run1.jsonl` events 2–4 |
| Plan attempt 2 (revise → plan + reviews) | ~3–5 s (2 model calls) | events 5–7 |
| Plan attempt 3 (plan + reviews, accept) | ~3–5 s (2 model calls) | events 8–11 |
| Step execution | ~0 (single no-tool step) | event 11 plan has `"tool":null` |
| Verify/synthesis call | ~2–4 s (1 model call) | event 12 `completed` |
| User-visible output before final answer | first line only after plan call 1 returns; **nothing** while any model call is in flight (no spinner, no streaming) | `cli.rb:773-794` renders 4 event types; `runtime.rb:39,107,361` emits `task_started`/`plan_accepted`/`completed` which human mode never renders |

Missing measurements: per-call durations are not recorded anywhere (observability
gap, see iteration 4). Stage times above are apportioned estimates
**[supported]** from call count × observed DeepSeek latency; total is measured.

## Completion breakdown

Turn reached `completed`, `satisfied: true`, answer correct. Truthful terminal
state — but only after the plan/review loop nearly burned all 3 plan attempts
(`max_plan_attempts = 3`, `runtime.rb:22`) on a one-word factual question. One
more `revise` would have produced `PlanRejectedError` ("no plan passed review
after 3 attempts", `runtime.rb:275`), exit 1 — a **simple chat would have failed
outright** through pure machinery self-interference.

## Evidence

- `tmp/ux-probe/run1.jsonl` — full event stream, 2 `revise` then 1 `accept`.
- `gems/tamoz-agent/lib/tamoz/agent/runtime.rb:40-63` — every turn runs
  plan → review → steps → verify regardless of content.
- `gems/tamoz-agent/lib/tamoz/agent/deliberation.rb:23-28` — semantic review is
  a separate model call with its own system prompt.
- `docs/benchmark.json` — the release benchmark itself gates "3 model calls per
  turn" as the *normal* case; no cheaper path exists to measure.

## Five Whys

Symptom: a one-word question takes 16 s and nearly fails.

1. Why 16 s? Seven sequential blocking non-streamed model calls.
2. Why 7 calls? The planner tied the answer to workspace evidence; the semantic
   reviewer rejected that twice ("overengineered… a direct answer would fulfill
   the task"), forcing 2 full re-plan cycles before verify.
3. Why does a factual question enter plan/review at all? There is no request
   classification — the only branch is `--allow-changes` (`runtime.rb:40`,
   `toolbox.rb:104`), an operator flag about mutation authority, not intent.
4. Why is there no classification? The architecture treats every input as a
   task to be planned and verified; "conversational response" is not a request
   class anywhere in `tamoz-agent` (grep for classify/route/intent: no
   request-path hits).
5. Why does the machinery self-interfere? Planner and reviewer share no notion
   of proportionality as a *system* property — proportionality is only a
   prompt-level suggestion the reviewer must re-derive per turn, at the cost of
   the very latency it complains about. Root cause: **missing request-class
   boundary before the deliberation graph; proportionality enforced by extra
   model calls instead of by routing.**

## Findings

| # | Finding | Severity | Frequency | Confidence | Components | User impact |
|---|---|---|---|---|---|---|
| 1.1 | No conversational/read-only fast path; every turn pays plan+review+verify | Critical | Every simple message | **[supported]** | `runtime.rb`, `session_*.rb` | 3–7 model calls where 1 suffices; 5–8× latency inflation |
| 1.2 | Semantic review loops on trivial tasks (2 revise cycles observed on "capital of France") | High | Common on short/ambiguous tasks | **[measured]** | `deliberation.rb`, `runtime.rb:213-306` | Latency + tail risk of `PlanRejectedError` on chat |
| 1.3 | Zero user-visible output while any model call runs (no spinner/stream; 4 of ~10 event types rendered) | High | Every turn | **[supported]** | `cli.rb:773-794`, `cli.rb:375-396` | Perceived latency equals total latency; no liveness signal |
| 1.4 | Planner forced to ground trivial answers in workspace tools ("read_only phase requirements") | Medium | Common | **[measured]** (run1 plan attempts) | planner prompt, `deliberation.rb:70-72` | Wasted tool steps, reviewer friction |
| 1.5 | Model calls are stateless per stage (fresh `RubyLLM.chat` per `generate`) | Medium | Every call | **[supported]** `ruby_llm_model.rb:49-56` | Full context re-sent per call → tokens and latency scale with stage count | Cost/latency multiplier on top of 1.1 |

## Recommended change (behavior, not code)

- Introduce an explicit request classification *before* the deliberation graph:
  conversational / read-only-question / bounded task / complex task / mutation.
  Cheap deterministic signals first (operator flags, message shape), with at most
  one cheap classifier call only when ambiguous. Conversational and direct
  factual questions route to a single model call with the answer returned
  directly — no plan, no review, no verify stage.
- Reserve plan→review→verify for requests that can mutate or that genuinely need
  multi-step tool use; make review proportionality a routing guarantee, not a
  per-turn debate.
- Render all existing lifecycle events in human mode and add a minimal
  in-progress indicator while a model call is in flight.
- Tradeoff/risks: misclassification is the new failure mode — a mutation
  misrouted to the fast path bypasses review/approval. Mitigation: fast path is
  read-only by construction (no action-capable toolbox), so worst case is an
  unhelpful answer, never an unreviewed mutation.

## Validation plan

- Scenario corpus: 20 conversational + 20 task prompts; assert model-call count
  per class (chat = 1, mutation task ≥ 3) and wall-time p50 for chat < 1.5× one
  model round-trip.
- Assert zero `PlanRejectedError` across the chat corpus.
- Regression gate: autonomy scorecard hard-zero counters unchanged; no mutation
  reachable from the fast path (toolbox sealed to read-only).

## Open questions

None blocking — classification absence is confirmed in source; call counts are
measured.

## Next iteration

Simple Telegram message — same question over the channel path, where queueing,
worker pickup and outbox delivery add their own latency on top of this one.
