# Facilitated brainstorming — Tamoz/OpenClaw chat experience refresh

Date: 2026-08-27

## Decision question

What is the smallest evidence-gated program that makes Tamoz useful,
interactive, and recoverable through real Telegram and durable CLI surfaces,
while preserving durable state, effect journaling, approval authority,
ownership fencing, delivery ambiguity, and channel isolation?

This session turns the three specialist reviews into options and testable bets.
It does not authorize implementation. A proposal below remains a proposal until
the owner accepts it through the later decision roadmap and its dependencies and
safety gates are met.

## Evidence boundary

- **Fact:** The previous study implemented meaningful durability and lifecycle
  plumbing, but its B0 benchmark uses a deterministic provider and fake
  transport. Its CLI fixture submits directly to `DurableRunner`, not through
  the real CLI (`test/support/openclaw_comms_runner.rb:26-32`;
  `test/support/openclaw_comms_fixture.rb:145-163,419-427`).
- **Fact:** The previous study already rejected a second runtime and placed
  boundary correctness, truthful status, bounded liveness, and recovery in that
  order (`docs/openclaw-chat-study/implementation-plan/README.md:34-55`).
- **Fact:** Focused and composition tests are plumbing evidence. The package has
  no current real-provider plus real-Telegram experience artifact and no human
  usefulness result (`docs/openclaw-chat-study/README.md:59-76`;
  `docs/openclaw-chat-study-refresh/specialist-reviews/01-gap-audit.md:75-94,379-403`).
- **Inference:** The refresh should preserve the previous study's durable core,
  but reopen its operator contract and evidence claims. “Phases implemented” is
  not equivalent to “the conversation is useful.”
- **Evidence gap:** No current artifact establishes real Telegram latency,
  callback responsiveness, user comprehension, return-after-time-away recovery,
  or real-provider answer usefulness.

## Evidence-backed problem statements

### P1 — A paused turn can become channel silence

- **Fact:** `Worker#settle_paused_view` projects every non-empty interrupt as
  `request.approval_request`, while a clarification descriptor has `kind:
  clarify` and no approval decision. `OutboxDeliverySink#decision_evidence`
  unconditionally reads approval-only fields
  (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-735`;
  `gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:138-156`;
  `gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:248-257`).
- **Inference:** Clarification is a correctness and recovery blocker, not a copy
  problem. A polished status card cannot recover a question that never reached
  the outbox.

### P2 — The operator does not have one durable work handle

- **Fact:** Telegram work is exposed by an `r<reference>`, CLI queue work prints
  a UUID, synchronous CLI ask drives the session directly, and CLI controls are
  generally thread-oriented (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:220-241`;
  `gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:29-40,158-218`;
  `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:224-255`).
- **Inference:** Cross-surface status, return, cancellation, and redirection are
  not one operator contract even when their underlying durable operations are
  individually valid.

### P3 — “Accepted” does not mean a worker is working

- **Fact:** Gateway and worker are separate foreground processes. The gateway
  can durably admit work while an absent worker means no answer is produced
  (`documentation/guides/telegram.md:90-103`).
- **Inference:** Better progress wording can deepen mistrust if it hides the
  difference between persisted, queued without a worker, and actively running.

### P4 — Current status is accurate but optimized for diagnostics

- **Fact:** Gateway status exposes phase, event, effect, capability, queue, and
  cancellation fields, while CLI session status and comms status expose
  different delivery truth (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_status.rb:18-78`;
  `gems/tamoz-agent-session/lib/tamoz/agent/session_status_projection.rb:18-37`;
  `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:286-321`).
- **Inference:** The user still has to translate internal lifecycle vocabulary
  into “what is happening?” and “what can I safely do next?”

### P5 — Progress is bounded, but not necessarily meaningful

- **Fact:** Milestones are coalesced and capped, and Telegram milestone text is
  currently `r<ref>: <phase>`
  (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:22-24`;
  `gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:123-161`).
- **Hypothesis:** Human-safe current/next-action cards will reduce perceived
  silence and resubmission, but this has not been measured.

### P6 — Safe delivery ambiguity is not yet a useful recovery experience

