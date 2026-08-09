# Codebase Review — apps/tamoz-agent + bin/

*12-agent codebase review, 2026-08. See [INDEX.md](INDEX.md). Scope: `apps/tamoz-agent`, `bin/`, plus the CLI wiring they delegate to — `gems/tamoz-agent/exe/tamoz`, `gems/tamoz-agent/lib/tamoz/agent/cli.rb`, `cli_session_commands.rb`, and the eval CLI behind `bin/tamoz-eval`.*

## Overall assessment

`apps/tamoz-agent` contains no code — only `app.json` + `README.md`; the manifest is pinned by `test/public_api_test.rb:279`. `Tamoz::Evals::CLI` (`gems/tamoz-evals/lib/tamoz/evals/cli.rb`) is clean: named exit constants, precedence-ordered exit aggregation, typed rescues, no state beyond injected factories. The agent CLI itself is a ~800-line god class split into modules that merely relocate methods, and its two entry paths disagree on what the operator-facing word `unknown` means for effect resolution.

## High

### H1 — Inconsistent `resolve_effect` vocabulary between the two CLI entry paths

`gems/tamoz-agent/lib/tamoz/agent/cli_session_commands.rb:242` maps the operator-facing status `unknown` to `:failed` (`status_symbol = status == 'unknown' ? :failed : status.to_sym`), while `map_answer` in `cli.rb:474-479` maps `"unknown"`/`"?"` to `:unknown` for the same `resolve_effect` interrupt kind (pinned at `test/agent_cli_test.rb:801`). The session doc says `:unknown` effects are only cleared by explicit resolution (`session.rb:466-468`), so an operator typing `tamoz resolve … unknown` silently records `:failed` — a different durable state than the interactive path records for the same word. Violates §3.1 (one concept, one verb).

**Fix:** accept and pass through `:unknown` in `parse_resolution`, reserving `failed` for explicit `failed`.

### H2 — `CLI` is a ~800-line god class split by concerns that merely relocate methods

`cli.rb:16-24` includes six modules (`CLIWorkerCommands`, `CLIScheduleCommands`, `CLIProfileCommands`, `CLISessionCommands`, `CLIAuthority`, `CLIRendering`) sharing the same instance state (`@out`, `@err`, `@options`, `@cancellation`, `@stream_error`, `@rendered_stale_request_ids`, `@prompts`, `@parser`, `@policy`). The file comment admits the split is "so neither half becomes unreadable" — exactly the banned pattern in §6 ("concerns that merely relocate methods") and the 250-line signal in §2.

**Fix:** extract real collaborators with own state (e.g. a `StreamDriver` owning `run_with_stream`/`drain_to_terminal`/`render_stream_part`, a `SessionLauncher` owning `run_durable`/`build_model`/`build_toolbox`).

## Medium

### M1 — Duplicated subcommand dispatch, nested two levels

`cli.rb:97-123` has a `case` over subcommands, then re-dispatches `init/queue/worker/status/schedule/approve` in a second inner `case` inside `catch(:tamoz_subcommand_help)`. Two places to edit per new command, and the `else raise` at :122 is unreachable given `ArgumentParser` validates against `SUBCOMMANDS`.

**Fix:** flatten to one `case`, wrap only the worker-family calls in the `catch`.

### M2 — Audit event emitted with fabricated identifiers

`cli.rb:441-447`: the `--all --i-understand-approve-all` path emits `audit.approve_all` with hardcoded `"thread_id" => "unknown", "request_id" => "unknown"`. An audit record that cannot name its thread/request is worse than none (§11: a doc/record describing something false is worse than none).

