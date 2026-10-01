# ADR-057 — A user's stop ends the turn; it never aborts the graph

**Status:** Accepted 2026-10-01
**Date:** 2026-10-01
**Tier:** F
**Implementation:** Complete — for chat stops; the stop watcher runs only when the worker has a comms store
**Relates to:** [ADR-015](./adr-015-durable-means-synchronous-barrier-commit.md), [ADR-016](./adr-016-every-external-effect-is-journaled-and-ambiguity-stops-as-unknown.md) (what a stop cannot undo), [ADR-005](./adr-005-interrupt-by-throw-not-by-exception.md) (a pause, which is different)

When a user stops a turn, the turn's own next step routes to a typed `cancelled_by_user` terminal,
abandoning any model call in flight. The stop never cancels the graph's execution token, so the
graph engine never drops a superstep half done because a user pressed stop.

## Context

Two things can end work early. A process shutdown cancels the graph context's token: the executor
drops the running superstep, leaves the request `running`, and the next pass recovers it, so the
answer still arrives. A user's stop means something else — "don't finish this" — and must produce a
truthful terminal outcome. Routing a user stop through the executor's token would leave the request
running, and recovery would resume the very work the user stopped. Treating it as an exception would
lose which effects already happened.

## Decision

- A user stop (a chat `/cancel`) stamps the request. The worker's `watching_for_stop` turns the stamp
  into a per-thread stop token registered in `Tamoz::Cancellation::Stops` for the running turn.
- The stop is kept out of the graph context. The work loop checks it at its next step and routes to
  the `cancelled_by_user` terminal. A model call in flight is raced against the token, abandoned,
  and recorded as a failed attempt.
- Effects that already completed stay completed and journaled; a stop undoes nothing. An `:unknown`
  effect stays unknown.
- Status shows `stopped` only for a `cancelled_by_user` terminal; a turn that completed before the
  stop landed says so.
- Process shutdown keeps its own path: the executor's token, a `running` request, and recovery.

## Consequences

A stop is a real outcome with a durable record, and recovery never resumes stopped work. **Cost:** a
stop takes effect at the next step, not instantly — a tool call already running finishes first, and an abandoned model call keeps
running in its thread until the HTTP call returns, so the provider still bills it.

## Invariants

- 53 — the request inbox is durable, ordered, and redirect-safe.
- 15 — streaming is one bounded projection (stuck workers retire and cannot commit).
- 14 — no ambient tenant state (see Residual risk).

## Threat model

**Asset:** a truthful record of what a stopped turn did. **Adversary:** races between stop,
completion, and crash.

| Threat | Mitigation |
|---|---|
| A stopped turn is resumed by recovery | The stop routes to a terminal; nothing is left `running` |
| A completion races the stop and is reported as stopped | Status says "completed before" and never "stopped" |
| A crash after the stop stamp loses it | The stamp is durable; recovery observes it |
| A stop is read as "nothing happened" | Completed effects stay journaled; unknown stays unknown |

**Residual risk:** `Cancellation::Stops` is a process-global registry keyed by thread id, which is
the kind of ambient state invariant 14 forbids; it is safe only while one worker process owns each
thread (ADR-017).

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Cancel the graph context's token on a user stop | Leaves the request `running`; recovery resumes the stopped work |
| Raise an exception into the running node | Loses effect state mid-node and can be rescued by user code |
| Kill the worker thread | Unsafe in Ruby; can leave a half-committed barrier |

## Reopen when

A user needs a stop to interrupt a long-running tool call immediately, or more than one process can
run turns for the same thread.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A CLI cancel routes a parked thread to its terminal | CLI | `test/agent_cli_test.rb` — `test_cancel_routes_to_terminal` | — |
| A chat stop routes the running turn to `cancelled_by_user` | `gems/tamoz-agent-session/lib/tamoz/agent/session_work.rb` (`stopped?`, `CANCELLED`) | source inspection | The chat stop → `stopped?` path has no test |
| A consumed cancel runs no second turn | worker | `test/cancellation_visibility_test.rb` — `test_a_real_worker_claim_consumes_a_cancel_redirect_and_stamps_observation` | — |
| A raced completion is never reported as stopped | status projection | `test/cancellation_visibility_test.rb` — `test_a_raced_completion_says_completed_before_effect_and_never_stopped` | — |
| A crashed claim recovers through the recover path | worker | `test/cancellation_visibility_test.rb` — `test_a_crashed_claim_is_recovered_through_the_recover_path_and_stamps_observation` | — |
| A model call in flight is abandoned | `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb` (`until_cancelled`) | source inspection | No test isolates mid-call abandonment |
| The stop is registered per thread | `gems/tamoz-cancellation/lib/tamoz/cancellation/stops.rb`, `gems/tamoz-agent/lib/tamoz/agent/worker.rb` (`watching_for_stop`) | source inspection | Watcher runs only with a comms store |
