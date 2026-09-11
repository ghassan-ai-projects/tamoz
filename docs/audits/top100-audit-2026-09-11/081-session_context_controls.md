# Audit 081 — `gems/tamoz-agent-session/lib/tamoz/agent/session_context_controls.rb`

Rank 81 · 485 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: DEAD

The /new control is implemented and audited but dispatched by no production entry point, and one
conversation-history expression is copy-pasted three times.

## Findings

- **[major][DEAD]** `new_generation` (and its only helper consumer `next_generation_thread`) has
  zero production callers, grep-proven test-only: the gateway dispatches only
  reset/compact/usage/context/think/verbose (gateway_context_controls.rb:33-40; /new goes to
  comms `bump_generation`) and the CLI has no `new` command. Owning seam: comms gateway/CLI
  context-control dispatch — or delete. (session_context_controls.rb:114-120, 85-90)
- **[minor][DUP]** `SessionPlanningContext.conversation_history(app_for_thread(thread).checkpointer,
  thread_id: thread)` is copy-pasted at three sites in one file. Owning seam: a private
  `conversation_length(thread)` helper on this module.
  (session_context_controls.rb:128-129, 168-170, 209-211)

## Resolution — 2026-09-11

- **[major][DEAD] fixed by deletion.** Independently confirmed the finding: the gateway's
  context-control dispatch handles only reset/compact/usage/context/think/verbose
  (`gateway_context_controls.rb`), `/new` is routed by `gateway_commands.rb` to the comms
  store's `bump_generation` (a conversation-generation bump with its own
  `Admission.thread_id` naming), and the CLI has no `new` command. `new_generation` and
  `next_generation_thread` were therefore reachable only from their own tests. Deleted both,
  plus the vestigial `successor_thread_id` field on `ContextControlProjection` (its only
  writer was `new_generation`; `document` already compacted it away). Dropped the now-dead
  test `test_new_addresses_the_successor_generation...` and the `next_generation_thread`
  assertions.
  - Chose **delete** over "wire it into the gateway": `/new` already works through the comms
    conversation generation, so dispatching a second, differently-named (`.gN`) generation
    scheme would add a competing mechanism rather than fix one.
  - `generation_of` is KEPT — it has four production callers that read `.gN` ids. Worth
    noting for a later look (outside this finding): with the only `.gN` writer gone, nothing
    in production mints those ids, so `generation_of` now always reads 1 there. That was
    already true before this change, since `new_generation` was never dispatched.
  - The durable `context_control` record schema keeps its optional `successor_thread` field:
    a durable format is a compatibility contract, and narrowing it could reject a historical
    record. That is deliberate, not an oversight.
- **[minor][DUP] fixed.** The thrice-copied
  `SessionPlanningContext.conversation_history(app_for_thread(thread).checkpointer, thread_id:
  thread)` is now the private `conversation_history_for(thread)`; the two length sites take
  `.length` and `/compact` uses the array.

Tests: session_context_controls_test 10 runs / 0 failures (was 11 runs — the deleted test);
context_control_exposure_test unchanged vs pristine. RuboCop on the lib: 9 -> 8 offenses.
