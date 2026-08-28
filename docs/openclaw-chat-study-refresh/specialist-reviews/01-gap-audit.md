# Lane A — Gap audit

Date: 2026-08-27

## Scope and method

This is a re-audit of the earlier OpenClaw/Tamoz chat study after Phases 0–3.
The question is not whether the new durable machinery exists; it is whether an
operator can use and recover a turn through the actual Telegram and durable CLI
surfaces, and whether the benchmark proves that experience.

I read the required report, review-log, implementation-plan, implementation-bar,
benchmark-protocol, scenario catalog/index, and phase evidence in full. I then
traced the current paths:

* Telegram production path: CLICommsCommands#comms_serve builds a
  Tamoz::Telegram::Transport, Gateway#serve_once polls and admits normalized
  envelopes, Gateway::Admission#admit_request persists the request and accepted
  reply, the separate worker consumes the request, OutboxDeliverySink projects
  committed facts, and DeliveryDrainer calls the transport. Sources:
  gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_commands.rb:37-85,
  gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_shared.rb:153-177,
  gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb:21-29,174-205, and
  gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:31-70.
* Durable CLI path: CLI#run dispatches ask, which directly drives a durable
  Session; queue add writes directly to the durable request inbox and prints a
  UUID; worker later drains it. Sources:
  gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:96-123,156-181,
  gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:29-40, and
  gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:195-242.
  tamoz comms request is a separate SQLite query for comms-admitted R<ref>
  requests, not a query for CLI queue UUIDs:
  gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:224-260.
* Benchmark path: the B0 runner uses a deterministic provider and fake transport;
  its “CLI” legs call a fixture helper that submits directly to
  DurableRunner, while only four of nine scenarios drive both nominal surfaces.
  Sources:
  test/support/openclaw_comms_fixture.rb:145-163,419-427 and
  test/support/openclaw_comms_runner.rb:13-48,133-168.

Evidence labels in this report are:

* Fact — verified in current source, test, or a reproducible run.
* Inference — conclusion from named facts.
* Hypothesis — plausible operator effect not yet measured.
* Proposal — closure or future behavior.
* Evidence gap — an important claim the repository cannot currently prove.

I ran the relevant tests with the pinned Ruby through rbenv: the canonical
composition test passed (1 run, 106 assertions), B0 passed (14 runs, 151
assertions), gateway passed (35 runs, 194 assertions), and the focused callback,
progress, cancellation, reconnection, context, pairing, SQLite, and drainer
suites passed. test/agent_cli_test.rb exited 0 with 33 runs and 753 assertions,
but emitted an unhandled background CheckpointConflictError from
CheckpointStore#open_writer at
gems/tamoz-sqlite/lib/tamoz/sqlite/lease_operations.rb:50; that is recorded
as an evidence defect below. These are plumbing tests. None is intelligence,
perceived-usefulness, real-provider, or live-Telegram evidence.

## Changed, stale, and contradictory claim ledger

