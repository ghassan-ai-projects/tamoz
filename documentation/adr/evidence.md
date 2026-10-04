# ADR implementation evidence

Evidence supports the decision records without adding sections to them. Source inspection, executed tests and their limits are recorded separately; citation validation checks existence, not correctness. Dates below are the original check dates, not new execution claims.

## ADR-001

Checked 2026-10-02 (source inspection; the CLI test marked *run* was executed that day).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Tamoz-owned gem names use `tamoz-*`; Ruby entry points use `tamoz/*` and `Tamoz` | Gems' manifests and library declarations in `gems/` | Source inspection of gemspecs and Ruby entry points | Inspection of current sources, not a regression test for future names or former aliases |
| The operator CLI is `tamoz` | `gems/tamoz-agent-cli/exe/tamoz` | `test/agent_cli_test.rb` — `test_help_output_is_stable` *(run)* | Test checks the advertised command; executable wiring inspected separately |
| Tamoz Agent is the reference application | `apps/tamoz-agent` | `README.md` — reference-application description | Product role, not a tested runtime boundary |

External gem-name availability and trademark clearance are not verified here. No dedicated test
checks the absence of former-name aliases; that claim was not verified in this review.

## ADR-005

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The throw is caught inside each worker | `gems/tamoz-concurrency/lib/tamoz/pool.rb` (`Pool::Base#execute`) | `test/core_pool_test.rb` — `test_interrupt_is_captured_inside_each_worker` | — |
| A normal value is never read as an interrupt | same | `test/core_pool_test.rb` — `test_normal_value_cannot_be_confused_with_an_interrupt` | — |
| The cursor uses `throw` | `gems/tamoz-graph/lib/tamoz/graph/interrupt.rb` | `test/graph_identity_test.rb` — `test_interrupt_cursor_is_explicit_positional_and_uses_throw` | — |

## ADR-006

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Reducers are explicit and pure | `gems/tamoz-graph/lib/tamoz/reducers.rb` | `test/graph_reducer_test.rb` — `test_reducers_do_not_mutate_inputs` | — |
| Conflicting unreduced writes fail before commit | graph executor | `test/graph_execution_test.rb` — `test_conflicting_last_value_writes_fail_before_state_commit` | — |

## ADR-007

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Round-trips are deterministic and immutable | `gems/tamoz-core/lib/tamoz/core.rb` (`deep_freeze`), state codec | `test/core_state_codec_test.rb` — `test_built_in_round_trip_is_deterministic_and_immutable` | — |
| Unsupported, cyclic, and ambiguous values fail closed | state codec | `test/core_state_codec_test.rb` — `test_sensitive_unsupported_cyclic_and_ambiguous_values_fail_closed` | — |
| Registered types must declare immutability | state codec | `test/core_state_codec_test.rb` — `test_registration_requires_and_enforces_an_explicit_immutability_contract` | — |

## ADR-008

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Only `:inline` and `:threads` are accepted; threads is default | `gems/tamoz-core/lib/tamoz/configuration.rb` (`CONCURRENCY_MODES`, defaults) | source inspection | No test asserts the default or the accepted set |
| `:fibers` is refused | `gems/tamoz-concurrency/lib/tamoz/pool.rb` (`Pool.for`) | `test/core_pool_test.rb` (asserts `ConfigurationError` for `:fibers`) | — |
| Inline and threads commit identical histories | graph executor | `test/graph_execution_test.rb` — `test_inline_and_threads_commit_byte_identical_histories` | One graph shape, not a property over all graphs |

## ADR-009

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Header bytes are identical across processes and locales | `gems/tamoz-context-engine/lib/tamoz/context_engine/request_header.rb` | `test/context_header_test.rb` — `test_header_bytes_are_identical_across_processes_and_locales` | — |
| A changed header starts a series with a reason | `gems/tamoz-context-engine/lib/tamoz/context_engine/series.rb` | `test/context_header_test.rb` — `test_declared_boundary_and_changed_bytes_start_a_series` | — |
| Every request extends the previous one | work loop | `test/work_loop_test.rb` — `test_the_header_is_frozen_and_every_request_extends_the_previous_one` | Measured cache hit rates are not part of this proof |

## ADR-010

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| CI runs exactly `.ruby-version` | `.github/workflows/ci.yml` | `test/ci_configuration_test.rb` | 3.4 and 4.0 are not exercised anywhere |

