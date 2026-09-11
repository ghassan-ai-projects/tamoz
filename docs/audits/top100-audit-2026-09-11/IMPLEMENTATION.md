# Top-100 audit — implementation progress — 2026-09-11

Tracks implementation of the `IMPROVE` audit docs. One row per doc. This file is the
implementation source of truth (kept separate from `INDEX.md`, which the auditing agent
owns for verdicts). Each done row is committed separately; `Resolution` sections are
appended to the individual audit docs.

Status: `todo` → `done` (implemented + tests green + committed) / `partial` (some
findings implemented, others rejected with reason) / `rejected` (finding not upheld).

| Doc | File | Status | Notes |
|---|---|---|---|
| 076 | recorders.rb | done | flush crash fixed + regression test; DropLedger mixin; Journal split out |
| 031 | cli_worker_commands.rb | partial | ERR: unavailable_approval surfaced + cmd_approve refuses; observability_status reports unavailable; doctor PLACE deferred (manifest regen blocked) |
| 058 | profile.rb | partial | ERR fail-closed fixed; DUP rejected (Core.deep_freeze stringifies keys, breaks **spread) |
| 089 | admission.rb | done | ERR surfaced via AdmissionResult stored?; OwnerRequest value |
| 008 | worker_runtime.rb | todo | ERR bypass durable + SIZE |
| 095 | approval_engine_test.rb | done | uses resolve return + grant_store.size |
| 055 | verifier.rb | done | shared verify_terminal_diagnostic_status! table |
| 087 | state_codec.rb | done | scalar/array handlers; add_registration; merged counter |
| 004 | agent_toolbox_test.rb | done | public preview/execute/bytes contract |
| 005 | sqlite_comms_store_test.rb | todo | TEST |
| 007 | sqlite_stale_request_test.rb | todo | TEST |
| 009 | packaging_test.rb | todo | DUP/TEST/SIZE |
| 010 | agent_cli_test.rb | partial | raw SQL + fabricated record replaced by public request_history; cancellation/map_answer probes deferred |
| 011 | agent_profile_machinery_test.rb | partial | over-claim fixed + refusal proven (+2 asserts); ProfileFixture value; doc/stub dedup; CLI-private probes deferred |
| 012 | comms_gateway_test.rb | partial | debug removed; gateway_graph dedup; raw-SQL probes deferred to 006 seam |
| 013 | openclaw_comms_runner.rb | todo | SIZE/DUP/DEAD/B9 |
| 014 | openclaw_durable_cli_adapter.rb | todo | PLACE/SIZE/NAME |
| 015 | memory_engine_test.rb | partial | dead probe removed; promote_wisdom helper; private-read deferred |
| 021 | session.rb | todo | SIZE/DEAD/DUP/STATE |
| 022 | agent_session_kill_matrix_test.rb | done | dup child scan removed; reference yields with_scenario; workspace-entries helper |
| 023 | invocation.rb | todo | SIZE/DEAD/FX |
| 024 | runtime.rb | todo | SIZE/STATE/DUP |
| 026 | schedule_store.rb | partial | JOIN DUP + dead renew removed; lease_for/SIZE declined |
| 033 | episode_nodes.rb | partial | frame assembler DUP; dead snapshot param; decision_builder declined |
| 034 | memory_store.rb | partial | security-lockstep DUP fixed; STATE deferred (retrieval ripple) |
| 037 | openclaw_comms_fixture.rb | partial | install_delivery_sink seam; read_rows deferred to 006 seam |
| 038 | readiness.rb | partial | artifacts verified once per evaluate; three-seam SIZE split pending |
| 039 | record.rb | partial | Core.deep_dup shared (deep_freeze remedy rejected); FailureEvent value, 0 ParameterLists; engine split pending |
| 040 | sqlite_scenario_runtime.rb | partial | dispatch fail-fast; append_checkpoint DEAD rejected (has defaults) |
| 051 | subprocess_runner.rb | todo | SIZE |
| 061 | sqlite_trace_recorder.rb | done | ShapeValidation shared module; siblings noted for 043 |
| 062 | openclaw_mission_runner.rb | todo | SIZE/DUP/DEAD |
| 063 | sqlite_convergence_probe.rb | partial | explicit PROBE_METHODS table + probes guard; FX pair deferred (needs adapter API decision) |
| 064 | progress_projection_test.rb | done | install_delivery_sink; names; drain_row merged |
| 068 | session_adaptive.rb | partial | lifecycle_event 12->5 params (allowlisted splat); node-method split declined (documented justification) |
| 069 | stream_episode_skills_memory_test.rb | done | run_episode lifecycle helper; projection factory; -159 lines |
| 070 | scoreboard.rb | todo | SIZE/PLACE/DUP |
| 073 | comms_command_parity_test.rb | todo | TEST/DUP |
| 078 | context_control_exposure_test.rb | todo | DUP/TEST |
| 081 | session_context_controls.rb | done | dead /new generation pair deleted; conversation_history_for helper |
| 082 | autonomy_case.rb | partial | vacuous hard-counter gate fixed; shared ScriptedModel deferred |
| 084 | agent_session_test.rb | partial | __send__ dropped (seam was already public); ToolPolicy value; shared-double DUP deferred |
| 085 | server_config.rb | rejected | SIZE rubocop-clean; STATE fix blocked by Style/DataInheritance |
| 092 | comms_evidence_gated_approval_test.rb | partial | Harness returns transport (0 ivar probes); PressBinding value; store __send__ deferred to 006 seam |
| 094 | dependency_isolation_test.rb | done | declared_features + capture_json helpers; dead regex alternative removed |
| 100 | failure_record.rb | partial | DEAD+ERR fixed; SIZE rejected (rubocop clean, Max 20) |