**Fix:** thread the real ids into `answer_for` (they're available at every call site) or drop the event.

### M3 — Exit code `2` is a magic number

`cli.rb:152` (`result.satisfied ? 0 : 2`) while every other code is a named constant (`USAGE_ERROR`, `EXIT_PAUSED`, …).

**Fix:** name it `EXIT_UNSATISFIED = 2` next to the others at `cli.rb:11-14`.

### M4 — `build_list_session` monkey-patches a singleton as a fake model

`cli.rb:488-497`: `dummy_model = Object.new; def dummy_model.generate(**) = "{}"`. A caller-visible duck-type fake inside production wiring; if `Session` ever calls anything but `generate` this breaks at runtime, far from any test.

**Fix:** add a named `Tamoz::Agent::NullModel` (or make `model:` optional for view-only sessions) and use it here.

### M5 — `bin/tamoz-eval` load-path bootstrap is fragile and untested

`bin/tamoz-eval:4` hand-unshifts only `gems/tamoz-evals/lib`. It works today because the gemspec declares zero runtime dependencies (`gems/tamoz-evals/tamoz-evals.gemspec`), but nothing pins that: the day tamoz-evals gains a dependency on another tamoz gem, this wrapper silently breaks outside Bundler, violating the §9 "every transitive tamoz gem on `-I`" spirit. No test invokes `bin/tamoz-eval` as a subprocess (only the gem's `Tamoz::Evals::CLI` is tested).

**Fix:** either `require "bundler/setup"`/exec through bundler, or add a smoke test that runs `bin/tamoz-eval --version` in a clean process.

### M6 — `apps/tamoz-agent/app.json` namespace claims `Tamoz::App`, which does not exist

`apps/tamoz-agent/app.json:4` declares `"namespace": "Tamoz::App"` but no such constant exists anywhere; the test at `test/public_api_test.rb:280-287` pins the manifest's string values verbatim rather than resolving the namespace. §11: "A doc describing a surface the repository does not have is worse than no doc."

**Fix:** point `namespace` at the real entry (`Tamoz::Agent::CLI`) and have the test const-resolve it.

## Low

- **L1 — `map_answer` uses a boolean-style `case` inside a `case` with raise-as-validation.** `cli.rb:462-486` is a 24-line method with three vocabularies (`approve_tool`, `clarify`, `resolve_effect`); at the method ceiling and a natural split per kind. **Fix:** one small parser per kind, selected by a lookup table.
- **L2 — Mutable per-process state held on the CLI object.** `@rendered_stale_request_ids` (`cli.rb:46`, `294-323`) and `@stream_error` (`cli.rb:45`, with a comment at :339-341 explaining why it is deliberately *not* reset between calls) are hidden cross-call state; §5 prefers explicit collaborators. The stream driver extraction (H2) would naturally own both.
- **L3 — Boolean-parameter-adjacent `read_only:` flag on `run_durable`.** `cli.rb:499` `read_only: false` only controls whether `adapter.close` runs in `ensure` (:534). A boolean argument switching behavior is §4's `BooleanParameter` smell (already reek-suppressed elsewhere in `cli_session_commands.rb:7` for `--force`). **Fix:** always close the adapter (closing a read connection is harmless) or pass the policy by name.
- **L4 — `install_signal_handlers` leaves traps unrestored on "DEFAULT".** `cli.rb:562-571`: `Signal.trap` returns `"DEFAULT"`/`"IGNORE"` strings, which are truthy and correctly restored, but the restore only happens `if old_int` — fine today; however nesting two `run_durable` calls would clobber the outer token since `@cancellation` is a single ivar. No nesting exists today; flag for the extraction above.
- **L5 — README examples unverifiable.** `apps/tamoz-agent/README.md:6-11` shows `bundle exec tamoz …` commands that are never exercised by any test or script; §11's "check claims against the code" suggests a smoke test (or at least a `packaging_test` assertion that `exe/tamoz` boots `--help`).
- **L6 — Two entry-point shims for the same CLI drift risk.** `bin/tamoz-eval` and `gems/tamoz-evals/exe/tamoz-eval` are near-duplicates (only the `$LOAD_PATH` line differs). Acceptable as dev-convenience, but worth one comment in `bin/tamoz-eval` saying why it exists, so it isn't "cleaned up" into the gem exe.

## Notes (not violations)

- The "reference application" framing in `apps/tamoz-agent/README.md:34` is aspirational but consistent with the bounded-slice status.
- `bin/tamoz-eval`'s RuboCop exclude (`.rubocop_todo.yml:3668`, `Style/StringLiterals`) is legacy debt that shrinks naturally — the file has no string literals at all now, so the exclude entry is dead and could be dropped on the next `.rubocop_todo.yml` regeneration (generated file; do not hand-edit, §2).
