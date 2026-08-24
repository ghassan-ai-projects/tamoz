# Tamoz Scheduler Clean-Code Refactoring Bar

Status: frozen before implementation

Branch: `codex/refactor-tamoz-scheduler-reading-order`

Baseline: `a4811a2`

## Scope

The scheduler gem is behaviorally correct, but its main value and consumer entry
points mix their public stories with validation, policy selection, time arithmetic,
subprocess handling, parsing, and output assembly. The refactor must stage those
details in the order a reader asks questions.

The implementation agent owns:

- `gems/tamoz-scheduler/lib/tamoz/scheduler.rb`
- `gems/tamoz-scheduler/lib/tamoz/scheduler/**/*.rb`
- `test/scheduler_values_test.rb`
- `test/scheduler_due_occurrences_test.rb`
- `test/scheduler_consumer_test.rb`
- `test/scheduler_contract_test.rb`

Read-only dependencies:

- scheduler callers under `gems/tamoz-agent`, `gems/tamoz-agent-cli`,
  `gems/tamoz-evals`, and `gems/tamoz-sqlite`
- integration and architecture tests outside the owned scheduler test files
- `docs/CODING_STANDARD.md`, `docs/QUALITY_PROGRAM_STATE.md`, and existing design
  documents

Forbidden:

- changes outside the owned paths
- changes to public constants, method signatures, error classes/messages, store
  contracts, wire hashes, digests, or scheduler behavior
- changes to `docs/public-api.json`, quality baselines, `.rubocop_todo.yml`, Reek
  configuration, fixtures, generated artifacts, or gate configuration
- backward-compatibility shims, new dependencies, commits, pushes, or external
  mutations

## Behavior contract

All of the following remain byte- and behavior-identical:

- `Tamoz::Scheduler`'s public constant surface and `ScheduleStore::CONTRACT_VERSION`;
- `Schedule` defaults, validation errors, immutable fields, `to_h`, and definition
  digest for every accepted definition;
- `next_fire_at`, `due_occurrences`, misfire selection, overlap decisions, and
  deterministic jitter for both `:at` and `:interval` schedules;
- `Occurrence` identity, request id, transition guards, error messages, state,
  terminal classification, evidence, and `to_h`;
- grant intersection normalization, status classification, effective grants, and
  narrowing/revocation behavior;
- scorecard command selection, subprocess invocation, JSON parsing, success summary,
  failure hashes, stderr truncation, and `SystemCallError` handling;
- all scheduler callers in SQLite, agent, CLI, and evals.

No behavior or public-interface change is authorized.

## Required reading path

- `Schedule#initialize`: validate the definition, select the supplied or computed
  digest, then construct the immutable value. Field-level rules and repetitive field
  plumbing must sit below this story.
- `Schedule#next_fire_at`: reject an unavailable schedule, dispatch by kind, and
  return the next bounded instant. Interval arithmetic and one-shot checks must sit
  one level down.
- `Schedule#due_occurrences`: reject an unavailable schedule, dispatch by kind, and
  return the bounded oldest-first due window. Kind-specific mechanics must sit one
  level down.
- `ScorecardSummaryConsumer#run`: select the command, execute it, parse the report,
  and return a validated summary. Failure mapping and summary assembly must be named
  lower-level concepts.
- `GrantIntersector.intersect`: normalize both grants, compute the intersection,
  classify it, and return the frozen result. Collection mechanics must not obscure
  that sequence.

`Occurrence`, `ScheduleStore`, and the error hierarchy may remain unchanged when their
current public stories are already coherent. Do not extract code merely to touch every
file.

## Must-pass criteria

- [ ] B1 Scope: only owned paths changed; no forbidden interface or artifact changed.
- [ ] B2 Story: every targeted entry point reads in the required order without
  interleaving lower-level mechanics.
- [ ] B3 Abstraction: every changed method has one coherent level of intent and stays
  within the repository's method limits unless a documented existing exception
  remains necessary.
- [ ] B4 Names: every extracted unit names a scheduler concept; no `process_data`,
  `handle_result`, generic service, manager, or utility abstraction.
- [ ] B5 Restraint: no shallow wrapper, duplicated capability, speculative case,
  narrative comment, compatibility shim, or new runtime dependency.
- [ ] B6 Preservation: all eight focused and integration test files pass with the
  same observable contracts; any added characterization test is mutation-relevant.
- [ ] B7 Static gates: scheduler RuboCop remains at zero; raw scheduler Reek warnings
  do not exceed the frozen baseline of 81 and no new smell appears in changed
  production contexts.
- [ ] B8 Architecture: public API remains exact; no new dependency cycle, layer
  violation, cross-gem edge, public constant, or unexplained Enola spillover.
- [ ] B9 Hygiene: no scratch files, generated churn, permission drift, or unrelated
  diff; every created repository file has mode `0644`.
- [ ] B10 Repository gate: `rake ci` introduces no failure beyond the frozen known-red
  baseline. Pre-existing failures are not work for this slice.

## Evidence required

Run one test file per command:

1. `test/scheduler_values_test.rb` — baseline 17 runs, 110 assertions.
2. `test/scheduler_due_occurrences_test.rb` — baseline 9 runs, 24 assertions.
3. `test/scheduler_consumer_test.rb` — baseline 4 runs, 17 assertions.
4. `test/scheduler_contract_test.rb` — baseline 3 runs, 23 assertions.
5. `test/sqlite_schedule_determinism_test.rb` — baseline 4 runs, 15 assertions.
6. `test/sqlite_schedule_store_test.rb` — baseline 21 runs, 73 assertions.
7. `test/agent_schedule_test.rb` — baseline 9 runs, 65 assertions.
8. `test/public_api_test.rb` — baseline 3 runs, 1,015 assertions.

Also require:

- `rubocop gems/tamoz-scheduler/lib` — baseline zero offenses in eight files.
- `reek gems/tamoz-scheduler/lib` — baseline 81 raw warnings; exit 2 is known-red.
- Enola snapshot comparison against the pinned worktree baseline. Enola's Ruby
  extractor does not expose methods inside the `Data.define` blocks, so direct diff
  and tests remain required evidence for `Schedule` and `Occurrence`.
- `rake ci` outside the sandbox for localhost tests. The baseline is red from
  unrelated repository drift: acceptance-workflow SIGKILL, approval-policy/toolbox
  API drift, skills-toolbox surface drift, stale benchmark/protocol/holdout digests,
  ADR-049 wording drift, approval replay, capability-host fixture drift, MCP handshake,
  and related CLI/websearch failures. Scheduler tests are green in the baseline.

Only an independent reviewer `PASS` for B1-B10 followed by the orchestrator's final
verification satisfies this bar. A blocker leaves the bar unmet.