| ID | Earlier claim | Current audit result |
| --- | --- | --- |
| L1 | The Phase 3 log says the canonical test composes “CLI and Telegram projections” and the whole story is complete (docs/openclaw-chat-study/08-review-log.md:205-236; docs/openclaw-chat-study/implementation-plan/evidence/phase-3/implementation-review.md:41-49). | Narrowed. The story composes durable rows through a fixture helper, not the CLI command/parser/output path. It is strong plumbing evidence, not operator-surface parity. |
| L2 | All nine B0 scenarios are “ready with empty pending seams” (docs/openclaw-chat-study/08-review-log.md:233-236). | Technically true only for the fixture runner’s local status. C2, C3, C4, C7, and C8 are explicitly Telegram-only, and their parity values are unavailable; metrics_ready? ignores unavailable values. This is contradictory with the protocol’s requirement that every scenario run on both surfaces. |
| L3 | Every scenario runs on both durable CLI and Telegram (docs/openclaw-chat-study/benchmark-protocol/02-scenario-catalog-and-scoring.md:8-10; docs/openclaw-chat-study/benchmark-protocol/scenarios/00-implementation-bar.md:22-28). | False at current B0. The runner’s SURFACES_DRIVEN has CLI only for C1, C5, C6, and C9 (test/support/openclaw_comms_runner.rb:41-48,133-135); B0 asserts this reduced matrix (test/benchmark_comms_b0_test.rb:test_all_nine_catalog_scenarios_score_with_an_empty_pending_seam). |
| L4 | Callback queries are acknowledged immediately after durable admission and before processing (docs/openclaw-chat-study/implementation-plan/evidence/phase-2/implementation-review.md:40-43; 08-review-log.md:207-216). | Timing claim unproved and wording is imprecise. Gateway::Admission#route_admission resolves and durably consumes the callback decision before calling acknowledge_callback (gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:31-38; gateway_callbacks.rb:10-16,21-63). No live acknowledgement latency is measured. |
| L5 | The scenario README says the index is not consumed and scenarios remain incomplete (docs/openclaw-chat-study/benchmark-protocol/scenarios/README.md:84-116). | Stale. B0 now consumes SCENARIO_INDEX.json and produces artifacts (test/support/openclaw_comms_runner.rb:62-83); the index marks C1–C9 READY (SCENARIO_INDEX.json:19-31 and corresponding entries). The README, scenario front matter, index, and B0 tests disagree. |
| L6 | The benchmark plan expected comms oracles/runner work in the existing eval path and a later real executor (docs/openclaw-chat-study/benchmark-protocol/03-implementation-plan.md:36-39,59-107). | Partially landed, structurally different. Oracles are in gems/tamoz-evals-runner, but the comms runner is caller-owned test support (test/support/openclaw_comms_runner.rb:26; test/test_helper.rb:44-46). The shipped script/benchmark_comms_run is hardwired to fixture output (script/benchmark_comms_run:38-53,74-94). |
| L7 | Phase 3 records C8 cancellation as complete while naming the engine-observed-before-settle edge and missing failed-settle leg (docs/openclaw-chat-study/implementation-plan/evidence/phase-3/implementation-review.md:94-108). | Still open, not a closed operator proof. The oracle itself records engine_observed_before_settle as unavailable (gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb:597-629), and the runner stamps the clean-stop observation through a store seam (test/support/openclaw_comms_runner.rb:787-835). |
| L8 | The earlier study correctly says no live Telegram, real provider, or usefulness claim exists (docs/openclaw-chat-study/08-review-log.md:201-203; docs/openclaw-chat-study/implementation-plan/evidence/phase-3/implementation-review.md:99-108). | Confirmed, but now a delivery blocker rather than a future footnote. No current command or artifact provides a Track-B comms run with real provider, real Telegram delivery/ack receipts, and two agreeing witnesses. |

## Concrete gap ledger

### G1 — B0 has no real-provider/real-transport mode

Class: Fact; evidence gap.

OpenclawCommsRunner hardcodes RUN_KIND = 'fixture', a scripted provider,
and a no-egress transport (test/support/openclaw_comms_runner.rb:26-32).
script/benchmark_comms_run loads an external fixture factory and always prints
fixture: true (script/benchmark_comms_run:38-53,85-94). The planned B1
real executor remains a plan, not an implementation
(docs/openclaw-chat-study/benchmark-protocol/03-implementation-plan.md:87-107).

Impact: There is no evidence that an actual model answer can complete the
turn, that a real Telegram user sees the lifecycle, or that a provider/API
failure is intelligible to the operator. A deterministic answer is not
intelligence evidence.

Closure: Add a guarded Track-B executor and one private, credentialed
happy-path run. Record provider/model class, Telegram transport class, durable
receipts, and an independent trace digest; readiness must publish only when both
witnesses agree.

### G2 — “Ready” does not require the declared surfaces

Class: Fact; high-impact benchmark defect.

The runner defaults five scenarios to ['telegram']
(test/support/openclaw_comms_runner.rb:41-48,133-135). The B0 test explicitly
expects that shape and expects C2 parity to be unavailable
(test/benchmark_comms_b0_test.rb:test_all_nine_catalog_scenarios_score_with_an_empty_pending_seam,
test_scenarios_without_a_cli_leg_keep_typed_unavailable_parity). Yet
metrics_ready? discards unavailable metric hashes before deciding ready
(test/support/openclaw_comms_runner.rb:161-168). This conflicts with the
scenario bar’s “both surfaces” requirement.

Impact: A green B0 result cannot establish CLI experience or cross-surface
parity for five scenarios. It also allows a missing required cell to look like
successful readiness.

Closure: Make required surface execution an admissibility check. A missing
surface or required metric must be inconclusive/blocked, never ready.
Add a regression test that removes one CLI leg from C2 and asserts non-ready
status and no publishable axis.

### G3 — The benchmark’s “CLI” is not the CLI

Class: Fact.

OpenclawCommsFixture#submit_cli_task is a helper over
submit_cli_request, which calls
@runtime.session_for(thread_id).app.durable_runner.submit directly
(test/support/openclaw_comms_fixture.rb:145-163,419-427). The canonical test
uses this helper (test/canonical_cross_surface_composition_test.rb:209-216);
pairing approval also calls store.approve_pairing directly
(test/canonical_cross_surface_composition_test.rb:171-191). No CLI argv
parser, process, stdout, stderr, or exit status is involved.

