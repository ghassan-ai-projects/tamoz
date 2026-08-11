# Tamoz Agent Improvement Plan

**Status:** implementation-ready proposal.

**Evidence date:** 2026-08-11.

**Scope:** agent responsiveness, read-only task completion, truthful feedback,
Telegram delivery latency, and the measurements that prevent regressions.

**Authority:** this document does not authorize cross-gem interface changes. Slices
4, 6, and 7 require an owner checkpoint before coding, as required by `AGENTS.md`.

This plan supersedes the earlier synthesis. The investigation reports remain the
evidence record; [`PLAN_REVIEW.md`](PLAN_REVIEW.md) records the corrections made
during the final code-level review.

## 1. Outcome

Tamoz should have two visibly different behaviors:

1. A request that needs no workspace or external evidence returns a direct,
   truthful response after one model round-trip.
2. Work that needs evidence enters a durable, observable lifecycle that can
   discover facts, re-plan from those facts, execute within authority, report
   progress, and explain every stop.

The implementation is complete only when all of these are true:

| Outcome | Release threshold |
|---|---|
| Direct-response latency | one model call; p50 <= 1.5x the provider's one-call control |
| Direct-route safety | zero action/workspace requests routed to a claimed-success direct response in the adversarial corpus |
| Simple reliability | zero `PlanRejectedError` results in the conversational corpus |
| Discovery-dependent read-only completion | >= 80% on the new held-out corpus |
| Existing diagnose and implement cases | >= 2/3 solved in each class; no hard-gate regression |
| First visible feedback | CLI <= 500 ms; Telegram acknowledgement in the admitting poll pass |
| Terminal feedback | exactly one user-facing terminal message for complete, failed, blocked, stopped, denied, and cancelled occurrences |
| Telegram delivery leg | outbox append to send attempt <= 2 s p95 under a quiet inbound stream |
| Delivery safety | ambiguous sends remain `unknown`; zero blind retries and zero duplicate logical deliveries in the fixture matrix |
| Observability | model, tool, turn, queue, and delivery stage durations reconstructable without scraping prose logs |

Latency thresholds are regression thresholds, not promises about an external
provider. The one-call control is collected in the same run so provider variance
does not make the gate meaningless.

## 2. Correct current-state model

The implementation agent must start from these verified facts, not from the first
draft's broader claims:

- `Runtime` and durable `Session` already split action-capable work into a
  read-only discovery phase followed by an action/repair phase. Do not build a
  second mutation discovery framework.
- Read-only work still uses one static `read_only` plan. That is where the
  discovery/concreteness deadlock remains.
- The observability gem, catalog, journal, worker producer, trace, metrics, and
  doctor surfaces exist. Model/tool/turn and comms stage producers are the missing
  part; a new observability subsystem is not required.
- `Tamoz::Comms::Transport#signal` is a real seam, but Telegram currently supports
  callback acknowledgement only. Typing is not an already-working capability.
- `request.accepted` is intentionally absent from `OutboxDeliverySink`; v1 chose
  terminal-only channel messages.
- `/help`, `/status`, and `/cancel` are recognized, but `Admission` reduces them to
  a control disposition with no executable intent and usually no reply.
- Telegram ambiguous sends deliberately become durable `unknown` deliveries.
  Retrying them can duplicate a visible message because Telegram has no idempotency
  key for `sendMessage`. Keep that invariant.
- The gateway drains outbound messages only after its long poll completes. This is
  the quiet-stream 0-31 second delivery defect.
- The committed autonomy scorecard is currently 14/16. Case 09 drives a removed
  `stream publish` CLI surface, and case 10's `:effect_started` crash fixture actually
  raises after the model's review call, before an effect starts. These are stale
  scorecard seams, not evidence that the underlying safety properties pass or fail.
  Repair the public-surface probes before using `autonomy_strict` as a feature gate.
