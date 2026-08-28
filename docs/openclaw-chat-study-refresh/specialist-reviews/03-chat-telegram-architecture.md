# Lane C — Chat, Telegram, and channel architecture review

Date: 2026-08-27

## Scope and evidence boundary

This review traces the existing channel-to-worker path and asks what the
smallest architectural change is that makes a chat session interactive,
recoverable, and productive. It preserves the existing durable request,
effect-journal, outbox, and ownership-fencing model. It does not recommend a
second runtime or a new event bus.

The planned architecture subagent completed source synthesis but failed to
materialize its owned report within three bounded deadlines. This report is a
main-orchestrator fallback based on the verified source evidence in the Lane A
and Lane B reports and a bounded re-read of the named seams. It is therefore
usable as an architecture study, but its independent-agent status is an
evidence gap recorded in the correction log.

Evidence labels:

- **Fact** — observed in current source, tests, or documentation.
- **Inference** — a system or user consequence of named facts.
- **Proposal** — a future contract or migration choice.
- **Hypothesis** — a claim requiring live or user evidence.
- **Evidence gap** — not established by the current repository.

## 1. Current end-to-end seam map

| Stage | Current owner and behavior | Architectural consequence |
| --- | --- | --- |
| Channel input | **Fact:** `Telegram::Normalizer` derives distinct update, message, reply, and callback identities; it produces Telegram-bound correspondent and conversation IDs (`gems/tamoz-telegram/lib/tamoz/telegram/normalizer.rb`). | The adapter has useful identity facts, but the core envelope still validates Telegram prefixes directly. |
| Admission | **Fact:** `Comms::Gateway` polls, authenticates, normalizes, and admits through `Gateway::Admission`; admission persists the request and accepted delivery before the worker runs (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb:174-205`; `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:31-70`). | The durable acknowledgement boundary is the correct reuse point for every channel. |
| Durable request | **Fact:** SQLite stores request, conversation, history, task status, delivery status, and outbox rows (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb`; `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb`). | The source of truth already exists; a status cache or parallel chat store would duplicate authority. |
| Execution | **Fact:** a separate foreground worker claims an occurrence, journals model/tool effects through the runtime, emits lifecycle facts, parks on interrupts, and settles terminal state (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:506-756`). | Gateway availability and worker availability are separate. The user-visible contract does not currently expose that distinction well. |
| Projection | **Fact:** `OutboxDeliverySink` converts committed worker events into bounded control, approval, and terminal deliveries; milestones are coalesced (`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:28-161`). | This is the correct human-projection seam, but its interrupt branch assumes approval semantics. |
| Delivery | **Fact:** `DeliveryDrainer` claims rows, records send-start, calls the transport, and fences completion; ambiguous sends become `unknown` rather than being blindly retried (`gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb`; `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:222-233`). | Safety is strong; the user-facing recovery/read model is incomplete. |
| Telegram transport | **Fact:** `Telegram::Transport` maps delivery to `sendMessage`/`editMessageText` and callback acknowledgement to `answerCallbackQuery` (`gems/tamoz-telegram/lib/tamoz/telegram/transport.rb:45-79`). | Telegram presentation is a surface adapter, not an execution authority. |
| Operator controls | **Fact:** gateway commands support `/status`, `/cancel`, `/redirect`, `/new`, context controls, and callbacks; CLI operations use a separate set of thread-oriented commands (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb`; `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb`). | Semantic parity is incomplete even where underlying durable operations are related. |

## 2. Highest-risk architecture gaps

### G1 — Approval and clarification are collapsed at the projection boundary