## ADR-011

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Safety pragmas are verified on every connection | `gems/tamoz-sqlite/lib/tamoz/sqlite/connection_pool.rb` | source inspection (raises `ConfigurationError` when pragmas did not apply) | Power-loss durability depends on the filesystem honoring fsync; not tested |
| A faulted transaction reopens as old or new complete state | `gems/tamoz-sqlite/lib/tamoz/sqlite/store.rb` | `test/sqlite_store_test.rb` — `test_every_store_transaction_fault_reopens_as_old_or_new_complete_state` | Fault injection is in-process, not a real crash |
| Online backup is consistent and refuses to overwrite | `tamoz-sqlite` backup | `test/sqlite_backup_test.rb` — `test_online_backup_is_secure_consistent_and_reopenable` | Restore procedure and post-restore lease handling are not documented |

## ADR-013

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The public surface is inventoried | `documentation/reference/public-api.md`, `docs/public-api.json` | `test/public_api_test.rb` | Counts the surface; does not judge whether a concept was needed |

## ADR-014

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The capability source set is closed | `gems/tamoz-core/lib/tamoz/core/capability/registry.rb` (`BUILT_IN_SOURCES`) | `test/capability_closed_world_test.rb` | — |
| Transports and exporters pass their contract suites | `tamoz-comms`, `tamoz-observability` | `test/comms_seams_test.rb`, `test/otel_test.rb` | No test asserts that nothing loads adapter code dynamically; source inspection only |

## ADR-015

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A kill before or after commit recovers one execution | `gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_committer.rb` | `test/sqlite_crash_recovery_test.rb` — `test_process_kill_before_and_after_checkpoint_commit_recovers_one_execution` | Real process kill; not power loss |
| A committed node is not re-executed | executor + committer | `test/sqlite_crash_recovery_test.rb` — `test_process_kill_after_durable_task_write_does_not_reexecute_node` | — |
| A non-durable checkpointer is refused | `tamoz-graph` durable runner | `test/graph_durable_runner_test.rb` — `test_a_non_durable_checkpointer_is_refused_at_construction` | — |

## ADR-016

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Effects route through one dispatcher | `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb` | `test/agent_session_effect_test.rb`, `test/agent_runtime_effects_test.rb` | No mechanical test that no node calls a model raw |
| Identity is request-derived and stable | `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_journal_key.rb` | `test/effect_identity_test.rb` — `test_logical_identity_is_stable_for_same_checkpointed_operation` | — |
| Succeeded is immutable | `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_journal.rb` | `test/sqlite_effect_journal_test.rb` — `test_prepare_start_complete_is_idempotent_and_succeeded_is_immutable` | — |
| Unsafe ambiguous attempts become `:unknown` | effect journal + dispatcher | `test/sqlite_effect_journal_test.rb` — `test_expired_unsafe_running_attempt_becomes_unknown_and_can_record_late_truth` | — |
| Human resolution is audited and fenced | `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_reconciler.rb` | `test/sqlite_effect_journal_test.rb` — `test_human_resolution_refuses_a_foreign_writer_row_scope` | — |

## ADR-017

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Fences increase and reject a concurrent owner | `gems/tamoz-sqlite/lib/tamoz/sqlite/lease.rb` | `test/sqlite_checkpoint_test.rb` — `test_lease_fences_increase_after_release_and_reject_concurrent_owner` | — |
| An expired owner cannot write after takeover | `gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_committer.rb` | `test/sqlite_checkpoint_test.rb` — `test_expired_owner_cannot_write_after_takeover` | — |
| Two racing processes get one live fence | lease operations | `test/sqlite_crash_recovery_test.rb` — `test_two_processes_racing_for_one_namespace_have_one_live_fence` | Real processes, one host |
| Effect start needs the current fence | effect journal | `test/sqlite_effect_journal_test.rb` — `test_effect_start_requires_current_graph_fence_but_late_receipt_does_not` | — |

## ADR-018

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Strict sequence; stale base refused | checkpointers (`gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_appender.rb`) | `test/graph_identity_test.rb` — `test_memory_checkpointer_assigns_strict_sequence_and_rejects_stale_base` | The in-memory checkpointer is tested here; SQLite through `test/sqlite_checkpoint_test.rb` |
| A fork appends a new sequence | same | `test/graph_identity_test.rb` — `test_fork_uses_historical_parent_but_appends_new_sequence` | — |

## ADR-019

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Identity is checked before state or user code | `tamoz-graph` history | `test/graph_history_test.rb` — `test_graph_identity_is_checked_before_state_access_or_user_code` | — |
| A future graph is rejected before resume | agent runtime | `test/agent_durable_compatibility_spike_test.rb` — `test_runtime_rejects_a_future_graph_before_resume` | — |
| Another protocol version is refused | durable runner | `test/graph_durable_runner_test.rb` — `test_a_checkpointer_at_another_protocol_version_is_refused` | — |

