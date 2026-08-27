# Product-engineering review 2 — architecture, security, reliability, and channel boundaries

Date: 2026-08-27  
Lane: bounded architecture/security/reliability review  
Scope: OpenClaw/Tamoz chat-experience refresh; existing Telegram, durable CLI,
gateway, worker, session, event, projection, outbox, drainer, identity, and
authority seams.

## 1. Scope and sources inspected

**Fact:** I read the review bar, orchestration protocol, all specialist reports,
both brainstorming reports, the consolidated study, decision roadmap, evidence
index, correction log, and package README:

- `docs/openclaw-chat-study-refresh/00-review-bar.md`
- `docs/subagent-orchestration.md`
- `docs/openclaw-chat-study-refresh/specialist-reviews/01-gap-audit.md`
- `docs/openclaw-chat-study-refresh/specialist-reviews/02-interaction-product.md`
- `docs/openclaw-chat-study-refresh/specialist-reviews/03-chat-telegram-architecture.md`
- `docs/openclaw-chat-study-refresh/brainstorming/01-facilitator.md`
- `docs/openclaw-chat-study-refresh/brainstorming/02-fourier.md`
- `docs/openclaw-chat-study-refresh/01-consolidated-study.md`
- `docs/openclaw-chat-study-refresh/02-decision-roadmap.md`
- `docs/openclaw-chat-study-refresh/03-evidence-index.md`
- `docs/openclaw-chat-study-refresh/04-correction-log.md`
- `docs/openclaw-chat-study-refresh/README.md`

