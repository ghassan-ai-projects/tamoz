# Chat experience refresh — phased implementation plan

Version: v2 (revised after review loop 1; see `02-plan-review-log.md`).

This plan operationalizes `../02-decision-roadmap.md` and closes the canonical
findings in `../05-open-findings-ledger.md`. It is a plan, not evidence of a
working experience. The implementation-readiness verdict remains **NEEDS
FIXES** until the phase gates and the evidence gate pass. Each phase enters
through its own change brief, review, and gates; this document does not
authorize code changes by itself.

## Status framing

- What is true today: durable admission, orthogonal task/delivery state,
  bounded milestones, fenced delivery, and `unknown` handling are real and
  tested as plumbing.
- What is not true today: clarification cannot reach a channel (CF-1),
  request-scoped status and cancellation are not request-local (CF-2, CF-3),
  there is no portable operator handle or worker-health truth (DG-1, DG-2), the
  human card is undefined (DG-3), and no real-transport/provider or human
  evidence exists (EG-4..EG-6).
- What this plan does: sequences the smallest corrections that make one
  truthful, controllable work session real on Telegram and the actual CLI,
  behind a fail-closed evidence gate.

**Sponsor honesty note.** Phases 0–1 are correctness, not delight: they close
crashes and false status and are largely invisible to a user. Perceived
improvement is not claimable until Phase 2 renders the human card over those
now-authoritative facts, and it is not *proven* until Phase 4 measures it on a
real path. Progress will therefore look slow before Phase 2. This is
deliberate: the study's central failure mode is shipping a convincing card over
facts that are not yet true, and this plan refuses that trade.

## Global non-goals (rejected in writing)

No second runtime, event bus, in-memory status cache, model narrator, token
streaming, generic channel plugin registry, or new production channel in this
program. No Telegram approval grant beyond the policy/evidence contract. No
byte-identical cross-surface rendering. A new surface is a decision gate
(Phase 5), not a build phase.

## Hard-zero invariants (preserved by every phase)

Model proposes / policy decides; all external and nondeterministic work stays
behind `EffectDispatcher`; request/decision/delivery ownership and fence checks
stay authoritative; `unknown` is never converted to `delivered` or blindly
retried; only confirmed terminal content enters conversation history; channel
capabilities cannot broaden approval authority; fixture output is never
intelligence evidence.

---

## Phase 0 — Typed interruption and clarification ingress

**Closes:** CF-1, CF-4.

**Goal:** a clarification pause reaches the channel as a bounded question with a
durable, occurrence-bound answer path, and never enters the approval evidence
contract.