## ADR-020

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Secrets are refused on each swept surface, by type | state codec | `test/secret_sweep_test.rb` — `test_the_swept_surface_list_is_complete`, `test_the_refusal_is_by_type_not_by_key_name` | Only the surfaces in the sweep list |
| A secret never renders its value | `Tamoz::Secret` | `test/secret_sweep_test.rb` — `test_a_secret_never_renders_its_value` | — |
| Sensitive store values need a protection codec | `gems/tamoz-sqlite/lib/tamoz/sqlite/store.rb` (`protect`) | `test/sqlite_store_test.rb` — `test_sensitive_values_fail_closed_and_round_trip_only_with_protection` | The codec's cryptographic strength is the operator's |

## ADR-021

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Activation survives a new base; attempt changes | `tamoz-graph` identity | `test/graph_identity_test.rb` — `test_activation_survives_new_base_while_attempt_identity_changes` | — |
| A stale attempt is rejected before the barrier | executor | `test/graph_interrupt_test.rb` — `test_stale_attempt_result_is_rejected_before_barrier_use` | — |
| A successful sibling is not re-executed after restart | SQLite checkpointer | `test/sqlite_checkpoint_test.rb` — `test_successful_sibling_is_not_reexecuted_after_restart_and_resume` | — |
| A fork binds a new execution to an explicit checkpoint | request inbox | `test/sqlite_request_inbox_test.rb` — `test_fork_binds_new_execution_to_an_explicit_historical_checkpoint` | — |

## ADR-022

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| No execution when no plan passes review | `gems/tamoz-agent-kernel/lib/tamoz/agent/deliberation.rb` | `test/agent_runtime_test.rb` — `test_never_executes_when_no_plan_passes_review` | Durable deliberation path |
| A semantic reviewer can force replanning before action | same | `test/agent_runtime_test.rb` — `test_semantic_reviewer_can_force_replanning_before_action` | — |
| Read-only work discovers before planning | session routing | `test/agent_durable_routing_test.rb` — `test_read_only_work_uses_durable_discovery_before_read_only_plan` | — |
| Work loop: mutations before an accepted plan are refused; widening scope returns to review | `gems/tamoz-agent-session/lib/tamoz/agent/work_gate.rb` (`PLAN_BOUND_TOOLS`) | `test/work_loop_test.rb` — `test_mutations_before_an_accepted_plan_are_refused_and_fed_back`, `test_widening_the_scope_goes_back_to_review_and_narrowing_does_not` | Only `apply_patch`, `create_file`, `run_check` are plan-bound |

## ADR-023

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Generator cannot read holdout or evaluator output | `tamoz-agent-improvement` | `test/improvement_candidate_test.rb` — `test_generator_cannot_read_the_holdout_or_the_evaluator_output` | Heuristic candidates only |
| A candidate cannot evaluate or promote itself | same | `test/improvement_candidate_test.rb` — `test_a_candidate_cannot_evaluate_or_promote_itself` | — |
| Evaluator tampering is refused | same | `test/improvement_candidate_test.rb` — `test_evaluator_tampering_is_refused` | — |
| Holdout regression refuses promotion; rollback is byte-identical | same | `test/heuristic_promotion_controls_test.rb` — `test_overfit_candidate_is_refused_on_holdout_regression`, `test_rollback_restores_the_prior_epoch_byte_identically` | Deterministic tests; no real-model improvement result |
| Every human-gate class is enforced | same | `test/improvement_candidate_test.rb` — `test_every_human_gate_class_is_enforced` | — |
| Profile/skill/config approval binds the exact candidate and actor | `CandidateLifecycle` | `test/agent_improvement_lifecycle_test.rb` — `test_approval_digest_binds_the_exact_candidate_and_actor` | No holdout for these kinds |

## ADR-024

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The protocol is frozen and pinned | `documentation/benchmark/BENCHMARK_PROTOCOL.json` | `test/benchmark_protocol_test.rb` — `test_committed_sha256_pin`, `test_all_eleven_stop_rules_are_frozen` | Pins the protocol; does not produce a result |
| Fixture runs are labeled plumbing, not capability | run-kind boundary in `documentation/benchmark/README.md` | `test/benchmark_report_test.rb` | No mechanical check that prose never overclaims |

## ADR-025

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Only the runner depends on `tamoz-evals` | gemspecs | `test/packaging_test.rb`; source inspection of `gems/*/*.gemspec` | — |
| The evals gem loads only the verifier boundary | `tamoz-evals` | `test/dependency_isolation_test.rb` — `test_evals_loads_the_verifier_boundary_only` | — |
| The verifier enforces the artifact contract | `tamoz-evals` | `test/evals_verifier_test.rb` | "Safety is never weighted" and "every evaluator change starts a lineage" are design rules with no mechanical check |

