# Phase 2 — adaptive read-only continuation

Status: partial — the durable adaptive read-only continuation slice is implemented
in graph version 3. Requires: Phases 0 and 1 (effect identity and discovery must
already exist).

Implemented slice (2026-08-20):

- `Session` accepts the existing `routing: :adaptive` experimental seam and binds
  a separate graph version (`3`); graph versions `1` and `2` remain unchanged.
- Intake records the adaptive mode plus authority and catalog revisions, then
  runs `adaptive_decide -> adaptive_validate -> adaptive_dispatch ->
  adaptive_observe -> adaptive_decide`.
- Decisions are closed to one `action` or `final`; action arguments are checked
  for credential and authority fields, current read-only capability membership,
  read-only safety, and source-owned validation before dispatch.
- Model and capability calls use `SessionEffects#model_call` and
  `SessionEffects#dispatch`, with iteration/sub-operation identity, journaled
  receipts, bounded observations, provenance, truncation, and evidence refs.
- Iterations are capped at three, repeated action signatures stop with a typed
  terminal reason, final answers must cite persisted observation refs, and
  mutation decisions hand off to the existing reviewed planner without entering
  adaptive dispatch.

The full Phase 2 exit bar is not claimed yet. The CLI/Telegram vertical slice,
minimum lifecycle event envelope, bounded inspection descriptor, and the broader
restart/kill-matrix coverage remain subsequent work.

Study reference: Stage 2 (`04`), P2 (`05`), root cause #1 (`05`: Session does
not re-decide after each successful observation). This is the core intelligence
change of the program.

## Goal

`Session` gains a bounded adaptive read-only mode: after each successful
observation, the model sees it and chooses the next action or stops. Mutation
or external write exits this mode into the existing reviewed plan path.

## Entry and sequencing gates

Phase 0's identity contract and Phase 1's sealed inventory are hard
dependencies. Implement the durable record shape and graph route first, then
the one-action loop, then mutation handoff and the inspection surface, and only
then run the two-surface vertical slice. A fixture model may drive the tests;
it must not be used to claim intelligence.

## Design constraints (from the study, binding)

- Extend `Session` (`session.rb`, `session_nodes.rb`, `session_lifecycle.rb`,
  `session_steps.rb`, `session_evidence.rb`) with a new durable graph
  version/branch selected only by the existing route and authority. Do not
  mount `EpisodeGraph` into chat — its
  `ReasoningDocument`/diagnosis contracts are domain-specific — but copy its
  control shape: reason → validate → one tool → durable effect → rebuild frame
  with observation → reason again.
- Do not route Telegram or durable CLI to `Runtime`. `Runtime` stays explicitly
  ephemeral.
- Every model/tool call goes through `SessionEffects` / `EffectDispatcher`
  (invariant 5), keyed on the request, with the Phase 0 iteration identity.
- Explicit model/provider role identity is preserved; no implicit fallback in
  this phase.

## Work items

1. **Versioned route and state.** Extend `Session#build_definition`,
   `Session#app_for_thread`, `Session#guard_state!`, `SessionNodes`, and
   `SessionRouting` with one new graph version for adaptive read-only turns.
   The route record must name the mode and authority/catalog revision. Existing
   graph versions remain selectable for their recorded checkpoints; do not add
   a migration or degraded compatibility path for new adaptive state.
2. **Closed decision protocol.** Extend the existing deliberation/parser seam so
   one adaptive model decision is either `final(answer, evidence_refs)` or one
   `action(capability_id, arguments)`. Validate shape, argument schema,
   capability membership, read-only effect class, and the current Phase 1
   inventory before dispatch. Reject a second action, unknown capability,
   mutation, secret-shaped argument, or authority-changing field as a bounded
   terminal/handoff outcome. The decision protocol is data; no domain catalog
   or mission-specific tool order belongs in Ruby.
3. **One durable iteration.** The graph branch is exactly:
   `adaptive_decide` → `adaptive_validate` → `adaptive_dispatch` →
   `adaptive_observe` → `adaptive_decide` or `verify`/`terminal`. Each durable
   iteration may dispatch at most one capability. Model decisions use
   `SessionEffects#model_call`; capability execution uses
   `SessionEffects#dispatch`; neither node calls a provider or tool directly.
4. **Observation and next-action persistence.** Extend the allowlisted
   `SessionRecords` observation/receipt schema and `SessionView` projection so
   each observation carries `effect_key`, iteration, capability/source id,
   provenance class, truncation/byte bound, result classification, and the
   next-action/terminal decision digest. Store authoritative receipts and
   verification facts separately from model text. Rebuild every prompt from
   checkpointed state; no in-memory trajectory is authoritative.
