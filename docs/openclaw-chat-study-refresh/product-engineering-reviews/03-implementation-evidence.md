# Product-engineering review 3 — implementation and evidence readiness

Date: 2026-08-27

## 1. Scope and sources inspected

**Fact — scope.** This is a bounded, read-only review of whether the refreshed
study and roadmap are concrete enough to drive bounded implementation slices
without repeating the investigation. It covers implementation seams, tests,
telemetry, evidence admissibility, cross-gem risk, and release gates. No source,
test, fixture, configuration, lockfile, sibling review, or git metadata was
changed.

**Fact — required package sources read.** I read the complete contents of:

- `AGENTS.md` and `docs/subagent-orchestration.md`;
- `docs/openclaw-chat-study-refresh/00-review-bar.md`;
- all three files under `docs/openclaw-chat-study-refresh/specialist-reviews/`;
- both files under `docs/openclaw-chat-study-refresh/brainstorming/`;
- `docs/openclaw-chat-study-refresh/01-consolidated-study.md`;
- `docs/openclaw-chat-study-refresh/02-decision-roadmap.md`; and
- `docs/openclaw-chat-study-refresh/03-evidence-index.md`.

**Fact — implementation sources inspected.** The claimed seams were traced in
the current tree, including:

- worker pause/settlement and interruption facts:
  `gems/tamoz-agent/lib/tamoz/agent/worker.rb:611-735,878-906` and
  `gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:138-167`;
- outbox projection, approval evidence, milestone coalescing, and terminal
  reservation: `gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:27-265`;
- Telegram admission, callback acknowledgement, gateway lifecycle, and
  drainer fencing: `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:31-118`,
  `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb:10-77`,
  `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb:131-205`, and
  `gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb:45-151`;
- CLI ask, queue, control, request-view, and human rendering:
  `gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:29-41,158-218`,
  `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:195-242`,
  `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:224-321`,
  `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:96-123,387-449`, and
  `gems/tamoz-agent-cli/lib/tamoz/agent/cli_rendering.rb:60-122,181-205`;
- channel identity and transport contracts:
  `gems/tamoz-comms/lib/tamoz/comms/inbound_envelope.rb:22-184`,
  `gems/tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:30-118,141-259`,
  `gems/tamoz-comms/lib/tamoz/comms/transport.rb:7-55`, and
  `gems/tamoz-telegram/lib/tamoz/telegram/transport.rb:19-104`;
- benchmark runner, fixture, oracles, and existing durable CLI evidence adapter:
  `test/support/openclaw_comms_runner.rb:13-168,425-567,745-883`,
  `test/support/openclaw_comms_fixture.rb:18-167,419-441`,
  `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb:138-164,359-383,589-631`,
  and
  `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb:15-25,79-125,203-237,290-329`.

**Fact — tests run in this review.** Using the pinned executable
`/opt/homebrew/bin/rbenv exec ruby`:

- `/opt/homebrew/bin/rbenv exec ruby -Itest test/agent_outbox_delivery_sink_test.rb`
  passed: 11 runs, 44 assertions, 0 failures, 0 errors;
- `/opt/homebrew/bin/rbenv exec ruby -Itest test/benchmark_comms_b0_test.rb`
  passed: 14 runs, 151 assertions, 0 failures, 0 errors;
- `/opt/homebrew/bin/rbenv exec ruby -Itest test/canonical_cross_surface_composition_test.rb`
  passed: 1 run, 106 assertions, 0 failures, 0 errors; and
- `/opt/homebrew/bin/rbenv exec ruby -Itest test/agent_cli_test.rb` exited 0
  with 33 runs, 753 assertions, 0 failures, 0 errors, but emitted an unhandled
  background `Tamoz::CheckpointConflictError` from
  `gems/tamoz-sqlite/lib/tamoz/sqlite/lease_operations.rb:50`, originating from
  `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:406`.

These are **Fact — plumbing observations**. They are not real-provider,
real-Telegram, production, perceived-quality, or intelligence evidence.

## 2. Hard-zero risks and release/implementation gates

The following are unresolved high-severity findings. Count: **7**.