**Fact:** I traced the relevant implementation end to end through `Gateway` and
`Gateway::Admission` (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb:21-29,152-217`,
`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:31-70`), callback
resolution and acknowledgement (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb:10-77`),
status and command controls (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_status.rb:10-60`,
`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb:96-121`), the
SQLite request/status/outbox implementation (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:522-713,988-1004`,
`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store_rows.rb:41-50`,
`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:141-233`), worker/session
pause and authority paths (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-735,996-1047,1099-1108`,
`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:91-130`), sink/drainer
projection (`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:66-265`,
`gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb:45-151`), and
Telegram/CLI adapters (`gems/tamoz-telegram/lib/tamoz/telegram/normalizer.rb:34-80`,
`gems/tamoz-telegram/lib/tamoz/telegram/transport.rb:37-104`,
`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:387-449`,
`gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:158-218`,
`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:220-241`).

**Fact:** I inspected the focused tests for normalizer identity, gateway
admission/replay/callbacks, outbox rendering, cancellation, status, and CLI
behavior. I ran these commands with
`/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby` from the repository root:

- `ruby -Itest test/telegram_normalizer_test.rb` — 8 runs, 23 assertions, 0 failures.
- `ruby -Itest test/agent_outbox_delivery_sink_test.rb` — 11 runs, 44 assertions, 0 failures.
- `ruby -Itest test/comms_gateway_test.rb` — 35 runs, 194 assertions, 0 failures.
- `ruby -Itest test/cancellation_visibility_test.rb` — 11 runs, 98 assertions, 0 failures.

**Inference:** These runs establish focused plumbing behavior only. They do not
establish real-provider reasoning, live Telegram behavior, process-level
restart behavior, or human comprehension; that boundary is also explicit in
`docs/openclaw-chat-study-refresh/00-review-bar.md:25-30` and
`docs/openclaw-chat-study-refresh/01-consolidated-study.md:104-110`.

## 2. Hard-zero risks and invariants

| Invariant | Severity/status | Exact closure gate |
| --- | --- | --- |
| **Fact:** interruption kind must remain typed; approval evidence must never be read from a clarification. The worker currently emits `request.approval_request` for every non-empty interrupt (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-735`), while clarification has `kind: clarify` and no approval decision (`gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:138-166`). | **Critical / unresolved** | Drive a real clarify pause through worker → sink → durable outbox. Assert one bounded question, no approval prompt/evidence lookup, same-occurrence text answer, durable resume, and no `KeyError`. |
| **Fact:** authority is not allowed to travel in a queued payload; worker authority is intersected with current enabled sources and thread profile binding (`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:91-130`). | **High / invariant intact; proof incomplete** | After worker restart and profile/catalog/policy revision, resume a stored thread and prove payload cannot select authority, the current binding is used, and the resulting catalog/effect receipts are replay-stable. |
| **Fact:** model and tool calls cross `EffectDispatcher.run`: session model/tool paths do so explicitly (`gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:19-53,75-85`), the runtime model path does too (`gems/tamoz-agent/lib/tamoz/agent/runtime.rb:619-650`), and the episode model/tool nodes use the same dispatcher (`gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_call.rb:67-86`, `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_tool_call.rb:74-89`). **Fact:** the dispatcher prepares, starts, completes, replays, and records terminal outcomes (`gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:33-65,78-108,174-210`). Renderers only consume views/events and write/render deliveries; they do not invoke providers/tools (`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:66-118`, `gems/tamoz-agent-cli/lib/tamoz/agent/cli_rendering.rb:60-71,140-171`). Existing replay/journal assertions are in `test/agent_runtime_effects_test.rb:42-66,165-183`. | **High / invariant intact; regression gate required** | Run the effect replay tests and a static/dependency check over every new renderer: no provider/tool call or dispatcher bypass; model/tool nondeterminism must remain behind the existing journal. |
| **Fact:** request, callback, and delivery ownership are fenced at their current seams: callback binding checks surface revision, correspondent, conversation, and prompt receipt (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb:66-77`); outbox outcome writes require claim owner/fence (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:204-220`). | **High / invariant intact; new projection must not bypass it** | Add stale-owner, cross-conversation, stale-prompt, and exact-reference tests around every new human action. |
| **Fact:** an ambiguous delivery is represented as `unknown` and is not automatically retried (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:141-157,204-233`). | **High / invariant intact; user boundary incomplete** | Inject post-send ambiguity, restart gateway/worker, show explicit uncertainty, prove no duplicate send, and require the existing operator resolution path before confirmed history changes. |
| **Fact:** conversation history combines admitted task text with only journaled, succeeded terminal deliveries; the SQL filter excludes pending/claimed/unknown/failed rows and all milestone kinds (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:537-549,1098-1115`). Milestones are explicitly `journaled: false` and non-terminal (`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:123-161`); `test/progress_projection_test.rb:203-220,361-384` asserts this boundary and the terminal positive control. | **High / invariant intact; regression gate required** | Run the history/projection tests after the new human projection: a succeeded milestone must never enter model context, while a confirmed succeeded terminal answer/failure/stopped/blocked row does; replay and restart must preserve the same result. |
| **Fact:** callback acknowledgement happens after durable callback resolution and is best effort (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:31-38`, `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb:10-17`). | **High / invariant intact; live evidence missing** | Run a guarded Telegram callback and capture callback-ack receipt plus durable decision/disposition ordering. |
| **Inference:** exact-ref controls cannot be considered safe while request status and cancellation can target or report a different occurrence in a shared conversation/thread. | **High / unresolved** | Admit two open requests, cancel one exact ref, and assert only that row is stamped/settled; independently resolve each ref while the other has pending/unknown delivery. |
| **Fact:** channel text is not an authority source in the current callback path: approval checks compare the active prompt’s pinned evidence before recording a decision (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb:30-63`). | **High / preserve** | Typed human projection tests must prove model text, question text, buttons, and future surface capabilities cannot create or widen an approval decision. |

## 3. Findings ordered by severity

### F1 — Clarification is collapsed into an approval event and can fail before delivery

**Classification:** Fact; Inference; Proposal.

**Evidence:** `Worker#settle_paused_view` emits `request.approval_request` for
any non-empty interrupt and parks without carrying its kind
(`gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-735`). A clarification is
constructed as `kind: clarify` with a question/context and no approval decision
(`gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:138-166`).
The sink unconditionally fetches
`descriptor['decision']['required_evidence']`
(`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:248-257`), so the
clarification path can raise before a channel question is appended.

