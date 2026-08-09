# Codebase Review — gems/tamoz-evals + agenteval/

*12-agent codebase review, 2026-08. See [INDEX.md](INDEX.md). Judged against `docs/CODING_STANDARD.md`.*

## Overall assessment

The tamoz-evals verifier/subprocess layer is unusually careful (TOCTOU-stable reads, process-group management, bounded everything); the weak spots are concentrated in `agenteval/` (untested, one serious process bug) and in size/duplication in the harness corpora. The evals-outside-runtime boundary is properly executable (`test/dependency_isolation_test.rb:56-84`, gemspec audit included); `agenteval/` is a separate top-level tool (not a gem, not packaged) that drives `tamoz` purely through its CLI — the right shape; its problems are internal quality, not boundary violations. Nothing in scope looked like it belongs in a different gem; the natural extraction is inside tamoz-evals itself (status-policy matrix, memory cell-runner).

## High

### H1 — `Trial#kill_tree` kills the harness's own process group

`agenteval/lib/agenteval/trial.rb:96-104`. `Open3.popen2e` at `trial.rb:74` spawns without `pgroup: true`, so the child shares agenteval's process group; `Process.kill("KILL", -Process.getpgid(pid))` then SIGKILLs the whole group, including agenteval itself, on any timeout.

**Fix:** spawn with `pgroup: true` (as `SubprocessRunner` correctly does at `gems/tamoz-evals/lib/tamoz/evals/harness/subprocess_runner.rb:215`) before using group kill.

### H2 — Whole `agenteval/` framework is untested

No file under `test/` references `Agenteval` (grep confirms). `Trial#judge`'s status matrix (`trial.rb:108-142`), `Report.compare` (`report.rb:106-145`), `Suite#digest`/`#scenarios` (`agenteval.rb:49-116`) are the decision-critical paths and have zero characterization tests, violating §9 behavior-first testing. `cmd_validate` (`bin/agenteval:73`) validates the corpus, not the framework.

**Fix:** add `test/agenteval_*_test.rb` pinning the judge matrix and compare transitions.

### H3 — Missing modifiers `freeze` and `ambiguous`

Documented in `agenteval/DESIGN.md:47,54` and referenced in supports lists at `agenteval/packs/maintenance.rb:39,66,100`, but never `define`d in `agenteval/lib/agenteval/modifier.rb` (only 7 of the promised 9 exist). `--modifiers all` silently never runs them.

**Fix:** implement the two modifiers or remove the references and DESIGN rows.

### H4 — `Tamoz::Evals::ReferenceError` shadows Ruby's built-in `ReferenceError`

`gems/tamoz-evals/lib/tamoz/evals/errors.rb:10`. Any unqualified `ReferenceError` inside `Tamoz::Evals` resolves to the evals class; a `rescue ReferenceError` intended for Ruby's constant-lookup error would silently catch artifact errors instead.

**Fix:** rename to `ArtifactReferenceError` (error identity is pinned by tests per §7, so ship with a migration note).

### H5 — `Workspace#run` leaks grandchildren and has no output bound

`agenteval/lib/agenteval/workspace.rb:86-101`. Timeout kills only the direct child pid (`workspace.rb:93`); test subprocesses spawned by the suite survive with the tmpdir already removed. And `out << stream.read` is unbounded — a runaway suite can exhaust memory (compare `SubprocessRunner::DEFAULT_OUTPUT_LIMIT_BYTES`).

**Fix:** spawn with `pgroup: true` + group kill, and cap captured bytes.

## Medium

### M1 — Five-status decision matrix duplicated

`Verifier#verify_evidence_status!` (`gems/tamoz-evals/lib/tamoz/evals/verifier.rb:325-379`) and `#verify_decision_evidence!` (`verifier.rb:473-525`) restate the same passed/failed/invalid/infrastructure_error/insufficient_evidence case logic with subtly different payloads. Two copies of a security-relevant rule will drift.

**Fix:** extract one shared status-policy table consumed by both.

### M2 — `AgentSmokeCorpus` is a 3,287-line god class

`gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb`. It mixes the declarative case registry (lines 19-545), a scripted model stub (~488-600), 22 scenario-runner methods, workspace file setup, and oracles — exactly the "policy + orchestration + rendering in one method/class" §4/§6 warn against; it also has a dual source of truth with `suites/agent/smoke/*.case.json` (guarded by the id check at line 807-820, but every case is authored twice).

**Fix:** split the declarative registry from the per-scenario runners (one file per scenario family), keep the JSON as the single generated form.

### M3 — Memory corpus duplication

`agent_memory_corpus.rb:243` and `agent_memory_repository_corpus.rb:145` share the `cases`/`run_cell(case_artifact, cell_root:, store:, memory_config:, memory_capture:)` scaffolding; `run_recall_requirement`/`run_sensitive_guard` (agent_memory_corpus.rb:270,296) and `run_real_recall_ladder`/`run_real_sensitive_guard` (repository: 169,192) are near-parallel.

**Fix:** extract a shared cell-runner; two real consumers already exist, satisfying §6.