Impact: CLI-specific defects in command routing, runtime configuration,
human rendering, JSON output, file reopening, and process supervision can pass
the “cross-surface” composition test.

Closure: Add a black-box durable-CLI composition test that invokes the
actual Tamoz::Agent::CLI#run (and, for the unattended path, tamoz queue add
and tamoz worker --once), captures output and exit status, and compares those
observations with the Telegram leg.

### G4 — Durable CLI identity is disconnected from Telegram comms identity

Class: Fact; inference.

queue add generates a UUID, submits an ordinary durable request with
delivery: :queue, and prints that UUID
(gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:220-241).
ask also creates a random UUID and directly drives Session
(gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:29-40). By
contrast, tamoz comms request accepts R<reference> and resolves rows through
CommsStore#requests_by_reference
(gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:224-255).
The oracle openly records that CLI-queued work has no comms conversation
visibility (gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb:525-547).

Impact: An operator who starts durable work in the CLI cannot use the same
reference/status/reconnect contract as a Telegram request. The fixture’s
digest-derived CLI IDs (test/support/openclaw_comms_fixture.rb:151-163) hide
this production mismatch.

Closure: Choose and implement one contract: either route durable CLI
submissions through a shared request/reference projection, or give CLI queue
requests a first-class CLI status/reconnect command. Test the actual command
output, durable lookup, restart, and unknown-delivery case.

### G5 — tamoz ask has no comms acknowledgement lifecycle

Class: Fact; inference.

The ask path runs drive_turn inside run_durable immediately
(gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:29-40), while
Telegram first persists admission and an accepted outbox row
(gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:49-67).
Human final rendering prints the verified answer/status but no comms request
reference (gems/tamoz-agent-cli/lib/tamoz/agent/cli_rendering.rb:60-107).

Impact: A synchronous CLI user has no durable “accepted, reference, query
later” moment equivalent to Telegram. A slow or disconnected terminal does not
give the same recovery handle the study treats as central.

Closure: Define the intended CLI mode explicitly. For asynchronous durable
work, print the stable handle before execution and make it resolvable after the
process exits. Add a subprocess test that kills the caller after admission and
reconnects by the printed handle.

### G6 — Human CLI liveness remains largely silent

Class: Fact; inference.

CLI#run_with_stream uses standard stream parts, but human
render_stream_part only renders custom, interrupt, and error parts; task,
update, and checkpoint parts are ignored
(gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:387-449).
The renderer documents that committed milestones do not ride the turn stream
and are available through tamoz comms request instead
(gems/tamoz-agent-cli/lib/tamoz/agent/cli_rendering.rb:19-25). The CLI test
records this as a named limitation, not a visible milestone test
(test/agent_cli_test.rb:920-925).

Impact: During unattended/slow durable work, the operator can see no
progress in the terminal and must know a separate command plus a comms
reference that queue add does not provide. This is a direct usability gap
even if the durable facts are correct.

Closure: Capture a real human-mode queue add → worker → reconnect session
and assert an initial handle plus bounded progress/next-action output. Keep
model tokens and raw plan text out of that output.

### G7 — CLI show and comms /status do not expose the same delivery truth

Class: Fact.

SessionStatusProjection.document defaults delivery to not_reported
(gems/tamoz-agent-session/lib/tamoz/agent/session_status_projection.rb:18-37),
and show renders that projection
(gems/tamoz-agent-cli/lib/tamoz/agent/cli_rendering.rb:181-192).
The comms request view instead reads task and delivery from outbox-backed
projections (gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:286-321).

Impact: Two operator queries over the same underlying work can truthfully
show different levels of delivery information, with the CLI surface appearing
less certain than Telegram’s request view.

Closure: Add a black-box parity test for completed, failed, and
delivery=unknown cases. If the surfaces intentionally differ, expose the
difference as an explicit contract; otherwise bind CLI status to the same
durable delivery projection.

### G8 — C2 is not a slow-liveness test

Class: Fact; evidence gap.

The scenario requires a several-phase slow run, a silence bound, coalescing
pressure, and both surfaces
(docs/openclaw-chat-study/benchmark-protocol/scenarios/C2-slow-liveness.md:20-43).
The B0 driver instead uses crashing_factory(:c2_recovery), crashes after
plan, and recovers a worker
(test/support/openclaw_comms_runner.rb:425-439;
test/support/openclaw_comms_fixture.rb:678-682). Its oracle explicitly marks
both wall-clock latencies unavailable
(gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb:140-156).

Impact: “Liveness passed” currently means milestones were projected and
backed in a synchronous fixture. It does not show that a real operator avoids
silence over time or that Telegram edits arrive within a useful interval.

Closure: Drive a virtual-clock multi-phase model for Track A and a real
provider for Track B. Record accepted-to-first-visible-update, update spacing,
terminal latency, and actual received/edit receipts separately for CLI and
Telegram.