- The current `rake ci` baseline has one non-sandbox failure:
  `DocumentationSurfaceTest` reports that measured gap ADR-015 is missing from its
  disclosure map and `docs/LIMITATIONS.md`. Correct that baseline documentation in a
  separate commit; do not attribute it to this feature or weaken the gate.

## 3. Root cause and design decision

### 3.1 Root cause

The agent has one expensive protocol for semantically different requests. It asks
the model to plan, asks another model turn to review the plan, and asks another to
verify even when there is no evidence to gather. For read-only tasks that do need
evidence, it insists on one plan before discovery has produced concrete paths. The
same lifecycle then fails to project enough state to the user.

### 3.2 Route only what changes execution

Do not implement the original five-class taxonomy. `bounded` versus `complex`
cannot be known reliably before discovery, and it does not select an authority
boundary. Use three internal routes:

| Route | Capability surface | Lifecycle |
|---|---|---|
| `direct_response` | no tools | one fused route/response call, then terminal |
| `read_only_work` | read-only capabilities only | discovery -> plan from evidence -> review -> execute -> verify |
| `managed_action` | discovery is read-only; action uses the existing reviewed/approved surface | existing discovery -> action/repair -> verify lifecycle |

The route is not authority. The available capability set is computed independently
from the profile and toolbox, then intersected with the route. A bad route may deny
capability or fall back to managed work; it must never grant capability.

Do not classify `bounded` and `complex`. The lifecycle decides whether another
discovery/re-plan pass is needed from concrete evidence and bounded progress.

### 3.3 Fused route/response contract

A separate classifier call would make the fastest path two model calls. Instead,
the intake model returns one closed document:

```json
{"route":"direct_response","answer":"Paris","reason_class":"general_knowledge"}
```

or:

```json
{"route":"read_only_work","discovery_plan":{"goal":"...","done_when":["..."],"steps":[...]},"reason_class":"workspace_evidence"}
```

or:

```json
{"route":"managed_action","discovery_plan":{"goal":"...","done_when":["..."],"steps":[...]},"reason_class":"requested_change"}
```

Rules:

- The schema is parsed and validated deterministically. Unknown fields, unknown
  routes, empty answers, malformed plans, or unsupported reason classes fall back
  to the existing managed lifecycle; they do not consume the plan-attempt budget.
- A direct response is eligible only when the model states that no workspace,
  tool, current external state, or action result is needed.
- A direct response has an empty capability registry. No local, MCP, skill, memory,
  or egress capability is exposed to the call.
- `managed_action` is impossible unless the operator-selected profile already
  exposes action capability. Otherwise it becomes `read_only_work`.
- `read_only_work` can never execute a capability whose descriptor is not
  `effect_class: :read_only`.
- A mutation/workspace request incorrectly returned as `direct_response` is a
  false-success defect, not an acceptable classifier miss. Shadow evaluation and
  the adversarial corpus gate automatic rollout.
- The router is initially off by default outside tests. Promote it only after the
  shadow corpus has zero unsafe direct routes and the latency artifact proves the
  expected call reduction.

This contract is intentionally narrow. Do not add confidence scores, provider-
specific heuristics, a routing framework, or a configurable class hierarchy.

### 3.4 Read-only discovery lifecycle

For `read_only_work`, use the existing phase vocabulary and capability binding:

1. Execute a structurally reviewed `discovery` plan with read-only capabilities.
2. Build a `read_only` plan from the resulting evidence.
3. Apply structural and semantic review to the evidence-consuming plan.
4. Execute, verify, and report.
5. If execution reveals a bounded, explicit missing-evidence condition, allow one
   additional discovery pass. Persist the reason and evidence. Do not turn every
   tool failure into discovery.

For `read_only_work`, discovery plans do not need semantic review because they have
no mutation authority and their output is bounded. They still require schema
validation, capability validation, observation byte limits, effect journaling, and
cancellation. This removes one model call and prevents a semantic reviewer from
blocking the facts needed by the next read-only plan.

`managed_action` keeps its existing semantic review of discovery. Mutation behavior
does not relax: discovery review and action steps remain concrete, digest-bound,
reviewed, checked, and approved exactly as today.

