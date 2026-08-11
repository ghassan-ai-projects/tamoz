# Plan (v2, simplified) — Telegram approval: delivery FIXED, resolution blocked

**Date:** 2026-08-11
**Branch:** `codex/fix-mcp-cli-alms-live`

## 1. Status — what is DONE and verified live

| # | Item | State |
|---|------|-------|
| 1 | Approval prompts now delivered to Telegram | ✅ verified live (msgs 49–52, prompts `active`) |
| 2 | Worker hot-loop fix (durable fail of a queued request whose claim raises) | ✅ code + regression test green |
| 3 | Start script: kills gem-binstub workers, fails loudly if worker dies | ✅ |
| 4 | Deploy with current repo code | ✅ gateway+worker running |
| 5 | Approve button (v2): sink markup, transport buttons, gateway action routing | ✅ code + unit tests green (not yet live-verified) |

## 2. The ONE remaining blocker (verified live)

User pressed **Deny** on `c3594a22`'s prompt. Prompt `consumed`, decision `18b125d799b9`
(deny, `pending`) recorded — but the turn never resolves. Evidence:

- `tamoz_request_transitions`: `queued → failed`, evidence
  `{"kind":"claim_validation","operation":"turn","reason":"latest checkpoint is not terminal"}`
- thread's latest checkpoint = the OLD **15:37 paused** checkpoint (pre-fix era, never resolved)
- the decision stays `pending` forever because the request is terminal `failed`

**Root cause chain:**
1. `claim_next_request(validator: claim_validator)` (durable_runner.rb:72) runs
   `stale_request_reason` → `RequestStaleness#turn_reason`
   (request_staleness.rb:38-39): a queued `:turn` on a thread whose latest
   checkpoint is **paused** (not completed/failed) is rejected as stale.
2. `run_next` returns the terminal-failed request **without executing**
   (durable_runner.rb:77 `return request unless %i[claimed redirecting].include?`).
3. `claim_and_run` then calls `settle` (worker.rb) regardless; `settle` →
   `view_of` reads the thread's **latest checkpoint** — which is the OLD
   *paused* view — and the `:paused` branch (worker.rb:483-492) **creates a
   fresh approval prompt for the just-rejected request** and parks it.
4. The prompt is delivered and activated; the user presses Deny; the prompt is
   consumed and a decision recorded — but the request is already terminal
   `failed`, so the worker has nothing to resume and the decision never applies.

So: **`settle` misattributes a stale thread view (old paused checkpoint) to a
claim-rejected occurrence.** The approval prompt that reaches Telegram is real,
but the underlying request can never be resumed.

## 3. The fix (smallest correct change)

**Gate the `:paused` settle branch on the view actually belonging to the
occurrence being settled.** When `run_next` returns a terminal-failed request
(claim rejection, not an executed turn), `settle` must NOT treat the thread's
old paused view as this occurrence's pause.

Concretely, in `worker.rb` `claim_and_run` (and `recover`):
- capture the request returned by `run_next` / `recover`;
- if that request is terminal (`failed`), emit the appropriate terminal event
  and `return` **without** calling `settle` (or with a guard that skips the
  `:paused` branch).

Minimal, no store-schema change, no new state. The stale claim stays durably
failed (correct: the operator can see it in `tamoz status`), but no phantom
approval prompt is created, and no decision can dangle.

**Guard rails:**
- only skip when the returned request is terminal-failed (claim rejection);
- a genuinely paused execution still goes through the normal `:paused` branch;
- `request.failed` still emitted so the operator sees the rejection.

## 4. Also fix (same root family, cheap)

`comms_gateway#resolve_callback` currently records the decision and consumes
the prompt even when the underlying request is terminal. That is fine as-is
(consumption is idempotent); the dangling decision is prevented by §3. No
change needed here.

## 5. Tests

- Unit: a queued request on a thread whose latest checkpoint is `paused` is
  claim-rejected; the worker emits `request.failed`, creates **no** approval
  prompt, and no decision is left pending.
- Unit: a genuinely paused turn still creates the prompt + parks (existing
  `comms_deny_callback_test` / scorecard case 13 stay green).
- Live E2E: fresh thread (no stale paused checkpoint) → queue an
  approval-requiring task → prompt delivered → deny via Telegram →
  `request.denied` + terminal message delivered; then same with approve.

## 6. Verification gates

- `rbenv exec bundle exec rake ci` (default + `LC_ALL=C LANG=C`) for the
  touched slice; `rbenv exec rubocop`.
- Live E2E with real receipts, not mocks.
