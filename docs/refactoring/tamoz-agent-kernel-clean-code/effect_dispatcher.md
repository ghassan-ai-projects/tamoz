# Effect dispatcher slice

## Scope

Only `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb` is writable
in this slice. Callers and tests were inspected read-only. `BAR.md`,
`SLICE-BAR.md`, `TODO.md`, the deliberation slice, and all other production files
remain untouched.

No tests, lint, Enola, provider, or live commands are run here.

## Candidate decisions

| Surface | Candidate defect | Decision | Risk |
| --- | --- | --- | --- |
| `Outcome` / `MAX_ATTEMPTS` | Immutable result shape and attempt cap are explicit journal contracts. | Leave stable. | High if changed: public shape and retry policy. |
| `run` | Mixes configuration guards, logical/physical key resolution, journal preparation, reconciliation recovery, replay mapping, and execution dispatch. | Refactor. Extract run-contract validation and decision resolution; retain the journal prepare call in the public story. | High: ordering, logical keys, reuse, and block forwarding are externally observable. |
| `resolve_key` | Resolves generated logical identity versus journal storage key in one named key-resolution concept. | Leave stable. | High: logical-key and attempt identity semantics. |
| `run_reconciliation` | Owns the bounded reconciliation decision and attempt-budget fallback. | Leave stable. | High: retry/reconciliation order and evidence. |
| `recorded_outcome` | Projects one journal record into the stable `Outcome` shape. | Leave stable. | High: output shape and attempt identity. |
| `execute_outcome` | Mixes start/after-start/perform lifecycle with two typed exceptional completion paths and error-detail serialization. | Refactor. Extract one named exceptional-attempt completion seam; preserve callback timing and block forwarding. | High: error classes, details, completion status, and exactly-once effects. |
| `build_logical_key` | Maps the structured identity contract to the journal's existing logical-identity seam. | Leave stable. | High: cross-attempt deduplication. |
| `tool_error_detail` | Encodes the existing repairability and public error-class mapping in one focused operation. | Leave stable. | High: serialized error details. |
| `unknown_error_detail` | Encodes bounded disclosure for terminal unknown outcomes in one focused operation. | Leave stable. | High: safety/error disclosure contract. |
| `terminal_attempt` / `current_attempt_identity` | Each answers one journal-record lookup question with explicit names. | Leave stable. | Medium. |
| `reconcile_filesystem` | Observes a path, builds reconciliation evidence, and chooses completed/not-applied/unknown; this is one coherent filesystem reconciliation story. | Leave stable. | High: before/after proof and receipt recovery. |
| `observe` / `mode_matches?` | Small, named seams for shared observation and create-file mode checking. | Leave stable. | High if the shared seam changes. |

## Selected refactor

`run` will read as: validate the dispatcher contract, resolve the journal key,
prepare the effect, then resolve the journal decision. The new decision helper
will retain the existing reconciliation branch and action-to-outcome mapping in
the same order.

`execute_outcome` will read as: start the attempt, run the after-start callback,
perform the effect, complete typed exceptional outcomes or complete success. A
new helper will own only the repeated journal-completion plus `Outcome`
projection for an exceptional attempt.

New helpers will be private singleton methods. Existing public constants,
methods, signatures, and visibility remain unchanged.

## Behavior contract

- Preserve `MAX_ATTEMPTS`, `Outcome` fields, statuses, and all output shapes.
- Preserve logical-key generation, physical journal-key selection, and attempt
  identity exactly.
- Preserve the order: configuration validation, key resolution, `prepare`,
  reconciliation, replay mapping, `start`, `after_start`, perform, and complete.
- Preserve exactly-once behavior: reused terminal records never invoke the
  perform block; executed effects complete exactly once.
- Preserve `after_start` timing and forwarding of the caller's block through all
  helper layers.
- Preserve `ToolError` and `EffectUnknownError` classes, serialized detail
  fields/messages, completion statuses, and returned `Outcome` values.
- Preserve reconciliation evidence, disposition strings, attempt-budget
  exhaustion, and all existing exception classes/messages/timing.
- Do not change filesystem observation, canonicalization, or shared journal
  seams.

## Final diff concepts

Implemented only in `effect_dispatcher.rb`:

- `run` now states the journal workflow as contract validation, key resolution,
  `prepare`, and decision resolution. `validate_run_contract!` owns only the
  existing two configuration guards.
- `resolve_decision` owns the existing reconciliation branch and action mapping
  without changing their order or returned values.
- `execute_outcome` still starts the attempt, invokes `after_start`, forwards
  the perform block, and completes success. `complete_exceptional_attempt`
  owns the repeated terminal completion plus `Outcome` projection for typed
  failures.
- New helpers are private singleton methods. Existing public methods/constants,
  signatures, journal calls, key arguments, statuses, error details, and block
  forwarding remain unchanged by inspection.
- Callers reread after extraction: `SessionEffects#model_call`,
  `SessionEffects#dispatch`, `SessionEffects#reconciler_for`, memory
  consolidation, healing remediation effect execution, and the episode model/tool
  callers still use the unchanged `EffectDispatcher` seams.
- `git diff --check` was run. Tests and all repository quality/live gates were
  intentionally not run, so behavioral equivalence remains inspection-based in
  this slice.

## Unimplemented behavior-change proposals

None. A behavior change is not needed for this reading-order refactor.
