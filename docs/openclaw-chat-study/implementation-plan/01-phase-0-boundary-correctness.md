# Phase 0 — correctness at the boundaries

Status: not started — no production code changed by this planning pass.

Study reference: Stage 0 (`../04-tamoz-target-architecture.md`), P0
(`../05-comparison-and-priorities.md`), root causes #5 and #8
(`../03-tamoz-current-state.md`). This phase exists because every later phase
adds visible surface; expanding the conversation contract before these
correctness gaps close makes the redesign untrustworthy.

## Goal

Delivery identity, inbound identity, admission limits, and drainer failure
handling are correct and tested **before** any richer chat experience is built.
No new user-facing behavior ships in this phase; it closes the trust holes the
study found so that later liveness work rests on a sound base.

## Required order

Fix the delivery owner/fence path and the Telegram identity fields first — they
are correctness, not UX. Then enforce the admission limits at their real
boundaries, then give the drainer typed failure states. Do not begin Phase 1's
status projection until the fence and identity tests are green.

## Design constraints (from the study, binding)

- Extend `DeliveryDrainer`, `CommsOutbox`, `Telegram::Normalizer`, and the
  `CommsStore` admission path. Do not create a second delivery worker, a second
  identity system, or an in-memory delivery cache.
- Telegram sends stay behind `DeliveryDrainer`; an ambiguous send stays
  `unknown` (invariant 6). This phase strengthens the boundary, never relaxes it.
- Model/tool effects stay behind `SessionEffects` / `EffectDispatcher`
  (invariant 5); this phase touches the delivery and admission boundaries only.

## Work items

1. **Fence the send boundary.** Ensure `DeliveryDrainer#send_row` cannot cross
   the external send boundary after its owner/fence/attempt transition fails.
   Today `mark_delivery_send_started` returns `:not_claimable` when the fence is
   lost and the drainer ignores that result before sending: `send_row` must
   honor the failed fence transition by aborting before `transport.deliver`,
   and `mark_delivery` must carry owner/fence/attempt so a stale caller cannot
   record another owner's result. The current owner is the only writer of a send
   result; a losing owner records nothing and takes no external action.
2. **Complete Telegram inbound identity.** Make `Telegram::Normalizer#digest`
   hash the meaningful normalized/raw payload content, not just `update_id`, and
   have the store compare that digest on admission. Same `(surface, bot,
   update_id)` with a different digest becomes a durable integrity conflict with
   a typed refusal reason; an exact duplicate maps to the one existing request.
3. **Keep the four Telegram IDs distinct.** Retain the current message's own
   Telegram `message_id` in addition to `update_id`, the quoted `reply_to`
   message ID, and the callback-message ID. Stop using `update_id` as the control
   reply target where the message ID is meant. Update fixtures that set
   `message_id == update_id` so they cannot mask a real mismatch.
4. **Enforce the unenforced declared limits.** `outbox_capacity`,
   `control_capacity`, and `max_denial_prompts_per_request` are already enforced
   at the admission/delivery boundary (`CommsStore#capacity_saturated?`,
   `append_delivery`); keep them under regression test. The gap is
   `max_open_requests`, `max_inbound_bytes`, and `max_response_bytes`: all three
   are validated in `SurfaceDescriptor` configuration only and enforced nowhere
   (`max_response_bytes` lives under the descriptor's `transport` section).
   Enforce them where the resource is actually admitted (the `CommsStore` admit
   path and the response boundary). Each breach returns a typed refusal reason
   and does not enqueue work.
5. **Typed drainer failure handling.** Give `DeliveryDrainer` typed handling for
   authentication and storage failures so it cannot stop silently. A persistent
   auth failure produces an operator-visible delivery state and a typed reason,
   not an unbounded retry loop and not a false terminal.

## Tests

- `test/delivery_drainer_test.rb` (extend; outbox coverage lives there and in
  `test/comms_gateway_test.rb` today — there is no `test/comms_outbox_test.rb`,
  so either extend the existing files or create it deliberately) proves a stale
  drainer that lost the fence performs no external send and records no result,
  and that `mark_delivery` rejects a stale owner/attempt;
- `test/tamoz_telegram_transport_test.rb` and a normalizer test prove exact
  duplicate → one request, same-ID/different-content → durable conflict, and that
  message/update/quoted/callback IDs are carried and used distinctly;
- `test/comms_admission_test.rb` (extend) proves each declared limit refuses at
  its admission boundary with a typed reason and enqueues no work;
- a drainer failure case proves authentication and storage failures produce a
  typed, operator-visible state rather than a silent stop or a false success.

## Exit bar

- All five work items are done in the stated order; the delivery, identity, and
  admission suites are green under `rake ci` and `ci_full` in both locales.
- Invariants 1, 2, 4, 6, and 10 are verified with named tests.
- No stale owner can cross a send boundary; no same-ID/different-content pair is
  silently deduplicated; no declared limit is unenforced at its boundary.
- The evidence manifest contains the test commands, changed files, and an
  explicit statement that this phase proves plumbing only — no live Telegram or
  real-provider behavior is claimed.

## Out of scope

The lifecycle vocabulary, request references, `/status` projection, command
parity, progress projection, and any real-provider or live-transport claim
(Phases 1–3 and the benchmark).
