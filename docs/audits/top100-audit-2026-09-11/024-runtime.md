# Audit 024 — `gems/tamoz-agent/lib/tamoz/agent/runtime.rb`

Rank 24 · 763 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 2 minor) · Bar fails: SIZE, STATE, DUP

Model calls correctly route through EffectDispatcher, but the class carries all three routing
pipelines plus a 54-line model-call method and an untyped repair-loop state hash.

## Findings

- **[major][SIZE]** One class mixes legacy, shadow, and experimental routing pipelines, the action
  repair loop, and model/receipt plumbing; `model_generate` alone is 54 lines. Owning seams:
  routing strategy objects and the existing model-call boundary. (runtime.rb:57-761, 625-678)
- **[minor][STATE]** `action_state` threads a mutable symbol-keyed hash bag through eight
  repair-loop methods (`draft_action_plan`, `execute_action_plan`, `resolve_action_outcome`,
  `continue_repair?`, …). Owning seam: a repair-loop value object. (runtime.rb:422-435, 437-572)
- **[minor][DUP]** Discovery/read-only plan→execute shapes are re-spelled per routing variant:
  `discover_action_observations` vs `routed_discovery_observations`, `run_read_only_work` vs
  `routed_read_only_work`. (runtime.rb:405-420, 309-316, 161-174, 288-307)

## Resolution — 2026-09-12 (round 5)

- **[major][SIZE] PARTIAL** — `model_generate` is split: `dispatch_model_call` (the
  EffectDispatcher request/logical-identity assembly and the journaled `perform`) plus
  `model_outcome_value` (the status → content/typed-failure mapping); the method itself is now
  the ~10-line telemetry wrap. The full routing-strategy-object extraction (legacy/shadow/
  experimental pipelines as separate objects) is REJECTED this round: the co-hosted seams
  (`runtime/plan_review.rb`, `runtime/step_execution.rb`) and any new `runtime/` file sit outside
  round-5 file ownership (`runtime.rb` only). Seam: routing strategy objects beside the included
  PlanReview/StepExecution modules.
- **[minor][STATE] FIXED** — the symbol-keyed `action_state` hash bag is replaced by
  `ActionLoopState` (declared in `runtime.rb` beside `Result`): named fields, and the loop's
  transitions live on it (`iteration_context`, `record_plan!`, `record_failure!`,
  `repeated_action?`/`repeated_failure?`, `attempts_exhausted?`, `enter_repair!`,
  `observations_add!`). The eight loop methods now read and drive the object; no `fetch(:sym)`
  stringly lookups remain on the path.
- **[minor][DUP] FIXED** — one `execute_observations` executor now serves all four re-spellings:
  `run_read_only_work`, `discover_action_observations`, `routed_discovery_observations`, and
  `routed_read_only_observations`. The plan-acceptance halves of the variants deliberately stay
  separate: the routed variant's fallback contract (`route_plan_fallback`, discovery pass,
  semantic review) differs from legacy's raise, so merging them would change behavior.