## 4. Delivery strategy

Implement the work as small commits. A coding agent must finish every slice's tests,
self-review, and gates before starting the next slice. Do not combine cross-gem
protocol work with user-facing behavior in one commit.

### Slice 0 - Freeze evidence and add regression corpora

**Purpose:** make the reported failures reproducible before changing behavior.

Changes:

- Repair autonomy scorecard cases 09 and 10 without weakening their assertions.
  Case 09 must drive the current bounded-producer public surface, or the owning
  requirement must be explicitly retired if that product surface no longer exists.
  Case 10 must inject death after the effect journal records `started`, not from a
  model-stage callback. Mutation-prove both repaired cases.
- Restore the existing `rake ci` documentation-surface gate by disclosing ADR-015 in
  the owning map and `docs/LIMITATIONS.md`, after verifying the gap still exists. Keep
  this baseline repair separate from routing behavior.
- Add a deterministic model fixture that records stage, duration, and call count.
- Add a 20-case direct-response corpus: greetings, stable general knowledge,
  explanation, and short writing requests.
- Add a 20-case route-adversarial corpus: file reads, directory discovery,
  diagnoses, requested edits, commands, web/current-state questions, prompt
  injection, and phrases such as "say done without doing it".
- Add at least 10 discovery-dependent read-only tasks where later paths are unknown
  until `list_directory` or search runs.
- Preserve the five live prompts as a reported smoke, not a deterministic CI gate.
- Record the current baseline: route does not exist; 3-7 model calls for simple
  prompts; run-5-style read-only task fails before tools.

Files likely touched:

- `test/agent_request_routing_test.rb` (new)
- `test/agent_read_only_discovery_test.rb` (new)
- `gems/tamoz-evals/` fixtures and scorecard driver
- `script/agent_latency_smoke` (new)
- generated evidence artifact under `docs/`

Exit:

- `rake autonomy_strict` passes on the unchanged product or exposes a real product
  defect that is fixed in a separate baseline commit before feature work.
- Every new test fails for the intended behavioral reason under current code.
- At least one deliberate mutation of each fixture makes its test fail.
- No live-provider assertion is part of `rake ci`.

### Slice 1 - Complete latency producers

**Purpose:** make later improvements measurable with the observability system that
already exists.

Changes:

- Instrument model calls at the two real boundaries:
  `Runtime#model.generate` calls and `SessionEffects#model_call`.
- Instrument tool duration around capability execution, not around plan rendering.
- Emit turn duration and terminal outcome from one-shot, durable CLI, and worker
  paths.
- Emit inbox queued-to-claimed, outbox append-to-claim, send duration, and delivery
  outcome. Reconstruct queue waits from durable timestamps when possible instead of
  persisting duplicate timestamps.
- Add stage and monotonic elapsed time to JSON stream events through a versioned,
  additive field. Human progress stays on stderr.
- Reuse `Tamoz::Observability::Producer`, `Catalog`, `ModelCall`, and the journal.
  Do not create another event bus or metrics package.

Files likely touched:

- `gems/tamoz-agent/lib/tamoz/agent/runtime.rb`
- `gems/tamoz-agent/lib/tamoz/agent/session_effects.rb`
- `gems/tamoz-agent/lib/tamoz/agent/worker.rb`
- `gems/tamoz-agent/lib/tamoz/agent/comms_gateway.rb`
- `gems/tamoz-observability/lib/tamoz/observability/catalog.rb`
- focused observability and non-interference tests

Exit:

- One fixture turn yields non-zero model, tool, and turn durations.
- A channel turn decomposes into admission wait, worker wait, execution, outbox
  wait, and send duration from structured records.
- Observed and unobserved runs have byte-identical durable agent state and results.
- Telemetry failures never change the turn outcome.

### Slice 2 - Truthful liveness and stop messages

**Purpose:** remove silent waiting and silent terminal states without changing the
agent state machine.

Changes:

