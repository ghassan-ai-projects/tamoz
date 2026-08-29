# Fourier lens — Tamoz/OpenClaw chat experience refresh

Date: 2026-08-27

## Scope, method, and evidence boundary

This brainstorming pass examines the chat system at seven time and ownership
scales: individual turn, conversation, work session, operator workflow, channel,
organization, and long-term learning/measurement. At each scale it asks what the
useful signal is, where latency or queues accumulate, what information is lost,
which feedback loop forms, what failure can recur, what safety property is at
risk, and what bounded experiment could resolve the uncertainty.

Evidence labels are used throughout:

- **Fact** — verified in current source, tests, or the named study/protocol.
- **Inference** — a conclusion derived from named facts.
- **Hypothesis** — plausible behavior that still needs measurement.
- **Proposal** — a future design, experiment, or decision rule.
- **Evidence gap** — an important claim the current repository cannot prove.

This is not implementation authorization. Deterministic-provider and fake-
transport results are plumbing evidence only. They do not show model
intelligence, answer usefulness, human comprehension, or live Telegram quality.

## Fourier finding

**Inference:** Tamoz is strongest at high-frequency correctness and weakest at
low-frequency continuity. Individual durable transitions have request, session,
effect, ownership, and outbox facts. The human experience degrades when those
facts must survive minutes of silence, several queued requests, a process
restart, a channel switch, an operator handoff, or months of benchmark drift.

The core mismatch is not merely “bad copy.” It is frequency aliasing:

- worker facts such as `claimed`, `running`, and `waiting` are sampled into a
  few human messages;
- Telegram edits can overwrite the visible history of intermediate states;
- quiet periods hide whether the cause is slow model work, queueing, a missing
  worker, a parked clarification, or delivery uncertainty;
- a green fixture benchmark samples durable rows but can miss the operator's
  actual command path, live timing, comprehension, and answer quality.

**Proposal:** preserve a lossless durable fact stream, define a small shared
semantic contract, and let each surface render that contract according to its
attention constraints. Do not collapse source facts, human wording, diagnostics,
and transport capability into one “unified projection” object.

## Scale 1 — individual turn

| Dimension | Fourier analysis |
| --- | --- |
| Signal | **Fact:** gateway admission commits the request and accepted delivery before worker execution (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:31-70`). Task and delivery are separate axes (`gems/tamoz-comms/lib/tamoz/comms/lifecycle.rb:7-24`). **Fact:** committed worker events are projected through `OutboxDeliverySink` (`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:28-161`). |
| Latency / queueing | **Fact:** the gateway and worker are separate foreground processes; admission can succeed while no worker answers (`documentation/guides/telegram.md:90-103`). **Evidence gap:** live Telegram acknowledgement, callback, first-meaningful-update, and terminal latencies have not been measured. B0 marks relevant wall-clock latency unavailable (`gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb:140-156`). |
| Information loss | **Fact:** milestone text is effectively `r<ref>: <phase>` (`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:123-161`). It preserves a lifecycle label but drops goal orientation, worker availability, safe next action, and expected wait. **Fact:** every non-empty interrupt is currently projected as `request.approval_request`, while clarification descriptors have no approval decision (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-735`; `gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:138-156`). |
| Feedback loop | **Hypothesis:** ambiguous silence causes the person to resend or ask `/status`; the extra request increases queue depth and notification traffic, extending the silence that triggered the resend. Exact Telegram duplicates are identity-safe, but a new update carrying the same intent is a new request. |
| Periodic failure mode | **Inference:** any task longer than the user's patience threshold repeatedly crosses a “still alive?” boundary. A clarification pause can turn this periodic uncertainty into permanent silence because the approval-only projection can raise before the question reaches the outbox (`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:186-220,248-257`). |
| Safety risk | Framework status derived from model prose could make untrusted text look authoritative. A reassuring terminal message could also merge `completed + delivery=unknown`, or invite a blind resend after ambiguity. |
| Concrete response | **Proposal — turn-state experiment:** drive accepted, queued, working, clarify, approval, completed, failed, stopped, and delivery-unknown facts through the existing worker/sink/gateway seams. Compare current text with a typed state/ref/next-action rendering. Measure acknowledgement latency, worker-unavailable detection, first meaningful update, maximum silence gap, clarification delivery/resume, state comprehension, and false “done/delivered” judgments. Require zero `KeyError`, zero fabricated milestone, and zero unknown-to-delivered coercion. |

