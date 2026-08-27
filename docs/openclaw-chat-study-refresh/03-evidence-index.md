# Evidence index

This index prevents a design proposal from being mistaken for current
behavior. “Plumbing” means deterministic source/test evidence. “Real” means a
real provider or transport path with provenance. “Human” means a comprehension
or usefulness observation.

| Claim or decision | Class | Evidence | Current status |
| --- | --- | --- | --- |
| Telegram admission persists request and accepted delivery before execution | Fact | gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:31-70 | Confirmed plumbing |
| Task and delivery states are orthogonal | Fact | gems/tamoz-comms/lib/tamoz/comms/lifecycle.rb:7-24 | Confirmed plumbing |
| Milestones are bounded/coalesced; terminal rows are reserved | Fact | gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:28-161 | Confirmed plumbing |
| Unknown delivery is not blindly retried | Fact | gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:222-233 | Confirmed plumbing |
| Clarification is projected through an approval event | Fact | gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-734; gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:145-153 | Confirmed defect |
| Approval evidence lookup can raise for clarification | Fact | gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:248-257 | Confirmed by source; focused closure test still needed |
| Telegram approval is policy/evidence gated | Fact | gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:253-265; documentation/guides/telegram.md:135-150 | Confirmed plumbing/docs |
| Gateway and worker are separate foreground processes | Fact | documentation/guides/telegram.md:90-103; scripts/start-tamoz-comms.sh | Confirmed docs/source |
| User can be told accepted while no worker answers | Inference | Gateway/worker split above | Needs worker-health runtime observation |
| Telegram milestone text is ref plus internal phase | Fact | gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:123-161 | Confirmed source/fixture |
| Goal-oriented current/next-action card will improve comprehension | Hypothesis | Lane B report, section 6; brainstorming reports | Needs human comparison |
| CLI and Telegram expose different request handles | Fact | gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:220-241; gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb:224-255 | Confirmed source |
| Canonical CLI leg bypasses actual CLI | Fact | test/support/openclaw_comms_fixture.rb:145-163,419-427 | Confirmed test harness defect |
| B0 uses deterministic provider and fake transport | Fact | test/benchmark_comms_b0_test.rb:6-11; test/support/openclaw_comms_runner.rb:26-32 | Confirmed plumbing boundary |
| Five B0 scenarios omit CLI legs | Fact | test/support/openclaw_comms_runner.rb:41-48,133-168 | Confirmed readiness gap |
| Unavailable metrics can be excluded from readiness | Fact | test/support/openclaw_comms_runner.rb:161-168 | Confirmed readiness gap |
| C4 does not execute all declared restart boundaries | Fact | test/support/openclaw_comms_runner.rb:542-567; benchmark protocol C4 | Confirmed evidence gap |
| C8 clean-stop observation is manually stamped | Fact | test/support/openclaw_comms_runner.rb:810-835 | Confirmed evidence gap |
| Real Telegram polling, send/edit, and callback receipts are unproven | Evidence gap | FakeTransport in test/support/openclaw_comms_fixture.rb:75-119; production transport in gems/tamoz-telegram/lib/tamoz/telegram/transport.rb:45-79 | Not run |
| Real provider answer usefulness is unproven | Evidence gap | B0 deterministic provider; docs/openclaw-chat-study/implementation-plan/00-implementation-bar.md | Not run |
| Human comprehension, trust, and enjoyment are unproven | Evidence gap | No current participant instrument or real transcript | Not run |
| Core envelope and surface descriptor are Telegram-closed | Fact | gems/tamoz-comms/lib/tamoz/comms/inbound_envelope.rb:160-168; gems/tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:31,153 | Confirmed extension cost |
| Request-scoped runtime status aggregates delivery/effect state across a conversation/thread | Fact | gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:522-529,611-713; gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store_rows.rb:41-47 | Confirmed high-severity seam defect |
| Gateway cancellation is thread-oriented rather than exact-reference scoped | Fact | gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb:96-121; gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:988-994 | Confirmed high-severity control gap |
| Proposed clarification answer has no durable comms ingress | Fact | gems/tamoz-comms/lib/tamoz/comms/commands.rb:7-20; gems/tamoz-comms/lib/tamoz/comms/admission.rb:36-47,89-121 | Confirmed contract gap |
| Safe goal label has deterministic owner and redaction rules | Evidence gap | gems/tamoz-agent-session/lib/tamoz/agent/session_status_projection.rb:5-8,19-37,76-105 | Must be defined before human projection |
| Callback observed_at is derived from top-level message.date, absent on callback-only updates | Fact | gems/tamoz-telegram/lib/tamoz/telegram/normalizer.rb:34-48,69-80; test/telegram_normalizer_test.rb:80-99 | Confirmed medium defect (CF-5); must precede callback/latency telemetry |
| CLI test exits 0 despite an unhandled background CheckpointConflictError | Runtime observation | gems/tamoz-sqlite/lib/tamoz/sqlite/lease_operations.rb:50; gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:105-123 | Confirmed reliability defect (CF-6); reproduce before fixing |
| Benchmark impl-plan cites nonexistent tamoz-evals paths; OpenclawDurableCliAdapter is the real owner | Fact | docs/openclaw-chat-study/benchmark-protocol/README.md:45-47; gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb:15-25 | Confirmed doc/governance defect (EG-7); reconcile before Slice 4 |
| Future channel should be deferred | Proposal | Consolidated study and facilitator/Fourier synthesis | Decision recommendation |
| A local web or TUI is the candidate after gates | Proposal | Architecture report, Fourier challenge, roadmap Slice 5 | Candidate only; no implementation authorization |

## Verification runs used by the refresh

The pinned Ruby executable is
/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby. Focused runs completed before
consolidation:

- test/canonical_cross_surface_composition_test.rb — 1 run, 106 assertions,
  0 failures.
- test/benchmark_comms_b0_test.rb — 14 runs, 151 assertions, 0 failures.
- test/comms_gateway_test.rb — 35 runs, 194 assertions, 0 failures.
- test/progress_projection_test.rb — 12 runs, 360 assertions, 0 failures.
- test/cancellation_visibility_test.rb — 11 runs, 98 assertions, 0 failures.
- test/context_control_exposure_test.rb — 6 runs, 58 assertions, 0 failures.
- test/comms_pairing_first_contact_test.rb — 7 runs, 40 assertions, 0 failures.
- test/agent_cli_test.rb — 33 runs, 753 assertions, 0 failures, but an
  unhandled background CheckpointConflictError was emitted during the run;
  this is retained as an unresolved runtime evidence defect.

These runs are plumbing evidence only. The system ruby in PATH is 2.6.10 while
the repository pins 3.3.11; commands using the system ruby produced syntax
failures and are not product evidence.

## Evidence required before an experience-ready claim

1. A real, private Telegram/provider run with accepted, waiting, terminal,
   callback, and delivery receipts.
2. Actual CLI subprocess evidence with output, exit status, database reopen,
   and the same reference/control semantics.
3. Process-level C2/C4/C8 timing and restart evidence with an independent
   witness.
4. Separate human comprehension, actionability, trust, annoyance, recovery,
   and answer-quality measurements.
5. A reconciled scenario index/readiness state in which missing required cells
   are blocked or inconclusive, never silently omitted.