## ADR-026

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Unobserved episodes admit only as reported | `tamoz-agent-memory` admission | `test/memory_engine_test.rb` — `test_episodes_without_independent_observation_admit_only_as_reported` | — |
| No model call decides admission | same | `test/memory_engine_test.rb` — `test_no_model_call_decides_admission` | — |
| Consolidation preserves preimages | consolidation | `test/memory_engine_test.rb` — `test_consolidation_preserves_preimage_and_failure_keeps_prior_knowledge` | — |
| Lifecycle transitions are exact | lifecycle | `test/memory_engine_test.rb` — `test_lifecycle_transitions_and_eligible_state_set_are_exact` | — |
| Wisdom promotion is gated | `gems/tamoz-agent-memory/lib/tamoz/agent/memory/wisdom.rb` | source inspection | Pipeline tests live in the improvement gem (ADR-023) |

## ADR-027

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Access sees only this owner and workspace | `Memory::Access` | `test/memory_access_test.rb` — `test_find_sees_only_this_owner_and_workspace_while_eligible` | — |
| No gem reaches past the facade | boundary test | `test/memory_boundary_test.rb` — `test_no_gem_outside_memory_reaches_into_its_storage_or_scopes` | Source scan |
| Sensitive records are never indexed; other scopes are never returned | retrieval | `test/memory_spec_test.rb` — `test_sensitive_never_indexed_and_other_scopes_never_returned` | Surface-level filtering has no dedicated test |
| Sensitive records are never injected or decrypted | repository adapter | `test/memory_repository_adapter_test.rb` — `test_sensitive_records_are_matched_never_injected_never_decrypted` | — |
| Correction and deletion leave recall and index | lifecycle | `test/memory_engine_test.rb` — `test_correction_removes_bad_record_from_active_recall_and_index`, `test_deletion_emits_receipt_and_propagates_to_index` | Derived artifacts outside memory are not covered |

## ADR-028

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Recovery only through the oracle | `tamoz-agent-healing` remediation | `test/healing_remediation_test.rb` — `test_full_lifecycle_recovers_only_through_the_oracle`, `test_oracle_mismatch_never_recovers` | Deterministic scenarios |
| Scope intersection refuses out-of-authority targets | same | `test/healing_remediation_test.rb` — `test_scope_intersection_refuses_a_target_outside_authorized_resources` | — |
| Unknown effects reconcile then escalate | same | `test/healing_remediation_test.rb` — `test_effect_unknown_reconciles_then_escalates_without_an_executor` | — |
| Open circuit stops before classification | same | `test/healing_remediation_test.rb` — `test_open_circuit_terminates_before_classification` | — |
| Never-mutate classes never reach a mutating family | matrix | `test/healing_matrix_test.rb` — `test_never_mutate_classes_never_reach_a_mutating_family` | — |
| A rule with total abstention cannot be promoted | `gems/tamoz-agent-healing/lib/tamoz/agent/healing/promotion_gate.rb` | `test/healing_matrix_test.rb` — `test_promotion_gate_rejects_total_abstention_and_never_mutate_leak` | — |

## ADR-029

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Loads only core and the official SDK | `tamoz-mcp` | `test/dependency_isolation_test.rb` — `test_mcp_loads_only_core_and_the_official_sdk` | — |
| Catalogs are immutable with exact digests; protocol range fails closed | `tamoz-mcp` catalog | `test/mcp_catalog_test.rb` — `test_compile_produces_immutable_catalog_with_exact_digests`, `test_protocol_outside_configured_range_fails_closed` | — |
| Credentials never appear in errors | same | `test/mcp_catalog_test.rb` — `test_credential_values_never_appear_in_errors_or_stderr_metadata` | — |
| A crash mid-call is unknown and never retried | session + effect journal | `test/agent_mcp_adversarial_test.rb` — `test_crash_mid_call_is_typed_unknown_and_never_retried` | — |
| Elicitation is a durable interrupt | `tamoz-mcp` elicitation | `test/mcp_elicitation_test.rb` — `test_build_produces_the_durable_interrupt_descriptor_shape` | — |

## ADR-030

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Four sources dispatch through one protocol | `gems/tamoz-tools/lib/tamoz/tools/capability_host.rb` | `test/capability_closed_world_test.rb` — `test_four_built_ins_dispatch_through_one_protocol` | — |
| Descriptor digests cover every field; unknown classes fail closed | descriptor contract | `test/capability_descriptor_contract_test.rb` — `test_definition_digest_is_verified_against_all_descriptor_fields`, `test_unknown_effect_class_and_policy_values_fail_closed` | — |
| A widened profile is refused for a bound thread | worker runtime | `test/agent_worker_profile_digest_test.rb` — `test_a_widened_on_disk_profile_is_refused_for_a_bound_thread` | — |

