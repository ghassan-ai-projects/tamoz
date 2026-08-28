# OpenClaw/Tamoz chat experience refresh — consolidated study

Date: 2026-08-27

## Executive decision

Tamoz should not add another production chat channel yet. The immediate
problem is not lack of channel breadth; it is that the existing Telegram and
durable CLI paths do not present one truthful, actionable work session.

The prior study substantially improved durability: admission, lifecycle state,
outbox fencing, delivery ambiguity, cancellation visibility, context controls,
and pairing are real seams with focused plumbing tests. The refresh found a
more important boundary failure: clarification interrupts can be routed into
an approval-only projection and fail before a question reaches the channel.
It also found that the benchmark and CLI parity claims are broader than their
actual executable coverage.

The recommended next program is five ordered bets:

1. Preserve interruption type end to end. A clarification is a question; an
   approval is a policy-bound decision. They need different payloads, actions,
   and channel projections.
2. Give every operator-visible request one caller-bound reference and one
   honest work state, including the difference between accepted, queued without
   a worker, running, waiting for a person, and terminal.
3. Add a bounded human projection over the existing durable facts. The default
   card says state, reference, safe goal label, current action, next action, and
   delivery certainty. Diagnostics remain available explicitly.
4. Make control, reconnect, and unknown-delivery behavior exact and visible.
   /status, cancel, redirect, clarification answers, and operator handoff
   must identify the same durable occurrence.
5. Replace fixture readiness with an admissible experience gate: actual CLI
   subprocess evidence, faithful restart/cancellation moments, independent
   traces, real Telegram/provider evidence, and separate human usefulness
   measures.

This is a proposal, not a claim that the implementation already provides it.

## Evidence boundary

### Confirmed facts

- Telegram admission durably creates the request and accepted delivery before
  worker execution
  (gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:31-70).
- Task state and delivery state are separate
  (gems/tamoz-comms/lib/tamoz/comms/lifecycle.rb:7-24).
- Milestones are bounded/coalesced and terminal deliveries are reserved in the
  outbox
  (gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:28-161).
- Unknown external delivery is not blindly retried
  (gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:222-233).
- settle_paused_view labels every non-empty interrupt as
  request.approval_request, while clarification_descriptor emits
  kind: clarify without an approval decision
  (gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-734;
  gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:145-153).
- decision_evidence unconditionally fetches approval evidence, so a clarify
  descriptor can raise before channel delivery
  (gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:248-257).
- Telegram identities are normalized distinctly, but core envelope validation
  and surface kinds are Telegram-specific
  (gems/tamoz-telegram/lib/tamoz/telegram/normalizer.rb;
  gems/tamoz-comms/lib/tamoz/comms/inbound_envelope.rb:160-168;
  gems/tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:31,153).
- The gateway and worker are separate foreground processes; the gateway can
  admit work while no worker answers
  (documentation/guides/telegram.md:90-103).
- Telegram exposes short request references, while CLI queue/ask and comms
  operations use different UUID/thread/reference paths
  (gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:220-241;
  gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:224-255).
- B0 uses a deterministic provider and fake transport; five scenario legs are
  Telegram-only, unavailable metrics can be filtered from readiness, and the
  canonical CLI helper bypasses the actual CLI
  (test/support/openclaw_comms_runner.rb:41-48,133-168;
  test/support/openclaw_comms_fixture.rb:145-163,419-427).

### Inferences

- A user can see a truthful acceptance and still believe the agent is silent
  because worker health, semantic progress, and next action are absent.
- A durable operation can be correct while a user fears canceling the wrong
  request because references and controls differ by surface.
- More frequent internal lifecycle text would increase noise without solving
  the missing question, action, and outcome semantics.
- A green fixture result can create a self-sealing confidence loop if required
  surfaces and real moments are represented as unavailable but readiness still
  passes.

### Hypotheses requiring measurement

- A state/reference/next-action card reduces duplicate resubmissions and
  improves comprehension compared with r<ref>: <phase>.
- Explicit worker-unavailable state reduces the “is it alive?” status loop.
- One editable live card plus mandatory waiting and terminal notices balances
  comprehension and notification burden.
- A human can use the same short reference across Telegram and CLI without
  cross-request control errors.
- Better projection wording improves interaction only if real model answers
  remain useful; plumbing and answer quality must be scored separately.

### Evidence gaps

There is no current real Telegram/provider run proving acknowledgement latency,
callback acknowledgement, first meaningful update, process restart behavior,
human comprehension, answer usefulness, or perceived enjoyment. Focused tests,
fixture transports, local fixture servers, and deterministic providers prove
plumbing only.

## Root causes

### 1. Pause semantics collapse at the channel boundary

The engine has typed interrupt descriptors, but the worker and outbox project a
non-empty interrupt set through an approval event. This is the confirmed
production-path defect. The fix belongs at the existing worker-to-sink seam;
it does not justify a second runtime.

### 2. Two durable submission contracts were treated as one surface

Telegram enters through gateway admission and CommsStore references. CLI ask
and queue add drive Session/DurableRunner directly and expose different handles.
The benchmark helper hides this by submitting directly instead of invoking the
CLI. The result is a durable system without a portable operator work handle.

### 3. Internal diagnostic truth is not paired with human meaning

The status projection correctly retains phase, event, effect, capability, and
reason (gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_status.rb:18-78),
but the default conversation needs a narrower, redacted projection that
answers “what happened, what is happening, and what can I do?”.

### 4. Evidence completeness was weaker than the study’s scenario bar