| ID | Severity/status | Hard-zero or gate | Evidence and required disposition |
| --- | --- | --- | --- |
| F1 | High / confirmed implementation defect | Clarification must not enter approval evidence | **Fact:** `Worker#settle_paused_view` emits `request.approval_request` for every non-empty interrupt at `gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-731`; the clarify descriptor has `kind`, `question`, and `context`, but no `decision` at `gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:145-156`; `OutboxDeliverySink#decision_evidence` requires `descriptor['decision']['required_evidence']` at `gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:248-257`. **Gate:** fix and test before claiming Telegram clarification support. |
| F2 | High / confirmed evidence-governance defect | Missing required surfaces/metrics must never score ready | **Fact:** `SURFACES_DRIVEN` lists CLI only for C1, C5, C6, and C9, with other scenarios defaulting to Telegram at `test/support/openclaw_comms_runner.rb:41-48,133-135`; `metrics_ready?` filters unavailable values at `test/support/openclaw_comms_runner.rb:161-168`; B0 asserts the reduced matrix and `ready` status at `test/benchmark_comms_b0_test.rb:198-227`. **Gate:** a missing required cell yields blocked/inconclusive and no publishable axis. |
| F3 | High / confirmed harness defect | A benchmark CLI leg must execute the actual CLI | **Fact:** `OpenclawCommsFixture#submit_cli_task` calls `submit_cli_request`, which directly calls `durable_runner.submit` at `test/support/openclaw_comms_fixture.rb:145-163,419-427`; the canonical test invokes that helper at `test/canonical_cross_surface_composition_test.rb:209-216`. No argv parser, process, stdout, stderr, exit status, or database reopen is covered by that leg. **Gate:** use the actual queue/worker/status command path for CLI parity. |
| F4 | High / confirmed contract gap | One caller-bound handle and exact target must span surfaces | **Fact:** `queue add` generates a UUID and prints it at `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:220-241`; `ask` creates a UUID and drives `run_durable` immediately at `gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:29-40`; `comms request` resolves `R<reference>` through `requests_by_reference` at `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:230-258`. **Inference:** a user cannot currently assume that a CLI handle resolves through the Telegram request/status path. **Gate:** choose one current-schema contract, then test exact-target status/cancel/redirect with two open requests. |
| F5 | High / confirmed evidence gap | Declared restart/cancellation moments must be executed, not represented | **Fact:** C4 declares M1–M6 at `documentation/benchmark/openclaw-chat-study/scenarios/C4-restart-boundary-matrix.md:34-47`, while the runner records only inbound persistence, worker-claim crash, terminal enqueue, and repeated drain at `test/support/openclaw_comms_runner.rb:542-567`. **Fact:** C8 manually calls `mark_cancellation_observed` at `test/support/openclaw_comms_runner.rb:810-835`, and its oracle explicitly marks `engine_observed_before_settle` unavailable at `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb:597-629`. **Gate:** process-level M1–M6 and runner-observed C8 evidence or a narrowed claim. |
| F6 | High / confirmed evidence gap | A real artifact requires an independent witness and real transport/provider provenance | **Fact:** B0 hardcodes fixture provider/transport at `test/support/openclaw_comms_runner.rb:26-32`, and its artifact contains fixture metadata at `test/support/openclaw_comms_runner.rb:187-205` but no independent trace binding. **Fact:** `Telegram::Transport` makes real Bot API operations at `gems/tamoz-telegram/lib/tamoz/telegram/transport.rb:37-79`, but current transport tests use `TelegramFixtureServer` at `test/tamoz_telegram_transport_test.rb:16-27`. **Gate:** guarded private real Telegram/provider run, durable receipts, callback/send/edit receipts, and independent trace agreement. |
| F7 | High / unresolved operational contract | Accepted must not imply a healthy worker or active execution | **Fact:** the guide states gateway and worker are separate foreground processes and that the gateway can admit work while no worker answers at `documentation/guides/telegram.md:84-117`; the launcher only starts/checks processes at `scripts/start-tamoz-comms.sh:150-183`; gateway admission persists accepted work at `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:49-70`. **Inference:** the current acknowledgement can be truthful about persistence while being interpreted as active execution. **Gate:** choose and test queue-versus-refuse behavior, with a bounded worker-availability fact. |

**Fact — non-hard-zero evidence gap.** Human comprehension, trust,
actionability, annoyance, recovery experience, and real answer usefulness have
no current participant instrument or real transcript. The executable catalog
metrics cover plumbing axes at
`documentation/benchmark/openclaw-chat-study/02-scenario-catalog-and-scoring.md:39-60`.
This blocks experience claims, even after the seven high-severity gates above
are closed.

## 3. Findings ordered by severity

### F1 — Clarification is projected through an approval-only path

**Classification: Fact (confirmed production-path defect).**

`Worker#settle_paused_view` sends `request.approval_request` for all non-empty
interrupts at `gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-734`. A real
clarification descriptor is built with `kind: clarify`, `question`, and
`context`, without an approval `decision`, at
`gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:145-156`.
The sink then unconditionally fetches
`descriptor['decision']['required_evidence']` at
`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:248-257`.

**Affected slice/seam:** Roadmap Slice 0; `Worker#settle_paused_view`,
`OutboxDeliverySink#push`, clarification descriptor, prompt/answer routing.

**Failure mode/root cause:** **Inference:** a clarification can remain paused
while sink projection raises `KeyError` before a channel question is durably
appended. The root cause is typed interruption semantics being collapsed to one
approval event at the worker-to-channel boundary.

**Impact:** **Inference:** Telegram can become silent and cannot collect the
answer; queued work can remain behind the paused occurrence. The CLI
`PromptAdapter#clarify` loop at
`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:463-477` is a separate interactive
path and does not close the channel projection defect.

**Scope-creep check:** **Proposal:** extend the existing worker-to-sink seam;
do not add a second runtime, approval engine, or status store. Preserve
approval evidence, one-use receipts, caller/conversation binding, expiry, and
occurrence identity.

**Smallest correction:** **Proposal:** preserve `clarify` versus
`approve_tool`; emit a bounded clarification control row with a text-answer
action, or a durable typed-unavailable notice for an unsupported surface.

**Exact closure test/evidence:** **Proposal:** add a focused test named
`test_clarification_pause_projects_a_bounded_question_without_approval_evidence`
that drives a real clarify descriptor through `Worker#settle_paused_view` and
asserts: one bounded question row; no approval keyboard; no
`decision_evidence` lookup; paused occurrence; stale/wrong caller rejection;
replay deduplication; and valid answer resumption of the same occurrence.
Then run a guarded real Telegram question/answer receipt observation if this
surface is supported. A real-provider run is needed if producing the
clarification is provider-dependent; a deterministic descriptor fixture is
enough to prove the projection plumbing.