**Fact:** the worker emits `request.approval_request` for every non-empty
interrupt set in `settle_paused_view` (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-734`).
`OutboxDeliverySink#decision_evidence` then unconditionally reads
`descriptor['decision']['required_evidence']`
(`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:248-257`). A
clarification descriptor is instead `kind: clarify` with a question and no
approval decision (`gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:145-153`).

**Inference:** a real clarification pause can raise before a question is
appended to the channel outbox. The turn remains paused while Telegram cannot
collect the answer. The CLI prompt loop does not prove the channel path.

**Proposal:** preserve the typed interrupt kind through a dedicated
`waiting_for_input` projection. Approval and clarification must have separate
payload schemas and actions. Clarification text must never enter the approval
evidence path.

**Closure:** add a worker-to-outbox test that drives a real clarify interrupt,
asserts one bounded question, no approval keyboard/evidence lookup, a paused
occurrence, and a text answer that resumes the same occurrence. A supported
channel must pass a guarded Telegram observation; an unsupported channel must
emit a typed unavailable notice rather than raise.

### G2 — Channel neutrality is asserted by architecture but not by core identity

**Fact:** `InboundEnvelope` requires `telegram:user:` correspondents and
`telegram:chat:`/`telegram:group:` conversations
(`gems/tamoz-comms/lib/tamoz/comms/inbound_envelope.rb:160-168`).
`SurfaceDescriptor::KINDS` contains only `telegram`
(`gems/tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:31,153`).

**Inference:** adding a second channel would require editing core envelope
validation and surface contracts, increasing the chance that channel-specific
identity rules leak into durable semantics. A plug-in registry would be more
machinery than the current need, but the present closed contract is a real
extension cost.

**Proposal:** separate channel-neutral `correspondent_id` and
`conversation_id` shape from adapter-owned namespace validation. Keep an
allowlisted surface descriptor with explicit `kind`, `revision`, and
capabilities. Reject unknown kinds at configuration/admission; do not make
the worker aware of them.

**Closure:** add a non-Telegram contract fixture for envelope construction and
prove that worker, store, lifecycle, and outbox code do not branch on channel
kind. Add an invalid-capability and cross-conversation-isolation test.

### G3 — The transport interface has no typed capability contract

**Fact:** `Comms::Transport` exposes only `authenticate`, `poll`, `deliver`,
and `signal` (`gems/tamoz-comms/lib/tamoz/comms/transport.rb`). Telegram uses
`signal(:ack)` for callback acknowledgement, while ordinary message delivery
is a different operation (`gems/tamoz-telegram/lib/tamoz/telegram/transport.rb:45-79`).

**Inference:** the system can describe a surface as Telegram, but it cannot
express whether a future surface supports edits, callbacks, text answers,
thread replies, or bounded message size. The gateway therefore either grows
conditionals or silently degrades controls.

**Proposal:** add a declarative capability matrix to the existing surface
descriptor, not a new runtime API. Minimum capabilities are
`poll`, `push_text`, `edit_text`, `callback_ack`, `action_buttons`,
`text_input`, `thread_reply`, `message_limit`, and `rate_limit`. The gateway
and sink select only actions declared by the bound surface; safety policy
still decides whether an action is authoritative.

**Closure:** matrix-driven contract tests must verify that unsupported actions
become explicit text controls or typed unavailable results, never silently
disappear. Test Telegram with its actual capabilities and a deliberately
limited fake future surface.

### G4 — Gateway and worker supervision are separate but not part of the chat contract

**Fact:** the Telegram guide requires two foreground processes. The gateway
can admit work while a missing worker means that “nothing is ever answered”
(`documentation/guides/telegram.md:90-103`). The launcher checks processes at
startup but does not provide ongoing supervision or a user-facing worker-health
state (`scripts/start-tamoz-comms.sh`).

**Inference:** an acknowledgement can mean “persisted” while the person
interprets it as “someone is working.” This is the largest source of perceived
silence that a better message alone cannot solve.

**Proposal:** make worker health a bounded operational fact in the accepted and
status projections: `accepted`, `queued_worker_unavailable`, `working`, or
`waiting_for_user`. Do not let the gateway pretend that execution started. A
supervisor may be added later, but it must remain process supervision around
the current gateway/worker, not a second executor.

**Closure:** kill the worker after admission, observe the accepted card and
status, restart it, and verify the same request advances without duplicate
effects. Define whether admission is refused when no worker heartbeat exists;
choose one policy and test it.

### G5 — The default status projection is diagnostic, not conversational

**Fact:** gateway status exposes phase, event, effect, capability, queue,
request, cancel, and reason fields (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_status.rb:18-78`).
CLI session status defaults delivery to `not_reported`, while comms status reads
outbox-backed delivery facts (`gems/tamoz-agent-session/lib/tamoz/agent/session_status_projection.rb:18-37`; `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:286-321`).

**Inference:** the same work has two truthful but differently useful read
models. Internal vocabulary leaks into mobile output, while the human CLI can
appear less certain than Telegram.

**Proposal:** retain the lossless diagnostic projection and add a bounded
human projection over the same facts: state, reference, goal label, current
safe phase, next action, and delivery certainty. `/status --diagnostic` and
CLI JSON keep internal fields. Human cards must never infer a state from model
prose.

**Closure:** golden tests assert semantic fields and redaction for Telegram
and CLI; the diagnostic projection remains backward-compatible within the new
schema, with no legacy-row tolerance.

### G6 — Request identity and control targeting diverge across surfaces

**Fact:** Telegram uses an `r` reference, while CLI queue/add and ask use UUID
or thread-oriented paths; `tamoz comms request` resolves comms references and
the benchmark CLI helper bypasses the actual CLI
(`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:220-241`;
`gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:224-255`;
`test/support/openclaw_comms_fixture.rb:145-163,419-427`).

**Inference:** the operator cannot reliably leave Telegram, use the CLI, and
return to the same task. A cross-surface benchmark can pass while missing
parser, stdout, process-reopen, and handle defects.

**Proposal:** choose one request reference projection for user-facing work.
The durable thread remains the authority handle; surface adapters display the
short reference and resolve it through the store. `cancel`, `redirect`, and
`status` must echo the exact affected reference and resulting state.

**Closure:** run the actual CLI command in a subprocess, capture stdout,
stderr, and exit status, reopen the database, and compare the handle/status
with a Telegram-submitted equivalent. Two open refs must include a hard-zero
cross-target cancellation test.

### G7 — Delivery ambiguity is safe internally but weak at the user boundary

**Fact:** the drainer fences `send_started` and treats an ambiguous external
send as `unknown`; operator resolution is available through CLI operations
(`gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb`;
`documentation/reference/cli.md:134-149`). Restart recovery preserves terminal
rows, but the user-facing return card is not defined
(`documentation/guides/telegram.md:105-133`).

**Inference:** suppressing blind resend is correct, but silence leaves the user
unable to tell whether work finished or the message was lost.

**Proposal:** project `delivery: uncertain` as an explicit read-only state
with “do not resend automatically” and a safe query/recovery action. Never
offer a user-facing retry for an unsafe external effect. A “since you were
away” card may summarize confirmed state, but cannot re-send an unknown
terminal answer.

**Closure:** inject post-send ambiguity, restart gateway and worker, verify no
duplicate external send, verify explicit user text, resolve through the
operator path, and confirm confirmed-only history.

### G8 — Approval capability is policy-bound and currently deny-only in practice

**Fact:** approval markup offers `approve` only when `chat_bound` meets the
engine-pinned evidence; otherwise it offers only deny
(`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:253-265`). The
Telegram guide states the current policy requires stronger evidence than a
chat binding for filesystem operations (`documentation/guides/telegram.md:135-150`).

**Inference:** a user may see a waiting card with no way to complete the task
in Telegram and must discover the CLI operator path. This is safe but not a
productive conversational loop.

**Proposal:** keep the deny-only rule until an explicit policy/ADR grants a
proper evidence class. Improve the waiting card to explain the bounded action,
why it is blocked, and the safe operator route. Never add an approve button as
a presentation feature.

**Closure:** policy-profile tests prove button omission and callback refusal;
real Telegram observation proves the user receives an actionable unavailable
notice rather than an apparently frozen task.

## 3. Smallest channel-neutral interaction architecture

The recommended architecture is a typed human projection over the existing
durable facts:

```text
Inbound adapter
  -> Gateway admission and durable request/reference
  -> existing Session / Worker / EffectDispatcher
  -> typed task + interrupt + delivery facts
  -> HumanProjection (bounded, redacted, channel-neutral)
  -> surface adapter (Telegram, CLI, future surface)
  -> receipt / unknown state back to the existing outbox
```

**Proposal — shared event contract:**

```text
accepted(ref, queue_position?, worker_availability)
queued(ref, ahead_count)
working(ref, safe_phase, next_action)
waiting_for_user(ref, kind: clarify|approval, question_or_impact, actions)
progress(ref, safe_phase, next_action)
completed(ref, verification: verified|response_only|not_verified)
failed(ref, reason_category, next_action)
stopped(ref, effect_uncertainty, next_action)

delivery: pending|delivered|failed|unknown
```

The task state and delivery state remain orthogonal. `HumanProjection` may
choose words and card layout, but it must not invent a transition, evaluate an
approval, re-send an unknown effect, or place model-authored prose in an
authority field. The event must carry a stable request reference and an
idempotency identity from the durable occurrence.

**Proposal — action contract:**

```text
status(ref)
cancel(ref)
redirect(ref, replacement_text)
answer_clarification(ref, answer_text)
approve(ref, decision_receipt)  # only when policy/evidence permits
deny(ref, decision_receipt)
```

All actions resolve the durable occurrence, verify conversation/correspondent
binding, and produce a durable result. Text commands, buttons, and CLI flags
are merely adapters to these actions.

## 4. Capability matrix and new-channel decision

| Capability | Telegram | Durable CLI | Future local web/TUI |
| --- | --- | --- | --- |
| durable submit and reference | yes, via gateway | partial/divergent today; target yes | target yes |
| accepted/status card | target bounded card | target same semantic card plus diagnostics | target same semantic card |
| text clarification answer | missing today; P0 | CLI prompt loop exists | target yes |
| approval buttons | policy-gated; deny-only for current profile | operator decision path | policy-gated |
| cancel/redirect by ref | partial; target exact ref echo | thread-oriented today; target ref parity | target ref parity |
| edit/coalesce progress | Telegram edit target | TTY line/card target | target websocket/terminal redraw |
| callback acknowledgement | Telegram-specific | not applicable | optional capability |
| reconnect/history | operator CLI today; user return card target | partial `show`/`follow-up` | target read-only reconnect |
| unknown delivery resolution | display only; operator resolves | operator resolves | display only unless policy grants |
| process supervision | external launcher today | external worker today | deployment-specific |

**Decision:** do not add a production channel in the next implementation
slice. First establish the shared interaction contract, clarification path,
worker-health truth, request-reference parity, and real Telegram evidence.
When those gates pass, a local web/TUI surface is the best next candidate
because it can expose durable history, action controls, and diagnostics without
forcing Telegram to carry large structured state. It must remain an adapter
over the same gateway/store/outbox contracts. Do not build a generic channel
plugin marketplace or multi-agent routing layer for this problem.

## 5. Migration, tests, telemetry, and safety gates

### Order

1. **P0 interruption correctness:** split clarify from approval in worker and
   sink projection; add Telegram/text-answer or typed-unavailable behavior.
2. **P0 human projection:** define card schema, redaction, reference placement,
   next-action language, and diagnostic opt-in over current lifecycle/outbox
   seams.
3. **P0 handles and health:** unify request references across actual CLI and
   Telegram; expose accepted versus worker-unavailable; choose admission policy
   for missing workers.
4. **P1 recovery and control parity:** exact-ref cancel/redirect, return card,
   unknown-delivery wording, and status/history parity.
5. **P1 real evidence:** guarded real Telegram/provider happy path, callback
   receipt, process restart boundaries, independent witness, and captured
   artifacts.
6. **P2 future surface gate:** only after the shared contract and real evidence
   pass; implement one small local web/TUI adapter and repeat isolation,
   capability, delivery, and recovery gates.

### Required tests and telemetry

- Clarification pause/resume, approval evidence separation, and no `KeyError`.
- Human-card golden tests for accepted, queued, working, waiting, completed,
  failed, stopped, and unknown delivery.
- Actual CLI subprocess tests with stdout/stderr/exit status and database
  reopen; two-reference targeting and cross-surface parity.
- Worker-dead-after-admission and worker-restart tests; no duplicate effects.
- Process-level restart at acknowledgement, effect receipt, terminal enqueue,
  and ambiguous-send boundaries.
- Real Telegram callback acknowledgement and send/edit receipts.
- Metrics: latency to accepted receipt, time to first meaningful update,
  maximum silence gap, card edits versus pushes, worker-unavailable duration,
  clarification completion, control-target accuracy, recovery rate, unknown
  resolution time, and terminal delivery success.
- Separate answer usefulness, comprehension, trust calibration, and annoyance
  measures from plumbing pass rates; real provider only for answer quality.

### Hard safety gates

- No model or channel text becomes authority; approval decisions come from the
  policy/engine evidence path.
- No external/non-deterministic call bypasses `EffectDispatcher` or its durable
  receipt/replay semantics.
- Ownership and fence checks remain on requests, decisions, and deliveries.
- `unknown` terminal delivery is never blindly retried or silently relabeled.
- History contains only confirmed terminal content under the current store
  rule; milestones remain projections, not conversational memory.
- Channel capability changes cannot broaden approval authority.
- Every real run records provider/transport provenance, durable receipts, and
  an independent trace; fixture runs remain plumbing evidence.

## 6. Rejected complexity and remaining uncertainty

- Rejected: a second chat runtime, event bus, in-memory status cache, or model
  narrator. The existing Gateway, Worker, Session, EffectDispatcher, outbox,
  and store are the right seams.
- Rejected: token streaming and raw tool/plan output as a substitute for
  meaningful progress.
- Rejected: automatic retry of unsafe unknown sends.
- Rejected: UI-only approval escalation, group/multi-user/media support, and
  channel expansion before identity/isolation evidence.
- **Evidence gap:** no current run proves real Telegram timing, callback
  acknowledgement, real-provider answer quality, or human comprehension.
- **Evidence gap:** the architecture subagent did not deliver an independent
  report; this fallback must be challenged in the product-engineering round.

## Verdict

**Report/content bar: MEETS BAR WITH GAPS.** The report maps the real seams,
names eight concrete architecture risks with closure observations, preserves
the safety invariants, defines a channel-neutral contract and capability
matrix, rejects unnecessary machinery, and gives a gated migration. The
independent architecture-agent materialization gap remains explicitly open.

**Current system/evidence readiness: NEEDS FIXES.** The confirmed clarification
projection defect, split request handles, worker-supervision ambiguity, closed
channel contract, incomplete recovery UX, and absent real Telegram/provider
evidence block a claim that Tamoz currently offers an interactive,
decision-grade OpenClaw chat experience.
