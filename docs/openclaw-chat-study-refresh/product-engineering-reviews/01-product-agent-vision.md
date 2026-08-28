# Product-engineering review 1: product usefulness and Tamoz agent vision

Review lens: whether the proposed conversation contract lets a human delegate work, understand progress, redirect safely, recover, and return later, while extending Tamoz's existing durable runtime. This is a bounded review of the refresh package and the current implementation seams. It is not an implementation approval.

## 1. Scope and sources inspected

**Fact (review scope).** I read `AGENTS.md:1-114`, `docs/subagent-orchestration.md:1-78`, `docs/openclaw-chat-study-refresh/00-review-bar.md:1-117`, `docs/openclaw-chat-study-refresh/specialist-reviews/01-gap-audit.md:1-697`, `docs/openclaw-chat-study-refresh/specialist-reviews/02-interaction-product.md:1-373`, `docs/openclaw-chat-study-refresh/specialist-reviews/03-chat-telegram-architecture.md:1-381`, `docs/openclaw-chat-study-refresh/brainstorming/01-facilitator.md:1-454`, `docs/openclaw-chat-study-refresh/brainstorming/02-fourier.md:1-370`, `docs/openclaw-chat-study-refresh/01-consolidated-study.md:1-247`, `docs/openclaw-chat-study-refresh/02-decision-roadmap.md:1-170`, and `docs/openclaw-chat-study-refresh/03-evidence-index.md:1-68`. I also inspected `docs/openclaw-chat-study-refresh/README.md:1-41` and `docs/openclaw-chat-study-refresh/04-correction-log.md:1-94`.

**Fact.** I inspected the existing seams in `gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-768` (`settle_paused_view`, `emit_approval_request`), `gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:138-156` (`clarification_descriptor`), `gems/tamoz-agent-session/lib/tamoz/agent/session_status_projection.rb:19-37,76-105` (`document`, `next_action`), `gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:28-42,123-161,192-265` (`EVENT_KINDS`, `push_milestone`, `decision_evidence`), and `gems/tamoz-comms/lib/tamoz/comms/lifecycle.rb:12-40` (task and delivery states).

**Fact.** I inspected command and ingress seams in `gems/tamoz-comms/lib/tamoz/comms/commands.rb:7-60`, `gems/tamoz-comms/lib/tamoz/comms/admission.rb:36-47,89-121`, `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb:13-121`, `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb:10-87`, `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:31-90`, and `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission_acknowledgement.rb:10-29`.

**Fact.** I inspected persistence and delivery ownership in `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:367-431,522-549,601-639,660-713,1084-1115` (`conversation_status`, `status_projection`, `conversation_runtime_status`, `delivery_state_for`, request-reference lookup, history, cancellation, and terminal-delivery history), `gems/tamoz-comms/lib/tamoz/comms/delivery.rb:25-121`, and `gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb:12-151`.

**Fact.** I inspected the CLI path in `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:96-123,387-449,480-599`, `gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:29-40,122-218`, `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:195-241,268-315`, `gems/tamoz-agent-cli/lib/tamoz/agent/cli_rendering.rb:73-122,140-220`, and `gems/tamoz-agent-cli/lib/tamoz/agent/cli_prompt_adapter.rb:26-55`, plus `scripts/start-tamoz-comms.sh:84-183` and `documentation/guides/telegram.md:84-150`.

**Fact.** I inspected benchmark/provider boundaries in `test/support/openclaw_comms_runner.rb:13-32,41-48,133-168,425-439`, `test/support/openclaw_comms_fixture.rb:75-119,145-168,419-427`, and `test/benchmark_comms_b0_test.rb:198-227,282-338`. I ran `rbenv exec ruby -Itest test/sqlite_comms_store_test.rb` (42 runs, 219 assertions, 0 failures/errors/skips) and `rbenv exec ruby -Itest test/comms_gateway_test.rb` (35 runs, 194 assertions, 0 failures/errors/skips). These are plumbing tests; they are not real-provider or perceived-usefulness evidence.

**Evidence gap.** I did not run a real-provider, real-Telegram, restart, or multi-request end-to-end journey. The report therefore treats those as unproven, regardless of fixture results.

## 2. Hard-zero risks and invariant checks

