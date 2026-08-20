# Tamoz communication: target architecture

## Design decision

Build a thin communication projection over Tamoz's existing durable request,
session, effect, and outbox seams. Do not create a second agent runtime, a
chat-specific model loop, or a parallel event bus.

The target is a shared external lifecycle that CLI and Telegram render
differently but interpret identically.

```text
submitted
  -> accepted(request_ref)
  -> queued | running | waiting | blocked
  -> progress (bounded, semantic, optional)
  -> completed | failed | stopped
  -> delivery: pending | delivered | failed | unknown
```

Task state and delivery state are separate axes. A completed task with an
unknown Telegram send is still completed, but its delivery is unknown. An
accepted request with a pending acknowledgement is not running yet.

## Ownership model

```text
CommsGateway
  owns transport credentials, inbound normalization, admission, controls,
  request references, and read-only status projection

Worker + Agent::Session
  owns durable request execution, graph/checkpoint truth, effect receipts,
  cancellation observation, committed progress, and terminal task truth

OutboxDeliverySink + DeliveryDrainer
  owns bounded channel projections, delivery claims, pacing, receipts,
  retry classification, and UNKNOWN delivery state

CLI renderer / Telegram adapter
  owns presentation only; neither can grant authority or create model/tool work
```

The Gateway continues to hold no model credential, session, toolbox, or
workspace access. The worker continues to hold no Telegram transport credential.

## External lifecycle contract

Every accepted turn should have a stable, non-authorizing reference derived from
the durable request identity. A human can see a short reference; machine clients
receive the full bounded IDs.

Suggested event envelope:

```json
{
  "schema": 1,
  "kind": "accepted|state|progress|interrupt|terminal|delivery",
  "thread_id": "...",
  "request_id": "...",
  "execution_id": "...",
  "sequence": 0,
  "state": "running",
  "phase": "execute",
  "progress": {
    "completed_steps": 1,
    "total_steps": 3
  },
  "reason_code": null,
  "retryable": null,
  "next_action": null,
  "task_state": "running",
  "delivery_state": "pending",
  "emitted_at": "..."
}
```

This is a target contract, not current behavior. It should preserve the
existing `StreamPart` identity fields (`run_id`, `task_id`, `sequence`,
`emitted_at`) instead of flattening them away in CLI output.

### State vocabulary

Use a small closed vocabulary:

- `accepted` — durable admission completed;
- `queued` — admitted but waiting behind earlier work or capacity;
- `running` — a worker owns the request and is making progress;
- `waiting` — an approval, operator answer, or recovery decision is required;
- `completed` — task execution reached its terminal success state;
- `failed` — task execution ended with a known failure;
- `blocked` — execution cannot proceed until a named external/effect decision;
- `stopped` — cancellation or budget policy ended execution;
- `unknown` — only for a genuinely ambiguous task/effect/delivery outcome, never
  as a generic error.

Delivery state is independently `pending`, `delivered`, `failed`, or `unknown`.

## Existing seam map

| Target behavior | Extend | Do not create |
| --- | --- | --- |
| Stable turn identity | `SessionView`, request inbox IDs, execution/occurrence IDs | A second chat ID system |
| Status snapshot | `Session#view`, request records, `CommsStore`, outbox rows | A mutable in-memory status cache as authority |
| Durable event identity | `StreamPart`, `Graph::StreamEmitter`, worker emitter | Raw model-token persistence |
| Telegram lifecycle projection | `Worker#notify_sink`, `OutboxDeliverySink::EVENT_KINDS` | A Telegram-only worker loop |
| CLI lifecycle projection | `CLI#run_with_stream`, `CLIRendering` | Separate CLI semantics for each command |
| Controls | `Comms::CommandIntent`, `DurableRunner`, `Session#resume/continue`, redirect | Free-form command prompts to the model |
| Delivery truth | `CommsOutbox`, `DeliveryDrainer`, `CLICommsOps` | Automatic retry after ambiguous send |
| Telegram identity | `InboundEnvelope`, `Telegram::Normalizer`, `CommsStoreRows` | Treating update ID as message ID or payload digest |

## Proposed behavior by surface

### Telegram

Default first version:

1. Send a precise durable-admission receipt with a short request reference.
2. Send a queued or running state only when it adds information.
3. Send at most one coalesced progress/waiting projection for slow work.
4. Send approval/waiting state with a bounded reason and next action.
5. Send one terminal task projection.
6. Keep delivery pending/unknown visible through `/status`, but keep resolution
   authority with the operator CLI.

Do not stream model tokens. Do not send raw plan prose, tool output, secrets, or
internal lease details. A later edit optimization may coalesce a known,
receipt-backed progress card, but every edit remains a durable outbox effect.

### CLI