## Scale 2 — conversation

| Dimension | Fourier analysis |
| --- | --- |
| Signal | **Fact:** confirmed successful terminal deliveries, not progress/control messages, enter conversation history (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:1084-1115`). Telegram exposes request references and conversation-bound status/control paths (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb`). |
| Latency / queueing | Multiple open requests queue within a conversation. The acknowledgement can say a request is behind earlier work (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission_acknowledgement.rb:8-29`), but later controls and cards do not consistently preserve one scannable request identity. |
| Information loss | **Fact:** Telegram uses short `r` references, while CLI `ask`/`queue add` use thread or UUID-oriented paths and `tamoz comms request` resolves a separate comms reference space (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:29-40`; `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:220-241`; `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:224-255`). The conversation therefore loses a portable human handle across surfaces. |
| Feedback loop | **Hypothesis:** notification noise makes users mute or ignore the channel; missed waiting/terminal transitions then cause stale tasks and more manual status queries. Conversely, too much coalescing can hide meaningful state changes and prompt resends. |
| Periodic failure mode | With two or more open refs, every control is a recurring targeting risk. Telegram redirect is ref-bound, Telegram cancel currently targets current-generation open work without a ref, and CLI controls are thread-oriented (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb:36-77,96-121`; `gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:158-218`). |
| Safety risk | Cross-request cancel/redirect, progress, approval, status, or delivery is a correctness and privacy failure. Context summaries or “since you were away” cards can also expose hidden conversation material if they echo raw summaries rather than bounded categories. |
| Concrete response | **Proposal — two-ref conversation experiment:** submit two requests, park one for clarification or approval, queue the other, then status/cancel/redirect each by visible ref from Telegram and actual CLI commands. Measure control-target accuracy, ref recall, queue comprehension, notification pushes versus edits, resend rate, and whether confirmed-only history remains intact. Pre-register cross-request action or disclosure as a hard zero. |

## Scale 3 — work session

| Dimension | Fourier analysis |
| --- | --- |
| Signal | A work session spans the gateway, request inbox, worker claim, durable session/effect receipts, outbox, and delivery drainer. **Fact:** the worker journals model/tool effects and settles occurrences (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:506-756`); the drainer fences send ownership and records ambiguity as `unknown` (`gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb`; `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:222-233`). |
| Latency / queueing | Queue delay, provider delay, approval/clarification wait, worker downtime, and delivery retry/unknown time are different queues but can all appear to the user as one silent open task. The current accepted message does not establish that a worker is healthy. |
| Information loss | A single `working` card can erase which queue currently owns the delay. Telegram edits further compress state history; CLI human mode ignores standard task/update/checkpoint stream parts (`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:387-449`). |
| Feedback loop | Worker failure causes silence; silence causes resends/status polling; more requests deepen the backlog; a restarted worker then emits a burst of updates, causing notification fatigue and future muting. This is a positive feedback loop across process health and human attention. |
| Periodic failure mode | Lease expiry, restart, process deployment, provider rate limit, and Telegram delivery drain create recurring pulses. The prior C4 protocol requires six restart boundaries, but the current B0 driver covers only a reduced fixture shape according to Lane A (`docs/openclaw-chat-study-refresh/specialist-reviews/01-gap-audit.md`, G9). |
| Safety risk | Restart can duplicate an effect or terminal send; a stale owner can cross the send boundary; delivery ambiguity can be retried blindly; cancellation can be reported as stopped before the runner observes it. These are existing protocol hard-zero classes (`documentation/benchmark/openclaw-chat-study/01-protocol-design.md:121-132`). |
| Concrete response | **Proposal — session kill/health matrix:** expose framework-owned worker availability as a bounded operational fact, then kill/restart gateway and worker independently at C4 M1–M6. Measure accepted-to-claim time, worker-unavailable duration, maximum user-visible silence, reference/sequence preservation, update burst size after recovery, effect executions, external send count, and unknown resolution time. Admission must never imply “working” without evidence. |

