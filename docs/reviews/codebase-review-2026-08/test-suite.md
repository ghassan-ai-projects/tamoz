# Codebase Review — test/ suite

*12-agent codebase review, 2026-08. See [INDEX.md](INDEX.md). Scope: test/ (133 files, ~41.8k lines, 1333 tests). Context: Minitest, parallelized via hand-rolled bin-packing sharding in `Rakefile:128-186`; coverage 88.4% line / 69.0% branch (`coverage/.last_run.json`).*

## Overall assessment

The suite is in good shape — deterministic seeded randoms, deadline polling exists in places, adversarial/kill-matrix coverage is unusually strong. Already good: kill-matrix/crash-recovery design (`agent_session_kill_matrix_test.rb`, `AutonomyCase::CrashingModel` raising outside `StandardError`, `test/support/autonomy_case.rb:47-54`) models `kill -9` honestly rather than faking it; rule-pinning tests carry their reasons (`sqlite_checkpoint_seams_test.rb:5-8`, `agent_profile_adoption_seams_test.rb:3-9`) per §9; seeded `Random.new(...)` everywhere — no nondeterministic randomness found; serial/slow test segregation in the Rakefile is documented with reasons, and the `ci` task warns what it skipped (`Rakefile:339`). The main weaknesses are fixed-sleep synchronization, heavy private-implementation testing via `send`, and ENV mutation without guaranteed restore.

## High

### H1 — Fixed-`sleep` synchronization — flaky under CI load

36 `sleep` calls across 12 files; the worst are fixed delays waiting on another process's durable state: `test/sqlite_crash_recovery_test.rb:28,82,121` (0.12–0.2s), `test/sqlite_checkpoint_test.rb:91`, `test/mcp_supervisor_test.rb:158,183` (0.3s), `test/agent_session_kill_matrix_test.rb:198,378,407,445,483,512,540` (0.3–0.35s), `test/sqlite_stream_critic_fix_test.rb:83`. The same file already shows the correct pattern (deadline polling at `mcp_supervisor_test.rb:110`).

**Fix:** replace every fixed sleep that waits on observable state with a deadline-poll helper in `test/support/`.

### H2 — Private-implementation testing via `send` — 75 occurrences in 19 files

Concentrated: `test/agent_cli_test.rb:557-802` (15 calls, incl. `map_answer`, `exit_for_cancellation`), `test/sqlite_stale_request_test.rb:860,903,916,949` (drives `CLI#drain_to_terminal` with a `FakeSession`), `test/agent_profile_machinery_test.rb` (9), `test/sqlite_checkpoint_test.rb` (7). This violates CODING_STANDARD §9 ("test through the narrowest stable boundary; do not test private implementation") and will block the ongoing CLI decomposition (the dirty `agent.rb`/`cli.rb` refactor is exactly what these tests pin).

**Fix:** either promote the tested seams to `:nodoc:` public contracts, or drive the CLI through `CLI.run` like `test/support/autonomy_case.rb` already does.

### H3 — ENV mutation without guaranteed restore

`test/subprocess_runner_test.rb:15` sets `ENV["TAMOZ_HIDDEN"] = "ambient-secret"` at file top level (restored at :48, but only on one path). MCP tests set server flags mid-test (`test/mcp_invocation_test.rb:468,511`, `test/agent_mcp_adversarial_test.rb:187-331`, `test/mcp_supervisor_test.rb:88,169,334,363`) and rely on each file's bespoke teardown (`mcp_invocation_test.rb:77-81`); `TAMOZ_MCP_TEST_CREDENTIAL` and `TAMOZ_KILL_*` (`agent_session_kill_matrix_test.rb:42-46,722`) are outside the saved-flag sets. Since shards run many files in one process, a leaked flag silently changes a later file's behavior.

**Fix:** one `with_env` helper in `test/support/` (save/restore/ensure) used by all; delete per-file `@saved_flags` copies.

## Medium

### M1 — Coverage holes in exactly the durability-adjacent code

From `coverage/.resultset.json`: `gems/tamoz-evals/lib/tamoz/evals/harness/sqlite_convergence_probe.rb` 21.9%, `sqlite_scenario_runtime.rb` 22.2%, `sqlite_scenario_driver.rb` 29.5%, `gems/tamoz-sqlite/lib/tamoz/sqlite/deletion.rb` 55.2%, `gems/tamoz-agent/lib/tamoz/agent/cli_prompt_adapter.rb` 65.9%, `gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb` 69.9%. Branch coverage overall is 69.0% vs 88.4% line — failure branches are the gap. Some of this is an artifact of slow tests being excluded from the coverage run; if so, the coverage command should compose the slow-set results, otherwise the baseline is understating.