### G9 — C4 does not execute the six restart boundaries

Class: Fact; evidence gap.

The C4 contract names six boundaries, including acknowledgement enqueue,
effect receipt, terminal enqueue, and send ambiguity
(docs/openclaw-chat-study/benchmark-protocol/scenarios/C4-restart-boundary-matrix.md:34-47).
The current driver only records inbound persistence, a worker-claim crash, and
terminal enqueue, then drains twice
(test/support/openclaw_comms_runner.rb:542-567). The oracle treats three
boundary labels as sufficient
(gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb:361-383).
The crash is a test exception and fresh worker in one fixture runtime, not a
process-level gateway/worker restart.

Impact: Effect replay and post-send unknown safety can be correct in unit
tests while still being absent from the claimed restart matrix. Recovery
confidence is overstated.

Closure: Add one kill/restart observation per M1–M6, with a fresh process
and persisted database. Assert reference, effect key, sequence, task state,
delivery state, and external-send count at every boundary.

### G10 — C8’s clean-stop observation is manually stamped

Class: Fact; evidence gap.

The C8 driver calls fixture.store.mark_cancellation_observed directly after
issuing /cancel (test/support/openclaw_comms_runner.rb:810-835); the canonical
story does the same (test/canonical_cross_surface_composition_test.rb:221-260).
The oracle acknowledges that observed-before-settle cannot be expressed offline
and marks that edge unavailable
(gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb:623-629).
Parity is also unavailable for C8 (:604-612).

Impact: The benchmark proves the shape of cancellation facts and wording,
not that the actual runner observed cancellation at the intended point through
the actual CLI and Telegram experience.

Closure: Either narrow the C8 claim to the store contract, or add a
real-running cancellation test that blocks an in-flight boundary, lets
DurableRunner perform observation, and includes a failed-settle variant.
Capture both surface outputs and a process restart.

### G11 — Callback acknowledgement is not observed in B0

Class: Fact; evidence gap.

The production Telegram transport calls answerCallbackQuery
(gems/tamoz-telegram/lib/tamoz/telegram/transport.rb:74-79), but B0’s
FakeTransport#signal is a no-op
(test/support/openclaw_comms_fixture.rb:104-119). The B0 C7 driver checks
prompt consumption and terminal facts
(test/support/openclaw_comms_runner.rb:745-783), not an acknowledgement
receipt. The separate
test_callback_ack_precedes_the_turn_and_the_decision_survives_a_worker_restart
test uses a recording fixture transport, not Telegram’s client.

Impact: The user-facing callback spinner, acknowledgement timing, and
failure behavior are unmeasured. “Callback ack works” is a plumbing statement,
not a Telegram observation.

Closure: Record signal(:ack) in the fixture oracle and assert its order
and result. Then run a guarded real Telegram callback with an
answerCallbackQuery receipt and latency bound.

### G12 — Pairing journey bypasses the operator command

Class: Fact.

The actual operator command is CLICommsOps#pair_approve, which verifies the
code and writes the binding
(gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:93-140).
The canonical composition instead constructs a Binding and calls
fixture.store.approve_pairing directly
(test/canonical_cross_surface_composition_test.rb:171-191).
B0 C5 likewise binds correspondents through fixture methods
(test/support/openclaw_comms_runner.rb:570-595).

Impact: Expiry, CLI configuration, output, exit status, and restart
behavior of the real first-contact handoff are not in the claimed operator
journey.

Closure: Use a process-level first-contact test: Telegram sends the code,
the operator copies it to tamoz comms pair approve CODE, then the same chat
submits a task. Assert no task before approval, one binding after approval,
and useful errors for expired/reused codes.

### G13 — Telegram gateway/transport integration is not live evidence

Class: Evidence gap.

The production path does build Tamoz::Telegram::Transport
(gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_shared.rb:156-181), but B0
uses FakeTransport, whose poll normalizes local hashes and whose deliver
returns synthetic message IDs
(test/support/openclaw_comms_fixture.rb:75-119).
test/tamoz_telegram_transport_test.rb uses TelegramFixtureServer, a local
server, not Telegram’s Bot API.

Impact: Long polling, getMe, offset confirmation, actual send/edit
receipts, rate limits, callback acknowledgement, and bot-token failure remain
unverified in one connected conversation.

Closure: Run one isolated, private Telegram bot cell with real provider
and transport, explicit cleanup, captured API receipts, and no credential
material in artifacts. A recorded-live transport is acceptable only if its
provenance and receipts are preserved.

### G14 — B0 lacks the protocol’s independent observability witness

Class: Fact; evidence gap.