5. **Identity and guards.** Pass the Phase 0 iteration/sub-operation identity
   through every model and tool call. Reuse journal receipt accounting and the
   existing cancellation, budget, repeated-signature, unknown-outcome, and
   worker recovery paths. Add only the missing checkpointed guards: maximum
   adaptive iterations, idle/no-decision breaker, and an output/observation
   budget. Every stop records a typed terminal reason and preserves requested,
   observed, terminal, and unknown distinctions.
6. **Mutation handoff.** A non-read-only decision never enters
   `adaptive_dispatch`. Record the rejected adaptive decision and hand off to
   `SessionDeliberation`/`SessionPlanAttempt`, then the existing
   `SessionSteps` approval/effect path. Structural and semantic review, exact
   argument/preview digest approval, durable execution, verification, and
   unknown outcome remain mandatory. A handoff must not silently reuse the
   read-only effect identity or execute a mutation inside the adaptive branch.
7. **Bounded model-facing inspection.** Expose one read-only descriptor through
   the Phase 0 host that returns caller-bound `SessionView` state, the Phase 1
   capability inventory, and a redacted config/authority schema. Resolve the
   thread from the durable context, cap fields/bytes, omit secrets and raw
   workspace/configuration, and provide no dispatcher, profile mutation, or
   arbitrary path/thread argument. Its invocation is itself journaled as a
   read-only effect if it crosses the model/tool boundary.
8. **Minimum durable lifecycle contract.** Before accepting the vertical slice,
   define and persist the allowlisted semantic envelope for `model_turn`,
   `tool_started`, `tool_result`, `checkpoint`, `approval`, `wait`, and
   `terminal` with sequence, request/thread/execution identity, iteration,
   effect key, phase, effect state, capability/source, provenance/truncation,
   and delivery state. CLI and Telegram consume this same durable projection;
   Phase 3 may improve rendering and add compaction, but cannot postpone the
   source-of-truth event contract. Delivery rows remain separate from task and
   effect records, and restart must not duplicate events or terminal delivery.

## Tests

- `test/agent_session_test.rb`, `test/agent_session_operations_test.rb`, and
  `test/agent_session_records_test.rb` prove a scripted three-step read/search
  mission, the closed decision protocol, persisted provenance/truncation, and
  graph-version binding;
- `test/agent_session_effect_test.rb`, `test/sqlite_effect_journal_test.rb`,
  and `test/agent_session_kill_matrix_test.rb` prove restart at pre-call,
  in-flight, post-effect, and post-checkpoint boundaries resumes without
  replaying a completed effect and that iteration/sub-operation keys are
  collision-free;
- a contradictory-observation case (matrix scenario 2) proves a new durable
  model decision, a changed next action, and no repeat of a successful effect;
- loop, idle, cancellation, output-budget, and model-call-budget cases each
  terminate with a distinct typed reason; repeated signatures do not hot-loop;
- mutation requests leave the adaptive branch and enter the reviewed plan
  path; denial, expiry, duplicate approval, unknown outcome, and restart while
  waiting are all covered without a mutation in the adaptive branch;
- the inspection descriptor returns redacted caller-bound state and cannot
  mutate, widen authority, or read an unrelated thread;
- duplicate request submission and duplicate effect identity each return the
  recorded receipt without a second effect.
- canonical lifecycle traces for the same fixture mission are identical through
  CLI and Telegram except for presentation; missing intermediate events fail
  the slice.

## Exit bar — first vertical slice

The study's recommended slice, end to end:

```text
Telegram or durable CLI request
  -> capability inventory (read-only, non-connecting)
  -> adaptive read-only model turns
  -> read/search through SessionEffects
  -> bounded observations with provenance
  -> final evidence-backed answer
  -> same lifecycle projection and durable receipt on both surfaces
```

Must hold: no mutation or shell authority; every model/tool/inspection call
journaled; loop bounded and restart-safe; duplicate request does not duplicate
work; CLI and Telegram share the same request/thread/authority/catalog/effect
trace and terminal result, with only presentation differences. The evidence
package contains fixture plumbing results plus one real-provider run per
surface, each labeled as a single data point and never as proof of intelligence
(that is Phase 5's bar).
The minimum durable lifecycle envelope and parity trace are required here;
compaction and rendering polish are Phase 3 work.

## Out of scope

Compaction and lifecycle projection polish (Phase 3), new capability
families (Phase 4), model/provider fallback policy, autonomous mutation, and
any benchmark claim beyond the recorded vertical-slice evidence.
