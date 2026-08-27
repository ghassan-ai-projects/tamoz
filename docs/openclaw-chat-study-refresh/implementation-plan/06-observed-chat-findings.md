# Observed chat findings — Harness A discovery log

Pain points found by actually driving the chat through Harness A (the
mock-Telegram experience harness over the real gateway/worker/outbox/drainer/
store), recorded one by one with real evidence.

Method:
- **Interaction findings** use the deterministic provider so the real chat
  plumbing runs reliably and cheaply, isolating the chat UX from model smarts —
  which is the sponsor's named gap (broken/awkward interaction). A
  deterministic run is plumbing/UX evidence, never intelligence evidence.
- **Model-dependent findings** (latency, planning failures) come from real
  runs (OpenRouter `z-ai/glm-5.3-flash`, DeepSeek `deepseek-chat`).

Each finding carries: what was observed (real output), the user pain, severity
(Blocker / High / Medium), the root cause and the canonical finding/phase it
maps to (see `05-open-findings-ledger.md` and `01-plan.md`), the proposed fix,
and a **benchmark assertion** a later fix must satisfy (runnable via Harness A
or a focused test).

Severity: **Blocker** breaks the interaction; **High** erodes trust/wastes
time; **Medium** friction.

---

## OF-1 — A trivial task fails with an internal error after doing the work

**Observed (real: openrouter/z-ai/glm-5.3-flash and deepseek-chat).** Asked
"what is written in note.txt?". Effect journal:

```
model.generate.plan   -> succeeded
model.generate.review -> succeeded
tool.read_file        -> succeeded      (the file WAS read)
model.generate.plan   -> succeeded      (a repair re-plan)
model.generate.review -> succeeded
request.failed  reason: Tamoz::CheckpointConflictError:
                        effect key is already bound to different logical semantics
```

User sees: `That request failed before it could finish. Please try sending it
again.` — after the agent had already read the file.

**Pain:** the most basic task cannot complete on a real model; the user is told
to retry work that partly succeeded. This is the single biggest blocker to any
useful session.

**Severity:** Blocker.

**Root cause / maps to:** the agent's repair loop re-issues an effect whose
idempotency key collides with an earlier effect under different logical
semantics → `CheckpointConflictError`. This reproduces **CF-6** (previously only
seen swallowed in a test) on a real model. Confirmed to be the agent, not the
harness: identical failure with a single-worker-pass `pump`, while the
deterministic turn completes cleanly.

**Fix (proposed):** make effect-key derivation stable across repair re-plans, or
make a repair that re-issues a logically-different effect under an existing key
a handled, retryable condition rather than a fatal `CheckpointConflictError`.
This is agent-runtime work adjacent to Phase 0b's graceful-failure goal (I5):
even if it must fail, it must not surface an internal error string after partial
success.

**Benchmark:** drive a read-only task that triggers one repair on a real
provider; assert the turn reaches a terminal `answer`/`completed` OR a bounded,
user-safe failure card — never `CheckpointConflictError` reaching the user, and
never "failed before it could finish" after a successful tool effect.

---

## OF-2 — A trivial task takes ~100 seconds

**Observed (real: z-ai/glm-5.3-flash).** The same one-line question ran for
`duration_ms: 102496` (~102s) before failing.

**Pain:** even if it completed, 100s of near-silence for "what's in this file?"
feels dead and would exceed real Telegram long-poll/edit expectations. Combined
with OF-4 (silence), the user cannot tell it is alive.

**Severity:** High.

**Root cause / maps to:** multiple sequential model calls (plan, review, repair
plan, review, verify) each at provider latency, with no interim liveness the
user can read. Latency has its own workstream (`docs/ux-latency-investigation/`);
the chat-side mitigations are Decision 3 (two-stage receipt) and honest liveness
(DG-2 / Phase 3).

**Fix (proposed):** out of scope for the chat plumbing itself, but the chat must
(a) not promise progress it then withholds for 100s, and (b) show honest live
state so 100s is legible, not silent. Track model-call latency separately.

**Benchmark:** record accepted→first-meaningful-update and total duration per
run; a task over ~10s must produce at least one meaningful liveness update, and
the accepted card must not over-promise (Decision 3).

---