The protocol requires durable receipts plus an independent observability trace
and treats divergence as a hard zero
(docs/openclaw-chat-study/benchmark-protocol/01-protocol-design.md:105-120).
B0’s artifact contains a durable snapshot and fixture metadata, but no trace
field (test/support/openclaw_comms_runner.rb:187-205,220-239). The
pushed_milestones recording is another fixture-side view of the same execution
(test/support/openclaw_comms_fixture.rb:121-135,435-447), not an independent
witness.

Impact: A projection can claim an event that no worker/transport observer
saw, or vice versa, without B0 detecting the divergence.

Closure: Bind each scenario artifact to an independent trace ID/digest
collected without advancing the turn. Add an artifact-mismatch hard-zero test.

### G15 — The benchmark does not measure perceived usefulness

Class: Evidence gap; hypothesis about user impact.

The protocol’s Track B says it will record answer quality and visible lifecycle
updates (docs/openclaw-chat-study/benchmark-protocol/01-protocol-design.md:60-65),
but the catalog’s executable metrics are completion, liveness, delivery,
recovery, parity, commands, context, identity, and cost
(docs/openclaw-chat-study/benchmark-protocol/02-scenario-catalog-and-scoring.md:39-60).
There is no operator rating, comprehension check, actionability measure, or
answer-quality rubric in the comms runner/oracles. B0’s scripted verify
responses prove fixture state transitions only
(test/support/openclaw_comms_fixture.rb:201-209).

Impact: The benchmark can establish that a message was delivered and that
states are truthful, but cannot establish that a human found the conversation
useful, understandable, or worth returning to. The working hypothesis that
better lifecycle communication feels useful remains untested.

Closure: Add a separate usefulness instrument to Track B: task success
rubric for answer quality plus blinded operator ratings for clarity,
confidence, actionability, and interruption burden. Report it by
(scenario, surface, run_kind, sample_count); do not merge it with plumbing
pass-rates.

### G16 — The green CLI suite tolerated an asynchronous runtime error

Class: Runtime observation; evidence gap.

The fresh test/agent_cli_test.rb run exited 0 but emitted
CheckpointConflictError: thread namespace already has an unexpired lease
from CheckpointStore#open_writer during a background execution. The CLI
rescue only applies in the calling CLI#run path
(gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:105-123); the test did not fail
on the thread exception.

Impact: A real operator can receive a zero exit code or partial output while
an asynchronous worker failed. This weakens confidence in the CLI’s claimed
error contract.

Closure: Reproduce under a subprocess/real command harness, make
unexpected worker-thread exceptions fail the command or emit a typed terminal
failure, and assert stderr is free of unhandled exceptions in the CLI
completion test. If the race is test-only, prove that with an isolated
reproduction and document the boundary.

### G17 — Evidence and catalog documents have contradictory state

Class: Fact.

Scenario prose still says C1–C9 are INCOMPLETE until B0
(docs/openclaw-chat-study/benchmark-protocol/scenarios/C1-happy-path.md:7-8,
and the analogous front matter for C2–C9), while SCENARIO_INDEX.json says
READY and B0 asserts all nine ready
(docs/openclaw-chat-study/benchmark-protocol/scenarios/SCENARIO_INDEX.json:19-31,
test/benchmark_comms_b0_test.rb:198-227). The README still says no runner
consumes the index (scenarios/README.md:88-90).

Impact: A future driver can select the wrong state source and either
relabel fixture plumbing as experience evidence or ignore a landed fixture
gate. This is a measurement-governance defect.

Closure: Regenerate or manually reconcile the catalog metadata through its
generator, make one authoritative state vocabulary (fixture-ready,
real-ready, inconclusive, blocked), and add a consistency test across
front matter, index, runner, and readiness output.

### G18 — Clarification interrupts are misclassified as approval requests

Class: Fact; confirmed production code-path defect.

`Worker#settle_paused_view` sends every non-empty interrupt through
`request.approval_request` and then calls `emit_approval_request`
(gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-735). A clarification interrupt
is a different descriptor: `SessionPlanOutcomes#clarification_descriptor`
contains `kind: clarify`, `question`, and `context`, but no `decision` or
`required_evidence` (gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:138-156).
`Worker#interrupt_facts` preserves that descriptor unchanged
(gems/tamoz-agent/lib/tamoz/agent/worker.rb:898-906). The channel sink maps the
worker event to the approval branch in `OutboxDeliverySink#push` and calls
`push_approval_prompt` (gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:66-84,186-220),
where `OutboxDeliverySink#decision_evidence` unconditionally fetches
`descriptor['decision']['required_evidence']`
(gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:248-257). A real
clarification pause therefore raises `KeyError` before a channel prompt is
durably appended. This is a distinct implementation failure, not merely an
unverified experience claim.