## ADR-031

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Claim → create → enqueue is atomic | `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb` | `test/sqlite_schedule_store_test.rb` — `test_put_schedule_cas_on_revision_and_materialize_due_is_atomic` | — |
| Occurrences dedup on identity | same | `test/sqlite_schedule_store_test.rb` — `test_materialize_due_dedups_on_occurrence_identity` | — |
| Restart survival; separate completion state | same | `test/sqlite_schedule_store_test.rb` — `test_restart_survival_and_completion_state_machine` | — |

## ADR-032

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Grants intersect at run time | `gems/tamoz-scheduler/lib/tamoz/scheduler/grant_intersector.rb` | `test/scheduler_values_test.rb` | — |
| Misfire and overlap policies behave as stored | `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb` | `test/sqlite_schedule_store_test.rb` — `test_misfire_skip_delivers_only_the_latest_and_records_older_skipped`, `test_overlap_forbid_skips_the_next_occurrence_while_one_is_in_flight` | — |
| An unattended worker never grants its own approval; approvals do not carry over | worker | `test/agent_unattended_policy_test.rb` — `test_a_worker_left_running_never_grants_its_own_approval`, `test_an_approval_does_not_carry_to_the_next_occurrence` | — |
| Cron/IANA | — | `documentation/overview/compatibility.md` records the gap | Not built |

## ADR-033

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Portable format conformance | `gems/tamoz-skills/lib/tamoz/skills/frontmatter.rb` | `test/skills_spec_conformance_test.rb` | — |
| Path escape, links, and YAML tricks are refused at compile | `tamoz-skills` walk and frontmatter | `test/agent_skills_adversarial_test.rb` — `test_symlink_to_a_file_outside_the_tree_is_rejected_and_never_indexed`, `test_ruby_object_tag_in_frontmatter_is_rejected_without_materialising_anything` | — |
| Loads are recorded with their tree digest | session | `test/skills_reachability_test.rb` — `test_a_model_load_is_recorded_with_its_tree_digest` | — |
| Scripts are never readable as resources | `tamoz-skills` resources | `test/agent_skills_adversarial_test.rb` — `test_reading_a_script_is_refused` | — |

## ADR-034

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Installed exactly as staged by a named non-creator | `gems/tamoz-skills/lib/tamoz/skills/candidates.rb` | `test/skills_candidates_test.rb` — `test_the_creator_cannot_approve_and_an_approver_must_be_named`, `test_a_candidate_changed_after_staging_is_refused` | — |
| Only digested files are installed | same | `test/skills_candidates_test.rb` — `test_only_the_digested_files_are_installed` | — |
| Loads record the tree digest | session | `test/skills_reachability_test.rb` — `test_a_model_load_is_recorded_with_its_tree_digest` | — |

## ADR-036

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A tampered snapshot fails before any model call | `gems/tamoz-stream/lib/tamoz/stream/situation_snapshot.rb` | `test/stream_situation_snapshot_test.rb` — `test_a_tampered_snapshot_fails_before_any_model_call` | — |
| Snapshot mismatch terminates the episode | episode worker | `test/stream_invariants_test.rb` — `test_invariant_2_snapshot_mismatch_terminates_before_any_model_call` | — |
| The episode path computes no stream-plane concept | `tamoz-stream` | `test/stream_invariants_test.rb` — `test_invariant_1_the_episode_path_computes_no_stream_plane_concepts` | Admission/reduction is in the Go repository, not checked here |

## ADR-038

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A missing or forged intent catalog fails before any model call | `gems/tamoz-stream/lib/tamoz/stream/decision_builder.rb` | `test/stream_episode_intent_authority_test.rb` — `test_gate1_a_forged_intent_catalog_digest_fails_closed_before_any_model_call` | — |
| The decision carries the catalog-declared risk | same | `test/stream_episode_intent_authority_test.rb` — `test_the_decision_carries_the_catalog_declared_risk` | — |
| The worker names no hardware mechanism | `tamoz-stream` | `test/tamoz_brain_hardware_boundary_test.rb` — `test_the_brain_names_no_hardware_mechanism` | Revalidation and dispatch are in `agentic-stream`, not checked here |