### F2 — Benchmark readiness admits missing required surface evidence

**Classification: Fact (confirmed evidence-governance defect).**

The scenario contract declares both CLI and Telegram at, for example,
`documentation/benchmark/openclaw-chat-study/scenarios/C2-slow-liveness.md:1-8`
and `documentation/benchmark/openclaw-chat-study/scenarios/C4-restart-boundary-matrix.md:1-8`.
The B0 runner only drives both for C1, C5, C6, and C9 at
`test/support/openclaw_comms_runner.rb:41-48`; the fallback is Telegram at
`test/support/openclaw_comms_runner.rb:133-135`. Its readiness function
removes unavailable metric hashes before checking pass at
`test/support/openclaw_comms_runner.rb:161-168`.

**Affected slice/seam:** Roadmap Slice 4; `OpenclawCommsRunner`, oracles,
scenario index, readiness/publication.

**Failure mode/root cause:** **Inference:** the harness confuses an honestly
typed unavailable metric with an admissible completed scenario. B0 therefore
can produce `ready` without every declared `(scenario, surface)` cell.

**Impact:** **Inference:** green B0 output cannot support CLI parity, liveness,
restart, callback, or cancellation claims for the omitted CLI legs. This is a
release/evidence failure, not a reason to weaken the safety or fixture firewall.

**Scope-creep check:** **Proposal:** change the readiness predicate and
catalog-state vocabulary; retain B0 as fixture plumbing. Do not make fixture
results real or invent a second benchmark framework.

**Smallest correction:** **Proposal:** required surface and required metric
presence become admissibility predicates. Missing values produce
`inconclusive` or `blocked`; unavailable values cannot be filtered from a
publishable axis.

**Exact closure test/evidence:** **Proposal:** mutate a scenario's required
surface set in a test, run the runner, and assert no `ready` status or
publishable axis. Then run the full Track-A matrix and assert every declared
`(scenario, surface, fixture)` cell exists. Add an index/front-matter/runner
consistency test.

### F3 — The canonical CLI leg bypasses the CLI

**Classification: Fact.**

`OpenclawCommsFixture#submit_cli_task` ultimately calls
`@runtime.session_for(thread_id).app.durable_runner.submit` at
`test/support/openclaw_comms_fixture.rb:419-427`; its helper contract is
described at `test/support/openclaw_comms_fixture.rb:145-163`. The canonical
composition test calls the helper at
`test/canonical_cross_surface_composition_test.rb:209-216`. The test therefore
does not exercise `Tamoz::Agent::CLI#run`, parser behavior, process boundaries,
stdout/stderr, exit status, or reopened runtime configuration.

**Affected slice/seam:** Roadmap Slices 2 and 4; actual CLI entry point and
benchmark adapter.

**Failure mode/root cause:** **Inference:** a durable runner result is being
used as evidence of a user-facing CLI path. The fixture was optimized for
deterministic composition and therefore bypasses the surface under test.

**Impact:** **Inference:** CLI-specific handle, rendering, asynchronous error,
configuration, and restart defects can pass cross-surface parity.

**Scope-creep check:** **Fact:** an existing reusable adapter already invokes
queue and worker CLI commands and reads a trace through the CLI contract at
`gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb:203-215,290-329`.
**Proposal:** integrate or extend this seam rather than creating a parallel
CLI harness.

**Smallest correction:** **Proposal:** make the benchmark CLI leg invoke the
actual queue/worker/status commands with captured output and exit status. Keep
fixture direct submission only in the fixture plumbing test.

**Exact closure test/evidence:** **Proposal:** subprocess test: `queue add`
prints a handle; the caller exits; `worker --once` advances the same database;
`comms request`/status resolves the handle after reopen; stderr has no
unhandled thread exception; two concurrent refs cannot cross-target cancel or
redirect.

### F4 — The roadmap does not choose the current request-reference contract

**Classification: Fact plus Inference.**

Telegram admission derives an `r<reference>` from request identity at
`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission_acknowledgement.rb:10-29`.
CLI queue prints a UUID at
`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:225-240`; CLI
ask runs immediately with a generated UUID at
`gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:29-40`; and
`comms request` accepts only an `R<reference>` lookup at
`gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:230-258`.
**Inference:** “unify handles” in Slice 2 is a design decision, not yet an
implementation-ready interface contract.

**Affected slice/seam:** Roadmap Slice 2; CLI queue/ask, CommsStore request
resolution, gateway commands, status rendering.

**Failure mode/root cause:** **Inference:** an operator can leave one surface
and fail to identify the same durable work on the other, or use a thread-level
cancel when the intended target was one of several requests.

**Impact:** **Inference:** cross-surface controls can be confusing or unsafe;
the user may resend work or fear that a different request was changed.

**Scope-creep check:** **Proposal:** select one current fresh-schema contract,
keep thread/occurrence IDs as internal authority handles, and resolve through
the existing store. Do not add compatibility rows, a global reference index,
or a new status cache.

**Smallest correction:** **Proposal:** add a short-reference field to the
operator-visible submission and status contract, explicitly define whether
`ask` is synchronous or durable-asynchronous, and make status/cancel/redirect
echo the affected reference and resulting state.