Impact: A model review that asks the operator for clarification can park the
durable turn while channel delivery fails. Telegram cannot show the question
or collect its answer through this path, so the operator sees silence or a
worker failure and queued work can remain behind the pause. The CLI
`PromptAdapter#clarify` loop is a separate interactive seam
(gems/tamoz-agent-cli/lib/tamoz/agent/cli_prompt_adapter.rb:44-55); it does not
prove channel projection or Telegram resumption.

Closure: Add a focused test named, for example,
`test_clarification_pause_projects_a_bounded_question_without_approval_evidence`
that drives a real clarify interrupt through `Worker#settle_paused_view` (or
the actual worker pause), asserts one bounded non-terminal clarification/control
outbox row containing the question, asserts no approval keyboard or
`decision_evidence` lookup, and confirms the request remains paused without a
`KeyError`. Then run a guarded Telegram transport observation and assert the
question is delivered and a clarification answer resumes the same occurrence.
If channel clarification is intentionally unsupported, the closure must
instead emit a typed durable/operator-visible unavailable notice; it must not
route the descriptor through the approval evidence contract.

## Top root causes — 5 Whys

### Root cause A: two durable submission contracts were treated as one surface

1. Why can a CLI operator not follow a Telegram request reference through
   the same status/reconnect path? Because queue add emits a UUID and writes
   the ordinary request inbox, while comms request resolves only comms-store
   references (G4).
2. Why are those different? Telegram enters through Gateway admission and
   CommsStore/outbox; CLI ask and queue add call Session/DurableRunner
   directly (G3–G5).
3. Why did the parity test not expose it? The fixture’s CLI helper bypasses
   the CLI and manufactures a deterministic request ID (G3, G4).
4. Why was that accepted as parity? The B0 oracle compares internal
   thread/request meaning and explicitly records CLI visibility as an
   unavailable edge (openclaw_comms_oracles.rb:525-547).
5. Why is an unavailable edge allowed inside a ready result? The runner
   treats unavailable values as excluded from metrics_ready? (G2).

Root cause: the implementation has durable components, but the benchmark
does not enforce one operator-facing lifecycle contract across its two
entry points.

### Root cause B: benchmark readiness is weaker than the scenario bar

1. Why are five scenarios ready without CLI evidence? Their driver defaults
   to Telegram only.
2. Why does readiness not fail? Unavailable metrics are filtered out.
3. Why are absent surfaces represented as typed unavailable rather than
   blocked? The oracle was designed to keep honest edges while still scoring
   the available fixture facts.
4. Why does that become misleading? Artifact status is still ready, and
   B0 tests assert that status for all nine.
5. Why was this not caught in review? The implementation review emphasized
   fixture honesty and empty pending seams, while the scenario bar’s
   required-cell rule was not encoded as a gate.

Root cause: “not a usefulness claim” was enforced, but “not a complete
scenario cell” was not. Provenance honesty and completeness were conflated.

### Root cause C: the evidence harness observes durable facts, not the operator

1. Why is perceived usefulness unmeasured? The runner records durable rows,
   scripted answers, and synthetic sends, not a human interaction or answer
   quality judgment (G15).
2. Why are real visible timings absent? B0 uses a fake transport and
   declares wall-clock latency unavailable (G1, G8, G13).
3. Why is the independent trace absent? B0 snapshots the store and fixture
   sink but has no Track-B artifact binding (G14).
4. Why do the composition tests look complete? They deliberately optimize
   for deterministic, byte-identical plumbing regression evidence
   (test/benchmark_comms_b0_test.rb:172-196).
5. Why is that insufficient for the refresh? The refresh asks whether the
   lifecycle feels useful and interactive, which is an experience question
   beyond deterministic correctness.

Root cause: the repository has a good safety/plumbing gate but no executed
experience measurement lane.

### Root cause D: boundary tests use seams instead of real interruption points

1. Why does C8 not prove runner observation timing? The driver manually
   calls the store observation method.
2. Why does C4 not prove all restart cases? The driver exercises only three
   labels and uses a fixture exception/fresh worker.
3. Why were these shortcuts used? The durable engine’s observed-before-
   settle edge and process boundary are difficult to express in a synchronous
   fixture.
4. Why were they still scored ready? The oracles accept the reduced
   boundary/timeline shape and record the missing edge as unavailable.
5. Why does that matter? Recovery and cancellation are exactly where
   operator trust is lost; a shape-level test cannot substitute for the
   interruption observation.

Root cause: the fixture seam is good for invariant checks but has been
allowed to stand in for process/runtime evidence at the exact points where
timing and ownership matter.

### Root cause E: pause semantics are collapsed at the channel boundary

1. Why does a clarification pause fail before a prompt is appended? Because
   `decision_evidence` fetches approval-only fields from a clarify descriptor
   (G18).