**Failure mode:** Inference — a real clarification pause can leave the durable
occurrence waiting while Telegram receives neither a question nor an answer
action. If a minimal typed fix changes only the event name, the existing
`park` default still records `approval_required`
(`gems/tamoz-agent/lib/tamoz/agent/worker.rb:996-1007`); deadline scanning only recognizes that reason and only
looks for `approve_tool` descriptors (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:1040-1047,1099-1108`). The
clarification would still have the wrong expiry/resume semantics.

**Root/system cause:** Inference — the worker-to-sink seam assumes “paused”
means “approval,” despite the session seam already carrying typed interrupts.
This is a semantic-boundary loss, not a missing channel or missing runtime.

**Security/reliability impact:** Critical — clarification text is not authority,
but routing it through approval evidence creates a crash path and can strand a
session. A future repair that reuses approval actions could also accidentally
turn a question answer into an approval decision.

**Channel-boundary impact:** Fact/Inference — the durable CLI has a prompt loop
that distinguishes `approve_tool` and `clarify` in
`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:463-519`, while the comms sink does
not. Telegram therefore cannot be treated as a peer surface.

**Scope-creep check:** Proposal — do not add a second runtime, event bus,
narrator, or channel plugin. Preserve the existing worker → sink → outbox seam.

**Smallest correction and existing seam:** Proposal — add typed sink branches
for `clarify` and approval, with separate bounded payloads and action schemas;
pass `reason/kind` into the existing park/deadline metadata; add an explicit
unavailable notice when a surface lacks text input. Keep approval evidence and
`Gateway::Callbacks` unchanged.

**Closure test:** Proposal — a worker-level integration test must create a real
clarification descriptor, assert one outbox question with no approval markup or
evidence lookup, restart the worker, submit an exact-ref text answer, and assert
the same occurrence resumes once. The Telegram adapter must pass a guarded
real observation; a deliberately text-input-limited surface must produce a
typed unavailable result.

### F2 — Request-scoped status aggregates delivery and effects across requests

**Classification:** Fact; Inference; Proposal.

**Evidence:** `conversation_runtime_status` accepts `request_id` but calls
`delivery_state_for(surface_id, conversation_id)` without it
(`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:522-529`). That delivery
query scans every outbox row for the conversation and collapses all statuses
(`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:701-713`). The outbox row schema has no `request_id`
(`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store_rows.rb:41-47`). Effect status
has the same shape: `effect_state_for` receives `request_id` but summarizes
`effect_statuses(thread_id)` for the whole thread
(`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:611-639`).

**Failure mode:** Inference — with two open requests, `/status rA` can report
`unknown`, `pending`, or `failed` because of request B’s outbox/effect, and
`/status rB` can inherit request A’s state. The proposed human card would make
this more legible while making the wrong occurrence more convincing.

**Root/system cause:** Inference — the API was made reference-addressed at the
request lookup layer, but durable delivery and effect projections retained
conversation/thread aggregation. The current content-addressed delivery id
includes an optional occurrence identity (`gems/tamoz-comms/lib/tamoz/comms/delivery.rb:64-85`),
but that identity is not exposed as a row field for projection queries.

**Security/reliability impact:** High — users can act on a false delivery or
effect state, conceal an unknown terminal send, or believe the wrong request
completed. This is a control-targeting and truthfulness defect, not just a UI
wording issue.

**Channel-boundary impact:** High — Telegram and CLI exact-ref controls require
the same occurrence truth. A channel-neutral card over an aggregate is not
channel-neutral semantics.

**Scope-creep check:** Proposal — extend the existing request/outbox/effect
projection mapping. Do not add a status cache, second event bus, or parallel
store. The repository’s no-legacy-row rule permits a fresh schema adjustment if
the smallest durable mapping requires one.

**Smallest correction and existing seam:** Proposal — persist the originating
request/occurrence identity on request-owned outbox rows, or add an equivalent
durable mapping that is queryable by request; make effect summarization filter
by the request’s occurrence/execution identity. Keep conversation-wide status
as a separately named aggregate.

**Closure test:** Proposal — admit A and B on one conversation; force A to
`unknown`, leave B pending, then make B succeeded. `request_status(A)` and
`request_status(B)` must each show only their own delivery/effect state. Repeat
after reopen and after a duplicate/replay. No aggregate assertion is sufficient.

### F3 — `/cancel` cannot target one request when a thread has multiple open requests

**Classification:** Fact; Inference; Proposal.

**Evidence:** Gateway cancellation accepts an envelope but no request reference,
selects the current conversation generation thread, and submits one thread
control (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb:96-118`).
The atomic stamp updates every admitted request on that thread
(`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:988-994`). The CLI likewise
submits a thread-oriented redirect cancellation
(`gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:182-218`).