| ID | Classification and invariant | Severity | Status |
|---|---|---:|---|
| HZ-1 | **Fact / invariant:** a clarification must not be represented or rendered as approval. `gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-768` routes all non-empty interrupts through `request.approval_request`; `gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:145-156` creates a `kind: clarify` descriptor. | High | Open; confirmed implementation defect |
| HZ-2 | **Fact about current code / Proposal as invariant:** status for one request must not expose another request's delivery state. `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:522-528` calls `delivery_state_for(surface_id, conversation_id)`, and `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:701-713` aggregates rows by surface and conversation. | High | Open; confirmed seam defect |
| HZ-3 | **Fact / invariant:** rendered cards and buttons are proposals, not authority. `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb:21-43,66-87` binds callback surface, revision, correspondent, conversation, and message before recording a decision. | High | Guarded in the inspected path; preserve and add adversarial tests |
| HZ-4 | **Fact / invariant:** an ambiguous delivery remains `unknown`; it is not silently retried as though delivery failed. `gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb:142-151` maps `Comms::AmbiguousDeliveryError` to `status: 'unknown'`. | High | Internal behavior preserved; user recovery remains underspecified |
| HZ-5 | **Fact / invariant, bounded to inspected seams:** `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:19-53,75-86` routes its model and tool calls through `EffectDispatcher.run`; `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:33-65,90-104` prepares the journal decision and returns recorded outcomes; `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_call.rb:50-86` and `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_tool_call.rb:74-103` use the same dispatcher. The inspected CLI renderer functions only print verification/projection/receipt fields (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_rendering.rb:73-122,140-220`) and contain no provider/tool dispatch. The package places the fix at the existing seam and rejects a second runtime (`docs/openclaw-chat-study-refresh/01-consolidated-study.md:112-119`). | High | Direction is sound; broader target evidence incomplete |
| HZ-6 | **Fact / invariant:** fixture/provider plumbing cannot establish agent intelligence. `test/support/openclaw_comms_runner.rb:13-19,29-32` declares a fixture run, deterministic provider, and fake transport; `test/support/openclaw_comms_fixture.rb:75-119` supplies the fake transport path. | High | Open evidence gate |

## 3. Findings ordered by severity

### H-01 — Clarification is currently approval-shaped

**Classification: Fact.** `gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-768` sends every non-empty interrupt through `request.waiting` plus `request.approval_request`, and `gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:192-265` renders an approval prompt whose `decision_evidence` fetches `descriptor.fetch('decision').fetch('required_evidence')`. The clarification descriptor in `gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:138-156` has `kind: clarify`, question, context, and plan identity, not a decision evidence object.

**User-visible failure.** A human asked to answer a question can receive approve/deny semantics, or the render can fail while trying to fetch approval-only fields. The user cannot tell whether the agent needs information or authorization.

**Root cause (Inference).** The existing pause/interrupt projection is approval-centric and has not yet been split into typed clarification and approval projections.

**Impact.** High: it breaks delegation at the first point where the agent needs human judgment and risks an unsafe or nonsensical control.

**Scope-creep check (Proposal).** Add typed projection/rendering and reuse the existing interrupt, outbox, callback, and status seams. Do not add a second runtime, token-streaming protocol, or model-written narrator.

**Smallest correction (Proposal).** Make `clarify` and `approval` distinct event kinds with distinct required fields and controls. Keep clarification answer handling durable and revision-bound.

**Existing owner/seam (Fact).** The current owners are `gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-768`, `gems/tamoz-agent-session/lib/tamoz/agent/session_status_projection.rb:19-37,76-105`, `gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:28-42,192-265`, `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:31-90`, `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb:21-87`, and `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:33-65`.

**Closure evidence/test (Proposal).** Add focused tests for clarify render, approval render, malformed cross-kind payload rejection, stale revision rejection, and durable resume after a clarification answer. Run the exact focused files plus a real ingress journey.

### H-02 — The proposed answer control has no demonstrated durable ingress

**Classification: Fact.** `gems/tamoz-comms/lib/tamoz/comms/commands.rb:7-20,32-60` has no answer command. `gems/tamoz-comms/lib/tamoz/comms/admission.rb:36-47,89-121` routes ordinary non-command text as a new request. `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb:10-87` resolves approval callbacks only.

**User-visible failure.** A user who follows a proposed “answer clarification” control can have the answer admitted as a new task, or have no supported path to answer a remote clarification at all. Return-later behavior is therefore not complete.

**Root cause (Inference).** The package defines the target control before defining a channel-neutral command/intent and durable occurrence binding.

**Impact.** High: the conversation cannot reliably progress through a clarification pause.

**Scope-creep check (Proposal).** Use one explicit durable command or reply-bound action through existing gateway admission. Do not reinterpret all plain text, which would destroy the current new-request behavior.

**Smallest correction (Proposal).** Specify `/answer <ref> <text>` or an equivalent typed reply action, including request reference, occurrence/revision, expiry, and idempotency. Persist and route it through the existing request/interrupt seam.

**Closure evidence/test (Proposal).** Add command parsing, wrong-reference, stale-occurrence, duplicate-answer, and resume tests for Telegram and CLI; add a real-provider-independent ingress test and a real channel run for perceived behavior.

### H-03 — Request status can report conversation-wide delivery as request-local truth

**Classification: Fact.** `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:522-528` obtains runtime delivery through `delivery_state_for(surface_id, conversation_id)`, and `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:701-713` aggregates outbox rows by surface and conversation. `gems/tamoz-comms/lib/tamoz/comms/delivery.rb:25-121` has no request identifier field in its attributes, initializer, or wire representation.

**User-visible failure.** Two requests in one conversation can cause status for request A to report delivery caused by request B, making “did my task complete?” unreliable.

**Root cause (5 Whys, Inference).** The card needs request-local delivery truth; delivery rows lack request ownership; the store therefore uses conversation scope; conversation scope is the available lookup; the proposed human contract has not frozen the ownership key.

**Impact.** High: the core return-later promise becomes misleading precisely when multiple tasks overlap.

**Scope-creep check (Proposal).** Add the smallest existing-domain ownership association to the outbox/delivery record or authoritative request-to-delivery index. Keep conversation aggregate as a separate aggregate, not as a substitute.

**Smallest correction (Proposal).** Freeze request-local delivery identity before implementation and cover two concurrent requests, stale rows, unknown delivery, and terminal delivery.

**Closure evidence/test (Proposal).** Extend SQLite store and outbox tests; run a two-request integration journey through status and delivery.

### H-04 — Durable CLI work has no proven return-later human handle

**Classification: Fact.** `gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:29-40,122-218` creates/uses UUID and thread-oriented operations, while `gems/tamoz-agent-cli/lib/tamoz/agent/cli_rendering.rb:73-122,140-220` renders terminal result content without the proposed reference in the final card. `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:195-241,268-315` prints a queued UUID/thread. The inspected rendering path in `gems/tamoz-agent-cli/lib/tamoz/agent/cli_rendering.rb:73-122,140-220` does not render the comms milestone stream.

**User-visible failure.** A user who queues work and returns later may know a thread or UUID but not have the same stable conversation reference, progress card, or explicit recovery affordance. A foreground CLI failure can be silent from the user's perspective.

**Root cause (Inference).** The package target is channel-neutral, but the CLI's durable session and the comms request projection are not yet joined by a frozen handle contract.

**Impact.** High for the stated multi-surface promise; lower if CLI is explicitly excluded from the first slice.

**Scope-creep check (Proposal).** Either define one CLI request handle over the existing durable request, or explicitly mark CLI return-later as a later surface. Do not build another session runtime.

**Closure evidence/test (Proposal).** Add a subprocess queue/return/status/recover test and document the CLI boundary in the roadmap.

### H-05 — Benchmark readiness can mask missing named surfaces

**Classification: Fact.** `test/support/openclaw_comms_runner.rb:41-48,133-168` filters unavailable metric values, and `test/support/openclaw_comms_runner.rb:425-439` drives C2 crash/recover without a slow-liveness measurement. `test/benchmark_comms_b0_test.rb:198-227` checks artifact readiness while `test/benchmark_comms_b0_test.rb:282-338` refuses fixture publication. This proves a useful guardrail, not the human experience.

**User-visible failure.** A package may appear ready while Telegram, CLI, restart, or real-provider evidence is absent.

**Root cause (Inference).** Artifact completeness and execution admissibility are mixed with surface availability.

**Smallest correction (Proposal).** Make each required matrix cell explicitly `pass`, `fail`, or `inconclusive/blocked`; never let unavailable required cells disappear from readiness.

**Closure evidence/test (Proposal).** Add a negative readiness test and one real channel/restart evidence record.

### H-06 — “Safe goal label” has no source, owner, or redaction contract

**Classification: Evidence gap.** The target card requires a safe goal label (`docs/openclaw-chat-study-refresh/01-consolidated-study.md:27-29,161-172`), but the inspected status projection (`gems/tamoz-agent-session/lib/tamoz/agent/session_status_projection.rb:5-8,19-37,76-105`) excludes model output, remote content, and authority payloads without defining the label producer.

**User-visible failure (Hypothesis).** Labels may be absent, leak request content, or vary across surfaces, weakening recognition on return.

**Smallest correction (Proposal).** Define a deterministic, framework-owned category/label source and redaction test. Do not let a model narrate authority or status.

### H-07 — Roadmap sequencing contradicts the package's own dependency order

**Classification: Fact.** `docs/openclaw-chat-study-refresh/02-decision-roadmap.md:46-68,152-152` places human projection in Slice 1 before handles/health in Slice 2 and depicts the sequential slice order; `docs/openclaw-chat-study-refresh/01-consolidated-study.md:19-32` places handles/state before projection in its five ordered bets.

**User-visible failure (Inference).** Implementers can ship a card whose reference, worker availability, and request-local delivery semantics are not yet authoritative.

**Smallest correction (Proposal).** Reorder the roadmap so identity/ownership, typed interruption, and health/failure semantics precede the projection, or explicitly label Slice 1 as non-claimable scaffolding.

### Medium findings

**M-01 — Worker availability lacks a durable freshness rule. Classification: Evidence gap.** The target contract includes `worker_availability`, but `scripts/start-tamoz-comms.sh:84-183` starts gateway and worker separately and performs startup checks; no inspected source establishes ongoing supervision or a heartbeat freshness window. Correction: define `available`, `starting`, `stale`, and `unknown` from an existing durable signal before rendering availability.

**M-02 — “Since you were away” lacks a read boundary. Classification: Evidence gap.** The phrase is proposed in `docs/openclaw-chat-study-refresh/01-consolidated-study.md:208-210`, but the inspected history/terminal-delivery paths in `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:535-549,1098-1115` do not establish a user read cursor or snapshot boundary. Correction: define a last-seen cursor or use neutral “Recent update” language.

**M-03 — Target states do not yet have a frozen mapping to lifecycle states. Classification: Inference.** `gems/tamoz-comms/lib/tamoz/comms/lifecycle.rb:12-40` defines accepted/queued/running/waiting/completed/failed/blocked/stopped and delivery pending/delivered/failed/unknown, while `docs/openclaw-chat-study-refresh/01-consolidated-study.md:144-154` also specifies accepted, working, progress, and completed verification. Correction: publish one mapping table and test it.

**M-04 — Attention-budget language is not an enforcement mechanism. Classification: Hypothesis.** The product options and hypotheses identify concise cards and bounded updates (`docs/openclaw-chat-study-refresh/brainstorming/01-facilitator.md:127-136,145-150`; `docs/openclaw-chat-study-refresh/specialist-reviews/02-interaction-product.md:273-294`), but no inspected seam enforces a human attention budget. Correction: keep it as a product hypothesis until measured with a bounded journey; do not turn it into a second event system.

## 4. Missing seams, tests, telemetry, and evidence

**Inference from the cited seams.** Missing or incomplete seams are: typed clarification ingress (`gems/tamoz-comms/lib/tamoz/comms/commands.rb:7-60`; `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb:21-87`); request-local delivery ownership (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:522-528,701-713`; `gems/tamoz-comms/lib/tamoz/comms/delivery.rb:25-121`); a stable cross-surface request handle (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:220-241`; `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission_acknowledgement.rb:10-29`); worker-health freshness (`scripts/start-tamoz-comms.sh:84-183`); CLI durable return-later projection (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_rendering.rb:140-220`); and explicit recovery UX for `unknown` delivery (`gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb:142-151`).