- **Fact:** Ambiguous external sends become `unknown` and are not blindly
  retried; operator resolution exists
  (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:222-233`;
  `documentation/reference/cli.md:134-149`).
- **Inference:** The safety boundary is correct, but a user who receives silence
  cannot distinguish failed work from a completed task whose final message may
  or may not have arrived.

### P7 — Benchmark readiness can hide missing operator surfaces

- **Fact:** Five B0 scenarios run Telegram only, and readiness filters typed
  unavailable metrics rather than blocking the cell
  (`test/support/openclaw_comms_runner.rb:41-48,133-168`). The canonical CLI leg
  bypasses argv, stdout, stderr, exit status, and process reopen.
- **Inference:** A green fixture benchmark is useful regression evidence but is
  not admissible evidence for durable CLI parity or operator experience.

### P8 — Usefulness and answer quality are unmeasured

- **Fact:** Existing executable metrics cover lifecycle plumbing, not operator
  comprehension, actionability, interruption burden, or answer usefulness
  (`docs/openclaw-chat-study/benchmark-protocol/02-scenario-catalog-and-scoring.md:39-60`).
- **Evidence gap:** The repository cannot currently say whether a person
  understands the state, chooses the right control, trusts completion and
  delivery correctly, or finds a real model answer useful.

## Divergent options

The options deliberately span product, interaction, architecture, operations,
and evidence. They are alternatives or ingredients, not current facts.

| ID | Option | Lens | Expected upside | Principal risk or unknown |
| --- | --- | --- | --- | --- |
| O1 | **Proposal:** Rewrite current acknowledgement, waiting, failure, and completion copy without changing state or identity. | Product | Fast visible improvement and low structural cost. | Cosmetic copy can mask P1–P3 and strengthen false confidence. |
| O2 | **Proposal:** Define one typed human card contract with state, ref, safe goal label, current action, next action, and orthogonal delivery state. | Interaction/product | Makes every update decision-oriented while retaining diagnostics separately. | A new projection can drift from durable facts or leak intent if it becomes a narrator. |
| O3 | **Proposal:** Use pull-only status after acceptance; suppress proactive progress except waiting and terminal transitions. | Interaction/operations | Lowest noise and simplest delivery behavior. | Long tasks may still feel dead; silence and resubmission hypotheses remain. |
| O4 | **Proposal:** Use one editable live card with a strict attention budget, plus mandatory waiting and terminal notices. | Interaction | Balances liveness with notification cost. | Edit receipts and platform behavior require real Telegram evidence; edits still consume rate and attention. |
| O5 | **Proposal:** Make clarification a first-class typed interrupt with a bounded question and same-occurrence answer/resume action. | Architecture/interaction | Closes a confirmed channel failure and enables real dialogue. | Answer correlation, expiry, redaction, and replay must preserve occurrence ownership. |
| O6 | **Proposal:** Project one short request reference across Telegram and actual CLI while retaining thread/occurrence IDs as internal authority handles. | Architecture/product | Enables return, exact targeting, and cross-surface reconciliation. | Resolution must remain caller-bound; a global or guessable reference would create isolation risk. |
| O7 | **Proposal:** Expose worker availability as a durable operational fact in acceptance/status and choose an explicit admit-or-queue policy when no worker is healthy. | Operations/architecture | Stops “accepted” from implying active execution. | Heartbeat freshness can lie; refusing admission and queueing each have product costs. |
| O8 | **Proposal:** Add a small declarative surface capability matrix to the existing descriptor before adding any new channel. | Architecture | Prevents future adapters from silently losing edits, callbacks, text input, or limits. | Premature abstraction if it becomes a plug-in framework instead of a closed contract. |
| O9 | **Proposal:** Add a single supervised operator launcher around the existing gateway and worker processes. | Operations | Reduces common “gateway up, worker absent” deployments. | Supervision does not replace user-visible health truth and can expand scope into deployment management. |
| O10 | **Proposal:** Build an admissibility-first benchmark lane: actual CLI subprocess, full required-surface matrix, process restarts, independent witness, and one guarded real Telegram/provider run. | Evidence/operations | Converts parity, latency, and recovery claims into observable evidence. | Credentials, private transport, external data, nondeterminism, and cost require explicit authorization and provenance controls. |
| O11 | **Proposal:** Add blinded comprehension and answer-usefulness studies alongside, not inside, plumbing scores. | Product/evidence | Tests whether cards and real answers help humans. | Small samples can be noisy; task rubrics and participant protocol must be declared before results. |
| O12 | **Proposal:** Build a local web/TUI now to provide rich cards, history, and controls. | Product/channel | Richest interaction surface and easier diagnostics. | Adds breadth before Telegram/CLI semantics are proven and risks creating another incomplete adapter. |
| O13 | **Proposal:** Stream raw model tokens, plans, and tool activity to create a lively feeling. | Interaction | Immediate visible motion. | Leaks data, confuses activity with progress, increases noise, and lets model text impersonate system truth. |
| O14 | **Proposal:** Let a model generate progress summaries from current execution state. | Product/architecture | Potentially natural language and task-specific updates. | Adds a nondeterministic effect, authority ambiguity, cost, replay questions, and prompt-injection exposure to a presentation path. |

## Assumptions to test

| Assumption | Label | How it could be wrong | Required observation |
| --- | --- | --- | --- |
| One short ref is easier than UUID/thread handles across surfaces. | **Hypothesis** | Users may prefer thread names or recent-task selection. | Two-open-request comprehension and target-accuracy test on Telegram and CLI. |
| A bounded current/next-action card feels more useful than lifecycle phase text. | **Hypothesis** | Copy may add reading burden without improving decisions. | Blinded state/ref/next-action comprehension and annoyance comparison. |
| One live card plus terminal notices is enough for long tasks. | **Hypothesis** | Some tasks need more milestones; some users want silence. | C10-style slow task with first-update, silence-gap, edit-count, and preference data. |
| Worker availability can be represented truthfully with a heartbeat. | **Hypothesis** | A fresh heartbeat may coexist with a wedged worker or saturated queue. | Kill, wedge, recover, and queue-pressure observations with declared freshness bounds. |
| Telegram and CLI can share semantics without byte-identical presentation. | **Inference** | Surface-specific shortcuts may cause control or delivery divergence. | Same scenario facts and outcomes through actual adapters; presentation may differ. |
| Real Telegram plus one provider run is enough to enter product learning. | **Proposal** | One happy path may miss callback, restart, unknown, and multi-ref failures. | Treat it as an entry gate only; no broad readiness verdict until the declared matrix passes. |

## Tensions and disagreement map

1. **Truth versus friendliness.** Lane B favors human-safe cards. Lane A warns
   that the actual CLI and real transport are absent from current evidence.
   Resolution: cards may improve presentation, but readiness depends on actual
   adapters and durable facts.
2. **Fast product value versus correctness first.** Copy and cadence are visible
   quickly; clarification currently has a confirmed failure path. Resolution:
   typed interruption correctness is a hard predecessor to claiming interactive
   dialogue.
3. **Liveness versus attention.** More pushes reduce silence but increase noise,
   rate pressure, and notification fatigue. Resolution: test one live card with
   bounded edits; waiting and terminal truth are never suppressed.
4. **Shared semantics versus surface fit.** Telegram wants compact cards and
   buttons; CLI needs TTY summaries plus machine-readable diagnostics.
   Resolution: require semantic parity, not byte-identical text.
5. **Acceptance availability versus operational honesty.** Queuing while the
   worker is absent preserves input; refusing admission avoids false hope.
   Resolution: record this as an owner decision and test either policy. Do not
   let acknowledgement imply execution.
6. **Channel neutrality versus unnecessary machinery.** Lane C identifies
   Telegram-specific identity and an untyped transport capability boundary, but
   all lanes reject expansion now. Resolution: a closed capability contract may
   be introduced only when needed by the selected interaction actions; no
   registry or plug-in marketplace.
7. **Safety versus conversational agency.** Telegram approval is deny-only under
   current evidence. Resolution: explain the operator route; do not convert a UI
   affordance into authority.
8. **Evidence rigor versus speed and privacy.** Real-provider/Telegram runs are
   necessary for experience claims but require credentials and may expose task
   data. Resolution: use a private, bounded, explicitly authorized cell with
   redacted provenance and a declared cleanup policy.

## Option clusters

### Cluster A — Presentation-only improvement

O1, O3, and parts of O4 can make the existing experience quieter or clearer
without changing semantics.

- **Inference:** This cluster is cheap, but insufficient alone because it does
  not close clarification, identity, worker-health, or evidence defects.
- **Decision use:** Retain its copy and attention ideas as acceptance criteria
  inside a stronger typed projection bet.

### Cluster B — One truthful operator contract

O2, O5, O6, and O7 establish typed interruption, one visible work handle,
human projection, and operationally honest state.

- **Inference:** This cluster attacks the root cause shared by all three lanes:
  durable components exist, but their operator-facing contract fragments at
  boundaries.
- **Tension:** It crosses several gems. The seams must stay separate and use
  shared semantics rather than one large “chat service.”

### Cluster C — Recovery and channel adaptation

O4, O8, and the recovery part of O6 define exact controls, bounded edits, and
explicit capability degradation.

- **Inference:** This cluster becomes valuable after stable refs and typed
  states exist. Before that, capability abstraction would encode an unstable
  contract.

### Cluster D — Operations and proof

O7, O9, O10, and O11 expose process truth and establish actual experience
evidence.

- **Inference:** O10 and O11 are mandatory for a readiness claim. O9 is optional
  because supervision cannot substitute for health/status truth.

### Cluster E — Premature breadth or unsafe liveliness

O12, O13, and O14 optimize surface richness or visible motion before the core
contract is proven.

- **Inference:** These options add cost and new failure modes without closing
  the confirmed blockers. They are discarded for the next program.

## Challenge to the strongest option

The strongest initial option is O2: a typed human projection with decision-
oriented cards. It directly addresses the experience complaint and reuses the
existing lifecycle/outbox seams. It is also the option most likely to create a
convincing but misleading demo.

Adversarial challenge:

1. **Fact:** A card cannot project a clarification that failed before outbox
   append (P1). Therefore O2 alone does not make the chat interactive.
2. **Inference:** A friendly `Working` label could hide an absent worker unless
   worker availability is a source fact (P3).
3. **Inference:** A “shared” card keyed by different CLI and Telegram handles
   would make divergence prettier rather than resolve it (P2).
4. **Safety risk:** Goal paraphrases, model-written phase summaries, paths, tool
   arguments, or provider payloads can leak data or impersonate authority.
5. **Reliability risk:** If `HumanProjection` becomes a new store or state
   machine, it duplicates lifecycle authority and can disagree after restart.
6. **Evidence risk:** Golden text tests can prove deterministic rendering while
   leaving real Telegram edits, notification previews, TTY behavior, and human
   comprehension unobserved.
7. **Maintenance risk:** One universal rendering abstraction can force Telegram
   and CLI into byte-identical output and accumulate channel conditionals.

Revised option:

- **Proposal:** Adopt O2 only as a pure, bounded projection over typed durable
  facts, after clarification kinds, stable refs, and worker availability are
  defined. Keep diagnostics separate, allow surface-specific rendering, forbid
  model-authored authority/status fields, and gate product claims on actual CLI,
  real Telegram, and comprehension observations.

This revision combines O2 with O5–O7 and moves O10–O11 from “later validation”
to part of the decision bar.

## Converged decision-ready bets

These five bets are ordered by dependency. They are proposed decisions for the
later consolidated study; they are not implementation authorization.

### Bet 1 — Preserve typed interruption semantics end to end

- **Proposal:** Split clarification from approval at worker projection. Add a
  bounded `waiting_for_user` clarification payload and same-occurrence answer
  action. Unsupported surfaces emit a typed unavailable result.
- **Owners/seams:** `Tamoz::Agent::Worker#settle_paused_view`;
  `SessionPlanOutcomes#clarification_descriptor`;
  `Tamoz::Comms::OutboxDeliverySink`; gateway input/callback routing. No new
  runtime or approval engine.
- **Tests:** Real clarify interrupt through worker-to-outbox; no
  `decision_evidence` lookup; one bounded question; paused occurrence; replay;
  wrong-correspondent and stale-occurrence rejection; text answer resumes the
  same occurrence; guarded Telegram delivery/answer observation.
- **Metrics:** clarification delivery rate; answer-to-resume latency;
  clarification completion rate; zero approval/clarification
  misclassification; zero cross-occurrence resumes.
- **Dependencies:** None beyond current typed interrupt descriptors and durable
  ownership. This is a P0 correctness gate.
- **Safety constraints:** Clarification answer is task data, never approval
  evidence; policy remains the sole approval authority; bound and redact the
  question; preserve occurrence/correspondent fencing.
- **Decision threshold:** Accept only if the owner agrees channel clarification
  is supported. Otherwise choose the explicit typed-unavailable path.

### Bet 2 — Give every operator-visible request one stable ref and honest work state

- **Proposal:** Project one caller-bound short ref through Telegram, attached
  CLI, queued CLI, status, cancel, and redirect. Expose persisted, queued without
  a healthy worker, working, and waiting as distinct facts. Keep thread and
  occurrence IDs internal.
- **Owners/seams:** Gateway admission/acknowledgement; `CommsStore` request
  resolution; CLI ask/queue/status rendering and command parsing; worker
  claim/health observation; existing session and request stores.
- **Tests:** Actual CLI subprocess with argv/stdout/stderr/exit status; print ref
  before long execution; reopen database and resolve it; equivalent Telegram
  flow; two open refs; exact-target status/cancel/redirect; caller isolation;
  worker killed after admission and restarted without duplicate effects.
- **Metrics:** acknowledgement p95 under 2 seconds when healthy; 100% admitted
  requests return or durably record a resolvable handle; control-target accuracy
  at least 95%; hard zero for cross-request action; worker-unavailable duration
  and accepted-to-claim latency reported separately.
- **Dependencies:** Owner must choose queue-versus-refuse behavior when worker
  health is stale. Bet 1 may proceed in parallel; both gate the human projection.
- **Safety constraints:** Refs remain correspondent/conversation bound and are
  not authority tokens; no legacy-row compatibility; no in-memory status source;
  accepted never implies started.

### Bet 3 — Add a bounded human projection and attention contract

- **Proposal:** Render state, ref, safe goal label, current action, next action,
  and orthogonal delivery certainty from existing facts. Default to one
  acceptance, one editable live card with at most two meaningful edits, mandatory
  waiting notice, and one terminal card on Telegram; use equivalent semantic
  cards in TTY. Keep JSON/diagnostic detail available explicitly.
- **Owners/seams:** `tamoz-comms` lifecycle/rendering and
  `OutboxDeliverySink`; gateway acknowledgement/status/control reply; CLI human
  rendering; current outbox coalescing and transport edit behavior.
- **Tests:** Golden semantic cards for accepted, queued, worker unavailable,
  working, clarification, approval, completed, failed, stopped, and delivery
  unknown; redaction and bounded-size tests; terminal reservation; confirmed-
  terminal-only history; diagnostics retain internal fields; Telegram capability
  fallback when edits/buttons are unavailable.
- **Metrics:** time to first meaningful update; maximum silence gap; pushes and
  edits separately; state/ref/next-action comprehension at least 90%, and at
  least 95% for waiting/cancel/unknown; attention efficiency and annoyance;
  zero false “delivered” judgments in the study sample.
- **Dependencies:** Bets 1–2 define the facts and handles this projection may
  render. Capability fields should be added only for actions actually required
  by this card contract.
- **Safety constraints:** Pure projection, not a store or state machine; no
  model narrator, raw plan/tool output, secrets, paths, provider payloads, or
  approval authority; unknown and terminal truth cannot be suppressed by a
  notification budget.

### Bet 4 — Make recovery and controls exact, visible, and non-destructive

- **Proposal:** Use exact-ref status/cancel/redirect; add a bounded “since you
  were away” read model; explain delivery uncertainty and the operator recovery
  path without automatic resend.
- **Owners/seams:** Gateway commands and callback routing; `CommsStore`
  status/history; `DeliveryDrainer` and outbox unknown resolution; CLI comms
  operations; existing generation/context controls.
- **Tests:** Two-ref cancel/redirect races; disconnect/restart/return; process
  restart at acknowledgement, effect receipt, terminal enqueue, and ambiguous
  send; no duplicate effect or terminal send; operator resolves unknown;
  confirmed-only history; context generation remains isolated.
- **Metrics:** recovery rate at least 95% for declared recoverable cases;
  return comprehension at least 90%; zero blind retries; unknown-resolution
  time; terminal delivery success separate from task completion.
- **Dependencies:** Stable refs and human states from Bets 2–3. Process-level
  harness and independent witness are supplied by Bet 5.
- **Safety constraints:** Cancellation does not claim an in-flight external
  effect stopped; redirect does not erase committed work; return cards never
  re-send unknown terminal content; ownership and delivery fences remain.

### Bet 5 — Replace readiness-by-fixture with an admissible experience gate

- **Proposal:** Keep deterministic B0 as plumbing regression evidence, but make
  required surfaces and metrics admissibility conditions. Add actual CLI
  subprocess execution, faithful liveness/restart/cancellation moments, an
  independent trace witness, and one bounded real-provider plus private Telegram
  lane. Measure answer usefulness separately from plumbing.
- **Owners/seams:** `OpenclawCommsRunner`; comms benchmark oracles and catalog
  state; actual CLI adapter; Telegram transport; real provider configuration;
  evidence manifests and publication/readiness logic.
- **Tests/evidence:** Removing one required surface produces non-ready; complete
  Track-A matrix has every declared cell; actual CLI stderr is free of unhandled
  worker exceptions; process M1–M6 observations; real send/edit/callback
  receipts; durable snapshot and independent trace digest agree; forced witness
  mismatch is a hard zero; blinded comprehension and task-specific answer rubric
  are predeclared.
- **Metrics:** latency to ack; first meaningful update; maximum silence;
  recovery and target accuracy; callback-ack latency; task and delivery success
  separately; answer relevance/correctness/completeness/actionability; sample
  count and run kind on every result.
- **Dependencies:** Bets 1–4 establish the interaction contract to evaluate.
  The first real happy path may run earlier as an evidence-discovery gate, but it
  cannot publish broad readiness.
- **Safety constraints:** Explicit authorization for external calls; private bot
  and bounded non-sensitive task; credentials never enter artifacts; provenance,
  cleanup, cost, model, transport, and git revision recorded; no fixture result
  relabeled as intelligence evidence.

## Explicitly discarded or deferred ideas

- **Discarded — O1 alone:** Copy polish without interruption, identity, and
  worker-health truth can make a broken path look trustworthy.
- **Discarded — O13:** Raw token, plan, and tool streaming is activity, not
  committed progress. It violates the desired attention and disclosure model.
- **Discarded — O14:** A model progress narrator introduces a new external
  effect and lets untrusted prose impersonate system state.
- **Deferred — O9:** A launcher/supervisor may improve deployment ergonomics,
  but it is not the root chat contract and cannot replace health truth. Revisit
  only after the worker-unavailable policy is measured.
- **Deferred — O12:** No production web/TUI or other channel until Telegram and
  actual CLI pass the shared contract and real-evidence gates.
- **Discarded:** A generic channel plug-in marketplace, new event bus, second
  runtime, or in-memory chat/status cache. Existing Gateway, Session, Worker,
  effect journal, store, outbox, and drainer remain the owners.
- **Discarded:** Automatic resend or a user-facing retry button for ambiguous
  unsafe delivery.
- **Discarded:** Telegram approval grant as a UI feature. Authority changes
  require policy evidence and a separate accepted decision.
- **Deferred:** Groups, media, broadcast, and multi-agent routing. They add
  identity and isolation dimensions before the one-user contract is proven.

## Facilitator record

I treated disagreement as a sequencing signal rather than forcing consensus.
Lane A's strongest claim is that current readiness evidence is inadmissible for
several operator surfaces. Lane B's strongest claim is that truthful internal
state still lacks a useful human contract. Lane C's strongest claim is that
clarification, identity, worker health, and channel capabilities must be fixed
without a new runtime. The convergence therefore puts interruption and handle
truth before presentation, retains the card proposal, and makes live evidence
part of the bar rather than a postscript.

I kept scope to Telegram and the actual durable CLI. I excluded production code,
tests, a new channel, deployment redesign, approval-policy expansion, model
reasoning changes, groups/media, and generic plug-in architecture. I challenged
the most attractive product option specifically for masking correctness and
evidence gaps. No brainstorm item is presented as an implemented fact or as
authorization to begin work.

## Verdicts

**Brainstorming/content bar: MEETS BAR.** The session restates the decision,
uses evidence-labelled problem statements, generates fourteen divergent options
across product, interaction, architecture, operations, and evidence, records
assumptions and tensions, clusters the options, challenges the strongest option,
converges to five owner/seam-specific testable bets, and records discarded ideas,
scope, and disagreement handling.

**Current evidence readiness: NEEDS FIXES.** The confirmed clarification
projection defect, divergent request handles, unobservable worker availability,
diagnostic-first human output, incomplete required-surface benchmark, fixture
CLI bypass, unfaithful timing/restart/cancellation moments, missing independent
witness, absent real Telegram/provider run, and absent comprehension/usefulness
evidence prevent an implementation-ready or experience-ready verdict. These
gaps constrain the later decision roadmap; this brainstorming report does not
close them.
