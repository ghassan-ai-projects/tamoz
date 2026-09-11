# Top-100 audit — implementation progress — 2026-09-11

Tracks implementation of the `IMPROVE` audit docs. One row per doc. This file is the
implementation source of truth (kept separate from `INDEX.md`, which the auditing agent
owns for verdicts). Each done row is committed separately; `Resolution` sections are
appended to the individual audit docs.

Status: `todo` → `done` (implemented + tests green + committed) / `partial` (some
findings implemented, others rejected with reason) / `rejected` (finding not upheld).

| Doc | File | Status | Notes |
|---|---|---|---|
| 076 | recorders.rb | todo | critical Fanout#flush bug |
| 031 | cli_worker_commands.rb | todo | ERR swallowed approval |
| 058 | profile.rb | todo | ERR fail-open containment |
| 089 | admission.rb | todo | ERR silent swallow |
| 008 | worker_runtime.rb | todo | ERR bypass durable + SIZE |
| 095 | approval_engine_test.rb | todo | TEST private probe |
| 055 | verifier.rb | todo | DUP status policy |
| 087 | state_codec.rb | todo | SIZE/NAME/DUP |
| 004 | agent_toolbox_test.rb | todo | TEST |
| 005 | sqlite_comms_store_test.rb | todo | TEST |
| 007 | sqlite_stale_request_test.rb | todo | TEST |
| 009 | packaging_test.rb | todo | DUP/TEST/SIZE |
| 010 | agent_cli_test.rb | todo | TEST |
| 011 | agent_profile_machinery_test.rb | todo | TEST/SIZE/DUP |
| 012 | comms_gateway_test.rb | todo | DEAD/TEST/DUP |
| 013 | openclaw_comms_runner.rb | todo | SIZE/DUP/DEAD/B9 |
| 014 | openclaw_durable_cli_adapter.rb | todo | PLACE/SIZE/NAME |
| 015 | memory_engine_test.rb | todo | DEAD/DUP/TEST |
| 021 | session.rb | todo | SIZE/DEAD/DUP/STATE |
| 022 | agent_session_kill_matrix_test.rb | todo | DEAD/DUP |
| 023 | invocation.rb | todo | SIZE/DEAD/FX |
| 024 | runtime.rb | todo | SIZE/STATE/DUP |
| 026 | schedule_store.rb | todo | SIZE/DEAD/DUP |
| 033 | episode_nodes.rb | todo | SIZE/DUP |
| 034 | memory_store.rb | todo | DUP/STATE |
| 037 | openclaw_comms_fixture.rb | todo | TEST |
| 038 | readiness.rb | todo | SIZE/DUP |
| 039 | record.rb | todo | SIZE/DUP |
| 040 | sqlite_scenario_runtime.rb | todo | DEAD/SIZE |
| 051 | subprocess_runner.rb | todo | SIZE |
| 061 | sqlite_trace_recorder.rb | todo | DUP |
| 062 | openclaw_mission_runner.rb | todo | SIZE/DUP/DEAD |
| 063 | sqlite_convergence_probe.rb | todo | FX/ERR/DEAD |
| 064 | progress_projection_test.rb | todo | TEST/NAME/DUP |
| 068 | session_adaptive.rb | todo | SIZE |
| 069 | stream_episode_skills_memory_test.rb | todo | DUP |
| 070 | scoreboard.rb | todo | SIZE/PLACE/DUP |
| 073 | comms_command_parity_test.rb | todo | TEST/DUP |
| 078 | context_control_exposure_test.rb | todo | DUP/TEST |
| 081 | session_context_controls.rb | todo | DEAD/DUP |
| 082 | autonomy_case.rb | todo | TEST/DUP |
| 084 | agent_session_test.rb | todo | DUP/TEST/SIZE |
| 085 | server_config.rb | todo | SIZE/STATE |
| 092 | comms_evidence_gated_approval_test.rb | todo | TEST |
| 094 | dependency_isolation_test.rb | todo | DUP/DEAD |
| 100 | failure_record.rb | todo | SIZE/DEAD/ERR |