2. Why does the sink take the approval-only branch? Because
   `settle_paused_view` labels every non-empty interrupt
   `request.approval_request`, regardless of its `kind`.
3. Why can one event kind carry incompatible payloads? Because the worker
   preserves typed interrupt descriptors but does not project a distinct
   clarification event or channel contract.
4. Why was the mismatch not caught? Approval sink tests construct descriptors
   with `decision.required_evidence`, while current clarify coverage exercises
   the CLI prompt loop rather than the outbox/Telegram path
   (`test/agent_outbox_delivery_sink_test.rb:115-187`,
   `test/agent_cli_test.rb:888-925`).
5. Why is there no channel closure guard? The benchmark and implementation bar
   treat approval interruption as the channel control case and do not require a
   clarification pause/resume observation.

Root cause: typed durable interruption semantics are not preserved across the
worker-to-channel projection, so a clarification descriptor reaches an
approval-only evidence contract.

## User impact

These are the likely operator-visible consequences; the first two are
inferences, not measured user studies:

* Inference: Telegram has a richer accepted/reference/status/reconnect
  contract than tamoz ask or queue add, so switching surfaces loses the
  handle needed to understand work.
* Inference: a human CLI terminal may be silent during durable progress,
  while Telegram receives a coalesced card; the user must discover a separate
  store query without a compatible reference.
* Fact: callback acknowledgement is not present in the B0 fake transport,
  so callback responsiveness is unknown.
* Fact: real Telegram polling, sending, editing, and answerCallbackQuery
  are not part of current benchmark evidence.
* Hypothesis: users will resend slow requests or abandon work when the CLI
  supplies no early lifecycle handle. This needs a Track-B observation.
* Fact: cancellation wording and durable timeline are strongly tested as
  store projections, but actual runner observation timing is an explicit
  unavailable edge.
* Fact: fixture/model tests prove plumbing only. They do not prove that an
  agent’s answer is correct, useful, or intelligent.

## Missing evidence and exact closure observations

| Closure unit | Exact closure observation |
| --- | --- |
| Benchmark admissibility | Run the nine B0 scenarios with one required surface intentionally disabled; the runner must emit non-ready status and readiness must refuse the axis. Then run the complete Track-A matrix and verify each (scenario, surface, fixture) cell exists. |
| Actual durable CLI | Run the real CLI command path with captured stdout/stderr/exit status: queue add or --session ask, worker --once, show/status after the caller exits. Assert the printed handle resolves to the same request after reopening the database. |
| Cross-surface identity | Submit equivalent turns through actual CLI and Telegram. Assert each accepted acknowledgement, terminal result, status query, cancellation, and unknown-delivery resolution names one stable request and does not require a hidden fixture-generated ID. |
| C2 liveness | Use a multi-phase provider with a controlled clock in Track A and a real provider in Track B. Record first update, inter-update gaps, terminal time, projected update count, and what the Telegram transport actually received. |
| C4 recovery | Kill/restart the gateway and worker independently at M1–M6. Reopen the same SQLite database and assert no duplicate effect or external terminal send, including M6 unknown. |
| C8 cancellation | Hold an in-flight boundary, issue cancel from each surface, let the real runner write observed, restart once, and run both a stopped and failed/completed-first variant. Compare visible wording with the durable settle kind. |
| Clarification channel path | Drive a real clarify pause through `settle_paused_view`; observe no approval-only evidence lookup, one bounded question/control row, a paused request, and a channel answer that resumes the same occurrence. If unsupported, observe a durable typed unavailable notice instead of `KeyError`. |
| Callback UX | Record the actual callback acknowledgement call and receipt, its order relative to durable decision recording, and bounded latency. Repeat with a provider/transport failure. |
| Pairing | Send first contact in Telegram, execute tamoz comms pair approve CODE, then submit. Capture code expiry/reuse/invalid-code output and exit codes. |
| Independent witness | Bind each real artifact to a separate worker/transport trace digest. Force a mismatch in a test and assert a hard-zero, not a green result. |
| Perceived usefulness | For a small declared sample, collect blinded operator ratings for clarity, confidence, actionability, interruption burden, and answer quality; report by surface and run kind. Keep these results separate from safety/plumbing metrics. |
| Async CLI health | Execute the real CLI in a subprocess and assert no unhandled thread exception appears on stderr and the exit status reflects any worker failure. Reproduce the observed checkpoint conflict before changing code. |
| Documentation authority | Run the catalog/index consistency test and ensure front matter, index, B0 artifact, readiness, and protocol all use the same state vocabulary and provenance. |

## Priorities