**Fix:** characterize `sqlite/deletion.rb` and `mcp/invocation.rb` failure paths first (per §9, characterization before the extraction slices).

### M2 — `test/agent_toolbox_test.rb` — 1285 lines, 59 tests, 70 inline `Toolbox.new` calls, 60 `Dir.mktmpdir` blocks, zero shared helpers

The same "mktmpdir + write files + `Toolbox.new(root:)`" scaffold repeats dozens of times (e.g. :17-30, :33-45, :48-54).

**Fix:** extract `with_toolbox(files: {...}) { |toolbox| }` — mirroring what other suites already do with their `with_*` helpers.

### M3 — Duplicated helper definitions across files

`build_config` is defined separately in 5 MCP test files with diverging signatures (`test/mcp_invocation_test.rb:83`, `test/mcp_supervisor_test.rb:63`, `test/mcp_catalog_test.rb:53`, `test/mcp_elicitation_test.rb:72`, `test/agent_mcp_adversarial_test.rb:58`); `profile_document` duplicated in `test/agent_profile_machinery_test.rb:1047` and `test/websearch_egress_test.rb:42`; `without_env_keys` (`agent_profile_machinery_test.rb:991`) duplicates what every MCP teardown re-implements.

**Fix:** move to `test/support/mcp_harness.rb` / `env_helpers.rb`; `test/support/` currently holds only 2 files for a 41k-line suite.

### M4 — Misfiled/misplaced test code (gem-boundary)

`test/sqlite_stale_request_test.rb` (1227 lines, the 2nd-largest file) spends its back half (`:840-1227`) testing `Tamoz::Agent::CLI` behavior with a `FakeSession` — an agent-CLI test living in a sqlite-named file, coupled to both gems' internals. Support files `test/stream_interlock_harness.rb`, `test/stream_simulated_connector.rb`, `test/healing_fixtures.rb` sit in `test/` root while a `test/support/` directory exists.

**Fix:** split CLI-drain tests into `agent_cli_*`, move harnesses to `test/support/`.

### M5 — `assert_equal true/false` anti-pattern

`test/memory_repository_adapter_test.rb:112,168,195`, `test/mcp_invocation_test.rb:220,235,252,266,296,393,455`.

**Fix:** `assert`/`refute` — better failure messages.

## Low

- **L1 — Six test files don't `require_relative "test_helper"` directly** (`agent_profile_adoption_seams_test.rb`, `agent_profile_schema_seams_test.rb`, `healing_failure_contract_test.rb`, `healing_matrix_test.rb`, `healing_remediation_test.rb`, `sqlite_checkpoint_seams_test.rb`) — they get it transitively via `healing_fixtures.rb`/other requires, so running one standalone only works by load-order luck in some cases. §9 names `require_relative "test_helper"` as the per-file convention. **Fix:** add the require to each.
- **L2 — `TEST_WEIGHTS` (`Rakefile:97-116`) is manually regenerated** via `rake test_profile`; nothing in CI detects drift, so sharding silently degrades as files grow. **Fix:** a cheap drift check (top-3 slowest file still in the table) or a comment-only date stamp plus a scorecard entry.
- **L3 — Inline `rescue nil` swallows harness bugs.** `test/agent_session_kill_matrix_test.rb:120` and `test/agent_acceptance_workflow_test.rb:73` use `(JSON.parse(prompt) rescue nil)` inside the scripted-model harness — a malformed prompt from production code masquerades as a "verify" phase. **Fix:** parse strictly and fail the test on `ParserError`.
- **L4 — `test_helper.rb:23-31` loads all 9 gems into every test process.** This masks missing per-gem requires (a test can pass while `require "tamoz/tools"` alone is broken). Partially mitigated by `test/dependency_isolation_test.rb`, but that only checks load isolation, not per-gem sufficiency. Consider a sufficiency smoke (clean process, `require` one gem, touch one entry point) per gem.
- **L5 — Fixture strategy is nearly all inline-generated.** `test/fixtures/` holds only 2 files. That's mostly a strength (self-contained per §9's subprocess rule), but the one binary fixture (`legacy_session_v1.sqlite3`, used at `test/legacy_session_resume_test.rb:21`) is the repo's only proof of cross-version resume; there's no second-generation fixture or generator script pinned alongside it, so the "generated artifacts are never hand-edited" rule (§2) can't be verified for it. **Fix:** commit the generator that produced it, or document its provenance in the test header.