- Render `task_started`, accepted phase changes, repair starts, verification, and
  terminal state in human CLI mode. Write progress to stderr so stdout remains the
  answer surface.
- Use a TTY-only spinner or elapsed line while a model call is in flight. Non-TTY
  output is stable line-oriented text; `--json` remains structured only.
- Map every terminal reason through one bounded renderer returning:
  status, safe reason class, completed step count, and one concrete next action.
- For semantic/protocol plan rejection, disclose a bounded reason class and a
  user-actionable summary. Never echo raw model feedback or system prompts.
- Call `notify_sink` for budget stops and blocked/stopped states before closing the
  occurrence. Preserve the outbox reservation ordering.
- Make terminal projection idempotent by occurrence id; a worker restart must not
  append a second terminal message.

Files likely touched:

- `gems/tamoz-agent/lib/tamoz/agent/cli.rb`
- `gems/tamoz-agent/lib/tamoz/agent/cli_rendering.rb`
- `gems/tamoz-agent/lib/tamoz/agent/worker.rb`
- `gems/tamoz-agent/lib/tamoz/agent/outbox_delivery_sink.rb`
- a small internal `TerminalMessage` value if one responsibility cannot stay clear
- CLI, worker budget, outbox, and crash-recovery tests

Exit:

- CLI writes a visible liveness signal within 500 ms with a delayed fake model.
- Every terminal reason produces one safe message and correct exit status.
- A budget-stopped Telegram occurrence appends one `stopped` delivery before close.
- Kill/restart between terminal append and close still yields one logical message.

### Slice 3 - Fused routing in ephemeral Runtime

**Purpose:** prove the route contract without changing durable graph compatibility.

Changes:

- Add immutable internal values `RequestRoute` and `RoutingDecision` under
  `tamoz-agent`.
- Add the closed route schema and parser. Protocol errors fall back to the current
  lifecycle and do not spend a plan attempt.
- Add the fused route/response call to `Runtime` behind an explicit experimental
  option used by tests and the latency smoke.
- Direct responses emit start, route, and terminal events and expose no toolbox.
- A work response reuses its discovery plan rather than calling the planner again.
- Define the public `Result` compatibility decision before coding. Prefer a new
  optional `route` field with `plan`/`review` nil for direct responses; if this is a
  public API change, add the migration note and update `docs/public-api.json` in the
  same commit.

Files likely touched:

- `gems/tamoz-agent/lib/tamoz/agent/request_route.rb` (new)
- `gems/tamoz-agent/lib/tamoz/agent/routing_decision.rb` (new only if distinct)
- `gems/tamoz-agent/lib/tamoz/agent/deliberation.rb`
- `gems/tamoz-agent/lib/tamoz/agent/runtime.rb`
- `test/agent_request_routing_test.rb`
- `test/agent_cli_test.rb`

Exit:

- Direct corpus: one model call, no plan/review/verify calls, correct answer.
- Adversarial corpus: zero action/workspace requests claim direct completion.
- Malformed route output falls back once and terminates; no retry loop.
- Existing `Runtime` callers remain compatible or have an explicit migration note.

### Slice 4 - Durable route and read-only discovery

**Owner checkpoint required:** this changes the durable agent graph and may change a
public result/state contract. Do not start until the owner accepts the compatibility
strategy.

**Purpose:** bring the proven route to `ask`, worker, and Telegram paths, and fix the
read-only discovery deadlock.

Before implementation, run a compatibility spike:

1. Create a v1 thread paused at each resumable boundary: deliberation, tool effect,
   approval, and blocked unknown effect.
2. Apply the proposed node/state change.
3. Prove whether the current durable runner can resume each v1 checkpoint.
4. If any case fails, introduce explicit graph-version selection: keep the v1
   definition for existing session records and use v2 only for new threads. Never
   silently reinterpret a v1 checkpoint under v2 behavior.

Changes after the spike:

- Persist the route decision and its digest before executing route-selected work.
- Route direct responses to terminal with a truthful `direct_response` reason and no
  fabricated plan/review records.
