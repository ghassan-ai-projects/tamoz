# Phase 4 plan: `tamoz-comms-gateway`

## Prerequisite

Do not extract the gateway while `tamoz-comms` rescues
`Tamoz::Telegram::ResponseTooLargeError`. First introduce a channel-neutral
Comms classification for an oversized response (or an injected classifier),
prove that the Telegram adapter maps its error into that contract, and verify
that `tamoz-comms` loads without `tamoz-telegram`.

## Planned boundary

- Move `Tamoz::Comms::Gateway` and `Tamoz::Comms::DeliveryDrainer` into
  `tamoz-comms-gateway` without changing their behavior or namespace unless
  the implementation bar records a deliberate namespace decision.
- Keep `Tamoz::Comms::OutboxDeliverySink` in the channel-neutral package: it
  projects worker lifecycle facts into the generic CommsStore contract and
  does not own the long-running transport process.
- Make the gateway package depend one-way on `tamoz-comms`, the durable store
  contract/provider it directly uses, and `tamoz-core`; it must not depend on
  Telegram, agent runtime, evals, or model code.
- Preserve the operator-supplied transport seam. The gateway package owns the
  process and lifecycle orchestration, not a particular channel adapter.

## Evidence required before implementation

1. A source map identifies every Gateway/DeliveryDrainer consumer and confirms
   that no production path depends on a Telegram-specific constant.
2. A before/after matrix pins offset advancement, lease fences, send ambiguity,
   retry/throttle, authentication refusal, receipts, and shutdown outcomes.
3. An installed package test injects a transport and store from outside the
   gem; no fixture is added to the new gem.
4. The generic error-classification change is independently reviewed before
   any file move.