## ADR-039

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The worker names no hardware mechanism | `tamoz-stream` | `test/tamoz_brain_hardware_boundary_test.rb` — `test_the_brain_names_no_hardware_mechanism` | Deployment-level interlocks cannot be tested from this repository |
| The episode path has no effectful reference | `gems/tamoz-stream/lib/tamoz/stream/capability_host.rb` | `test/stream_episode_capability_host_test.rb` — `test_dependency_direction_episode_path_has_no_effectful_reference` | — |

## ADR-040

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Each gem loads only its declared closure | gemspecs | `test/dependency_isolation_test.rb` | Covers the gems listed in that test |
| Each gem packages and runs from its release files alone | packaging | `test/packaging_test.rb` — `test_every_gem_is_strict_valid_and_contains_only_release_files` | — |

## ADR-041

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The contract gem loads core only, no HTTP | `tamoz-comms` | `test/dependency_isolation_test.rb` — `test_comms_loads_core_only_and_no_http_or_agent` | — |
| Transport and store contracts are structural | `tamoz-comms` | `test/comms_seams_test.rb` — `test_transport_contract_is_structural`, `test_comms_store_contract_is_structural_and_versioned` | — |
| The null sink discards without raising | same | `test/comms_seams_test.rb` — `test_null_sink_discards_events_without_raising` | — |

## ADR-042

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The gateway authenticates its transport before polling | `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb` | `test/comms_gateway_test.rb` — `test_start_authenticates_the_transport_before_polling` | — |
| A replayed update creates no second request | gateway + store | `test/comms_gateway_test.rb` — `test_a_replayed_update_does_not_create_a_second_request` | — |
| The packaged gateway runs with an injected transport and store | packaging | `test/packaging_test.rb` — `test_packaged_comms_gateway_runs_with_injected_transport_and_store` | "Never loads a model credential" is source inspection, not a test |

## ADR-044

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The recorder does not raise over a malformed payload | `tamoz-core` instrumentation | `test/core_instrumentation_test.rb` — `test_malformed_payload_under_a_null_notifier_does_not_raise` | With a notifier attached it does raise (`test_malformed_payload_with_a_notifier_still_raises`) |
| The catalog is closed and versioned | `tamoz-observability` catalog | `test/observability_catalog_test.rb` — `test_attribute_set_change_without_a_version_bump_raises` | — |
| Exporter egress rejects untrusted destinations and redirects | `tamoz-otel` | `test/otel_test.rb` — `test_egress_policy_rejects_untrusted_destinations`, `test_http_exporter_does_not_follow_redirects_or_use_proxy_environment` | — |

## ADR-045

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The journal rotates, keeps a cap, and survives reopen | `gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb` | `test/observability_runtime_test.rb` — `test_journal_cap_survives_reopen_and_one_file_retention` | — |
| Trace identity derives from durable identity | `tamoz-observability` correlation | `test/observability_correlation_test.rb` — `test_trace_id_follows_turn_identity` | — |
| No telemetry table in the runtime store | `tamoz-sqlite` | source inspection | No mechanical test |

## ADR-046

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Default emits digest and size only | `gems/tamoz-observability/lib/tamoz/observability/content_policy.rb` | `test/observability_runtime_test.rb` — `test_default_policy_emits_digest_and_size_without_content` | — |
| Restricted capture is refused at load | same | `test/observability_runtime_test.rb` — `test_restricted_policy_refuses_capture_at_load` | — |
| Enabled content is bounded; policy recorded | same | `test/observability_runtime_test.rb` — `test_enabled_content_is_bounded_and_policy_is_recorded` | — |
| A secret never reaches a signal | producer | `test/observability_runtime_test.rb` — `test_secret_is_rejected_before_it_can_reach_a_signal` | — |

## ADR-047

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Safety-bearing flags are seeded in the catalog | `gems/tamoz-observability/lib/tamoz/observability/catalog.rb` | `test/observability_catalog_test.rb` — `test_seeded_safety_bearing_flags` | — |
| Bulk saturation is counted | `gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb` | `test/observability_runtime_test.rb` — `test_bulk_saturation_is_counted_and_metric_cardinality_is_rejected` | The reserved-lane synchronous fallback is source inspection only |
| No record-time sampling exists | recorder | source inspection (no sampling code in the observability or otel gems) | — |