**Owner seams:**
- `Worker#settle_paused_view`, `interrupt_facts`, park/deadline metadata
  (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-735,996-1047,1099-1108`).
- `OutboxDeliverySink#push` interrupt branch and `decision_evidence`
  (`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:66-84,186-265`).
- `SessionPlanOutcomes#clarification_descriptor`
  (`gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:138-166`).
- Answer ingress: `Comms::Commands`, `Comms::Admission`, `Gateway::Callbacks`.

**Smallest correction:**
- Split the sink interrupt branch by descriptor `kind`: `clarify` emits a
  bounded question control row with a text-answer action; `approve_tool` keeps
  the existing approval prompt and evidence lookup unchanged.
- Carry `kind`/`reason` into park + deadline metadata so a clarify pause has
  clarify (not approval) expiry/resume semantics.
- Add one explicit durable answer ingress — `/answer <ref> <text>` (or a typed
  reply action) — that binds occurrence, correspondent, conversation, expiry,
  and replay, and resumes the same occurrence. Plain text stays a new request.
- If a bound surface has no text input, emit a typed durable/operator-visible
  unavailable notice; never raise, never route through approval.

**Entry criteria:** none beyond current typed interrupt descriptors.

**Exit criteria:** a real clarify pause is delivered and answerable on the
fixture channel with zero approval-path involvement and correct occurrence
resume; unsupported-surface path emits a typed unavailable notice.

**Named tests:**
- `test_clarification_pause_projects_a_bounded_question_without_approval_evidence`
  — one bounded question row; no approval keyboard; no `decision_evidence`
  lookup; occurrence stays paused; no `KeyError`.
- `test_clarification_answer_resumes_the_same_occurrence` — valid answer
  resumes; wrong-correspondent answer rejected; stale-occurrence answer
  rejected; duplicate answer deduplicated.
- `test_approval_prompt_unchanged_for_approve_tool_descriptor` — approval
  evidence/keyboard path is byte-for-byte unchanged (regression guard).
- `test_text_input_limited_surface_emits_typed_unavailable_notice`.

**Hard-zeros touched:** clarification answer is task data, never approval
evidence; occurrence/correspondent fencing preserved on the answer ingress.

**Rollout / rollback / stop:** fresh-schema for any new answer-ingress row. If
the clarify projection gate fails, **stop admitting new clarification waits**;
do not fall back to routing them through approval.

---

## Phase 1 — Request ownership, exact controls, portable handle, worker health

**Closes:** CF-2, CF-3, DG-1, DG-2.

**Goal:** every operator-visible request has one caller-bound reference and one
honest work state; status, cancel, and redirect target exactly one request;
worker availability is a durable, distinguishable fact.

**Owner seams:**
- Request-local status: `CommsStore#conversation_runtime_status`,
  `delivery_state_for`, `effect_state_for`; outbox row schema
  (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:522-529,611-713`;
  `comms_store_rows.rb:41-47`; delivery occurrence identity in
  `gems/tamoz-comms/lib/tamoz/comms/delivery.rb:64-85`).
- Exact-ref cancel: `gateway_commands#cancel_request`;
  `CommsStore#stamp_cancellation_requested!` (`comms_store.rb:987-994`);
  `CLISessionCommands` cancel/redirect.
- Portable handle: gateway admission acknowledgement;
  `CommsStore#requests_by_reference`; CLI `queue add`/`ask`/`status`.
- Worker health: gateway admission/status; worker claim/health;
  `scripts/start-tamoz-comms.sh`.

**Smallest correction:**
- Persist the originating request/occurrence identity on request-owned outbox
  rows (or an equivalent durable mapping queryable by request); make delivery
  and effect summaries filter by request; keep conversation-wide aggregates as
  a separately named method.
- Make cancel resolve a supplied reference through the same
  surface/conversation binding as request status and stamp only that request
  row; reject foreign/malformed/ambiguous refs without mutation.
- Project one caller-bound short reference through Telegram, attached CLI,
  queued CLI, status, cancel, and redirect; keep thread/occurrence IDs as
  internal authority handles shown only in diagnostic/JSON output.

**DG-2 worker-health design sub-decision (cross-gem; requires approval before
code).** DG-2 has two admissible shapes; the owner picks one before
implementation, because it is a cross-gem interface change under `AGENTS.md`:

- *Default (smaller):* derive `queued-without-observed-claim` from facts that
  already exist — an admitted request that no worker has claimed within a
  bounded window — with no new heartbeat producer. This distinguishes
  accepted / queued-unclaimed / working / waiting without new supervision.
- *Fuller (only if the default proves insufficient):* add a durable worker
  heartbeat. This requires naming the producer (which process writes it), the
  persistence row, the freshness window, and stale semantics, plus the
  queue-versus-refuse admission policy when health is stale. Do not build this
  shape without that named contract and cross-gem approval.

Either shape must never let "accepted" imply "working."

**Entry criteria:** Phase 0 need not complete first; Phase 1 may proceed in
parallel. Both gate Phase 2. The DG-2 sub-decision is recorded before code.

**Exit criteria:** request-local truth, exact targeting, portable handle, and
a distinguishable worker-availability state are authoritative and covered by
two-request and restart tests.

**Named tests:**
- `test_request_status_is_request_local_for_two_open_requests` — admit A and B
  on one conversation; force A `unknown`, leave B pending, then B succeeded;
  each ref shows only its own delivery/effect; holds after reopen and replay.
- `test_cancel_targets_one_reference_only` — cancel older ref; other ref
  unstamped and can complete; foreign/malformed/ambiguous ref rejected.
- `test_actual_cli_subprocess_handle_resolves_after_reopen` — real
  `queue add` prints a handle; caller exits; `worker --once` advances; status
  resolves the handle after DB reopen; stderr free of unhandled exceptions.
- `test_worker_unavailable_state_is_distinct_from_working` — admit while worker
  stopped; assert accepted/queued-unclaimed; start worker; same ref advances
  exactly once, no duplicate effect. (Asserts the chosen DG-2 shape.)

**Hard-zeros touched:** refs are correspondent/conversation-bound, not
authority tokens; no legacy-row compatibility; accepted never implies started;
no duplicate effect after restart.

**Rollout / rollback:** fresh-schema outbox mapping; roll back to
conversation-scoped read only if the request-local mapping fails tests, never
by weakening ownership.

---

## Phase 1b — Independent correctness fixes

**Closes:** CF-5, CF-6.

**Goal:** two standalone reliability defects that couple to nothing in the
ownership work but must land before their downstream consumers. Separated from
Phase 1 so the ownership review surface stays small.

**Owner seams:**
- CF-5: `Telegram::Normalizer#normalize` timestamp extraction
  (`gems/tamoz-telegram/lib/tamoz/telegram/normalizer.rb:34-48,69-80`).
- CF-6: `CLI#run` rescue scope (`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:105-123`);
  `CheckpointStore#open_writer`/`lease_operations`.

**Smallest correction:**
- CF-5: use the callback message's own date when present; define an explicit
  ingestion-time fallback when absent.
- CF-6: reproduce the checkpoint conflict under a subprocess harness first,
  then make unexpected worker-thread exceptions fail the command or emit a
  typed terminal failure. If the race is test-only, prove it with an isolated
  reproduction and document the boundary.

**Sequencing:** independent; may land any time. **CF-5 is a strict predecessor
of any callback-ack or latency telemetry in Phase 4 (EG-3/EG-5)** — an epoch
timestamp would corrupt those measures.

**Named tests:**
- `test_callback_observed_at_uses_callback_message_date` (CF-5) — asserts the
  value equals the embedded message date and is not epoch when a date exists.
- `test_cli_command_fails_or_reports_typed_failure_on_worker_thread_exception`
  (CF-6) — stderr free of unhandled exceptions; exit status reflects the
  failure.

**Hard-zeros touched:** none directly; CF-6 strengthens the CLI error contract.

---

## Phase 2 — Bounded human projection

**Closes:** DG-3, MG-2, MG-4.

**Goal:** every default update answers state, reference, now, next, and delivery
certainty, over frozen durable facts, without diagnostics or model-authored
authority.

**Dependency:** strict — Phases 0 and 1 must freeze interruption kinds,
request-local ownership, exact controls, and worker-health facts first. A card
built earlier can make the wrong request look complete.

**Owner seams:** `Comms::Lifecycle`; `OutboxDeliverySink`; `Comms::Rendering`;
`Gateway::StatusProjection`; `SessionStatusProjection`; CLI rendering.

**Smallest correction:**
- Freeze a versioned semantic payload (ref, task_state + reason_category,
  delivery_state, worker_availability, safe_phase, next_action,
  verification_class, projection_revision, allowed_actions) produced at the
  existing projection seams — not a new `HumanProjection` store/class unless
  duplication across sink/status/rendering is first demonstrated.
- Define a deterministic, framework-owned safe-goal-label producer with a
  redaction test, or omit the label from Phase 2 and add it later.
- Publish one mapping table from target states to `Comms::Lifecycle` states
  (MG-2) and test it.
- Route human CLI streaming through the same projection so task/update parts
  are no longer dropped (MG-4); keep JSON/NDJSON lossless.

**Entry criteria:** Phases 0 and 1 exit gates pass.

**Exit criteria:** golden semantic cards for every state exist with redaction
and bounded-size guarantees; diagnostics remain lossless; no milestone enters
history.

**Named tests:**
- `test_human_card_has_bounded_fields_for_every_state` — accepted, queued,
  worker-unavailable, working, clarify, approval, completed, failed, stopped,
  delivery-unknown; each with stable ref and bounded copy.
- `test_human_card_redacts_secrets_paths_tool_args_and_model_prose`.
- `test_diagnostic_projection_remains_lossless`.
- `test_safe_goal_label_is_framework_owned_and_redacted` (or documented
  omission).
- `test_target_state_to_lifecycle_mapping` (MG-2).
- `test_cli_human_stream_renders_task_and_update_parts` (MG-4) — the human CLI
  stream no longer drops task/update parts; JSON/NDJSON remains lossless.

**Hard-zeros touched:** pure projection, no store/state machine; no model
narrator; no provider/tool call in any renderer; unknown never shown as
delivered.

**Rollout / rollback:** versioned rendering/schema; roll back to the last
bounded renderer if serialization/redaction/delivery tests fail; diagnostics
stay available throughout.

**What this phase does not prove:** that a human understands the card, or that
the model's answer is useful. Those are Phase 4 measurements.

---

## Phase 3 — Recovery, reconnect, and attention budget

**Closes:** MG-1, MG-3; recovery/unknown-delivery UX.

**Goal:** long work is calm but not silent; a returning user recovers without
guessing or resending; unknown delivery is explicit and never auto-resent.

**Dependency:** strict — after Phases 1–2 (stable refs and typed cards).

**Owner seams:** `OutboxDeliverySink#push_milestone`; `CommsOutbox`
coalescing; Telegram edit transport; `CommsStore` history/status; drainer
unknown resolution; CLI show/follow-up; gateway status.

**Smallest correction:**
- Default Telegram budget: one acceptance, one editable live card, at most two
  meaningful edits, one terminal card; **waiting, terminal, and
  worker-unavailable transitions always interrupt quiet mode**; no-visible-change
  heartbeats do not notify. The worker-unavailable signal introduced in Phase 1
  must never be suppressible as a quiet heartbeat — that would re-create the
  "is it alive?" silence this program targets.
- One read-only "since you were away" card bounded by a last-seen cursor or
  snapshot boundary (MG-1); it never resends an unknown terminal answer.
- Project `delivery: uncertain` explicitly with a safe operator-resolution
  next action; keep the attention budget as a measured default, never a reason
  to suppress terminal truth (MG-3).

**Entry criteria:** Phases 1–2 exit gates pass.

**Exit criteria:** attention budget, return card, and unknown-delivery wording
are implemented and covered; confirmed-only history preserved.

**Named tests:**
- `test_attention_budget_one_live_card_two_edits_one_terminal`.
- `test_waiting_and_terminal_transitions_always_notify`.
- `test_since_you_were_away_is_read_only_and_bounded_by_cursor`.
- `test_unknown_delivery_is_explicit_and_never_auto_resent`.
- `test_confirmed_only_history_after_reconnect`.

**Hard-zeros touched:** terminal/waiting truth never suppressed by budget; no
blind resend; no hidden context echoed in a return card.

**Rollout / rollback:** cadence and budget are configuration; roll back to the
current coalescing default without changing durable facts.

**What this phase does not prove:** real Telegram edit/notification behavior or
that the budget reduces annoyance — Phase 4 measures those.

---

## Phase 4 — Evidence and release gate

**Closes:** EG-1, EG-2, EG-3, EG-4, EG-5, EG-6, EG-7.

**Goal:** stop calling fixture plumbing an experience result; make readiness
fail-closed and bind real runs to an independent witness.

**Owner seams:** `OpenclawCommsRunner` (`SURFACES_DRIVEN`, `metrics_ready?`,
scenario drivers); comms oracles; `OpenclawDurableCliAdapter` (the existing CLI
subprocess/trace owner — reuse, do not duplicate); `Telegram::Transport`; real
provider configuration; scenario index/front matter/README; artifact manifest.

**Smallest correction:**
- **EG-7 first (pre-work):** reconcile scenario front matter / index / README /
  runner into one state vocabulary (fixture-ready, real-ready, inconclusive,
  blocked); fix stale `tamoz-evals` paths to name `OpenclawDurableCliAdapter`.
- **EG-1:** any required surface/metric/moment that is unavailable yields
  blocked/inconclusive and no publishable axis; unavailable values cannot be
  filtered before the ready decision.
- **EG-2:** the CLI benchmark leg invokes the actual queue/worker/status
  commands via the existing adapter; direct `durable_runner.submit` stays only
  in the fixture plumbing test.
- **EG-3:** C2 virtual-clock multi-phase liveness; C4 process-level M1–M6 with
  fresh processes and persisted DB; C8 blocks an in-flight boundary and lets
  the runner write `observed`, with failed-settle and completed-before-cancel
  variants.
- **EG-4:** bind each artifact to an independent trace digest collected without
  advancing the turn; force a mismatch and assert a hard-zero.
- **EG-5:** one guarded, private, credentialed real-provider + real-Telegram
  happy path with accepted/waiting/terminal/callback/send/edit receipts,
  provider/transport provenance, cleanup, and a cost limit.
- **EG-6:** a separate usefulness instrument — blinded operator ratings for
  clarity, confidence, actionability, interruption burden, plus a task-specific
  answer-quality rubric — reported by (scenario, surface, run_kind, sample),
  never merged with plumbing pass-rates.

**Entry criteria:** the scenario/index/state vocabulary is frozen (EG-7). The
harness (EG-1/EG-2/EG-3/EG-4) may be built in parallel with Phases 0–3, but no
readiness may be published before Phases 0–3 define what is measured.

**Exit criteria:** removing one required cell yields non-ready; the full Track-A
matrix has every declared cell; one real happy-path artifact exists with two
agreeing witnesses; usefulness is reported separately.

**Named tests / evidence:**
- `test_missing_required_surface_yields_non_ready` (EG-1).
- `test_benchmark_cli_leg_invokes_actual_cli_commands` (EG-2).
- `test_c4_process_restart_m1_through_m6_no_duplicate_effect_or_send` (EG-3).
- `test_c8_runner_observed_cancellation_requested_le_observed` (EG-3).
- `test_artifact_requires_independent_trace_and_forced_mismatch_is_hard_zero`
  (EG-4).
- Real-run artifact validator + a private real run record (EG-5).
- Usefulness/answer-quality report schema (EG-6).

**Hard-zeros touched:** fixture published as real; artifact mismatch; missing
required cell reported ready; ack before admission; stale-owner send; duplicate
effect/send; blind retry after unknown; false stopped.

**Rollout / rollback:** readiness/publication logic is code-reviewed and
fail-closed; a real run that cannot bind an independent witness is inconclusive,
not ready. Real runs never write credentials into artifacts.

**What this phase does not prove:** broad readiness from one happy path. The
real run is an entry gate, not proof of the whole matrix.

---

## Phase 5 — Future channel decision gate (decision only)

**Closes:** DG-4 as a prerequisite; no build.

**Goal:** decide whether a third surface is justified — not build one.

**Entry criteria:** Phases 0–4 pass; actual Telegram and CLI show semantic
parity; a named high-value workflow still fails because Telegram/CLI cannot
represent multi-ref history, diagnostics, or controls within their attention
limits, evidenced by comprehension/completion/recovery data.

**If entered:** add an allowlisted capability matrix to `SurfaceDescriptor`
(not a plugin registry); choose one small local web **or** TUI (not both);
first slice is a read-only operator view over durable facts; mutation follows
only after stale-view and request-target fencing pass. The new surface repeats
every shared hard-zero gate and adds no second executor.

**Exit criteria (if built later):** the new surface passes the same durable
request, identity/isolation, delivery ambiguity, restart, action-authorization,
and human-comprehension gates.

---

## Dependency graph

```text
Phase 0 (interruption) ─┐
                        ├─> Phase 2 (projection) ─> Phase 3 (recovery) ─┐
Phase 1 (ownership)  ───┘                                               ├─> Phase 5 decision
Phase 1b (CF-5, CF-6) ── independent; CF-5 precedes Phase 4 telemetry    │
Phase 4 harness (EG-7 -> EG-1/2/3/4 build) ────────────────────────────┘
        └─ readiness publication requires Phases 0–3 complete + EG-5/EG-6
```

- Phases 0 and 1 may proceed in parallel; both are strict predecessors of
  Phase 2.
- Phase 1b is independent and may land any time; CF-5 is a strict predecessor
  of Phase 4's callback-ack/latency telemetry (EG-3/EG-5).
- Phase 4's harness (EG-7 → EG-1/EG-2/EG-3/EG-4) may be built in parallel with
  Phases 0–3, but its **assertions cannot pass** until their subjects land:
  EG-3's C4 process-restart assertions depend on Phase 1's worker-restart and
  request-local semantics. **Readiness publication** and the real run
  (EG-5/EG-6) require Phases 0–3 to define what is measured.
- Phase 5 is a decision gate reached only after Phase 4 evidences a need.

## Cross-cutting sequencing rules

- No human-projection copy (Phase 2) ships before its facts are authoritative
  (Phases 0–1). This is the study's central sequencing lesson.
- No phase's tests are cited as readiness before Phase 4's admissibility gate
  is in place.
- CF-5 (callback timestamp) lands before any callback-ack/latency telemetry in
  EG-3/EG-5 is trusted.