### M4 — Mutable module-level registries as ambient state

`Agenteval::Adapters.all` (`agenteval/lib/agenteval.rb:31`), `Registry.tasks` (`agenteval/lib/agenteval/task.rb:20`), `Modifiers.all` (`agenteval/lib/agenteval/modifier.rb:16`), all populated as a side effect of `Agenteval.load_packs` glob-requiring files (`agenteval.rb:18-20`). Violates §5 "no hidden global state"; load order and re-`load` (`load_adapter` uses `load`, agenteval.rb:26) make behavior depend on require history.

**Fix:** build an explicit registry object passed to `Suite`/`CLI`.

### M5 — Implicit cross-file `require` dependencies

`agenteval/lib/agenteval.rb` uses `JSON.generate` (line 69) but requires only `"digest"`; `agenteval/lib/agenteval/trial.rb` uses `Open3` (line 74) but requires only json/tmpdir. Both work only because `bin/agenteval`/`workspace.rb` happen to load json/open3 first — same pattern in `gems/tamoz-evals/lib/tamoz/evals/verifier.rb` (uses `Digest::SHA256` at line 136, requires only json/time; digest arrives via canonical_json's position in the require list at `evals.rb:8`). Violates §2's self-sufficiency spirit.

**Fix:** require what you use in each file.

### M6 — Oversized verifier

`gems/tamoz-evals/lib/tamoz/evals/verifier.rb` is 561 lines with several ~50-60-line methods (`verify_evidence_process!` 264-323, `verify_provenance!` 388-447, the two status matrices). All currently carried in `.rubocop_todo.yml` (lines 82, 1159, 1263, 1389, 1508, 1839), i.e. known debt — flagged so the remediation slice prioritizes the duplicated policy matrix (M1) over line-count shaving, per §4's "never split cohesive logic merely to satisfy a number".

### M7 — `SQLiteScenarioRuntime` reaches into tamoz-sqlite internals

`gems/tamoz-evals/lib/tamoz/evals/harness/sqlite_scenario_runtime.rb:33` uses `Tamoz::SQLite.const_get(:Wire, false)` rather than a public contract, and `validate_capabilities!` (66-74) probes other gems with `defined?` checks instead of a declared boundary. The load-isolation direction (evals outside the runtime graph) is asserted in `test/dependency_isolation_test.rb:56-63`, but this lazy constant path is exactly what §6.1 says load-time isolation can't catch.

**Fix:** assert the reference directly or go through a public sqlite API.

## Low

- **L1 — Error classes lack the §7 one-line "when raised" docs.** `gems/tamoz-evals/lib/tamoz/evals/errors.rb:5-11`; `Tamoz::Evals.verify` (the gem's public entry point, `evals.rb:48-50`) also lacks the §11 contract + runnable example. **Fix:** add the one-liners and entry-point doc.
- **L2 — Secret-handling in the tamoz adapter.** `agenteval/adapters/tamoz.rb:12-18` regex-scrapes `DEEPSEEK_API_KEY` out of the repo `.env` and injects it into the child env; `Trial#judge` then records `answer_excerpt` (`trial.rb:140`) into committed-style JSON reports (`agenteval/reports/baseline-20260805.json`). If the agent echoes its env, a key lands in a durable record — §8/invariant-24 territory. **Fix:** scrub the key value from captured output before excerpting, or document the check.
- **L3 — `Schema` recursion and per-call recompilation.** `gems/tamoz-evals/lib/tamoz/evals/schema.rb`: `resolve_reference` (64-74) has no cycle guard (a self-referential `$ref` → `SystemStackError`, not a `SchemaError`); `Regexp.new` is recompiled per validated string (`schema.rb:177`); `Schema.load` re-reads and re-validates the schema file on every artifact (`verifier.rb:54`). Schemas are repo-controlled so severity is low. **Fix:** memoize loaded schemas, track in-progress refs, compile patterns once in `validate_schema_definition!`.
- **L4 — Struct vs §5 immutable values.** `Agenteval::Scenario`/`Judgement` (`scenario.rb:6,24`), `Task`/`Built` (`task.rb:10,17`), `Adapter`/`Result` (`trial.rb:13,23`), `Project::Spec`/`Operation` (`project.rb:11,13`) are all mutable Structs; modifiers deliberately mutate a scenario in place (`modifier.rb:39,57,77,...`). Also `Agenteval::CommandResult` lives in `workspace.rb:104`, off the one-constant-per-file path rule (§2). **Fix:** `Data.define` for results/judgements; have modifiers return a new scenario instead of mutating.
- **L5 — Minor correctness nits in agenteval.** `Report#median` picks the upper-middle element for even counts (`report.rb:97-102`, fine but undocumented); `CLI#parse` accepts `--difficulty -3`, `--seeds ""`, `--repeat 0` without validation (`bin/agenteval:242-261`); `Suite#instantiate` returns a `[scenario, built]` pair that every caller must destructure positionally (`agenteval.rb:114`). **Fix:** validate numeric options; return a small value object.