## ADR-048

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Profile-named credential only; no generic fallback | `gems/tamoz-agent-kernel/lib/tamoz/agent/model_client_factory.rb` | `test/model_client_factory_test.rb` — `test_factory_requires_the_profile_credential_without_generic_fallback` | — |
| Native protocols and unknown providers fail closed | same | `test/model_client_factory_test.rb` — `test_native_protocols_and_unknown_providers_fail_closed` | — |
| Configuration binds without the secret | same | `test/model_client_factory_test.rb` — `test_factory_binds_profile_and_explicit_endpoint_configuration_without_secret` | — |
| Receipt identity changes with request and provider configuration | `gems/tamoz-agent-kernel/lib/tamoz/agent/model_receipt.rb` | `test/agent_model_receipt_test.rb` — `test_logical_key_changes_with_provider_configuration` | — |
| No retry of a received failure | `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_transport.rb` | `test/model_transport_parity_test.rb` — `test_transport_does_not_retry_a_received_failure` | — |
| The graph loads no model, eval, or HTTP package | `tamoz-graph` | `test/dependency_isolation_test.rb` — `test_graph_loads_no_model_eval_or_adapter_package` | — |

## ADR-049

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The lattice is closed and only sanctioned levels can be minted | `tamoz-comms` authority evidence | `test/comms_authority_evidence_test.rb` — `test_lattice_is_closed_and_totally_ordered`, `test_no_actor_kind_mapping_can_grant_operator_evidence` | — |
| A chat approve is refused when operator evidence is required; deny still works | `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb` | `test/comms_evidence_gated_approval_test.rb` — `test_a_chat_bound_approve_is_refused_when_the_decision_requires_operator_evidence`, `test_the_equivalent_deny_still_succeeds` | — |
| Expired evidence never approves | same | `test/comms_evidence_gated_approval_test.rb` — `test_expired_evidence_never_approves` | — |
| The prompt pins the requirement it was built with | `ApprovalPrompt.build` | `test/comms_evidence_gated_approval_test.rb` — `test_required_evidence_is_trusted_and_not_model_settable` | Shows the builder uses its argument; nothing tests that the delivered descriptor's `decision` is engine-written |
| Cross-correspondent, cross-surface, cross-message presses are refused | same | `test/comms_evidence_gated_approval_test.rb` — `test_a_cross_correspondent_press_is_refused`, `test_a_cross_surface_press_is_refused` | — |
| A reference is consumed exactly once | comms store | `test/comms_deny_callback_test.rb` — `test_a_replayed_reference_is_consumed_exactly_once` | — |
| A press on another message is refused | gateway | `test/comms_evidence_gated_approval_test.rb` — `test_a_cross_message_press_is_refused` | — |
| A prompt activates only from a live inactive row | `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb` (`activate_prompt`) | `test/sqlite_comms_store_test.rb` — `test_prompt_activation_requires_a_live_inactive_prompt` | — |
| The live policy approves from chat | `gems/tamoz-approval/policy/base.yaml` (`evidence.approve`) | `test/comms_adr049_consistency_test.rb` | Pins this page to the policy file |

## ADR-050

Not implemented. Phases 1–4 (observer-only) are in `gems/tamoz-observability`; no alerting or
actuator code exists there today.

## ADR-052

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Gems load only their declared closure | gemspecs | `test/dependency_isolation_test.rb` | — |
| No gem reaches past memory, skills, research, approval, or profile facades | boundary tests | `test/memory_boundary_test.rb`, `test/skills_boundary_test.rb`, `test/research_boundary_test.rb`, `test/approval_boundary_test.rb`, `test/profile_boundary_test.rb` | Other gems are unguarded |
| File staging, private directories, and locks go through core facades | `tamoz-core` | `test/file_facades_boundary_test.rb` | — |

## ADR-053

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Policy documents load only if their simulations pass | `gems/tamoz-approval/lib/tamoz/approval/policy_document.rb` | `test/approval_policy_document_test.rb` | — |
| No gem outside approval reads its stores | boundary | `test/approval_boundary_test.rb` — `test_no_gem_outside_approval_reads_its_stores` | — |
| Bound sessions keep their revision; reload never leaks | `gems/tamoz-approval/lib/tamoz/approval/engine.rb` | `test/approval_reload_test.rb` — `test_bound_session_keeps_old_rev_after_reload`; `test/approval_mode_switch_test.rb` — `test_rebind_never_redecides_an_already_recorded_decision` | — |
| Grant keys are argv-aware | engine | `test/approval_grant_key_test.rb` | — |
| A denial is fed back to the model | work loop | `test/work_loop_test.rb` — `test_an_asked_edit_pauses_for_approval_and_a_denial_is_fed_back` | — |

## ADR-054

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The id `websearch` is reserved | `gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb` | `test/agent_worker_mcp_test.rb` — `test_the_websearch_id_cannot_be_claimed_by_a_generic_server` | — |
| Egress is pinned; changed egress on resume stops | `gems/tamoz-mcp-websearch/lib/tamoz/mcp/websearch.rb` | `test/websearch_egress_test.rb` — `test_session_record_pins_the_canonical_egress_declaration`, `test_resume_with_changed_egress_stops_typed` | — |
| Websearch loads only its declared closure | packaging | `test/dependency_isolation_test.rb` — `test_websearch_loads_only_its_declared_tamoz_closure` | — |