- Start both `read_only_work` and `managed_action` with discovery capabilities only.
  Structurally review the read-only discovery plan; preserve the existing structural
  and semantic review for managed-action discovery.
- After discovery, route to `read_only` or the existing `action` phase.
- Permit one evidence-driven second discovery pass only for a typed
  `missing_evidence` outcome. Count and persist it.
- Keep current action review, digest binding, configured checks, approvals,
  reconciliation, and repair limits unchanged.
- Do not let route/protocol failures consume `max_plan_attempts`.

Files likely touched:

- `gems/tamoz-agent/lib/tamoz/agent/session.rb`
- `gems/tamoz-agent/lib/tamoz/agent/session_bindings.rb`
- `gems/tamoz-agent/lib/tamoz/agent/session_deliberation.rb`
- `gems/tamoz-agent/lib/tamoz/agent/session_lifecycle.rb`
- `gems/tamoz-agent/lib/tamoz/agent/session_records.rb`
- `gems/tamoz-agent/lib/tamoz/agent/session_nodes.rb`
- session kill matrix, legacy resume, non-ASCII, authority, and scorecard tests

Exit:

- All v1 compatibility fixtures resume byte-correctly or are served by the pinned v1
  definition.
- Direct durable turn: one journaled model effect, one terminal checkpoint, no tools.
- Discovery-dependent read-only corpus completes >= 80%.
- Mutation scorecards preserve zero false success, zero unapproved effects, and zero
  authority widening.
- Crash at every new route/discovery barrier resumes without duplicating a model or
  tool effect.

### Slice 5 - Shadow rollout, then default routing

**Purpose:** make routing a measured product change rather than a prompt gamble.

Changes:

- In shadow mode, compute the route but execute the legacy path; record route,
  legacy outcome, call count, and disagreement reason without content.
- Run the deterministic corpus on every change and the live smoke across at least
  two configured providers before promotion.
- Promote automatic routing only when the direct-route adversarial precision is
  100%, direct answer usefulness meets the corpus threshold, and no hard gate moves.
- Keep a single operator kill switch that selects the legacy lifecycle. Do not add
  per-class tuning knobs.

Exit:

- Promotion evidence is committed and reproducible except for explicitly marked
  live timing fields.
- Default direct prompts meet the one-call latency threshold.
- The kill switch is covered and does not change authority bindings.

### Slice 6 - Decouple Telegram outbound delivery

**Owner checkpoint required:** this changes ownership between `tamoz-agent`,
`tamoz-comms`, and `tamoz-sqlite` and must be reviewed as a cross-gem interface.

**Purpose:** remove the quiet-stream long-poll delay without weakening delivery
safety.

Design:

- Extract outbound claiming/sending into a focused `DeliveryDrainer` owned by the
  gateway process but scheduled independently of inbound `getUpdates`.
- Give the drainer its own store connection and transport/client instance. Do not
  share a SQLite connection or `Net::HTTP` object between the poll and delivery
  threads.
- Keep the existing claim fence, journal effect binding, receipt persistence, and
  prompt activation ordering.
- Wake on a short bounded interval first. Add notification primitives only if the
  measured polling cost requires them; do not introduce a general event loop.
- Retry only outcomes proven not sent: pre-send throttling and typed definitive
  transport failures, honoring `retry_after` and a bounded attempt/deadline policy.
- A timeout after send remains `unknown`, is never automatically retried, and raises
  an operator-visible alert/status item. Reconciliation remains an explicit operator
  action until the provider supplies evidence.
- `--once` remains deterministic: one inbound pass plus one bounded drain pass.

Files likely touched:

- `gems/tamoz-agent/lib/tamoz/agent/comms_gateway.rb`
- `gems/tamoz-agent/lib/tamoz/agent/delivery_drainer.rb` (new)
- `gems/tamoz-agent/lib/tamoz/agent/cli_comms_commands.rb`
- `gems/tamoz-sqlite` comms-store contract only if the existing claim surface is
  insufficient