**Exact closure test/evidence:** **Proposal:** actual CLI subprocess and
Telegram-equivalent run, database reopen, exact-ref status/cancel/redirect,
two open requests, caller/conversation isolation, and a cross-target action
hard-zero.

### F5 — C4 and C8 score reduced fixture moments as declared recovery evidence

**Classification: Fact (evidence gap, not proof that the durable engine is
incorrect).**

C4 requires six restart boundaries at
`documentation/benchmark/openclaw-chat-study/scenarios/C4-restart-boundary-matrix.md:34-47`.
The B0 driver executes only three labels and a second drain at
`test/support/openclaw_comms_runner.rb:542-567`. C8's clean-stop driver writes
the observation through `fixture.store.mark_cancellation_observed` at
`test/support/openclaw_comms_runner.rb:810-835`; the oracle records the
engine-observed-before-settle edge as unavailable at
`gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb:623-629`.

**Affected slice/seam:** Roadmap Slices 3 and 4; worker process, gateway
process, effect receipts, outbox, cancellation timeline, oracle.

**Failure mode/root cause:** **Inference:** a synchronous fixture seam is
standing in for process kill/restart and runner observation at exactly the
moments where ownership, ordering, and timing matter.

**Impact:** **Inference:** restart, cancellation, no-duplicate-send, and
false-stopped claims are weaker than the scenario contract implies.

**Scope-creep check:** **Proposal:** reuse existing worker recovery, drainer,
SQLite, and cancellation seams. Do not add a new recovery engine. If the
engine cannot express a required boundary offline, mark that claim partial
instead of adding manual stamps.

**Smallest correction:** **Proposal:** drive M1–M6 with fresh processes and a
persisted database; make C8 block an in-flight boundary and let the worker
write `observed`; include failed-settle and completed-before-cancel variants.

**Exact closure test/evidence:** **Proposal:** for each boundary assert stable
ref, effect key, execution count, sequence, task state, delivery state, and
external send count after reopen. For C8 assert requested ≤ observed and the
terminal wording matches the durable settle kind without a store-side stamp.

### F6 — Current evidence has no independent witness or real experience lane

**Classification: Fact and Evidence gap.**

B0 hardcodes `RUN_KIND = 'fixture'`, deterministic provider, and no-egress
transport at `test/support/openclaw_comms_runner.rb:26-32`. The protocol requires
durable receipts plus an independent trace at
`documentation/benchmark/openclaw-chat-study/01-protocol-design.md:83-120`.
The fixture artifact records store/fixture output at
`test/support/openclaw_comms_runner.rb:187-205`; its fixture transport's
`signal` is a no-op at `test/support/openclaw_comms_fixture.rb:104-119`.
Telegram transport tests use a local `TelegramFixtureServer` at
`test/tamoz_telegram_transport_test.rb:16-27`, not the Bot API.

**Affected slice/seam:** Roadmap Slice 4; `OpenclawCommsRunner`, scenario
oracles/readiness, Telegram transport, provider configuration, observability
trace, artifact manifest.

**Failure mode/root cause:** **Inference:** deterministic durable facts are
being asked to support claims about actual Telegram timing, callback ack,
provider usefulness, and operator-visible recovery without the corresponding
witnesses.

**Impact:** **Evidence gap:** the repository cannot currently prove real
acknowledgement, send/edit, callback receipt, provider answer quality, or human
comprehension. This blocks any experience-ready or intelligence claim.

**Scope-creep check:** **Proposal:** retain B0 as a useful fixture regression;
add one guarded Track-B path under the existing CLI/provider/Telegram seams.
Do not loosen the credential boundary or relabel fixtures as real.

**Smallest correction:** **Proposal:** name the real-run command, private
conversation, bounded non-sensitive task, provider/model provenance, transport
receipt source, independent trace source, cleanup, cost limit, and publication
rule in the slice brief.

**Exact closure test/evidence:** **Proposal:** private real-provider and
real-Telegram run with accepted/waiting/terminal/callback/send/edit receipts,
durable request/effect/outbox receipts, independent trace digest, forced
witness-mismatch hard zero, and separate answer-quality/comprehension report.

### F7 — Worker availability is proposed but not operationally specified

**Classification: Fact plus Inference.**

The guide explicitly states that gateway and worker are independent foreground
processes and that no worker means admitted messages are never answered at
`documentation/guides/telegram.md:84-117`. `Gateway#serve_once` admits then
drains at `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb:174-186`; the
launcher starts and checks both processes at
`scripts/start-tamoz-comms.sh:150-183`, but does not publish a durable worker
heartbeat. **Inference:** the roadmap's proposed `queued-without-worker` state
has no named source fact, freshness rule, or admission policy.

**Affected slice/seam:** Roadmap Slice 2; worker claim path, gateway admission,
status projection, launcher/supervision boundary.

**Failure mode/root cause:** **Inference:** a healthy-looking acceptance can
hide queueing behind a dead, wedged, or absent worker; a heartbeat can also be
stale unless its freshness and owner semantics are defined.

**Impact:** **Hypothesis:** operators may resend or repeatedly poll when the
actual cause is worker unavailability. This requires measurement, but the
current system cannot distinguish the states in the user contract.

**Scope-creep check:** **Proposal:** add one bounded operational fact at the
existing status/admission seam. A supervisor is optional and must remain
process supervision, not a second executor or chat runtime.