## Scale 4 — operator workflow

| Dimension | Fourier analysis |
| --- | --- |
| Signal | Operators pair correspondents, supervise gateway/worker processes, inspect status, handle policy-bound approvals, and resolve unknown delivery through CLI seams (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb`; `documentation/reference/cli.md:134-149`). |
| Latency / queueing | User work can wait on an operator who is unaware of the pause. Pairing code transfer, deny-only approval, delivery resolution, and process recovery are human queues outside the model/transport path. |
| Information loss | Telegram can show a waiting card without explaining that affirmative approval requires stronger local evidence. The user and operator do not share one stable request handle today. Pairing fixture paths bypass the actual operator command in current composition evidence (`test/canonical_cross_surface_composition_test.rb:171-191`). |
| Feedback loop | An under-explained blocked state produces repeated user attempts; operators see more requests but less causal context. If operators manually resend an unknown delivery to be helpful, the safety model is bypassed socially even when code refuses automatic retry. |
| Periodic failure mode | Shift changes, laptop restarts, token expiry, policy changes, and unattended weekends produce recurring operator gaps. A task that is safe in a continuously watched demo may be unusable in an intermittently staffed workflow. |
| Safety risk | A presentation feature must not create approval authority. Pairing/decision controls must remain actor-, conversation-, prompt-, digest-, expiry-, and policy-bound. Secrets and raw provider/tool arguments must not be placed in mobile cards. |
| Concrete response | **Proposal — operator handoff drill:** use the real pairing command, a clarify case, a deny-only approval, worker downtime, and an unknown delivery. Hand the workflow to a second operator using only durable refs/status. Measure time to identify the blocking queue, correct next action, number of hidden commands required, unsafe resend attempts, and successful recovery. Zero UI-created approval, zero authority from content, and zero secret/raw payload disclosure. |

## Scale 5 — channel

| Dimension | Fourier analysis |
| --- | --- |
| Signal | **Fact:** Telegram normalization preserves distinct update/message/reply/callback identities (`gems/tamoz-telegram/lib/tamoz/telegram/normalizer.rb`). `Telegram::Transport` maps delivery and callback acknowledgement to Bot API operations (`gems/tamoz-telegram/lib/tamoz/telegram/transport.rb:45-79`). |
| Latency / queueing | Telegram polling, Bot API rate limits, callback spinner latency, message edits, and delivery ambiguity differ from TTY/process latency. A nominally shared semantic event can have different observable timing and failure semantics per surface. |
| Information loss | **Fact:** core `InboundEnvelope` validation currently requires Telegram-prefixed identities and `SurfaceDescriptor` allows only Telegram (`gems/tamoz-comms/lib/tamoz/comms/inbound_envelope.rb:160-168`; `gems/tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:31,153`). **Fact:** `Comms::Transport` exposes `authenticate`, `poll`, `deliver`, and `signal` but no declared capability matrix (`gems/tamoz-comms/lib/tamoz/comms/transport.rb`). A future adapter can therefore silently lose edits, callbacks, text input, or threading. |
| Feedback loop | A noisy push channel encourages aggressive coalescing; a quiet TTY encourages richer progress. Forcing byte-identical presentation creates either Telegram overload or CLI under-information. Surface constraints therefore feed back into the semantic contract if they are not separated. |
| Periodic failure mode | Telegram rate-limit windows, long-poll reconnects, callback expiry, mobile notification batching, and local terminal disconnects create channel-specific cycles. A web surface would add browser reconnect, stale-tab, cache, session, and CSRF cycles; a TUI would add terminal resize, attach/detach, and process ownership cycles. |
| Safety risk | Unsupported capabilities must not disappear silently or broaden authority. A stale web card must not issue a control against a different request generation. Channel text and callback payload remain untrusted data. |
| Concrete response | **Proposal — capability degradation test:** express a minimal allowlisted capability descriptor at the existing `SurfaceDescriptor` seam, then run the same semantic facts through Telegram, TTY, and a deliberately limited fake surface. Assert explicit fallback/unavailable behavior for edit, callback ack, action buttons, text clarification, message limits, and thread replies. Measure semantic-field retention, attention events, control completion, and stale-control refusal. |

## Scale 6 — organization

| Dimension | Fourier analysis |
| --- | --- |
| Signal | Organization-level signal is not message volume. It is admitted work by owner/conversation, worker health, time spent queued/waiting/unknown, control accuracy, recovery, and verified task outcome. Current durable stores contain much of the raw execution/delivery truth, but no current evidence shows an operational service-level view. |
| Latency / queueing | Shared workers, operator availability, provider quotas, Telegram limits, and approval policy create fleet-level queues. A healthy median can hide one correspondent or policy class that is permanently starved. |
| Information loss | Aggregating all tasks into one “completion” or “responsiveness” number erases task-versus-delivery state, provider/transport confounds, user cohorts, and waiting causes. The benchmark protocol correctly uses per-axis verdicts, but current B0 completeness/readiness can still ignore unavailable required cells (`test/support/openclaw_comms_runner.rb:161-168`). |
| Feedback loop | Teams optimize visible benchmark numbers. If update count or latency becomes a target, implementations may emit meaningless milestones, reject slow tasks, or hide unavailable cells. If notification count is rewarded downward, waiting and terminal truth may be suppressed. |
| Periodic failure mode | Release cycles, credential rotation, provider model changes, policy-profile changes, on-call turnover, and workload seasonality can produce repeated regressions that per-commit fixtures do not capture. |
| Safety risk | Cross-conversation aggregation can leak content or identity. Operational pressure can encourage fixture results to be presented as real experience, or real-run controls to be weakened for a green report. |
| Concrete response | **Proposal — stratified operational review:** report queue/wait/unknown duration, worker availability, control errors, delivery outcomes, and verified completion by surface, scenario, run kind, provider/transport provenance, and declared privacy-safe cohort. Never aggregate away a hard zero or unavailable required cell. Review the worst cohort and tail, not only averages. |

## Scale 7 — long-term learning and measurement

| Dimension | Fourier analysis |
| --- | --- |
| Signal | **Fact:** the prior protocol defines eight axes, separate Track A/Track B claims, two agreeing witnesses, per-cell sample counts, and an append-only real-run scoreboard (`documentation/benchmark/openclaw-chat-study/01-protocol-design.md`; `documentation/benchmark/openclaw-chat-study/02-scenario-catalog-and-scoring.md`). |
| Latency / queueing | Fixture gates can run per change; real provider/transport and human-comprehension studies run more slowly. Product learning therefore arrives later than code feedback and can be ignored unless it has a scheduled decision cadence. |
| Information loss | **Fact:** current scenario prose/README, index state, and runner readiness disagree; the index says READY while prose still says INCOMPLETE, and five B0 scenarios omit the actual CLI surface while unavailable metrics are filtered from readiness (`documentation/benchmark/openclaw-chat-study/scenarios/README.md:84-116`; `documentation/benchmark/openclaw-chat-study/scenarios/SCENARIO_INDEX.json`; `test/support/openclaw_comms_runner.rb:41-48,161-168`). A proxy can therefore hide missing experience cells. |
| Feedback loop | A green fixture badge creates confidence, reducing pressure to run expensive live/user evidence. Missing live evidence then keeps product hypotheses untested, so future design decisions cite the same fixture proxy. This is a self-sealing measurement loop. |
| Periodic failure mode | Protocol/catalog drift, upstream provider drift, transport API change, stale thresholds, participant learning, and benchmark overfitting recur over months. Append-only scores without corrections or cohort/provenance context can create a false trend. |
| Safety risk | `fixture_published_as_real` and `artifact_mismatch` are existing hard zeros. A more subtle risk is optimizing human cards for benchmark comprehension while real users fail to complete useful work. Answer quality must remain a real-provider, task-rubric result, never a card/plumbing score. |
| Concrete response | **Proposal — measurement audit cadence:** encode required `(scenario, surface, run_kind)` cells as admissibility, reconcile index/prose/runner state, bind real artifacts to durable receipts plus independent traces, and run periodic comprehension/usefulness samples with first-attempt scoring. Track proxy-to-user divergence: fixture pass with live failure, comprehension pass with task failure, and low notification count with high resend/abandonment. |

## Cross-scale interactions that can reverse a local improvement

1. **Worker health → chat silence → resends → deeper queue.** A faster gateway
   acknowledgement is locally good, but misleading when no worker is healthy. It
   can increase accepted backlog and user retries. Worker availability must be a
   separate fact, not inferred from admission.

2. **More liveness → notification noise → muted channel → missed decisions.** A
   milestone cadence that improves C2 can reduce work-session success if the user
   mutes Telegram and misses clarification, approval, cancellation, or terminal
   truth. Measure pushes, edits, mutes/annoyance, resends, and decision completion
   together.

3. **More coalescing → lower cost → lost causal history.** Editing one card reduces
   attention and rate cost but can erase evidence that a task changed from queued
   to worker-unavailable to waiting. Durable facts must remain lossless, and an
   explicit status/reconnect view must reconstruct the current cause without
   inventing history.

4. **Stable internal thread → unstable human ref → unsafe control.** Durable
   ownership can be correct while a user switches from Telegram to CLI and cannot
   identify the same request. That produces wrong-target fear or action even when
   each surface passes isolated tests.

5. **Clarification type collapse → one turn failure → session starvation.** A
   high-frequency projection mismatch (`clarify` treated as approval) can park a
   request indefinitely. With ordered work, one invisible pause becomes a
   work-session queue and then an operator incident.

6. **Benchmark proxy → organizational confidence → user failure hidden.** B0 can
   prove durable rows while bypassing actual CLI parsing/output, omitting five CLI
   cells, using a deterministic provider, and using a fake transport. Treating
   this as readiness suppresses the live evidence that would reveal silence,
   callback delay, weak answers, or comprehension failure.

7. **New surface → richer view → multiplied stale-state risk.** A web dashboard
   may improve multi-ref visibility while adding cached state, reconnect, session
   identity, stale controls, and another delivery/capability matrix. It can hide
   rather than fix gateway/worker topology and reference divergence.

## Challenge: one unified human projection

The specialist reports converge on a bounded channel-neutral human projection.
That direction is useful, but “unified” is underspecified and can become a new
lossy authority boundary.

### What should be unified

**Proposal:** unify only the semantic minimum:

```text
request_ref
task_state + reason_category
delivery_state
worker_availability / blocking_queue
safe_phase
next_action
verification_class
source_fact_sequence / projection_revision
allowed_actions
```

These fields must be derived from framework-owned durable facts. The existing
owners remain `Lifecycle`, `Worker`, `SessionStatusProjection`, gateway status,
`OutboxDeliverySink`, `CommsStore`/`CommsOutbox`, and `DeliveryDrainer`; the
contract must not become a second store or event stream.

### What should not be unified

- Telegram cards, TTY lines, JSON diagnostics, and future web/TUI presentation.
- Push/edit/callback/TTY capabilities and rate/attention behavior.
- Task state and delivery state.
- User-safe wording and lossless operator diagnostics.
- Approval and clarification payloads/actions.
- Model answer quality and lifecycle/plumbing quality.

### Failure tests for the projection idea

**Proposal:** reject the projection design if any renderer cannot preserve
request ref, task state, delivery state, blocking cause, next action, and source
sequence; if it derives state from model prose; if a card edit destroys the only
recoverable evidence of a waiting/unknown state; if an unsupported action
silently disappears; or if projection code writes authority or execution state.

**Inference:** the smallest safe design may be a versioned semantic payload
produced at existing projection seams, not a new central `HumanProjection`
service/class. Prove the payload with golden/contract tests first; introduce a
new object only if duplication across the existing sink/status/rendering seams is
demonstrated.

## Challenge: “future local web/TUI” as the next channel

The architecture report recommends no immediate new channel and names a future
local web/TUI as the best candidate after Telegram/CLI gates. The defer decision
is sound. The combined “web/TUI” preference is not yet decision-grade.

**Fact:** core envelope and surface contracts are Telegram-closed today, and the
transport has no typed capability declaration (`gems/tamoz-comms/lib/tamoz/comms/inbound_envelope.rb:160-168`; `gems/tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:31,153`; `gems/tamoz-comms/lib/tamoz/comms/transport.rb`).

**Inference:** web and TUI are not one choice. A web surface adds browser/session,
CSRF, cache, stale-tab, reconnect, hosting, and remote-exposure questions. A TUI
adds terminal attachment, redraw, local process ownership, and accessibility
constraints. Both can duplicate status/control semantics before those semantics
are stable.

**Evidence gap:** there is no measured user failure that requires a third
surface rather than better Telegram/CLI semantics, and no comparison of web
versus TUI for the operator's actual workflow.

**Proposal — decision gate:** do not choose a production third channel until:

1. clarification, worker-health truth, request-ref parity, actual CLI black-box
   behavior, and one real Telegram/provider run pass;
2. a named high-value workflow still fails because Telegram/CLI cannot represent
   multi-ref history, diagnostics, or controls within their attention limits;
3. static or read-only prototypes of Telegram, TTY, TUI, and local web are tested
   on the same return/recovery and two-ref tasks;
4. the winning surface materially improves comprehension, completion, recovery,
   or operator time without adding a hard-zero or weakening isolation;
5. its identity, capability, stale-control, delivery, supervision, security, and
   operability contracts are explicit.

If a third surface becomes justified, the safest first slice is a read-only
operator view over existing durable facts. Mutation/control should follow only
after stale-view and request-target fencing pass. This is a proposal, not a
current recommendation to build it.

## Converged testable bets

### Bet 1 — Preserve interrupt type and expose the real blocking queue

- **Hypothesis:** distinguishing `clarify`, `approval`, worker-unavailable, and
  delivery-unknown will reduce silent/stale turns more than richer generic status
  copy.
- **Existing seams:** `Worker#settle_paused_view`
  (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-735`), clarification descriptor
  (`gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:138-156`),
  `OutboxDeliverySink` interrupt branches
  (`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:66-84,186-265`),
  gateway admission/status, and existing worker/request stores.
- **Measures:** clarification prompt delivery/resume rate; zero projection
  exceptions; worker-unavailable detection time; time in each blocking queue;
  maximum silence gap; user identification of the correct next actor/action.
- **Dependencies:** choose admission behavior when worker health is absent; define
  typed clarification answer binding. No new runtime or store.
- **Hard zeros:** clarification routed through approval evidence; authority from
  content; effect before evidence-bound approval; accepted/working claim without
  the corresponding durable fact; secret/raw payload disclosure.

### Bet 2 — Standardize semantic fields and request targeting, not rendering

- **Hypothesis:** one visible ref plus task state, delivery state, blocking cause,
  and next action will improve cross-surface comprehension and control accuracy
  without forcing identical Telegram/CLI output.
- **Existing seams:** `Comms::Lifecycle`, gateway acknowledgement/status/commands,
  `SessionStatusProjection`, CLI rendering/session/worker commands,
  `CommsStore#requests_by_reference`, and `OutboxDeliverySink`.
- **Measures:** state/ref/next-action comprehension; control-target accuracy with
  two refs; CLI-to-Telegram ref resolution; false completed/delivered judgments;
  semantic-field retention by renderer; diagnostic opt-in rate.
- **Dependencies:** Bet 1's blocking-state vocabulary; one explicit current-schema
  request-reference contract; actual CLI command/subprocess coverage.
- **Hard zeros:** cross-request status/control/delivery; task/delivery-axis merge;
  state inferred from model prose; unsupported action silently omitted; progress
  or unconfirmed output entering history.

### Bet 3 — Make benchmark admissibility prove the surface and moment it names

- **Hypothesis:** required-cell and faithful-moment gating will remove false
  readiness and localize failures before product decisions use fixture proxies.
- **Existing seams:** `test/support/openclaw_comms_runner.rb` required surfaces and
  `metrics_ready?`; `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb`;
  actual `Tamoz::Agent::CLI#run`; `Telegram::Transport`; C2/C4/C8 scenario drivers;
  protocol/index/readiness artifacts.
- **Measures:** 100% required `(scenario, surface, run_kind)` cell presence;
  actual argv/stdout/stderr/exit-status coverage; C2 real/controlled timings; C4
  M1–M6 process boundaries; C8 runner-observed cancellation; callback ack receipt
  and latency; durable-receipt/independent-trace agreement.
- **Dependencies:** black-box CLI harness; guarded private Telegram/provider
  environment; process-level restart controls; reconciled scenario metadata.
- **Hard zeros:** fixture published as real; artifact mismatch; missing required
  cell reported ready; ack before admission; stale owner send; duplicate effect or
  terminal send; blind retry after unknown; false stopped claim.

### Bet 4 — Optimize attention and recovery together before adding a channel

- **Hypothesis:** a bounded live card plus explicit waiting/terminal interrupts
  and a read-only return summary will reduce resends and abandonment without
  increasing missed decisions.
- **Existing seams:** `OutboxDeliverySink#push_milestone`, `CommsOutbox`
  coalescing, `Comms::Rendering`, gateway status/control replies, confirmed-only
  history in `CommsStore`, and delivery uncertainty in `DeliveryDrainer`/outbox.
- **Measures:** pushes, edits, meaningful transitions, maximum silence, resends,
  clarification/decision completion, annoyance, return comprehension, recovery
  rate, unknown-resolution time, and answer usefulness as a separate real-provider
  rubric.
- **Dependencies:** Bets 1–3; stable semantic payload; instrumentation that does
  not record sensitive content; a small declared participant/sample protocol.
- **Hard zeros:** terminal/waiting truth suppressed by a notification budget;
  automatic resend of unknown delivery; hidden context echoed in a return card;
  model answer score merged with plumbing/comprehension score; third-channel work
  before its decision gate passes.

## Options and discarded ideas

- **Keep current internal lifecycle text and only increase cadence — discarded.**
  It raises attention cost without restoring goal, blocking cause, or next action.
- **Stream model tokens/raw plans — discarded.** It is not durable liveness,
  increases leakage and ordering risk, and violates the C2 contract.
- **Build a central model narrator — discarded.** Status would become
  non-deterministic/model-authored and could cross the authority boundary.
- **Create a second chat runtime, event bus, or status cache — discarded.** The
  gateway, worker, session/effect journal, stores, outbox, and drainer already own
  the necessary facts.
- **Use one byte-identical renderer for all surfaces — discarded.** It aliases
  different attention and capability constraints into the semantic contract.
- **Build local web/TUI now — discarded for the next slice.** It multiplies
  identity, capability, stale-state, and operational frequencies before current
  Telegram/CLI semantics and evidence are closed.
- **Collapse all outcomes into a satisfaction score — discarded.** It hides hard
  zeros, unavailable cells, task/delivery divergence, and provider/transport
  confounds.

## Verdicts

**Brainstorming/content bar: MEETS BAR.** This pass covers all seven required
scales; identifies signal, queueing, information loss, feedback, periodic
failure, safety risk, and an experiment at each; challenges both the unified
projection and future web/TUI choice; records cross-scale reversals, discarded
ideas, and four bounded bets mapped to existing seams and measures.

**Current evidence readiness: NEEDS FIXES.** The repository has meaningful
fixture plumbing evidence, but the confirmed clarification projection defect,
worker-health ambiguity, split human request handles, actual-CLI bypass, missing
required surface cells, reduced C2/C4/C8 moments, absent independent witness,
and no real Telegram/provider or human-usefulness evidence block a decision-grade
claim about the current chat experience. Fixture results remain plumbing only;
they do not establish agent intelligence or answer usefulness.
