# Phase 3 — unified context and lifecycle projection

Status: partial as of 2026-08-20. Requires: Phase 2; exit bar not met.

Study reference: Stage 3 (`04`), P3 (`05`), "Context, memory, and compaction"
(`04`).

## Goal

Long tasks stay coherent (durable compaction), Telegram and durable CLI share
session/context identity, and the user can see the work happen: tool
starts/results, approvals, waits, checkpoints, terminal state.

The current slice implements the bounded canonical turn payload, transcript
readback, allowlisted lifecycle projection, separated status fields, and
journaled bounded compaction for deliberation and adaptive decisions. Restart-
across-compaction, universal model-stage preparation, full CLI/Telegram trace
parity, and scheduler recovery projection remain open.

## Entry and sequencing gates

Phase 2's adaptive records and first vertical-slice trace are the input
contract. Define the canonical context/lifecycle wire before adding any
surface-specific renderer. Compaction must be durable before a long-task parity
run is accepted; scheduled visibility is limited to state the scheduler already
owns.

## Work items

1. **Durable compaction seam.** Extend `SessionPlanningContext#planning_context_for`
   and the existing `SessionEffects#model_call` path with a bounded compaction
   decision before prompt construction when the context budget is exceeded.
   Preserve goal, constraints, authority/catalog/graph revisions, plan/effect
   ids, approvals, decisions, pending work, authoritative observations, and
   next action. Externalize large observation bodies through the existing
   `Tamoz::SQLite::ArtifactStore`/`Adapter#bind_artifact_store` seam, retaining
   tenant, digest, byte count, provenance, and truncation metadata in a
   checkpointed reference. Effect receipts and verification facts remain
   outside the model-generated summary.
2. **Compaction failure semantics.** Journal the summarization model call with
   `SessionEffects`; record the compaction checkpoint and summary digest only
   after the effect completes. A failed/unknown summary retries only according
   to the model effect policy, then falls back to a smaller deterministic frame
   or terminally stops with a typed reason. A summary is never evidence,
   authority, or a replacement for a receipt. Add a kill/restart test around
   each commit boundary.
3. **Canonical context identity.** Define one bounded turn payload containing
   thread/session id, request id, ordered conversation fragments, and their
   digest. Telegram continues to use `CommsStore#conversation_history` and
   `CommsGateway#admit_request`; durable CLI follow-ups use the same canonical
   payload builder before `CLISessionCommands#submit_follow_up`. Both are read
   back through `SessionPlanningContext.transcript_from`, so a re-executed node
   sees identical bytes. The transcript is context only and cannot add
   authority or capability names.
4. **Canonical lifecycle projection polish.** Extend the Phase 2 minimum
   durable contract into one allowlisted semantic event
   wire for `model_turn`, `tool_started`, `tool_result`, `approval`, `wait`,
   `checkpoint`, and `terminal`, including request/thread/execution ids,
   iteration, effect key, phase, effect state, capability/source,
   provenance/truncation, and delivery state. Emit it from the durable session
   and worker seams, then have `Worker#notify_sink`/`OutboxDeliverySink`,
   `CLI#run_with_stream`/`cli_rendering.rb`, and Telegram rendering consume the
   same projection. Do not forward model tokens or raw remote content.
5. **Status separation.** Extend `SessionView`,
   `cli_rendering.rb#show_document`, `cli_worker_commands#build_status`, and
   `CommsGateway#status_text` so task state, effect state, capability state,
   and delivery state are distinct, bounded fields. A delivery success cannot
   imply task success; an effect `unknown` cannot appear as a completed task.
6. **Visible existing background work.** Project scheduler occurrences and
   worker recovery/open-occurrence handles from `Worker#materialize_due_schedules`,
   `Worker#work_list`, and `WorkerRuntime` into status with occurrence/request
   identity, authority/grant revision, phase, pause reason, and delivery
   outcome. Do not invent child-task handles here: Phase 4 owns delegation and
   must add its own durable child record before it becomes visible.

## Tests

- `test/agent_session_test.rb`, `test/agent_session_kill_matrix_test.rb`, and
  the artifact-store tests prove a long task with large outputs, pending
  approval, active plan, and unresolved work preserves goal, constraints,
  plan/effect ids, approval, next action, and digest-bound external evidence;
- failed and unknown summarization tests prove bounded retry/fallback and no
  fabricated evidence or authority;
- `test/comms_gateway_test.rb`, `test/agent_cli_test.rb`, and
  `test/agent_outbox_delivery_sink_test.rb` prove the same mission through
  Telegram and durable CLI yields the same canonical event sequence and
  identity fields; only presentation differs;
- restart across a compaction boundary resumes with preserved identifiers and
  one final delivery, with no duplicate effect or delivery;
- `test/agent_schedule_test.rb`, `test/scheduler_consumer_test.rb`, and
  worker status tests prove a scheduled occurrence exposes phase, pause/recovery
  reason, authority/grant revision, and delivery outcome without implying
  execution success.

## Exit bar

- Context/compaction and Telegram/CLI parity scenarios pass with fixtures and
  their canonical trace artifact is committed.
- A long adaptive mission (Phase 2 loop + compaction) completes through one
  restart with one final delivery, no duplicate effects, and externally
  resolvable evidence digests.
- Task, effect, capability, and delivery states are distinct in CLI and
  Telegram status documents.
- `rake ci`, `rubocop`, `enola check`, and `ci_full` in both locales are clean.
  Fixture results prove plumbing only; no real-provider claim is made here.

## Out of scope

New capability families, child-task delegation or child authority records
(Phase 4), raw token streaming, model/provider fallback policy, and memory
attribution measurement (Phase 5).
