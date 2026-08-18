# Pattern 02 — Plan-and-Execute

Handbook: chapter-02-plan-and-execute.md. Verdict: **Partial — the interactive
Session path implements the pattern correctly; the production streaming path is a
single-decision judgment (planner/judge split), with no multi-step plan and no
re-planning on rejection.** Builds on: README substrate; pattern-01's loop
(02's PLAN route generalizes 01's execute loop). **Autonomy: production L1-L2,
Session L3** (Session plans with steps = handbook Level 3; the episode path stays
single-decision).

## Handbook definition (owner's)

- Planner/Executor split: an explicit Plan (a machine-validatable DAG:
  `{goal, tasks:[{id, task, deps, status: todo|in_progress|done|failed|blocked, result}]}`)
  before execution avoids myopia. ReAct is not replaced — it is wrapped: the Planner
  decides WHAT, the Executor decides HOW (per-task ReAct), the Re-Planner adapts when
  reality diverges.
- When: ≥5 dependent steps, parallelizable steps, reliability > latency. When not:
  short/exploratory tasks, no per-task success criterion, fast-changing environments.
- Re-planning semantics: Retry (transient) / Skip-Modify (rewire deps or inject a
  Discovery task) / Abort (terminal). Deadlock = nothing ready + incomplete work.
- Failure modes: stale plans, oscillation (global MAX_REPLANS + escalation), deadlock
  (DAG validation before execution), over-planning (5-7 step window).

## How tamoz implements it (HEAD)

**Two mechanisms on the same graph runtime.**

**A. Production path — planner/judge vs validator/executor (NOT plan-and-execute).**
- The episode "plan" is a single decision: `reason` produces a diagnosis document
  with **at most one actionable intent** (`MAX_ACTIONABLE_INTENTS = 1`,
  decision_builder.rb:28, enforced as a typed refusal at :150-156); no proposal or
  unproposable one degrades to the catalog R0 watch condition (:280).
- Intent authority: model proposes → `IntentCatalog` declares the vocabulary
  (type, exact risk_class, parameter_schema, presets, policy, rate_limit,
  compensation — digest-bound, intent_catalog.rb:8-24) → agentic-stream validates
  independently (`decisions.Validate`: risk EQUALITY, schema, preset byte-identity,
  evidence grounding — validator.go:189-441) → policy dispatches by risk class:
  R0/R1 auto, R2 approval (or calibrated-automation when an exact calibration
  artifact matches), R3/R4 deny (`switch row.RiskClass`, policy.go:308-340;
  `approveAutomatic` inserts + outbox, policy.go:566-599; calibration gate
  policy.go:313-320).
- Re-planning = RECONSIDER: superseded situation (`completeness="corrected"` +
  `late_data_policy: correct_and_reconsider`) admits a fenced RECONSIDER item
  (reconsideration.go:26-155); Tamoz `judge`/`compensate` resolve withdraw/downgrade/
  let_stand **deterministically from the catalog's compensation metadata**
  (episode_nodes.rb:203-275) — zero model calls.
- **A rejected decision is terminal**: rejection → `RecordRejection` + attempt
  `failed` + episode `concluded` (executor.go:388-423). No retry/re-plan with
  feedback. Retry/skip/abort → only abort (+ deterministic compensate) exist.

**B. Session path — the handbook's pattern, implemented.**
- `Plan = Data(goal, done_when, steps)`, `Step(id, purpose, tool, arguments,
  verification)`, `MAX_STEPS = 12` (plan.rb:24-92); planner prompt
  `PLAN_SYSTEM` "goal, done_when, steps" (deliberation.rb:14-20).
- Plan validation: deterministic `structural_issues` (done_when, tool allowlist,
  digest rules — deliberation.rb:186) + LLM semantic review
  (`REVIEW_SYSTEM`, route_review accept/needs_input), bounded `max_plan_attempts`
  (session.rb:67).
- Executor: `step_gate → step_execute → evaluate` per step, approval boundary for
  mutating tools, effects journaled via `EffectDispatcher` (session_steps.rb:25-40).
- Re-planning: `repair` phase with `bounded_repair` + seen-signature dedupe
  (session_evidence.rb:150-168; invoked from session_lifecycle.rb:59-62), feedback
  fed into the next plan.
- Verification: `verify` node judges `done_when` via `VERIFY_SYSTEM`
  (deliberation.rb:37; session_lifecycle.rb:54-120).

## Divergence from the handbook