- comms fixture, concurrency, crash, and autonomy scorecard tests

Exit:

- A test blocks inbound poll for 30 seconds, appends an outbox row concurrently, and
  observes a send attempt within 2 seconds.
- Two drainers race one delivery; one claims and sends it.
- Kill after send/before receipt produces one durable `unknown` and no retry.
- Throttle honors `retry_after`; shutdown is bounded and releases all leases.

### Slice 7 - Channel acknowledgement and controls

**Owner checkpoint required:** executable command intents cross the comms/agent/store
boundary.

**Purpose:** make the channel understandable and controllable.

Changes:

- After `admit_and_enqueue` succeeds, append a coalescible `accepted` control row.
  The independent drainer sends it in the same admitting pass or within its 2-second
  bound. Do not reserve terminal capacity with this row.
- Add best-effort Telegram `sendChatAction(typing)` through `Transport#signal` only
  as a supplement. Failure is ignored and counted; it never replaces durable ack or
  terminal delivery.
- Change `Admission::Decision` to carry a typed command intent, not executable text.
  This is the reviewed cross-gem contract.
- `/help`: static bounded control reply.
- `/status`: redacted state for the bound conversation thread: queued/running/
  paused/blocked/terminal, current phase, and queue position if available.
- `/cancel`: enqueue the existing typed cancel redirect for running or paused work;
  reply explicitly when work is queued and cannot yet be cancelled. Do not invent a
  second cancellation mechanism.
- Acknowledge callback presses with `signal(:ack)` before durable decision processing,
  then send the durable approved/denied result.
- Progress messages are stage transitions only, coalesced by
  `(occurrence_id, stage)`. No token streaming and no periodic "still working"
  message unless a measured user need remains.

Exit:

- Ack is visible in the admitting cycle.
- Every known command returns a reply; no command text reaches the model.
- `/cancel` targets only the bound conversation thread and cannot name another
  thread/profile/root/tool/budget.
- Duplicate commands and callback replays produce one logical effect.
- Control/progress traffic cannot consume reserved terminal capacity.

### Slice 8 - Verified partial progress and recovery

**Purpose:** make incomplete complex work useful without claiming completion.

Changes:

- Derive progress from committed step/effect receipts, never from model narration.
- Add completed/total counts and verified artifact identifiers to terminal rendering.
- On repair exhaustion, repeated action/failure, block, cancellation, and budget stop,
  report: accomplished facts, unverified facts, stop reason class, and next action.
- Resume from committed observations and receipts already in the durable state. Do
  not add a second progress store.
- Never mark a partial result `satisfied: true`.

Exit:

- Kill/restart after N steps reports the same N committed steps.
- An exhausted task says "3 of 5 committed; not satisfied" and names the blocker.
- Existing false-success and oracle-contradiction gates remain zero.

### Slice 9 - Release evidence and documentation

Changes:

- Run the deterministic routing, discovery, channel, crash, and adversarial suites.
- Run `rake autonomy_strict` and the agent scorecard/release benchmark applicable at
  the current commit.
- Run the live latency smoke and publish p50/p95, call counts, and provider control.
- Refresh `docs/LIMITATIONS.md`; remove the stale claim that Telegram does not exist.
- Add operator documentation for route fallback, the legacy kill switch, delivery
  `unknown`, `/status`, and `/cancel` limits.
- Regenerate every generated evidence file through its owning script.

Exit:

- The outcome table in section 1 passes.
- No generated artifact was hand-edited.
- The release notes state durable graph/public API compatibility decisions.

## 5. Test matrix