The B0 fixture is valuable regression evidence, but it is not a real operator
experience. It currently permits missing surface cells and does not execute all
declared restart or cancellation moments. The study must make missing required
cells inconclusive or blocked, never ready.

## Target interaction contract

The target is a projection over existing durable facts:

- accepted(ref, worker_availability)
- queued(ref, ahead_count)
- working(ref, safe_phase, next_action)
- waiting_for_user(ref, kind: clarify|approval, bounded_question_or_impact, actions)
- progress(ref, safe_phase, next_action)
- completed(ref, verification: verified|response_only|not_verified)
- failed(ref, reason_category, next_action)
- stopped(ref, effect_uncertainty, next_action)
- delivery: pending|delivered|failed|unknown

Task state and delivery state remain orthogonal. A presentation projection may
choose wording, layout, verbosity, or Telegram edit behavior, but it may not
invent a transition, evaluate approval, retry an unknown unsafe send, or put
model-authored prose in an authority field.

The default human card has five bounded fields:

    [r7f3a91c2e · Working]
    Task: make the landing page blue
    Now: applying the approved change
    Next: I’ll verify the result and send the answer
    Controls: /status r7f3a91c2e · /cancel r7f3a91c2e

This is a proposal. The existing diagnostic projection and JSON/NDJSON stream
remain available for operators and automation. Human output must not expose raw
tool arguments, paths, tokens, provider payloads, or model-generated approval
instructions.

### Interruption contract

- clarify: bounded question, text-answer action, same occurrence, expiry and
  caller/conversation binding.
- approval: policy/engine decision, evidence-bound actions, one-use receipt,
  and no UI-created authority.
- worker_unavailable: explicit operational condition, not working.
- blocked_on_operator: named safe operator route; never imply a Telegram
  denial authorized an operation.

### Controls

All surfaces adapt to the same durable actions:

- status(ref)
- cancel(ref)
- redirect(ref, replacement_text)
- answer_clarification(ref, answer_text)
- approve(ref, decision_receipt) only when policy/evidence permits
- deny(ref, decision_receipt)

Text commands, buttons, and CLI flags are adapters. They must resolve the
durable occurrence, verify the caller/conversation binding, and report the
resulting state using the same visible reference.

## Interaction rules

Telegram’s default should be one acceptance, one editable live card, at most
two meaningful edits, and one terminal card per request. Waiting and terminal
transitions interrupt quiet mode. No-visible-change heartbeats do not notify.
The CLI TTY should show the same semantic cards; JSON remains lossless and
diagnostic. Explicit status/context/history requests may disclose more bounded
detail.

On reconnect or status after a gap, show at most one “Since you were away” card
with active references, last confirmed state, delivery certainty, and next
action. It must never resend an unknown terminal answer automatically.

## New channel decision

Do not add a production channel in the next slice. First pass interruption
correctness, human projection, request-reference parity, worker-health truth,
and real Telegram/provider evidence. If those gates pass and a new surface is
still needed, choose one small local web or TUI adapter over the same durable
contract. A web/TUI is a candidate, not a combined implementation commitment;
the choice should follow a measured user need for richer history, controls, or
diagnostics.

Do not build a generic channel plugin marketplace, multi-agent router, second
chat runtime, event bus, or status cache for this problem.

## Hard-zero safety invariants

- The model may propose; policy and the effect/approval control plane decide.
- External and nondeterministic work remains journaled through
  EffectDispatcher; renderers do not call providers or tools.
- Request, decision, and delivery ownership/fence checks remain authoritative.
- unknown is never silently converted to delivered and never blindly retried
  for an unsafe external effect.
- Confirmed terminal content alone enters conversation history; milestone
  projections do not become memory.
- Channel capabilities cannot broaden approval authority.
- Real-run artifacts record provider/transport provenance, durable receipts,
  and an independent trace; fixture output is not intelligence evidence.

## What ready means

This study is ready to drive implementation only as a staged program. It is not
evidence that the current chat experience is ready for an intelligence or
enjoyment claim. The first implementation gate is the clarification path and
request-local status/control truth. Before human-card wording is claimable,
the system must close the clarification path, make delivery/effect status
request-local, and make cancellation exact-reference scoped. The first
evidence gate is a real, private Telegram/provider run with durable receipts
and an independent witness. Product learning starts only after the system can
show the same truthful work session through actual Telegram and actual CLI
paths.

## Product-engineering corrections

The final three-lens review sharpened the implementation gate with findings
that were not explicit in the first consolidation:

- CommsStore#conversation_runtime_status accepts a request ID but aggregates
  delivery and effect state at conversation/thread scope
  (gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:522-529,611-713).
  A human card over that aggregate could make the wrong request look complete
  or delivered.
- Gateway cancellation is thread-oriented and does not consume a request
  reference (gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb:96-121;
  gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:988-994). Exact-ref
  cancellation is a proposal, not current behavior.
- The proposed clarification answer action has no durable comms ingress;
  ordinary text is admitted as a new request and callbacks resolve approval
  decisions only (gems/tamoz-comms/lib/tamoz/comms/commands.rb:7-20;
  gems/tamoz-comms/lib/tamoz/comms/admission.rb:36-47,89-121).
- A safe goal label needs a deterministic framework-owned producer and
  redaction tests. It must not be generated by a model narrator.

Therefore Slice 0 must close typed interruption and request/control ownership
before Slice 1 can claim a human projection. The implementation-readiness
verdict remains NEEDS FIXES until those gates and the evidence gate pass.