**Failure mode:** Inference — if two requests are open, a user intending to
cancel `rA` can stamp both A and B. The current tests prove durable cancellation
and a two-request queue, but do not prove a two-reference cancellation target;
`test/sqlite_comms_store_test.rb:test_conversation_status_is_reference_addressed_and_queue_aware`
only checks the aggregate queue and active reference, while
`test/cancellation_visibility_test.rb` covers one request and thread timelines.

**Root/system cause:** Inference — cancellation was designed as a per-thread
control before the proposed per-occurrence action contract. The caller-bound
request lookup exists, but the cancel path does not consume it.

**Security/reliability impact:** High — wrong-request cancellation is an
operator control failure and may stop work the caller did not select. It also
destroys the meaning of exact-ref “next action” cards.

**Channel-boundary impact:** High — Telegram’s `/cancel` and CLI’s `cancel`
cannot promise the same target. A future button is unsafe until its target is
durably bound.

**Scope-creep check:** Proposal — add exact-ref parsing to the existing command
adapter and a request-scoped cancellation transaction. Do not introduce a new
control plane.

**Smallest correction and existing seam:** Proposal — require `cancel(ref)`
for multi-request contexts, resolve it through the same surface/conversation
binding as `request_status`, and update only that request row while enqueueing
the cancellation operation atomically. Preserve current-generation and worker
fencing rules.

**Closure test:** Proposal — admit two requests, cancel only the older reference,
replay the command, restart the worker, and assert the other request has no
requested/observed stamp and can complete. Foreign, malformed, and ambiguous
refs must be rejected without mutation.

### F4 — The evidence/readiness gate can still overstate coverage

**Classification:** Fact; Inference; Proposal; Evidence gap.

**Evidence:** The fixture runner uses deterministic/no-egress execution and
filters unavailable metrics (`test/support/openclaw_comms_runner.rb:41-48,133-168`);
the fixture declares Telegram-oriented behavior and the canonical CLI helper
bypasses the actual CLI process (`test/support/openclaw_comms_fixture.rb:145-163,419-427`).
The consolidated study explicitly says real Telegram/provider and human
evidence are absent (`docs/openclaw-chat-study-refresh/01-consolidated-study.md:104-110`),
while the roadmap requires actual subprocess, restart, independent trace, and
real-transport/provider gates (`docs/openclaw-chat-study-refresh/02-decision-roadmap.md:79-83,103-130`).

**Failure mode:** Inference — a green B0 plumbing result can be interpreted as
cross-surface readiness when required cells are unavailable, the CLI parser and
process boundary were not exercised, and no real model or Telegram receipt
exists.

**Root/system cause:** Inference — scenario specification, runner admissibility,
and evidence index are not one fail-closed contract. The correction log records
the same governance contradiction (`docs/openclaw-chat-study-refresh/04-correction-log.md:74-87`).

**Security/reliability impact:** High — false readiness can authorize changes to
approval, delivery, or recovery behavior without proving the real boundary.

**Channel-boundary impact:** High — claims of CLI/Telegram parity are unsupported
until actual adapters and process lifecycle are observed.

**Scope-creep check:** Proposal — tighten the current runner/protocol and
artifact manifest. Do not build a new benchmark system.

**Smallest correction and existing seam:** Proposal — any required surface,
metric, or restart moment that is unavailable must produce blocked/inconclusive,
never ready. Add an actual CLI subprocess invocation with stdout/stderr/exit
capture and a guarded real Telegram/provider lane with provenance and an
independent witness.

**Closure test:** Proposal — the readiness command must fail closed when a
required cell is absent; a passing run must include CLI process artifacts,
durable receipts, Telegram transport receipts, provider identity, restart
boundaries, and an independent trace. Keep human usefulness and answer quality
as separate measures.

