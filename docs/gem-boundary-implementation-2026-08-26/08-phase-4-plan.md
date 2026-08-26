# Phase 4 plan: `tamoz-comms-gateway`

## Prerequisite

Do not extract the gateway while `tamoz-comms` rescues
`Tamoz::Telegram::ResponseTooLargeError`. First introduce a channel-neutral
Comms classification for an oversized response, prove that the Telegram
adapter maps its error into that contract for both poll and send, and verify
that `tamoz-comms` loads without `tamoz-telegram`. The mapping is explicit:
oversized poll is a transient transport failure; oversized send is an
ambiguous delivery outcome. No Telegram constant may remain in the moved
process code.

## Plan-review corrections and scope boundary

The two independent plan reviews found real blockers in the first draft. The
implementation brief therefore includes these corrections:

- The moved process classes must keep their existing injected seams for the
  transport, CommsStore/lease/offset/disposition operations, checkpoint
  controls, request-inbox/profile adapter, and durable effect binding. The
  source map and package metadata must say which are caller-supplied protocols
  and which are actual runtime dependencies. No second store or journal is
  introduced.
- `tamoz-agent-cli` must depend on and require `tamoz-comms-gateway`; the
  parent `tamoz-comms` entrypoint must stop eagerly loading the two process
  classes. Public API and requirements inventories must assign ownership to
  the new package. The no-compatibility rule means no forwarding constants.
- The extraction must add characterization around offset fencing,
  claim/pacing ordering, prompt activation after delivery, journal
  projection, and authentication preflight. These are existing lifecycle
  semantics exposed by the current code. They are not silently reimplemented
  or broadened during the package split. If the quality bar requires changing
  one of them rather than proving it, that is a separately named blocker and
  this phase must not be reported as complete.
- The existing B4 single-journal projection is retained and documented: the
  CommsOutbox owns send lifecycle/reconciliation/receipt resolution, while
  effect binding remains metadata about the durable effect. The extraction
  must not create another journal or claim that metadata binding is the
  outbox lifecycle owner.
- Gateway callback metadata is derived from the existing descriptor kind, so
  the process package does not embed a Telegram constant or require the
  adapter. The descriptor remains Telegram-only in v1 and its closed decision
  schema still yields `telegram_user`/`telegram`; this phase does not expand
  `SurfaceDescriptor` into a multi-channel redesign.

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
- Keep `OutboxDeliverySink` and the CommsStore contract in `tamoz-comms`; do
  not move or duplicate SQLite outbox behavior. The new gem consumes the
  existing protocol through its injected adapter.

## Evidence required before implementation

1. A source map identifies every Gateway/DeliveryDrainer consumer and confirms
   that no production path depends on a Telegram-specific constant.
2. A before/after matrix pins offset advancement, lease fences, send ambiguity,
   retry/throttle, authentication refusal, receipts, and shutdown outcomes.
3. An installed package test injects a transport and store from outside the
   gem; no fixture is added to the new gem.
4. The generic error-classification change is independently reviewed before
   any file move.

## Implementation order

1. Add the generic Comms oversized-response error and map Telegram poll/send
   outcomes into the existing transient/ambiguous Comms errors. Add focused
   tests and prove the parent package loads without Telegram.
2. Move only `Gateway` and `DeliveryDrainer` into the new gem. Remove their
   eager parent requires, add the new entrypoint and real gem dependencies,
   and migrate the CLI and all registry/requirements ownership records.
3. Add installed-package evidence with a transport and store supplied from
   repository test support. Assert that the built gem contains no fixture
   source/data, fake transport, test server, or fixture-only dependency.
4. Add or preserve characterization for the lifecycle invariants above,
   regenerate the source/API/dependency evidence, run the required gates, and
   submit the implementation to five independent review lenses.