Human mode should render:

- an immediate local acknowledgement with request reference;
- a TTY-only elapsed/status line for queued, running, waiting, and finishing;
- concise committed progress milestones;
- terminal answer or failure with reason and next action;
- a clear distinction between task outcome and delivery outcome.

JSON mode should emit stable NDJSON envelopes containing the event identity and
both state axes. Human prose may change; the machine contract should not.

The ephemeral `tamoz TASK` path may remain, but help and output should explicitly
identify it as non-durable. Durable sessions and Telegram must share the durable
state vocabulary.

## Controls

Controls must be parsed before task admission and never become model input.

Minimum useful parity:

- `/help` — list commands actually implemented;
- `/status [reference]` — read-only caller-bound status;
- `/cancel [reference]` — enqueue a typed cancellation request;
- `/whoami` — show the bound correspondent and conversation, without authority;
- `/new` — create a new conversation generation without deleting audit history;
- `/redirect [reference] TASK` — use the existing durable redirect path with
  command-specific validation.

`/compact`, `/think`, `/verbose`, `/usage`, and `/context` should come later,
after the shared lifecycle contract exists. Their semantics must be defined as
typed session controls, not natural-language instructions.

The command table and Gateway handlers must be kept in lockstep. If a command is
not implemented, it must not parse as known.

## Status read model

`/status` and CLI status should be projections of durable evidence, not live
guesses. A request status should include:

- short request reference;
- thread and execution identity;
- task state and phase;
- queue position/age when queued;
- last committed progress;
- waiting/blocked reason;
- terminal reason and next action;
- delivery state and unknown reason if applicable;
- exact operator recovery command when authority is required.

Normal chat users may inspect status but must not resolve unknown effects or
unknown delivery. Those remain operator-authorized operations.

## Integrity and safety invariants

The redesign must preserve or strengthen these invariants:

1. Inbound identity includes the actual normalized/raw payload digest. Same
   `(surface, bot, update_id)` with a different digest is a durable conflict.
2. Telegram `update_id`, message ID, quoted-message ID, and callback-message ID
   remain separate fields and are used for their intended purposes.
3. Admission is durable before the external acknowledgement is considered sent.
4. Only the current owner/fence/attempt may cross a delivery effect boundary or
   record its result.
5. Model/tool effects remain behind `SessionEffects` and `EffectDispatcher`.
6. Telegram sends remain behind `DeliveryDrainer`; unknown sends are never blindly
   retried.
7. Untrusted content cannot expand the sealed capability set, change a reviewed
   plan, manufacture approval evidence, or replace an effect identity.
8. Approval binds actor, surface revision, conversation, prompt receipt,
   interrupt/effect digest, and expiry; deny remains fail-safe.
9. Cancellation is visible as requested, observed, and terminal; it does not
   imply that an already-issued external call stopped.
10. Declared byte, capacity, request, rate, output, and response limits are
    enforced at admission boundaries and produce typed refusal reasons.
11. Only confirmed successful terminal deliveries enter assistant conversation
    history. Progress/control messages never become normal model context.
12. Telemetry is bounded, redacted, and derived from durable facts; it never
    invents state when a writer or reader is unavailable.

## Staged delivery plan

### Stage 0 — correctness before UX expansion

- Fix and test Telegram message identity separate from update identity.
- Hash meaningful inbound payload content and quarantine same-ID/different-content.
- Carry delivery owner/fence/attempt tokens through send-start and completion.
- Enforce configured inbound bytes, open requests, response bytes, and capacity.
- Give the drainer typed handling for auth/storage failures.

### Stage 1 — truthful status and command parity

- Define the external state vocabulary and reason-code registry.
- Add request references to acknowledgements and status.
- Implement or remove `/new`, `/redirect`, and `/whoami`.
- Make `/status` expose task and delivery axes.
- Exclude pending/unknown terminal output from future context.

### Stage 2 — bounded semantic progress

- Project accepted, running/recovered, waiting, and terminal milestones through
  `Worker#notify_sink` and `OutboxDeliverySink`.
- Bound and coalesce progress per occurrence.
- Keep progress out of normal conversation history.
- Add callback acknowledgement and prompt-activation crash tests.

### Stage 3 — cross-surface recovery and evidence

- Preserve event identity in CLI JSON and add a durable/reconnectable status view.
- Add the canonical full Telegram composition test with real SQLite fixtures,
  worker recovery, provider failure, outbox ambiguity, duplicate update, and two
  isolated conversations.
- Add the operational metrics/read model needed to diagnose queue age, lease loss,
  delivery unknown, cancellation latency, and telemetry drops.

Do not expand groups, media, multi-agent routing, or affirmative remote approvals
until these stages and their evidence gates pass.