1. The production "plan" is a single decision with ≤1 intent — no task list, no
   deps, no per-step status, no success criterion.
2. No re-planning on decision rejection — rejection is terminal; RECONSIDER triggers
   only on operator correction, never on validator rejection.
3. The production re-planner is deterministic (catalog compensation), not an LLM —
   a novel correction needing a different action family fails closed.
4. No DAG anywhere: the Session plan is a linear steps array with a cursor; the
   graph runtime is DAG-capable (executor.rb bulk-synchronous, parallel pools) but
   no plan uses it.
5. Staleness handled at request/snapshot level (stale plan abandoned, not re-planned).
6. Budgets are per-episode/per-session, not per-plan-step (no MAX_REPLANS in the
   episode path).

## How it SHOULD be implemented (on existing seams)

1. **New PLAN route on the episode graph** — `intake`'s route branch
   (`branch :intake`, episode_graph.rb:101-106) gains a `plan` kind (situation_request.rb
   KIND_NAMES). A `plan` model node after `build_frame` returns a typed Plan
   document — reuse `Plan`/`Step` (plan.rb:24-92), raise MAX_STEPS per handbook's 5-7
   window.
2. **Plan validation ties to the intent catalog** — each step's `type` must be a
   catalog entry; parameters validated against `parameter_schema`; per-step risk ≤
   ceiling; a step naming an unallowlisted type is a typed refusal → `repair`
   exactly once (the existing repair/repair_directive pattern). Deterministic
   structural checks already exist (deliberation.rb:186).
3. **Executor loop on the graph** — generalize the existing
   `validate → execute_tool → rebuild_frame → reason` loop: **reuse the existing
   `step_cursor` channel** (session.rb:370 — it is already consumed by
   session_steps.rb:23/39/140 and session_lifecycle.rb:22/77) + a `steps` append
   state; each step dispatches through `EffectDispatcher.run` under logical key
   (episode, "step", slot=k); deps/parallelism land on the existing bulk-synchronous
   executor.
4. **Re-planning on rejection, journaled** — (a) stream-side: add rejection reasons
   (`risk_label_mismatch`, `parameter_schema_violation`) as RECONSIDER/REPLAN
   triggers in `admitReconsiderations` (reconsideration.go:26); (b) graph-side: a
   `replan` node appends failure reason + observed outcome to the frame (seam:
   the `repair_directive` state channel, episode_graph.rb:47) and re-calls `reason`
   under ordinal+1 — bounded by a `replan_count` channel (mirror `repair_count`) —
   the handbook's MAX_REPLANS.
5. **Budget ceilings** land in `Limits` (max_replans/max_plan_steps) + the wire
   budget hash; a plan-level max_model_calls gate in the executor node (pre-dispatch).
6. **Validator seam (only cross-repo change)** — the "at most one actionable
   intent" counter (validator.go:244-261) becomes kind-scoped: PLAN episodes carry N
   ordered actionable intents, each through the existing per-intent checks unchanged.

## Gap list (priority order)

| # | Gap | Landing spot |
|---|---|---|
| PL1 | Multi-step plan in the production path | New PLAN kind/route in episode_graph.rb + Plan document |
| PL2 | Re-plan on validator rejection | Rejection reasons as RECONSIDER triggers (reconsideration.go:26) |
| PL3 | LLM re-planner on the streaming path | `replan` node + frame directive channel (episode_graph.rb:47) |
| PL4 | DAG with deps + parallel ready-tasks | `deps`/`status` on `Step` (plan.rb) — executor already supports it |
| PL5 | Deadlock/cycle detection | Deterministic plan-validation check (seam: deliberation.rb:186) |
| PL6 | Per-plan budget / MAX_REPLANS | `replan_count` channel + Limits (limits.rb) |
| PL7 | Per-plan success criterion (`done_when`) | `done_when` in Plan + terminal `verify` node (seam: session_lifecycle.rb:54-120) |
| PL8 | Retry on transient failure | `retry` decision in `judge` for transient classes, journaled under a new fence |
| PL9 | R2 calibrated-automation gate is artifact-bound, not plan-aware | Calibration gate (policy.go:313-320) applies per intent; a plan with multiple R2 steps needs per-step artifact matching (see pattern-07) |

**Tests to update:** a new PLAN kind joins `KIND_NAMES` (situation_request.rb:42) —
`test/stream_episode_intent_authority_test.rb` + Go validator tests (the
at-most-one-actionable counter becomes kind-scoped); Session path changes touch the
session plan/repair tests.
