# Runtime clean-code refactoring bar

## Scope

The refactoring covers only these production files:

- `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb`
- `gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb`
- `gems/tamoz-agent/lib/tamoz/agent/runtime.rb`
- `gems/tamoz-agent/lib/tamoz/agent/worker.rb`

The implementation may add focused notes in this directory when a cleaner structure
would require a behavior or public-interface decision. No behavior change is approved
by default.

## Observable behavior to preserve

- Public method names, visibility, parameters, return values, and result shapes.
- Validation errors, exception classes/messages, and early-return behavior.
- Event names, event ordering, event payloads, callback forwarding, and delivery timing.
- Durable store ordering, claim/recovery/settle semantics, exactly-once boundaries,
  leases, retries, fencing, and child-task authority/budget behavior.
- Runtime routing (`legacy`, `shadow`, and `experimental`), model-call stages, model-call
  counting, verification, configured checks, and result outcomes.
- Runtime-directory permissions, YAML schema validation, migration atomicity/backups,
  source/channel/profile resolution, and workspace separation.

## Per-file reading-order bars

### `runtime_directory.rb`

- Public setup methods read as resolve/create/migrate workflows.
- File-system mechanics, document construction, validation, and atomic migration steps
  are named helpers at one lower abstraction level.
- Validation remains strict and preserves the existing error contract.

### `runtime.rb`

- `run` reads as normalize, start, announce, select routing, execute, and finish.
- Routing branches, action repair-loop mechanics, model calls, and result projection are
  separated into intent-named helpers.
- No helper is introduced only to rename an obvious single operation.

### `worker_runtime.rb`

- Runtime construction, durable child-task flow, occurrence flow, session/profile
  resolution, and capability construction each read as coherent workflows.
- Store operations remain durable and preserve their failure classification.
- Authority narrowing, profile binding, codecs, approval sessions, and delivery sinks
  remain at their existing boundaries.

### `worker.rb`

- `run`, `poll_once`, and thread advancement read as worker lifecycle orchestration.
- Scheduling, child reconciliation, inbox selection, approval resolution, settlement,
  mode switching, parking, and observability mechanics are named lower-level concepts.
- Per-thread failure isolation and terminal notification behavior remain unchanged.

## Binary completion criteria

- [ ] Only the four listed production files and this task's docs are changed.
- [ ] Each changed public/top-level method states its intent in reading order.
- [ ] Changed functions stay at one abstraction level and call one-level-down helpers.
- [ ] Names state domain intent; no `process_data`/`handle_result`/`do_work` helpers.
- [ ] No shallow wrappers, duplicate capabilities, speculative compatibility code, or
      narrative comments are added.
- [ ] No behavior or public-interface change is made without a note in
      `BEHAVIOR_NOTES.md`.
- [ ] Final tests and repository gates pass, with any pre-existing failures documented.
- [ ] Each file receives its own review/fix/check loop and commit.
- [ ] No scratch files or unrelated churn remain.

## Verification policy

Tests are intentionally deferred until all four refactors are complete. Before that
point, use source review, diff inspection, and (after the edits) the architecture snapshot
delta. At the end, run the focused tests for these files followed by the repository gates.

## Baseline

- Worktree: `codex/refactoring-agent-20260824`
- Base commit: `4c82bef`
- Baseline test execution: intentionally not run, per task instruction.
- Architecture baseline: generated and pinned before edits with enola.