## ADR-055

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Tool surface is exactly the allowlist; injection cannot bind a denied tool | `gems/tamoz-stream/lib/tamoz/stream/capability_host.rb` | `test/stream_episode_capability_host_test.rb` — `test_the_surface_is_exactly_the_permitted_allowlist`, `test_an_injected_instruction_cannot_bind_a_denied_capability` | Adapter internals are trusted |
| Tool context never carries effects or store | same | `test/stream_episode_capability_host_test.rb` — `test_the_context_passed_to_a_tool_never_carries_effects_or_store` | — |
| Tokens never persist or cross the wire | worker | `test/stream_token_custody_test.rb` — `test_the_token_never_enters_the_durable_payload`, `test_the_token_never_crosses_in_a_wire_event` | — |
| Serves over Unix socket or TCP, not both | `gems/tamoz-stream/lib/tamoz/stream/worker_server.rb` | `test/stream_worker_server_test.rb` — `test_the_server_refuses_both_or_neither_transport` | Both bind insecure ports; no TLS |
| Shared contract vectors reproduce exactly | `tamoz-stream` | `test/stream_invariants_test.rb` — `test_invariant_9_every_shared_contract_vector_reproduces_exactly` | The Go side is in a sibling repository and not checked here |

## ADR-056

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| No file outside the gem names an inner constant | `gems/tamoz-skills/lib/tamoz/skills.rb` | `test/skills_boundary_test.rb` — `test_no_file_outside_the_gem_names_an_inner_constant` | — |
| The gem loads only core | same | `test/dependency_isolation_test.rb` — `test_skills_loads_only_core` | — |

## ADR-057

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A CLI cancel routes a parked thread to its terminal | CLI | `test/agent_cli_test.rb` — `test_cancel_routes_to_terminal` | — |
| A chat stop routes the running turn to `cancelled_by_user` | `gems/tamoz-agent-session/lib/tamoz/agent/session_work.rb` (`stopped?`, `CANCELLED`) | source inspection | The chat stop → `stopped?` path has no test |
| A consumed cancel runs no second turn | worker | `test/cancellation_visibility_test.rb` — `test_a_real_worker_claim_consumes_a_cancel_redirect_and_stamps_observation` | — |
| A raced completion is never reported as stopped | status projection | `test/cancellation_visibility_test.rb` — `test_a_raced_completion_says_completed_before_effect_and_never_stopped` | — |
| A crashed claim recovers through the recover path | worker | `test/cancellation_visibility_test.rb` — `test_a_crashed_claim_is_recovered_through_the_recover_path_and_stamps_observation` | — |
| A model call in flight is abandoned | `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb` (`until_cancelled`) | source inspection | No test isolates mid-call abandonment |
| The stop is registered per thread | `gems/tamoz-cancellation/lib/tamoz/cancellation/stops.rb`, `gems/tamoz-agent/lib/tamoz/agent/worker.rb` (`watching_for_stop`) | source inspection | Watcher runs only with a comms store |

## ADR-058

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A novel domain produces a decision with zero new Ruby | `test/support/domain_loader.rb` | `test/stream_episode_intent_authority_test.rb` — `test_gate4_a_novel_domain_produces_a_decision_with_zero_new_ruby` | — |
| A family is built for every discovered domain | same | `test/benchmark_families_test.rb` — `test_a_family_is_built_for_every_discovered_domain` | — |
| The cross-repo digest is pinned | intent catalog | `test/agent_intent_catalog_test.rb` — `test_the_aquaculture_catalog_digest_matches_the_pinned_cross_repo_vector` | The Go side is not checked here |
| The protocol SHA is pinned | `documentation/benchmark/BENCHMARK_PROTOCOL.json` | `test/benchmark_protocol_test.rb` — `test_committed_sha256_pin` | No test fails on a domain literal in Ruby |

## ADR-059

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Applied migrations cannot be edited | `tamoz-sqlite` kernel | `test/sqlite_kernel_test.rb` — `test_migration_checksum_tampering_is_rejected` | — |
| No compatibility migration for session records | session records | `test/agent_session_records_test.rb` — `test_version_one_session_record_is_rejected_without_compatibility_migration` | — |
| No legacy readers | — | contradicted by `test/legacy_session_resume_test.rb` — `test_a_current_build_reads_the_old_database` | Open: delete that tolerance or narrow this rule |
