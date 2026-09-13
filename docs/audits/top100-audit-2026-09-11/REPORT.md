# Top-100 audit — report — 2026-09-11

**All 100 largest Ruby files audited against `BAR.md`. 60 IMPROVE, 40 PASS.**
One audit doc per IMPROVE file (60 docs, `NNN-<slug>.md`); PASS files live in `INDEX.md` only.

Method: ten read-only reviewer agents (10 files each) checked every file against the shared bar;
the orchestrator integrated verdicts, wrote the docs, and re-graded three files where the reviewer
under-scored a bar breach (`082-autonomy_case`, `085-server_config`, `058-profile` — all upgraded
to IMPROVE). Every finding cites file:line; dead-code claims are grep-proven.

## Defect-class findings (fix first)

1. **[critical] `Fanout#flush` crash** — a child flush failure resurfaces as `Integer(:dropped)`
   TypeError; the guard defeats itself. (`076-recorders`, recorders.rb:124-139)
2. **Fail-silent approval list** — a swallowed session-view error makes `approve` report "no paused
   approval" for an approval that exists. (`031-cli_worker_commands`, 539-543)
3. **Nondeterministic field in a claimed digest-identical replay stream** — `emitted_at` from
   `clock_gettime(CLOCK_MONOTONIC)` inside the wire stream the contract calls replay-identical.
   (`016-situation_request`, 649-656, 728-740)
4. **Fail-open containment check** — `verify_outside_root!` rescues `SystemCallError` to nil, so a
   traversal failure passes the profile-root refusal. (`058-profile`, 364-365)
5. **Silently dropped rejected-record failures** — `store_rejected` rescues to nil under a comment
   claiming operator visibility no code implements. (`089-admission`, 437-444)
6. **Assertions that cannot fail** — A-20 injection case compares byte-identical toolboxes
   (`044`), autonomy hard-counter gate passes vacuously on unparseable output (`082`), no-op
   no-model probe never injected (`015`). A safety gate that cannot fail is not a gate.

## Themes (by weight)

- **Tests probing private seams** (~18 files): `__send__`/`instance_variable_set`/`const_get`
  against production internals. Owning seam: public read/injection surfaces plus shared
  test/support fakes (ScriptedModel is re-spelled in ~24 files; no shared fake exists).
  Biggest offenders: `005`, `007`, `012`, `042`, `045`, `047`, `092`, `095`.
- **God-classes mixing 3-6 responsibilities** (~12 files): `worker.rb`, `worker_runtime.rb`
  (child-task subdomain + scheduled-work projection), `comms_store.rb` (~470-line read model with
  `private` starting at line 1147), `session.rb` (19-kwarg initialize, 156-line `build_definition`),
  `executor.rb` (156-line `run`), `situation_request.rb`, `openclaw_durable_cli_adapter.rb`,
  `readiness.rb`, `mission_runner.rb`, `scoreboard.rb`, `agent_smoke_corpus.rb`,
  `openclaw_comms_runner.rb`.
- **Copy-paste duplication** (~14 files): verbatim helper copies across evals harness files,
  conversation/request twins in `comms_store`, 12 heredoc copies of the policy YAML in `049`,
  duplicated comms gateway harness (`073`/`078`), child harness copy (`041`).
- **Blanket RuboCop disables hiding ceiling breaches**: `session_adaptive.rb` (six cops disabled
  class-wide), `mission_runner.rb` (15 kwargs via `**arguments`), `scoreboard.rb`,
  `readiness.rb`, `server_config.rb` (39-line initialize).
- **B9 (domain knowledge in Ruby)**: `boundary_source_audit.rb` hardcodes scenario-specific
  statement-label prefixes as audit policy (`048`, major); `openclaw_comms_runner.rb` re-encodes
  the comms lifecycle vocabulary (`013`, minor — `Tamoz::Comms::Lifecycle` owns it).
- **Metaprogrammed dispatch registries** (banned shape): `sqlite_scenario_runtime.rb` (convention
  method names), `agent_smoke_corpus.rb` (`send("run_#{scenario}")`),
  `openclaw_comms_runner.rb` (`send("drive_#{id}")` deferring typos to a rescue),
  `sqlite_convergence_probe.rb`.
- **Grep-proven dead code** (~12 items): `new_generation` (`081`), `verify_graph_binding!`
  (`021`), `renew_occurrence_lease` (`026`), `pre_dispatch?`/`effect_safety` (`100`),
  `planning_context_for` (`056`), `KINDS` (`057`), `budget` (`060`), `attr_reader :processed`
  (`003`), `Core = Tamoz::Core` alias (`088`, PASS-minor), plus scaffolding/debug remnants in
  `012`, `047`.

## What passed

40 files, including the whole durability spine: `migrator.rb`, `checkpoint_codec.rb`, `jcs.rb`,
`supervisor.rb`, `boundary_registry.rb`, `capability_binding.rb`, and the stronger test suites
(`graph_execution_test`, `agent_tool_error_recovery_test`, `autonomy_scorecard_test`,
`subprocess_runner_test`, `evals_verifier_test`). The recurring PASS-minor is re-spelled test
doubles — one shared `ScriptedModel` in test/support would close it everywhere.