**Smallest correction:** **Proposal:** choose queue-versus-refuse when worker
health is stale; define heartbeat owner, timestamp, freshness, and failure
semantics; expose accepted, queued-without-worker, working, and waiting
distinctly.

**Exact closure test/evidence:** **Proposal:** admit a request, kill or wedge
the worker, observe accepted/status, restart it, and assert same-ref progress
with no duplicate effect. Repeat under queue pressure and stale-heartbeat
conditions.

### F8 — The human projection and attention budget are not yet a bounded change brief

**Classification: Proposal with Evidence gap.**

Slice 1 proposes state, reference, now, next, and delivery certainty, and the
consolidated study proposes a safe goal label at
`docs/openclaw-chat-study-refresh/01-consolidated-study.md:142-159` (target
interaction contract). Existing diagnostic fields are sourced from
`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_status.rb:18-78`, while
current Telegram milestone text is only `ref: phase` at
`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:123-161`.
There is no named framework-owned source or redaction contract for a “safe goal
label,” and no current human-card serializer.

**Affected slice/seam:** Roadmap Slice 1 and part of Slice 3; sink/rendering,
gateway status, CLI rendering, outbox edit/coalescing.

**Failure mode/root cause:** **Inference:** a new human projection could drift
from durable state, leak task/path/provider content, or become a second state
machine if its input facts and ownership are not frozen first.

**Impact:** **Evidence gap:** golden text tests can prove deterministic copy
without proving comprehension, annoyance, or safe interpretation.

**Scope-creep check:** **Proposal:** first freeze a semantic payload derived
from existing durable facts; render surface-specific cards. Do not introduce a
model narrator, token stream, status cache, or byte-identical renderer.

**Smallest correction:** **Proposal:** name the payload owner and fields,
define safe goal-label provenance or omit it from the first slice, specify
redaction/size limits, and define projection revision/sequence behavior.

**Exact closure test/evidence:** **Proposal:** golden semantic tests for all
states, redaction and bounded-size tests, terminal/history invariants, and
Telegram/TTY receipt observations. Follow with blinded state/ref/next-action,
trust, annoyance, and actionability measurements separate from plumbing.

### F9 — Existing adapter and document paths are not reconciled before Slice 4

**Classification: Fact (scope and documentation risk).**

The repository already contains
`gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb:15-25`;
it invokes queue/worker/trace through the CLI at
`gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb:203-215,290-329`, and its tests assert the
command sequence and independent trace at
`test/openclaw_durable_cli_adapter_test.rb:14-36`. The older protocol README
and implementation plan point at nonexistent paths such as
`gems/tamoz-evals/lib/tamoz/evals/harness/sqlite_scenario_runtime.rb` and
`gems/tamoz-evals/lib/tamoz/evals/benchmark/openclaw_mission_runner.rb`
at `documentation/benchmark/openclaw-chat-study/README.md:45-47` and
`documentation/benchmark/openclaw-chat-study/03-implementation-plan.md:27-33`.

**Affected slice/seam:** Roadmap Slice 4 and the evidence index/benchmark
documentation.

**Failure mode/root cause:** **Inference:** a new “actual CLI harness” could
duplicate an existing durable CLI/trace adapter, while future reviewers cannot
locate the intended owner from the stale paths.

**Impact:** **Inference:** duplicated harnesses can disagree about provenance,
status, and failure handling; stale references make evidence claims harder to
reproduce.

**Scope-creep check:** **Proposal:** update the slice brief to reuse or extend
the existing `tamoz-evals-runner` adapter and name the comms-specific gap
separately. Do not add a second mission runner.

**Smallest correction:** **Proposal:** reconcile all benchmark paths and name
one authority for CLI subprocess execution, one for comms scenario driving,
and one for trace joining before implementation starts.

**Exact closure test/evidence:** **Proposal:** path/link consistency check;
adapter test showing actual queue/worker/trace invocation; comms runner test
showing required surface cells and witness joins; no duplicate evidence
publisher.

## 4. Seam-to-test-to-telemetry matrix

