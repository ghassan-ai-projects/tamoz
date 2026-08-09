# Codebase Review — gems/tamoz-scheduler

*12-agent codebase review, 2026-08. See [INDEX.md](INDEX.md). Scope: 871 LOC.*

## Overall assessment

The gem is small and generally well-disciplined: immutable `Data.define` values with content-addressed digests and frozen inputs (§5, exemplary); a closed, typed occurrence state machine where `enqueued` is never terminal (the "no false green" invariant enforced structurally); grant intersection as a pure function pinned at both seams (invariant 40), fail-closed on revocation; error classes each documenting when raised (§7). The two high findings are crash paths that escape the typed-failure contract.

## High

### H1 — `at` expression validation accepts impossible calendar dates, then crashes later

`gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb:342-345` pins only the `\d{2}` shape; `Schedule.at_instant` (`schedule.rb:242-247`) calls `Time.utc(2024, 13, 99, …)` which raises raw `ArgumentError` at poll time, not `Tamoz::ConfigurationError` at validation time. Error identity is public API (§7) and the poller contract is "typed failures, never the poller crashing" (`errors.rb:5`).

**Fix:** validate the parsed components (month 1–12, day valid for month) in `validate_times!`, or rescue `ArgumentError` in `at_instant` and re-raise `ConfigurationError`.

### H2 — `ScorecardSummaryConsumer#run` crashes on missing `tamoz-eval` binary

`scorecard_summary_consumer.rb:34`: `Open3.capture3` raises `Errno::ENOENT` when the default `["tamoz-eval", …]` isn't on PATH; every other failure path returns a fail-closed `{"ok" => false}` hash, this one escapes as an exception. No test covers it (`test/scheduler_consumer_test.rb` only covers non-zero exit and bad JSON).

**Fix:** `rescue SystemCallError` → `{"ok" => false, "reason" => "scorecard command unavailable"}`.

## Medium

### M1 — Three misfire policies are behaviorally identical

`schedule.rb:191-205`: `:skip`, `:latest`, and `:fire_once` all return `{materialize: [last], skipped: rest}`. The docs claim distinct semantics ("deliver only the latest" vs "coalesce" vs "one recovery instant") but the code is one branch — and `schedule.rb` sits in `.rubocop_todo.yml` under `Lint/DuplicateBranch` (line 650-657), hiding it. Either the design intends different behavior (bug) or three names for one behavior (§3.1 vocabulary violation).

**Fix:** collapse to the real semantics or differentiate; remove the todo entry.

### M2 — Boolean parameter violates §4

`grant_intersector.rb:74`: `effective_grant(stored, current, allow_narrowed: true)` is exactly the `BooleanParameter` case the standard bans ("split the method or pass a named policy").

**Fix:** split into `effective_grant` / `effective_grant_strict`, or pass a policy symbol.

### M3 — `due_occurrences` is public, load-bearing, and untested at the value level

`schedule.rb:151-173` is what `materialize_due` claims ("`next_fire_at` answers for the poller; `due_occurrences` is what materialize claims"), yet `test/scheduler_values_test.rb` has no test naming it — only indirect coverage through the sqlite store.

**Fix:** add value-level tests, especially catch-up windows, `limit` truncation, and `anchor` handling.

### M4 — Dead/duplicated code in `Schedule`

`schedule.rb:169` assigns `first = start` and never uses it; `schedule.rb:131-134` repeats `return nil if end_at && anchor > end_at` after the identical check already returned at lines 126-129.

**Fix:** delete both.

### M5 — `validate!` return plumbing is wasted work

`schedule.rb:61-91`: `initialize` builds `@validated` and `@digest` ivars on a `Data` value solely to forward to `super`; both ivars persist for the object's life but are never read again.

**Fix:** use local variables (`validated = validate!(…)`, then `super(**validated, definition_digest: …)`), cutting the redundant `.fetch` chain too.

## Low

- **L1 — `GrantIntersector.normalize` silently coerces.** `grant_intersector.rb:86-92`: a non-Hash grant becomes `[]` (fail-closed, fine) but `String(value)` silently stringifies symbols/numbers, so `{capabilities: [:read, 42]}` is accepted. **Fix:** reject non-String members with `ConfigurationError`.
- **L2 — Mixed positional/keyword signatures.** `occurrence.rb:83,89,105,111` (`running(execution_id, now:)`, `skipped(reason, now:)`) mix positional args with keywords against §4's "keyword arguments beyond one or two positional parameters". Borderline; acceptable, but `transition_from_running(to, execution_id, evidence, now)` (4 positionals, `occurrence.rb:144`) is not.
- **L3 — `ScheduleStore` contract is half a pair.** `schedule_store.rb`: declares `disable_schedule` but no `enable_schedule`, and no `fetch_schedule`/`list_schedules`, though the sqlite adapter implements all three (`gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:107,134,142`) and §4 requires install/remove pairs. The "interchangeable adapter" promise (`schedule_store.rb:7-8`) doesn't hold for those operations. **Fix:** promote `enable_schedule` and `fetch_schedule` into the contract or document them as adapter-specific.
- **L4 — Consumer arguably lives in the wrong gem.** `ScorecardSummaryConsumer` is a product task hard-wired to one named external executable (`tamoz-eval`, shipped by `tamoz-evals`) inside a gem whose charter is "validated values and the structural store contract" (`scheduler.rb:15-19`). §6.2 rejects exactly this ("an integration with one named external service living inside a core gem… an adapter behind an existing contract, or its own gem"). The dependency is runtime-PATH only, so no load-time boundary breaks, but it's a leaky coupling to tamoz-evals. **Fix:** move to tamoz-evals or make it a caller-supplied adapter.
- **L5 — Formatting debt in todo file.** `schedule.rb`, `occurrence.rb`, `scorecard_summary_consumer.rb`, `grant_intersector.rb` appear in `.rubocop_todo.yml` under `Layout/LineLength` and `Layout/SpaceInsideHashLiteralBraces`. Pre-existing debt, fine, but worth noting the gem leans on the todo more than its size warrants.