| Priority | Work | Value | Risk if deferred | Dependency | Cost |
| --- | --- | --- | --- | --- | --- |
| P0 | Encode required-surface/required-metric gating; remove ready from incomplete cells (G2, G17). | High: stops false confidence immediately. | High measurement and release risk. | Before any benchmark verdict. | Low–M. |
| P0 | Split clarification from approval in pause projection and close the channel path (G18). | Very high: prevents a parked clarification from becoming channel silence or `KeyError`. | High interruption deadlock and operator-recovery risk. | Before claiming clarification support on Telegram. | L–M. |
| P0 | Exercise the actual durable CLI and establish a shared or explicitly queryable request handle (G3–G7). | Very high: fixes the operator’s return/reconnect loop. | High surface divergence and lost work handles. | Before parity claims and Track B. | M. |
| P0 | Implement one guarded real-provider + real-Telegram happy path with durable receipts and independent trace (G1, G13, G14). | Very high: first experience evidence. | All usefulness/liveness claims remain unverified. | Requires configured provider, private bot, cleanup, and controls. | M. |
| P1 | Replace C2/C4/C8 shortcuts with faithful liveness, process-restart, and runner-observation drivers (G8–G10). | High: closes recovery and responsiveness risk. | Hidden failures at timing/ownership boundaries. | After black-box harness; C8 may require an engine seam decision. | M–H. |
| P1 | Observe callback ack and pairing through real operator commands (G11–G12). | High for first-contact and approval trust. | User sees spinners, silence, or misleading pairing state. | Requires real transport or recorded-live session. | M. |
| P1 | Fail the CLI command on unexpected asynchronous worker exceptions (G16). | High reliability value. | Zero/partial-success ambiguity. | Reproduce the conflict first. | L–M. |
| P2 | Add perceived-usefulness and answer-quality measurement (G15). | High product learning, after plumbing is real. | Product decisions remain based on protocol proxies. | Track B and a stable interaction contract. | M. |
| P2 | Maintain generated catalog/status artifacts and a longitudinal communication scoreboard. | Medium governance value. | Future benchmark drift. | After readiness semantics are fixed. | L. |

## Rejected distractions and deliberate non-goals

* Do not create a second chat runtime, event bus, or in-memory status cache.
  Existing Gateway, DurableRunner, Session, effect journal, outbox, and store
  seams are sufficient; this preserves the implementation plan’s reuse rule
  (docs/openclaw-chat-study/benchmark-protocol/README.md:69-71).
* Do not add token streaming or raw plan/tool output as a substitute for
  liveness. The scenario contract explicitly rejects it
  (C2-slow-liveness.md:12-18,58-63).
* Do not expand to groups, media, multi-agent routing, or another channel before
  the current Telegram/CLI contract has real evidence. The implementation bar
  keeps those as frontier work
  (docs/openclaw-chat-study/implementation-plan/00-implementation-bar.md:147-164).
* Do not treat deterministic scripted answers, fixture sends, local fixture
  servers, or green Minitest output as intelligence or perceived-usefulness
  evidence.
* Do not solve G4 by adding compatibility shims for multiple historical row
  shapes. The repository directive is fresh-schema/simple design; choose one
  current operator contract and test it.

## Final bar verdict

Phase 0–3 has meaningful plumbing evidence: durable admission, lifecycle
projection, bounded output, delivery uncertainty, controls, and store-level
recovery are exercised by focused tests. The earlier study was also correct to
withhold a real-provider/usefulness claim.

The refresh bar is not met because the current “ready” benchmark does not
require both surfaces, the canonical CLI legs bypass the CLI, the real
provider/Telegram path has not run, B0 has no independent trace witness, and
perceived usefulness is not measured. The C2/C4/C8 drivers also do not execute
the declared timing/restart/observation moments. These are not all production
code defects; they are unresolved contract and evidence defects that prevent
an honest operator-experience conclusion. In addition, G18 is a confirmed
production path defect: a clarification interrupt reaches the approval-only
`decision_evidence` lookup and can raise before channel delivery.

## Integration distinction

Report/content bar: MEETS BAR. This report is complete for Lane A: it states
scope and method, reconciles changed/stale/contradictory claims, records 18
concrete gaps, applies 5 Whys to the top causes, names user impact, specifies
exact closure observations, ranks value/risk/dependency/cost, records rejected
distractions, and states what remains unverified.

Current system/evidence readiness: NEEDS FIXES. The blockers remain the
required-surface gate, actual durable CLI black-box parity and handles, real
provider/real Telegram execution, independent trace, faithful C2/C4/C8
moments, callback/pairing observations, perceived-usefulness measurement, the
CLI asynchronous exception observation, and the confirmed G18 clarification
projection failure. The final verdict below is the system/evidence verdict;
it does not mean the Lane A report is incomplete.

NEEDS FIXES