| Proposed slice | Existing owner/seam | Acceptance and failure cases | Targeted tests/evidence | Telemetry required | Real transport/provider gate |
| --- | --- | --- | --- | --- | --- |
| Slice 0 — typed interruption | `Worker#settle_paused_view`; `SessionPlanOutcomes#clarification_descriptor`; `OutboxDeliverySink#push`; gateway input/callback; existing approval prompt store | **Proposal:** clarify remains clarify, question is bounded, unanswered occurrence stays paused, valid answer resumes same occurrence. **Hard zero:** no approval evidence lookup/keyboard, no authority minting, no cross-occurrence or wrong-caller answer, no terminal claim. | `test/agent_outbox_delivery_sink_test.rb:115-187` is approval-shaped only; add worker-to-sink clarify test, replay/TTL/binding cases, then guarded channel answer/resume observation. | **Proposal:** clarification projection success/failure, prompt delivery, answer-to-resume latency, completion rate, misclassification count, wrong-target rejection. | Real Telegram question/answer receipt if supported. Real provider only if the clarify-producing path is under test; fixture descriptor is sufficient for plumbing. |
| Slice 1 — human projection | `Comms::Lifecycle`; `OutboxDeliverySink`; `Comms::Rendering`; gateway status/control reply; CLI rendering; existing outbox coalescing | **Proposal:** accepted, queued, worker-unavailable, working, clarify, approval, completed, failed, stopped, unknown all have bounded ref/state/now/next/delivery fields. **Hard zero:** state from model prose, raw secrets/paths/tool args, progress in history, unknown shown as delivered. | Add named golden semantic-card tests for Telegram and TTY, redaction/size/sequence tests, diagnostic JSON preservation, terminal/history tests. Existing `test/progress_projection_test.rb:144-361` proves coalescing/history only, not the proposed card. | **Proposal:** projection revision, source sequence, card pushes/edits, render failures, redaction/overflow counters, state-field retention. | Render tests use fixtures. Real Telegram send/edit receipt is required before claiming visible card behavior; provider not required for pure projection. |
| Slice 2 — handles and worker health | Gateway admission/ack; `CommsStore#requests_by_reference`; CLI queue/ask/status; gateway commands; worker claim/health; launcher | **Proposal:** one caller-bound ref resolves after reopen; exact status/cancel/redirect target; accepted vs queued-without-worker vs working vs waiting. **Hard zero:** cross-request control, false working claim, duplicate effect after worker restart. | Actual CLI subprocess with stdout/stderr/exit status; Telegram equivalent; two-ref isolation; kill/wedge/restart worker; stale heartbeat; no unhandled async exception. Current CLI test passes but emits the thread conflict noted in section 1. | **Proposal:** ack p50/p95, accepted-to-claim, worker-health freshness, unavailable duration, queue age, target accuracy, duplicate effect count, async exception count. | Real Telegram needed for surface parity/ack timing. Real provider not needed for identity/health, but provider provenance is required if a real execution is included. |
| Slice 3 — recovery/reconnect/attention | `OutboxDeliverySink#push_milestone`; `CommsOutbox` coalescing; Telegram edit transport; CommsStore history/status; drainer unknown resolution; CLI show/follow-up | **Proposal:** one acceptance/live card/≤2 meaningful edits/terminal; waiting and terminal interrupt quiet; reconnect gives one read-only summary; unknown never auto-resends. **Hard zero:** terminal truth suppressed, unknown retried, hidden context disclosed, duplicate terminal send. | Add C10/C13/C14 only after catalog/index entries and metric schemas are created; process restart, unknown-send, confirmed-only history, return and two-ref tests. Existing C2/C8 drivers are insufficient at `test/support/openclaw_comms_runner.rb:425-439,810-835`. | **Proposal:** first meaningful update, max silence, push/edit count, waiting/terminal latency, resend/abandonment, unknown resolution time, return comprehension, annoyance. | Real Telegram send/edit and unknown receipt required for transport claim. Real provider required for real slow-liveness/answer-quality claim, not for deterministic coalescing tests. |
| Slice 4 — evidence/release gate | `OpenclawCommsRunner`; scenario index/oracles/readiness; existing `OpenclawDurableCliAdapter`; actual CLI; Telegram transport; worker processes; observability journal | **Proposal:** missing cells block, actual surfaces/moments execute, two witnesses agree, real provenance is bound, usefulness is separate. **Hard zero:** fixture-as-real, artifact mismatch, missing cell ready, blind retry, false stopped, duplicate effect/send. | Reuse/extend existing adapter; add required-cell negative test, full matrix, CLI stderr test, C4 M1–M6, C8 runner observation, callback/pairing command path, forced witness mismatch, real run artifact validator. | **Proposal:** every metric includes scenario/surface/run_kind/sample/provenance; ack/first-update/silence/recovery/callback/terminal timings; task vs delivery outcomes; answer rubric fields. | Explicit private real-provider + real Telegram/recorded-live gate, credentials/cleanup/cost limits, durable receipts, independent trace digest. |
| Slice 5 — future channel decision | No current second-channel owner; current core is Telegram-closed at `InboundEnvelope` and `SurfaceDescriptor`; current transport is four-method structural seam | **Proposal:** enter only after Slices 0–4 and measured user need; choose one web or TUI, not both. **Hard zero:** new executor, stale control, cross-conversation leakage, unsupported action silently disappears, weakened approval. | First do static/read-only comparison on same two-ref/recovery tasks; then capability/isolation/stale-control/delivery/restart/human-comprehension tests for the one selected adapter. | **Proposal:** capability retention, stale-control rejection, reconnect/session errors, control accuracy, delivery ambiguity, security/operability, comprehension. | Real transport/provider only after a selected channel has an explicit security/deployment owner and passes the shared contract. |

**Inference — matrix result.** Slices 0–2 are conceptually bounded but need
explicit payload/handle/health decisions and named tests before implementation.
Slice 3 is partially specified and depends on undefined C10/C13/C14 artifacts.
Slice 4 is the strongest evidence plan but must reuse the existing adapter and
freeze the publication schema. Slice 5 is a decision gate, not an
implementation-ready slice.

## 5. Missing tests and evidence