**Proposal.** Add only the following tests before broadening scope: typed clarify/approval render tests; durable answer and resume tests; stale/duplicate/wrong-reference control tests; two-request delivery isolation; restart/recovery with unknown outcome; worker unavailable/starting/stale mapping; and CLI queue/return/status. Keep existing callback binding and effect-journal tests as hard gates.

**Evidence gap.** Missing evidence is a real-provider run, real Telegram send/receive, gateway-worker restart, ambiguous delivery recovery, multi-request same-conversation run, and a human-readable perceived-usefulness evaluation. The current fixture runner is explicitly fixture/deterministic/fake (`test/support/openclaw_comms_runner.rb:13-19,29-32`) and its fixture transport is supplied by `test/support/openclaw_comms_fixture.rb:75-119`; those paths cannot supply the missing live or human-evaluation claims.

## 5. Contradictions and unsupported or overclaimed statements

**Fact.** The package simultaneously makes human projection the early implementation slice and identifies handles/health as later dependencies: `docs/openclaw-chat-study-refresh/02-decision-roadmap.md:46-68,152-152` puts projection in Slice 1 and handles/health in Slice 2, while `docs/openclaw-chat-study-refresh/01-consolidated-study.md:19-32` orders handles/state before projection. Resolve this before implementation.

**Fact.** The target clarification control is specified as `answer_clarification(ref, answer_text)` in `docs/openclaw-chat-study-refresh/01-consolidated-study.md:174-197`, but the current command table has no answer command (`gems/tamoz-comms/lib/tamoz/comms/commands.rb:7-60`) and callback resolution handles approval decisions (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb:21-87`). The target behavior is therefore a proposal, not an existing capability.

**Fact.** “Completed verification” is a target state (`docs/openclaw-chat-study-refresh/01-consolidated-study.md:144-159`); current worker completion text and CLI rendering provide verified answer/artifact content (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:796-815`, `gems/tamoz-agent-cli/lib/tamoz/agent/cli_rendering.rb:140-220`) but do not by themselves prove cross-surface reference, delivery, or return-later semantics.