| Risk | Required proof |
|---|---|
| Route grants authority | Property test: route-selected names are a subset of the profile capability binding; direct is empty; read-only contains only read-only descriptors |
| Route claims work happened | Adversarial mutation/workspace corpus; zero direct claimed-success outcomes |
| Discovery loops forever | Maximum discovery passes enforced durably; restart does not reset the count |
| Discovery leaks into mutation | Mutation steps accepted only in action/repair phase with existing review, digest, check, and approval gates |
| Protocol errors burn budgets | Malformed route/plan/review fixtures; route failure does not increment plan attempts; each retry class has its own bound |
| Old threads break | v1 paused/running/blocked kill matrix resumed under new binary |
| Progress lies | Counts derived only from committed receipts; kill before commit does not increment |
| Terminal duplicates | Crash between outbox append and occurrence close; one logical delivery after restart |
| Outbound race duplicates | Two drainer owners, one claimed row, one send |
| Ambiguous send duplicates | Timeout after send -> durable `unknown`; subsequent drains never resend |
| Ack crowds out answer | Saturated control lane still preserves reserved terminal row |
| `/cancel` widens scope | Foreign thread/profile identifiers in command arguments are ignored/refused; only bound thread can be targeted |
| Telemetry changes behavior | observed/unobserved/raising-recorder runs have identical durable state and result |
| Secret leakage | extend the repository secret sweep over route reasons, progress, terminal text, telemetry, and live-smoke artifacts |

## 6. Per-slice engineering loop

For every slice:

1. Read `docs/QUALITY_PROGRAM_STATE.md` and verify the current gate policy; it may
   have changed since this plan.
2. Run local Enola impact analysis when available, then pin a baseline before edits.
3. Add characterization or failing behavior tests first and mutation-prove the key
   assertion.
4. Implement the smallest cohesive change. No generic router, manager, event bus, or
   callback framework.
5. Review the diff against `docs/CODING_STANDARD.md`: correctness, authority,
   durability, recovery, privacy, performance, API growth, and generated artifacts.
6. Run focused tests, then the everyday gate:
   `rake ci`, `rubocop`, and
   `/Users/ghassan/.local/bin/enola check --fail-on=cycles,layers --min-confidence=0.8 .`.
7. Run `rake ci_full` under both required locales for slices 4, 6, 7, 8, and 9 because
   they touch durability, comms, packaging, or evidence.
8. Run `rake autonomy_strict` for slices changing worker, planning, actions, budgets,
   recovery, or comms.
9. Re-run Enola and reject cycles, layer violations, or unexplained spillover.
10. Commit one slice. Update this plan's status/evidence only from observed results.

## 7. Rollout and rollback

- Routing ships behind one legacy-path kill switch. Shadow mode precedes default-on.
- Durable graph v1 support remains until all known v1 open sessions are terminal or a
  documented migration tool proves safe conversion. Do not time-box compatibility by
  assumption.
- Telegram delivery decoupling can roll back to poll-coupled draining without schema
  rollback because it reuses the existing outbox states.
- Never roll back an `unknown` delivery to `pending` automatically.
- Observability producers are independently disableable through the existing null
  recorder; disabling them must not disable user feedback.

## 8. Stop and redesign criteria

Stop the current slice instead of weakening a gate if any of these occurs:

- A direct route can claim completion for requested workspace/action work.
- Durable v1 sessions cannot resume and no explicit version-selection design exists.
- Read-only discovery requires widening a capability or bypassing effect journaling.
- A second discovery pass cannot be tied to a typed missing-evidence reason.
- Terminal feedback can be lost or duplicated across the append/close crash window.
- Telegram latency can only be improved by blindly retrying ambiguous sends.
- Progress requires a second source of truth instead of committed session/effect state.
- Telemetry changes committed bytes, ordering, latency beyond the accepted overhead,
  or raises into the agent.
- A cross-gem interface change begins without the owner checkpoint required by
  `AGENTS.md`.

## 9. Definition of done

The improved agent is done when a simple question is answered directly in one model
call, evidence-dependent read-only work discovers and completes rather than dying at
review, mutation authority is unchanged, every pause/stop is truthful and actionable,
Telegram sends acknowledgement and terminal output without waiting on a quiet long
poll, ambiguous sends remain safe, and the repository's deterministic and live
evidence would detect a regression in any of those properties.
