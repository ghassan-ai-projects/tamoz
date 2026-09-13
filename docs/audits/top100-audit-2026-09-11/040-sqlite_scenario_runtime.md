# Audit 040 — `gems/tamoz-evals-runner/lib/tamoz/evals/harness/sqlite_scenario_runtime.rb`

Rank 40 · 662 lines · 2026-09-11 · **Verdict: IMPROVE** (2 major, 1 minor) · Bar fails: DEAD, SIZE

The scenario fixtures themselves are clear, but dispatch runs through a convention-derived
metaprogrammed preparer registry and one helper takes 12 parameters.

## Findings

- **[major][DEAD]** `prepare_action!` resolves a method-name string built by convention in test
  support (`"prepare_#{id.tr('.', '_')}"`, sqlite_harness_inputs.rb:318-321) and dispatches via
  `__send__` — a metaprogrammed registry (banned shape) binding this class's private method names
  to an external table. Owning seam: a declared preparer table inside SQLiteScenarioRuntime.
  (sqlite_scenario_runtime.rb:76-81)
- **[major][SIZE]** `checkpoint_attributes` takes 12 parameters (checkpoint plus 11 keywords
  defaulting from that same checkpoint), far over the ≤5 ceiling; a diff-on-checkpoint builder
  value should carry only the overridden fields. (sqlite_scenario_runtime.rb:560-591)
- **[minor][DEAD]** `append_checkpoint` is a pure pass-through to `@store.append_checkpoint` with
  an identical signature — no defaults, no validation, no behavior across ~15 call sites.
  (sqlite_scenario_runtime.rb:518-534)

## Resolution — 2026-09-11

- **[major][DEAD] hardened (dispatch fails fast).** `prepare_action!` still resolves the
  handler from the injected `@preparers` map, but `validate_runtime_inputs!` now also checks
  every handler `respond_to?` a real (private) method at construction. A manifest typo is
  therefore a named `ExecutionError` at setup, not a `NoMethodError` far away at dispatch —
  the specific harm the finding cites. Fully internalising the id→method table into this
  class would require moving the scenario catalog's id list off `test/support` (the map is
  injected as `runtime_inputs["preparers"]`); that harness re-coupling is deferred, the
  fail-fast guard removes the fragility now.
- **[minor][DEAD] rejected — NOT dead.** `append_checkpoint` is not a pure pass-through: it
  supplies defaults `consumed_task_ids: []` and `request_transition: nil` that many callers
  omit, while `@store.append_checkpoint` requires both keywords. Deleting it broke 10 driver
  cases (`missing keyword: :consumed_task_ids`). The wrapper carries real default behaviour;
  kept.
- **[major][SIZE] deferred.** `checkpoint_attributes`'s 12 params are a base checkpoint plus
  11 keyword overrides each defaulting from that checkpoint; a diff-on-checkpoint value type
  is a design change to this test harness, left as intrinsic ParameterLists debt.