**Fact.** The benchmark artifacts and focused tests establish deterministic plumbing only: `test/support/openclaw_comms_runner.rb:13-19,29-32` declares fixture/deterministic/fake execution, and `test/benchmark_comms_b0_test.rb:198-227,282-338` checks fixture artifact readiness and refuses fixture publication. They do not support claims that a real model reasoned well, that Telegram works, or that the conversation is useful to a human.

## 6. Smallest package corrections required before implementation

1. Freeze request identity and request-local delivery ownership.
2. Split clarification from approval in the contract, payload schema, renderer, and controls.
3. Define one durable answer ingress with occurrence/revision, expiry, and idempotency semantics.
4. Define the stable handle and the supported CLI/Telegram return-later boundary.
5. Define worker availability freshness and `unknown` recovery semantics.
6. Define safe-goal-label ownership/redaction and a read boundary for away-state language.
7. Reorder the roadmap or mark projection-before-identity as non-claimable scaffolding.
8. Change readiness to expose every required unavailable evidence cell as inconclusive/blocked, then add real-provider/channel/restart evidence gates.

**Proposal.** These corrections are the smallest package-level freeze. They do not authorize production edits or introduce a second runtime.

## 7. Separate verdicts

**Content verdict: MEETS BAR WITH GAPS.** **Inference from `docs/openclaw-chat-study-refresh/01-consolidated-study.md:19-38,142-210` and the cited findings above.** The package has a coherent human-facing direction: stable references, bounded projection, typed waiting, explicit controls, recovery, and admissibility-first evidence. It is not yet content-complete because clarification ingress, request-local delivery truth, health freshness, and the roadmap dependency order remain unresolved.

**Implementation-readiness verdict: NEEDS FIXES.** **Fact.** The inspected code has confirmed high-severity seam defects for clarification rendering (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-768`; `gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:192-265`) and conversation-wide delivery aggregation (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:522-528,701-713`), and it lacks demonstrated answer ingress (`gems/tamoz-comms/lib/tamoz/comms/commands.rb:7-60`; `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb:21-87`) and return-later evidence (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:220-241`; `test/benchmark_comms_b0_test.rb:198-227`). Fixture tests passing does not close those gaps (`test/benchmark_comms_b0_test.rb:282-338`).

**Unresolved high-severity findings: 7.** H-01, H-02, H-03, H-04, H-05, H-06, and H-07 remain open at report time. H-06 is an evidence/contract gap rather than a confirmed production defect; it is counted because the proposed card depends on it.

**Exact deviations from the assigned protocol.** Only the owned report and owned progress log were written. No production code, tests, fixtures, support files, configuration, lockfiles, sibling reports, or git metadata were changed; no commit was made; no scratch or generated artifact was created. The progress log did not exist at the start of this review, so it was created and updated append-only. No additional research was performed after the synthesis checkpoint.