| Category | Current evidence | Missing closure |
| --- | --- | --- |
| Unit/integration | **Fact:** approval-shaped sink tests pass at `test/agent_outbox_delivery_sink_test.rb:115-213`; lifecycle/coalescing tests pass in `test/progress_projection_test.rb:144-361`; gateway command/status tests exist in `test/comms_command_parity_test.rb:64-242`. | **Proposal:** clarify-to-outbox integration, human-card schema/redaction, stable-ref contract, worker-health state, and unsupported-capability behavior. |
| Crash/restart/replay | **Fact:** worker recovery tests exercise committed recovery milestones at `test/progress_projection_test.rb:468-509`; durable CLI adapter has subprocess plumbing at `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb:318-362`. **Fact:** B0 C4 runs a reduced fixture path at `test/support/openclaw_comms_runner.rb:542-567`. | **Proposal:** process-level gateway/worker M1–M6, effect receipt replay, terminal enqueue/send ambiguity, persisted DB reopen, and exact-ref recovery. |
| Concurrency/order/dedup | **Fact:** drainer fencing and unknown status are covered by `gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb:61-151` and `test/delivery_drainer_test.rb:100-118` (`test_crashed_send_boundary_becomes_unknown_without_a_retry`); callback binding/CAS tests exist in `test/callback_ack_crash_test.rb:192-245` (`test_callback_ack_precedes_the_turn_and_the_decision_survives_a_worker_restart`). | **Proposal:** two-ref cross-surface target races, clarification answer dedup/expiry, callback ack ordering receipt, concurrent gateway/worker admission, and no cross-conversation projection. |
| Real Telegram transport | **Fact:** production maps poll/send/edit/ack at `gems/tamoz-telegram/lib/tamoz/telegram/transport.rb:37-79`; tests use `TelegramFixtureServer` at `test/tamoz_telegram_transport_test.rb:16-27`. | **Evidence gap:** private real `getMe`, long poll, send/edit, callback ack, rate/timeout, actual receipt, and cleanup observation. |
| Real provider/model | **Fact:** B0 provider is deterministic at `test/support/openclaw_comms_runner.rb:26-32`; protocol reserves Track B for real provider at `documentation/benchmark/openclaw-chat-study/01-protocol-design.md:60-68`. | **Evidence gap:** real-provider task answer, model/provider provenance, cost, failure handling, effect receipts, and separate answer-quality rubric. |
| Operator/perceived quality | **Fact:** current catalog metrics are plumbing-oriented at `documentation/benchmark/openclaw-chat-study/02-scenario-catalog-and-scoring.md:39-60`. | **Evidence gap:** predeclared comprehension, correct next action, target accuracy, trust calibration, annoyance, recovery, abandonment/resend, and answer usefulness samples. |
| Observability | **Fact:** existing durable CLI adapter joins a trace at `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb:152-199`; B0 artifacts lack a trace field at `test/support/openclaw_comms_runner.rb:187-205`. | **Proposal:** independent witness digest, source/receipt join, required-field validation, forced mismatch hard zero, and no same-fixture “second witness.” |
| Rollback/stop conditions | **Proposal:** roadmap says render rollback and stop admission if clarification projection fails at `docs/openclaw-chat-study-refresh/02-decision-roadmap.md:158-168` (Rollout and rollback). | **Evidence gap:** no exact renderer version/config owner, rollback command, persisted-row behavior, operator alert, or stop/resume procedure. **Proposal:** freeze one current-schema version, name the reversible configuration, and test failed serialization/delivery without replaying unknown unsafe sends. |

## 6. Cross-document contradictions, stale references, and unsupported claims

1. **Fact — scenario state contradiction.**
   `documentation/benchmark/openclaw-chat-study/scenarios/SCENARIO_INDEX.json:19-31`
   marks C1–C9 `READY`.
   Scenario front matter still says `INCOMPLETE`, for example
   `documentation/benchmark/openclaw-chat-study/scenarios/C2-slow-liveness.md:7-8`
   and
   `documentation/benchmark/openclaw-chat-study/scenarios/C4-restart-boundary-matrix.md:7-8`.
   The scenarios README says the
   index is not consumed at
   `documentation/benchmark/openclaw-chat-study/scenarios/README.md:84-116`,
   while B0 consumes it at `test/support/openclaw_comms_runner.rb:62-83`.
   **Smallest correction:** one authoritative state vocabulary must distinguish
   fixture-ready, real-ready, inconclusive, and blocked, with a consistency test.

2. **Fact — stale implementation paths.** The protocol documentation names
   nonexistent paths such as
   `gems/tamoz-evals/lib/tamoz/evals/harness/sqlite_scenario_runtime.rb` and
   `gems/tamoz-evals/lib/tamoz/evals/benchmark/openclaw_mission_runner.rb`,
   while the existing durable CLI adapter is
   `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb:15-25`.
   Evidence is the stale references at
   `documentation/benchmark/openclaw-chat-study/README.md:45-47` and
   `documentation/benchmark/openclaw-chat-study/03-implementation-plan.md:27-33`.

3. **Fact — stale scenario filename.** The interaction review refers to
   `documentation/benchmark/openclaw-chat-study/scenarios/C4-restart-recovery-matrix.md`
   at `docs/openclaw-chat-study-refresh/specialist-reviews/02-interaction-product.md:29`;
   the current file is
   `documentation/benchmark/openclaw-chat-study/scenarios/C4-restart-boundary-matrix.md:1-8`.
   **Impact:** a closure
   test or reviewer can follow a nonexistent artifact.

4. **Fact — claimed parity exceeds executed surface.** The refresh evidence
   index says the canonical CLI leg bypasses the actual CLI at
   `docs/openclaw-chat-study-refresh/03-evidence-index.md:21-25`,
   while the canonical test and fixture directly submit to the runner at
   `test/canonical_cross_surface_composition_test.rb:209-216` and
   `test/support/openclaw_comms_fixture.rb:419-427`. The claim must remain
   “fixture composition,” not actual CLI parity.