### F5 — Accepted work does not truthfully expose worker availability

**Classification:** Fact; Inference; Proposal; Evidence gap.

**Evidence:** Gateway is a long-running admission/drain process and never
constructs a session (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb:21-29`).
The documented worker is a separate foreground process; the gateway can admit
work while no worker answers (`documentation/guides/telegram.md:90-103`).

**Failure mode:** Inference — “accepted” can be read as “execution started”
while the request is only durable and queued. Silence then encourages duplicate
submissions or unsafe manual intervention.

**Root/system cause:** Inference — process supervision and user-facing task
state are separate. The current gateway has no authoritative worker-health
receipt in its acceptance/status contract.

**Security/reliability impact:** High — a user may resend work, cancel the wrong
occurrence, or assume a safety boundary was reached when no worker claimed it.

**Channel-boundary impact:** High — Telegram and CLI need the same distinction
between persisted, queued, claimed, waiting, and terminal.

**Scope-creep check:** Proposal — expose a bounded operational state and use the
existing external supervisor. Do not make the gateway execute work or add a
second executor.

**Smallest correction and existing seam:** Proposal — add worker availability to
the existing accepted/status projection, with a clearly defined stale-heartbeat
policy or an explicit “queued; worker not observed” state. Keep admission and
execution separate.

**Closure test:** Proposal — admit while worker is stopped, capture acceptance
and status, start worker, and prove the same request advances exactly once with
no duplicate effect. Repeat after worker crash/restart.

### F6 — User-facing references and control paths diverge across Telegram and CLI

**Classification:** Fact; Inference; Proposal; Evidence gap.

**Evidence:** Queue add generates a UUID and prints thread/request data
(`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:220-241`), while
comms request resolves an `r<10-hex>` reference through the comms store
(`gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:224-260`). CLI `ask`,
`resume`, `redirect`, and `cancel` are session/thread-oriented
(`gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:29-61,158-218`).

**Failure mode:** Inference — a person cannot reliably leave Telegram, use
durable CLI, and return to the same occurrence. The benchmark’s direct helper
can hide this because it does not exercise the CLI parser/process.

**Root/system cause:** Inference — two valid durable submission contracts were
not unified at the operator-handle boundary.

**Security/reliability impact:** High — ambiguity about the target is an
operator safety defect, especially when multiple requests share a thread.

**Channel-boundary impact:** High — it violates the proposed shared action
contract `status(ref)`, `cancel(ref)`, `redirect(ref)`, and
`answer_clarification(ref, answer)` (`docs/openclaw-chat-study-refresh/01-consolidated-study.md:184-197`).

**Scope-creep check:** Proposal — adapt existing CLI/comms commands to the
durable occurrence reference. Do not replace the durable thread authority
handle or add a universal routing layer.

**Smallest correction and existing seam:** Proposal — persist/display one
caller-bound short reference for each request and make CLI human controls
resolve it through the store; retain UUID/thread IDs in diagnostic/JSON output.

**Closure test:** Proposal — submit equivalent work through actual CLI and
Telegram, reopen the database, compare refs/status, and run two-reference
cross-target controls with stdout/stderr/exit assertions.

### F7 — Telegram-specific identity is in core validation; future channel capability is untyped

**Classification:** Fact; Inference; Proposal; Evidence gap.

**Evidence:** Core envelope validation requires `telegram:user:` and Telegram
chat prefixes (`gems/tamoz-comms/lib/tamoz/comms/inbound_envelope.rb:160-168`),
and `SurfaceDescriptor::KINDS` contains only `telegram`
(`gems/tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:30-45`). The transport
contract has only `authenticate`, `poll`, `deliver`, and `signal`
(`gems/tamoz-comms/lib/tamoz/comms/transport.rb:7-55`); it does not declare
text-input, edit, callback, or action capability.

**Failure mode:** Inference — adding a second channel now would require channel
rules in core and encourage conditionals or silent degradation at the gateway
and sink.

**Root/system cause:** Fact — the current implementation is Telegram-first,
not yet a channel-neutral contract.

**Security/reliability impact:** Medium now, High if expansion proceeds without
identity isolation and capability tests.

**Channel-boundary impact:** Direct — the proposed capability matrix is not yet
implemented or proven.

**Scope-creep check:** Proposal — do not add a production channel in this
slice. First close F1–F6 and the evidence gate. If expansion is later funded,
extend `SurfaceDescriptor` with an allowlisted capability contract and keep
worker semantics channel-blind.

**Smallest correction and existing seam:** Proposal — document the current
Telegram-only non-goal; later add adapter-owned namespace validation and
descriptor capabilities, not a plugin marketplace.

**Closure test:** Evidence gap — no non-Telegram contract run exists. The later
gate must use a limited fake surface to prove unsupported actions become typed
unavailable results and cannot broaden approval authority.

### F8 — Callback timestamps are derived from the wrong update field

**Classification:** Fact; Inference; Proposal.

**Evidence:** `Normalizer#normalize` derives `observed` from the top-level
`message.date` (`gems/tamoz-telegram/lib/tamoz/telegram/normalizer.rb:34-48`),
but callback envelopes pass that value even though the date belongs under the
callback’s embedded message (`gems/tamoz-telegram/lib/tamoz/telegram/normalizer.rb:69-80`). The callback fixture has
no date and asserts identity/digest only (`test/telegram_normalizer_test.rb:80-99`).

**Failure mode:** Inference — callback durable `observed_at` becomes the Unix
epoch for callback-only updates. Ack ordering is still governed by durable
resolution, but latency/ordering telemetry and any age-based analysis are
corrupted.

**Root/system cause:** Fact — the normalizer shares a message-derived timestamp
with callback and membership branches without branch-specific extraction.

**Security/reliability impact:** Medium — this is not an approval bypass, but
bad timing evidence can conceal callback delays and undermine recovery analysis.

**Channel-boundary impact:** Medium — callback is Telegram-specific, but the
observed event fact feeds channel-neutral evidence/telemetry.

**Scope-creep check:** Proposal — one normalizer correction and one assertion;
no event redesign.

**Smallest correction and existing seam:** Proposal — use the callback message
date when present; define an explicit ingestion-time fallback when absent.

**Closure test:** Proposal — assert callback `observed_at` equals its embedded
message date, is not epoch when a valid date exists, and has a documented
fallback for missing date.

### F9 — Human CLI streaming drops meaningful lifecycle events and can hide worker errors

**Classification:** Fact; Inference; Proposal; Evidence gap.

**Evidence:** The CLI stream mode includes tasks/updates/interrupts/checkpoints/
errors, but `render_stream_part` renders only custom, interrupt, and error parts
(`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:387-449`). The worker thread is
joined, but its exception is not directly re-raised by this method; durable
drain behavior must be the evidence source, not an assumption.

**Failure mode:** Inference — a CLI user may see no semantic progress and may
miss a background failure until a later status/exit path. This undermines parity
with the proposed bounded human card.

**Root/system cause:** Inference — stream events and durable comms milestones
are separate presentation contracts, and the human renderer intentionally
filters internal event types without a shared semantic projection.

**Security/reliability impact:** Medium — silent errors can produce duplicate
operator actions; no authority should be added in the renderer.

**Channel-boundary impact:** High for experience parity, low for core authority.

**Scope-creep check:** Proposal — route both surfaces through the same bounded
projection over durable facts; keep JSON/NDJSON lossless and diagnostics opt-in.

**Smallest correction and existing seam:** Proposal — improve the existing CLI
render/drain path and make worker failure propagation explicit; do not add raw
streaming or a second lifecycle store.

**Closure test:** Evidence gap — actual CLI subprocess test must capture
stdout/stderr/exit status for accepted, progress, interruption, failure, and
restart cases. Focused in-process tests are insufficient.

## 4. Missing seams, tests, telemetry, and evidence

### Delivery ambiguity

**Fact:** The drainer fences claim/send/outcome and maps an ambiguous send to
`unknown`; it does not blindly retry (`gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb:71-151`,
`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:141-157`).

**Evidence gap:** No current run proves a user-facing unknown card through live
Telegram, gateway restart, worker restart, and operator resolution. Add a
receipt lineage containing delivery id, request occurrence, effect execution,
transport result, and resolution actor. Unknown must remain visibly distinct
from failed and delivered.

### Identity and authorization

**Fact:** Callback binding checks surface revision, correspondent, conversation,
and the originating Telegram message; approval evidence is compared before
decision recording (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb:30-76`).
Pairing is durably approved through the comms store rather than a UI-only flag
(`gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:48-140`).

**Evidence gap:** The package lacks a two-correspondent/same-conversation and
two-conversation/cross-reference matrix for every new action, especially
clarification answers and exact-ref cancellation. Add tests for stale surface
revision, foreign callback message, foreign ref, ambiguous ref, and replayed
one-use decisions. No channel capability may grant approval evidence.

### Ordering, deduplication, and replay

**Fact:** Gateway persists the Telegram next offset only after durable admission
of the returned prefix (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb:174-205`),
and duplicate admissions do not re-render the accepted control
(`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:56-70`).
Callback acknowledgement follows durable resolution
(`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:35-37`).

**Evidence gap:** Existing tests do not cover ordering of two request-scoped
status projections when their outbox rows are interleaved, nor callback
`observed_at` correctness (F2/F8). Add a replay matrix for duplicate inbound,
duplicate worker event, duplicate sink push, duplicate callback, and reordered
outbox claim; assert idempotency by durable occurrence, never by answer text.

### Crash and restart

**Fact:** The current package has focused crash/replay tests and durable worker
claim/outbox concepts, but the refresh's declared C4 contract requires process
boundaries at acknowledgement, effect receipt, terminal enqueue, and ambiguous
send (`docs/openclaw-chat-study-refresh/specialist-reviews/01-gap-audit.md:251-264`).

**Evidence gap:** No current real process-level run proves all four boundaries,
worker-dead-after-admission, exact cancellation after restart, or no duplicate
unsafe effect. The closure artifact must include process ids/timestamps,
durable rows before/after restart, effect receipts, outbox claims/fences, and
transport observations.

### Resumed-session authority and catalog behavior

**Fact:** The worker grant is intersected with currently enabled sources, and a
thread stores a profile id rather than accepting authority from request payload
(`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:91-130`). Queue submission
validates/binds the named profile before making work visible
(`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:220-233`).

**Evidence gap:** The package does not prove resumed clarification/approval work
after a worker restart, profile revision, catalog change, or policy revision.
Add a restart test that records the original request, resumes with the stored
thread binding, verifies the current catalog digest and policy decision path,
and proves no payload or channel can widen authority. If policy/catalog changes
make the continuation unsafe, it must stop with an explicit durable state.

### Telemetry and human evidence

**Evidence gap:** Add accepted-receipt latency, first meaningful update,
maximum silence gap, worker-unavailable duration, clarification completion,
control-target accuracy, unknown-resolution time, duplicate-send count, and
terminal delivery success. Separately measure comprehension, trust calibration,
annoyance/attention burden, recovery, and answer usefulness; only real-provider
runs can support the last category. This follows the required separation in
`docs/openclaw-chat-study-refresh/02-decision-roadmap.md:115-130`.

## 5. Cross-document contradictions and unsupported claims

1. **Fact:** The review bar says the package cannot be ready with an unresolved
high-severity reviewer finding (`docs/openclaw-chat-study-refresh/00-review-bar.md:99-106`).
The consolidated study nevertheless describes a concrete clarification defect
and current readiness as `NEEDS FIXES` while proposing implementation slices
(`docs/openclaw-chat-study-refresh/01-consolidated-study.md:11-18,239-247`). This is internally consistent as a
study, but it cannot be used as implementation authorization until F1–F3 are
closed.

2. **Fact:** The package’s specialist/brainstorming material repeatedly marks
content acceptable but implementation/readiness as needing fixes; the correction
log records that the architecture specialist failed to materialize and the
fallback is explicitly not independent evidence
(`docs/openclaw-chat-study-refresh/04-correction-log.md:36-47`). The final package
must not cite that fallback as a passed independent architecture review.

3. **Fact:** The correction log records stale implementation-plan prose,
benchmark/index/runner disagreement, and no live credentialed evidence
(`docs/openclaw-chat-study-refresh/04-correction-log.md:74-87`). **Inference:** any index entry saying “ready” is
unsupported unless the admissibility rule and artifact set are reconciled.

4. **Fact:** The consolidated target says every action resolves one durable
occurrence and verifies caller/conversation binding
(`docs/openclaw-chat-study-refresh/01-consolidated-study.md:184-197`), but current cancellation is thread-wide
and request status aggregates delivery/effects across a conversation/thread
(`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb:96-121`; `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:522-529,611-713,988-994`).
**Inference:** the target contract is a proposal, not a current capability.

5. **Fact:** The target says typed `clarify` and `approval` are separate
(`docs/openclaw-chat-study-refresh/01-consolidated-study.md:174-183`), while current worker/sink code collapses
them (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-735`; `gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:248-257`). **Inference:** a
human-projection implementation must wait for F1 rather than papering over it
at the renderer.

6. **Evidence gap:** No source or current run proves the hypotheses that a
bounded card reduces duplicate submissions, improves comprehension, or makes
the experience enjoyable. Those remain hypotheses in
`docs/openclaw-chat-study-refresh/01-consolidated-study.md:92-102`, not product facts.

## 6. Smallest package corrections required before implementation

**Proposal — P0 safety and targeting correction:** Close F1, F2, and F3 before
changing human wording. Preserve interrupt kind, clarification parking/deadline
semantics, request-scoped delivery/effect truth, and exact-ref cancellation.
The closure suite must include two concurrent requests and restart/replay.

**Proposal — P0 evidence correction:** Make the benchmark fail closed on missing
required surfaces, metrics, and moments. Add actual CLI subprocess evidence and
guarded real Telegram/provider artifacts with independent trace provenance.
Do not promote focused fixtures to intelligence or live-experience evidence.

**Proposal — P1 shared projection correction:** After P0, define one bounded,
redacted human projection over durable facts. Keep diagnostics and JSON/NDJSON
lossless; never put model prose, raw tool arguments, paths, tokens, or approval
authority into the human card. Use the existing sink/status/CLI rendering seams;
do not create a second runtime or status cache.

**Proposal — P1 operational correction:** Add honest worker availability and
reconnect/unknown-delivery wording, backed by durable receipts and explicit
operator resolution. Define process-level restart scenarios before calling the
experience reliable.

**Proposal — deferred channel correction:** Do not add a production web/TUI or
generic channel marketplace in this package. Reconsider one small adapter only
after interruption correctness, target parity, worker-health truth, real
Telegram/provider evidence, and identity/isolation gates pass.

## 7. Verdicts

### Content verdict: MEETS BAR WITH GAPS

**Fact:** The package contains a coherent five-bet proposal, preserves the
hard-zero safety invariants, maps the existing durable seams, rejects a second
runtime/new channel for now, and explicitly distinguishes facts, hypotheses,
proposals, and evidence gaps (`docs/openclaw-chat-study-refresh/01-consolidated-study.md:40-110,225-237`).

**Inference:** It is sufficiently substantive for bounded implementation
planning after the corrections above, but the request/effect aggregation and
thread-wide cancellation findings were not explicit in the prior package and
must be added to the correction/roadmap record.

### Implementation-readiness verdict: NEEDS FIXES

**Fact:** F1 is a confirmed production-path clarification failure; F2 and F3
are current request/control truth defects; F4–F6 leave readiness and surface
parity unproved. The review bar forbids a ready claim with an unresolved
high-severity finding (`docs/openclaw-chat-study-refresh/00-review-bar.md:99-106`).

**Unresolved high-severity findings:** 6 — F1 clarification/approval collapse;
F2 cross-request status misattribution; F3 non-targetable cancellation; F4
non-admissible readiness evidence; F5 worker-availability ambiguity; F6
cross-surface handle/control divergence.

**Exact implementation gate:** Do not authorize the refresh implementation until
F1–F3 pass their two-request, replay, and restart closure tests; F4 produces
fail-closed admissible artifacts; and F5–F6 have actual process/surface parity
evidence. F7–F9 remain required corrections or explicit deferred evidence gaps,
but are not a basis to add a new channel now.