5. **Fact — C8 readiness is broader than its oracle.** C8 is asserted `ready`
   by `test/benchmark_comms_b0_test.rb:235-279`, while its oracle reports parity
   and engine observation unavailable at
   `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb:603-629`.
   **Smallest correction:** block publication or narrow the C8 status to
   durable store-contract evidence.

6. **Inference — roadmap dependency ambiguity.** The roadmap gives a strict
   `Slice 0 -> Slice 1 -> ... -> Slice 5` graph, then says Slice 4's harness can
   develop in parallel after the scenario bar is frozen at
   `docs/openclaw-chat-study-refresh/02-decision-roadmap.md:150-156`
   (Dependency graph).
   This is resolvable, but the brief must distinguish harness development from
   readiness publication and from implementation of Slices 0–3.

7. **Inference — capability dependency is not placed in a slice.** The
   architecture and brainstorming reviews propose a capability matrix over
   `SurfaceDescriptor`, but the roadmap only requires a “capability descriptor”
   as a Slice 5 entry criterion. Current `SurfaceDescriptor::KINDS` is only
   `telegram` at `gems/tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:30-35`,
   and `Comms::Transport` has only four methods at
   `gems/tamoz-comms/lib/tamoz/comms/transport.rb:24-55`. **Proposal:** either
   make capability declaration an explicit bounded prerequisite when a second
   surface is selected, or remove it from current implementation scope. Do not
   let it grow into a plugin registry.

## 7. Smallest package corrections required before implementation

1. **Proposal — freeze the first change brief around Slice 0.** State the
   clarify/approval wire distinction, same-occurrence answer identity, expiry,
   caller/conversation binding, unsupported-surface behavior, exact test names,
   and real Telegram entry gate. This is the only confirmed production-path
   correctness defect and should precede copy work.

2. **Proposal — make evidence status admissibility binary and explicit.**
   Reconcile front matter, index, runner, artifact, and readiness states. Any
   required cell, metric, witness, or provenance field missing means
   inconclusive/blocked. Keep fixture runs permanently publication-blocked.

3. **Proposal — reuse the existing CLI adapter.** Update the Slice 2/4 brief
   to identify `OpenclawDurableCliAdapter` as the current queue/worker/trace
   owner, then add only the comms-specific actual CLI and Telegram join needed
   for parity. Correct the stale `tamoz-evals` documentation paths.

4. **Proposal — decide the handle and worker-health contracts before code.**
   Write the current-schema reference fields, synchronous/asynchronous CLI
   behavior, exact-ref control semantics, heartbeat source/freshness, and
   queue-versus-refuse policy. This is a cross-gem interface decision and must
   be approved before touching CLI/comms boundaries under `AGENTS.md:7-8`.

5. **Proposal — split plumbing closure from experience closure.** Name exact
   C4/C8 process moments, callback/pairing command paths, independent witness
   source, real-run command/environment, private task, cleanup, cost, and
   publication rules. Do not use golden cards or focused Minitest output as
   human-quality evidence.

6. **Proposal — narrow Slice 5 to a decision gate.** Do not implement “web or
   TUI” as one open-ended slice. Choose one only after a measured failure of
   Telegram/CLI, then name its owner, identity/capability/stale-control/
   security/deployment seams, and repeat the shared hard-zero tests.

## 8. Separate verdicts

### Content verdict — MEETS BAR WITH GAPS

**Fact:** the package separates facts, inferences, hypotheses, proposals, and
evidence gaps; maps the current Gateway/Worker/Session/EffectDispatcher/
outbox/drainer/CLI/Telegram seams; preserves the hard-zero safety invariants;
and provides a staged roadmap with explicit rejection of a second runtime.

**Finding:** the stale benchmark paths/state vocabulary, undefined future C10–C14
artifacts, and under-specified handle/health/capability decisions prevent a
fully decision-grade implementation brief without a small correction pass.

### Implementation-readiness verdict — NEEDS FIXES

**Fact:** F1 is a confirmed production-path clarification defect. F2–F7 are
unresolved high-severity implementation/evidence gates. The focused tests pass
but do not close these gates, and `test/agent_cli_test.rb` emits an unhandled
background lease conflict despite its zero exit status.

**Unresolved high-severity findings: 7.**

**Conclusion:** the roadmap is directionally sound and bounded in intent, but
it is not ready to authorize implementation or an experience-ready claim until
the seven high-severity findings are either corrected and evidenced or the
affected claims are explicitly narrowed/blocked. The smallest safe entry is a
frozen Slice 0 clarification brief plus the evidence-admissibility correction;
cross-surface handle and health changes require explicit cross-gem interface
approval.

## Exact deviations from the requested review execution

**Fact:** this report and the assigned progress log are the only intended
materialized outputs. No production, test, fixture, documentation sibling,
configuration, lockfile, or git metadata was edited; no commit was made.

**Evidence gap:** I did not run full `rake ci`, RuboCop, Enola, a real Telegram
transport, a real provider, a process-level C4/C8 matrix, or a human study in
this bounded review. Those are intentionally reported as missing evidence, not
as passed gates. I also did not modify sibling reports while they may be under
concurrent construction.
