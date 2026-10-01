# Removed ADR sections — 2026-10-02

Historical snapshot retained when the owner requested simpler ADRs. These passages are not current decision rules. Implementation evidence is maintained separately in `documentation/adr/evidence.md`.

## ADR-001 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Keep the old names as aliases through the rename *(retrospective, 2026-10-01)* | Nothing had shipped, so aliases offered no released-user benefit and added a second naming surface to maintain |
| Separate framework and application branding *(retrospective, 2026-10-02)* | Offers independent product identity, but shared branding keeps discovery and documentation simpler for the reference application |

## ADR-001 — Reopen when

A published gem name collides with an existing RubyGems package or a trademark claim.

## ADR-001 — Verification

Checked 2026-10-02 (source inspection; the CLI test marked *run* was executed that day).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Tamoz-owned gem names use `tamoz-*`; Ruby entry points use `tamoz/*` and `Tamoz` | Gems' manifests and library declarations in `gems/` | Source inspection of gemspecs and Ruby entry points | Inspection of current sources, not a regression test for future names or former aliases |
| The operator CLI is `tamoz` | `gems/tamoz-agent-cli/exe/tamoz` | `test/agent_cli_test.rb` — `test_help_output_is_stable` *(run)* | Test checks the advertised command; executable wiring inspected separately |
| Tamoz Agent is the reference application | `apps/tamoz-agent` | `README.md` — reference-application description | Product role, not a tested runtime boundary |

External gem-name availability and trademark clearance are not verified here. No dedicated test
checks the absence of former-name aliases; that claim was not verified in this review.

## ADR-005 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| An `Interrupt` exception (LangGraph's design) *(retrospective, 2026-10-01)* | Any broad `rescue` in a node swallows it; the framework cannot detect that |
| A sentinel return value *(retrospective, 2026-10-01)* | A node can return the sentinel by accident, and nested helpers must propagate it by hand |

## ADR-005 — Reopen when

A pool is added whose tasks do not run on a Ruby stack the pool controls (for example, out of
process), so a worker-local `catch` is impossible.

## ADR-005 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The throw is caught inside each worker | `gems/tamoz-concurrency/lib/tamoz/pool.rb` (`Pool::Base#execute`) | `test/core_pool_test.rb` — `test_interrupt_is_captured_inside_each_worker` | — |
| A normal value is never read as an interrupt | same | `test/core_pool_test.rb` — `test_normal_value_cannot_be_confused_with_an_interrupt` | — |
| The cursor uses `throw` | `gems/tamoz-graph/lib/tamoz/graph/interrupt.rb` | `test/graph_identity_test.rb` — `test_interrupt_cursor_is_explicit_positional_and_uses_throw` | — |

## ADR-006 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| `Data`/`Struct`-typed state | Partial updates against a fixed shape are awkward and every node would construct one |
| Last-writer-wins for unreduced keys *(retrospective, 2026-10-01)* | Silently drops a parallel write; the order would decide the result |
| A `Memory` object family that hides state *(retrospective, 2026-10-01)* | State must be explicit and injected; hidden state defeats replay |
| Config-dict dispatch (`config["configurable"]["llm"]`) *(retrospective, 2026-10-01)* | Stringly typed action at a distance |

## ADR-006 — Reopen when

A real graph needs a merge rule that a per-key reducer cannot express (for example, a constraint
across two keys).

## ADR-006 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Reducers are explicit and pure | `gems/tamoz-graph/lib/tamoz/reducers.rb` | `test/graph_reducer_test.rb` — `test_reducers_do_not_mutate_inputs` | — |
| Conflicting unreduced writes fail before commit | graph executor | `test/graph_execution_test.rb` — `test_conflicting_last_value_writes_fail_before_state_commit` | — |

## ADR-007 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Shallow freeze | Nested arrays and hashes stay mutable |
| Copy-on-read without freezing *(retrospective, 2026-10-01)* | Costs a copy per read and still lets a node mutate its copy and leak it into a write by accident |

## ADR-007 — Reopen when

Copy-and-freeze cost shows up as a measured bottleneck in a real workload.

## ADR-007 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Round-trips are deterministic and immutable | `gems/tamoz-core/lib/tamoz/core.rb` (`deep_freeze`), state codec | `test/core_state_codec_test.rb` — `test_built_in_round_trip_is_deterministic_and_immutable` | — |
| Unsupported, cyclic, and ambiguous values fail closed | state codec | `test/core_state_codec_test.rb` — `test_sensitive_unsupported_cyclic_and_ambiguous_values_fail_closed` | — |
| Registered types must declare immutability | state codec | `test/core_state_codec_test.rb` — `test_registration_requires_and_enforces_an_explicit_immutability_contract` | — |

## ADR-008 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| An async/await API beside the sync one *(retrospective, 2026-10-01)* | Two APIs to document and keep equivalent |
| Fibers (`async` gem) as default *(retrospective, 2026-10-01)* | Adds a dependency and a scheduler for no measured gain over threads on I/O waits |

## ADR-008 — Reopen when

A measured workload is bound by thread count or memory per thread, or a fiber pool passes the pool
conformance tests.

## ADR-008 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Only `:inline` and `:threads` are accepted; threads is default | `gems/tamoz-core/lib/tamoz/configuration.rb` (`CONCURRENCY_MODES`, defaults) | source inspection | No test asserts the default or the accepted set |
| `:fibers` is refused | `gems/tamoz-concurrency/lib/tamoz/pool.rb` (`Pool.for`) | `test/core_pool_test.rb` (asserts `ConfigurationError` for `:fibers`) | — |
| Inline and threads commit identical histories | graph executor | `test/graph_execution_test.rb` — `test_inline_and_threads_commit_byte_identical_histories` | One graph shape, not a property over all graphs |

## ADR-009 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| A style guideline ("keep the system prompt stable") *(retrospective, 2026-10-01)* | Nothing fails when it is broken; the failure is a bill |
| Rebuild the prompt each turn and rely on the provider to cache whatever matches *(retrospective, 2026-10-01)* | Order and locale drift make the prefix differ without anyone changing anything |

## ADR-009 — Reopen when

A provider's caching stops being prefix-based, or a measured workload shows the series discipline
costs more in forced re-sends than it saves.

## ADR-009 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Header bytes are identical across processes and locales | `gems/tamoz-context-engine/lib/tamoz/context_engine/request_header.rb` | `test/context_header_test.rb` — `test_header_bytes_are_identical_across_processes_and_locales` | — |
| A changed header starts a series with a reason | `gems/tamoz-context-engine/lib/tamoz/context_engine/series.rb` | `test/context_header_test.rb` — `test_declared_boundary_and_changed_bytes_start_a_series` | — |
| Every request extends the previous one | work loop | `test/work_loop_test.rb` — `test_the_header_is_frozen_and_every_request_extends_the_previous_one` | Measured cache hit rates are not part of this proof |

## ADR-010 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Keep 3.2 as the floor *(retrospective, 2026-10-01)* | It was already past end of support |
| A floating multi-version CI matrix | Regenerates sealed-build pins per version; needs pins keyed by Ruby version first |

## ADR-010 — Reopen when

Before the first public release (decide whether 3.4/4.0 enter CI or leave the promise), or when
3.3 reaches end of life.

## ADR-010 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| CI runs exactly `.ruby-version` | `.github/workflows/ci.yml` | `test/ci_configuration_test.rb` | 3.4 and 4.0 are not exercised anywhere |

## ADR-011 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| PostgreSQL as the default *(retrospective, 2026-10-01)* | Every operator must run and secure a server before the agent works; the single-operator workload does not need concurrent writers |
| Plain JSON files per record *(retrospective, 2026-10-01)* | No atomic multi-record transaction, so an admission and its request could not commit together |

## ADR-011 — Reopen when

A supported deployment needs more than one host, or a measured workload is bound by SQLite write
contention (busy-timeout failures under normal load).

## ADR-011 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Safety pragmas are verified on every connection | `gems/tamoz-sqlite/lib/tamoz/sqlite/connection_pool.rb` | source inspection (raises `ConfigurationError` when pragmas did not apply) | Power-loss durability depends on the filesystem honoring fsync; not tested |
| A faulted transaction reopens as old or new complete state | `gems/tamoz-sqlite/lib/tamoz/sqlite/store.rb` | `test/sqlite_store_test.rb` — `test_every_store_transaction_fault_reopens_as_old_or_new_complete_state` | Fault injection is in-process, not a real crash |
| Online backup is consistent and refuses to overwrite | `tamoz-sqlite` backup | `test/sqlite_backup_test.rb` — `test_online_backup_is_secure_consistent_and_reopenable` | Restore procedure and post-restore lease handling are not documented |

## ADR-013 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| A hard cap on public concepts *(retrospective, 2026-10-01)* | Forces hiding necessary failure states |
| No budget *(retrospective, 2026-10-01)* | The surface grows until nobody can learn it, as the reference frameworks did |

## ADR-013 — Reopen when

The public API inventory grows by more than a few concepts in one release without a stated reason.

## ADR-013 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The public surface is inventoried | `documentation/reference/public-api.md`, `docs/public-api.json` | `test/public_api_test.rb` | Counts the surface; does not judge whether a concept was needed |

## ADR-014 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| A versioned adapter API: third-party adapter gems that pass the published conformance suite, enabled by the operator *(retrospective, 2026-10-01)* | Conformance proves the interface, not that the adapter does not exfiltrate the credential it is handed; until adapters can run with only their own credential, the reviewer must be us |
| A plugin marketplace with discovery *(retrospective, 2026-10-01)* | Adds a supply-chain surface and a compatibility promise before 1.0 |

## ADR-014 — Reopen when

A second party needs to ship an adapter, **and** adapters can run with access to only their own
credential (for example, in their own process). A loosening ADR must show the adapter's privilege
boundary, an operator-pinned digest for each enabled adapter, and the conformance suite run by the
adapter author.

## ADR-014 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The capability source set is closed | `gems/tamoz-core/lib/tamoz/core/capability/registry.rb` (`BUILT_IN_SOURCES`) | `test/capability_closed_world_test.rb` | — |
| Transports and exporters pass their contract suites | `tamoz-comms`, `tamoz-observability` | `test/comms_seams_test.rb`, `test/otel_test.rb` | No test asserts that nothing loads adapter code dynamically; source inspection only |

## ADR-015 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Asynchronous durable commit (write-behind) *(retrospective, 2026-10-01)* | A crash loses barriers the caller already observed; resume then repeats visible work |
| Commit every N supersteps *(retrospective, 2026-10-01)* | Same loss window, made configurable |

## ADR-015 — Reopen when

A measured workload is bound by per-barrier commit latency and can tolerate replay of the uncommitted
window under ADR-016.

## ADR-015 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A kill before or after commit recovers one execution | `gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_committer.rb` | `test/sqlite_crash_recovery_test.rb` — `test_process_kill_before_and_after_checkpoint_commit_recovers_one_execution` | Real process kill; not power loss |
| A committed node is not re-executed | executor + committer | `test/sqlite_crash_recovery_test.rb` — `test_process_kill_after_durable_task_write_does_not_reexecute_node` | — |
| A non-durable checkpointer is refused | `tamoz-graph` durable runner | `test/graph_durable_runner_test.rb` — `test_a_non_durable_checkpointer_is_refused_at_construction` | — |

## ADR-016 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Blind retry after an ambiguous outcome | Duplicates irreversible work |
| Key effects by their result (content hash of the answer) *(retrospective, 2026-10-01)* | A replay gets a different answer and a different key, so it would run again |
| Rely on the graph checkpoint alone *(retrospective, 2026-10-01)* | The checkpoint commits after the node; the effect happened before it |

## ADR-016 — Reopen when

A target offers a reliable idempotency-key protocol that lets an unsafe class become idempotent,
or `:unknown` resolutions become frequent enough that operators rubber-stamp them.

## ADR-016 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Effects route through one dispatcher | `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb` | `test/agent_session_effect_test.rb`, `test/agent_runtime_effects_test.rb` | No mechanical test that no node calls a model raw |
| Identity is request-derived and stable | `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_journal_key.rb` | `test/effect_identity_test.rb` — `test_logical_identity_is_stable_for_same_checkpointed_operation` | — |
| Succeeded is immutable | `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_journal.rb` | `test/sqlite_effect_journal_test.rb` — `test_prepare_start_complete_is_idempotent_and_succeeded_is_immutable` | — |
| Unsafe ambiguous attempts become `:unknown` | effect journal + dispatcher | `test/sqlite_effect_journal_test.rb` — `test_expired_unsafe_running_attempt_becomes_unknown_and_can_record_late_truth` | — |
| Human resolution is audited and fenced | `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_reconciler.rb` | `test/sqlite_effect_journal_test.rb` — `test_human_resolution_refuses_a_foreign_writer_row_scope` | — |

## ADR-017 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Optimistic concurrency on the base checkpoint only *(retrospective, 2026-10-01)* | Catches a concurrent commit but not a zombie whose base is still the head |
| A process-level lock file *(retrospective, 2026-10-01)* | Does not survive a paused process outliving its lock, and gives no token to check at write time |

## ADR-017 — Reopen when

A deployment needs two writers on one namespace (for example, multi-host), which ADR-011 rules out.

## ADR-017 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Fences increase and reject a concurrent owner | `gems/tamoz-sqlite/lib/tamoz/sqlite/lease.rb` | `test/sqlite_checkpoint_test.rb` — `test_lease_fences_increase_after_release_and_reject_concurrent_owner` | — |
| An expired owner cannot write after takeover | `gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_committer.rb` | `test/sqlite_checkpoint_test.rb` — `test_expired_owner_cannot_write_after_takeover` | — |
| Two racing processes get one live fence | lease operations | `test/sqlite_crash_recovery_test.rb` — `test_two_processes_racing_for_one_namespace_have_one_live_fence` | Real processes, one host |
| Effect start needs the current fence | effect journal | `test/sqlite_effect_journal_test.rb` — `test_effect_start_requires_current_graph_fence_but_late_receipt_does_not` | — |

## ADR-018 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| UUIDv7/ULID lexical order as the sequence | Not safe under clock skew or across hosts |
| Timestamps *(retrospective, 2026-10-01)* | Same problem, plus collisions at clock resolution |

## ADR-018 — Reopen when

Never expected; only if a backend cannot assign a per-namespace sequence atomically.

## ADR-018 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Strict sequence; stale base refused | checkpointers (`gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_appender.rb`) | `test/graph_identity_test.rb` — `test_memory_checkpointer_assigns_strict_sequence_and_rejects_stale_base` | The in-memory checkpointer is tested here; SQLite through `test/sqlite_checkpoint_test.rb` |
| A fork appends a new sequence | same | `test/graph_identity_test.rb` — `test_fork_uses_historical_parent_but_appends_new_sequence` | — |

## ADR-019 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Best-effort resume (run if the state keys still match) *(retrospective, 2026-10-01)* | Runs new behavior on old state with no record that anything changed |
| Implicit migration on load *(retrospective, 2026-10-01)* | A migration is a decision; doing it invisibly hides a behavior change |

## ADR-019 — Reopen when

Users need long-lived paused threads to survive graph releases routinely (then migrations become a
first-class tool, not an exception).

## ADR-019 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Identity is checked before state or user code | `tamoz-graph` history | `test/graph_history_test.rb` — `test_graph_identity_is_checked_before_state_access_or_user_code` | — |
| A future graph is rejected before resume | agent runtime | `test/agent_durable_compatibility_spike_test.rb` — `test_runtime_rejects_a_future_graph_before_resume` | — |
| Another protocol version is refused | durable runner | `test/graph_durable_runner_test.rb` — `test_a_checkpointer_at_another_protocol_version_is_refused` | — |

## ADR-020 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Regex scrubbing by key name | Lossy and incomplete; misses secrets in values |
| `Marshal` as the default serializer *(retrospective, 2026-10-01)* | Remote code execution on a tampered artifact |
| Encrypt the whole database file *(retrospective, 2026-10-01)* | Protects data at rest but not logs, traces, exports, or error text, and every reader needs the key |

## ADR-020 — Reopen when

A secret is found on any durable or observable surface, or an operator needs protected store
values and there is no codec to give them (then ship one).

## ADR-020 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Secrets are refused on each swept surface, by type | state codec | `test/secret_sweep_test.rb` — `test_the_swept_surface_list_is_complete`, `test_the_refusal_is_by_type_not_by_key_name` | Only the surfaces in the sweep list |
| A secret never renders its value | `Tamoz::Secret` | `test/secret_sweep_test.rb` — `test_a_secret_never_renders_its_value` | — |
| Sensitive store values need a protection codec | `gems/tamoz-sqlite/lib/tamoz/sqlite/store.rb` (`protect`) | `test/sqlite_store_test.rb` — `test_sensitive_values_fail_closed_and_round_trip_only_with_protection` | The codec's cryptographic strength is the operator's |

## ADR-021 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| One id per node invocation *(retrospective, 2026-10-01)* | A crash resume would look like new work and repeat effects |
| Fork keeps the source execution id *(retrospective, 2026-10-01)* | Re-execution would silently return the source's recorded effects |

## ADR-021 — Reopen when

A product need appears to fork *with* effect reuse (replaying a branch against recorded receipts) —
that would be a new, explicit replay policy.

## ADR-021 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Activation survives a new base; attempt changes | `tamoz-graph` identity | `test/graph_identity_test.rb` — `test_activation_survives_new_base_while_attempt_identity_changes` | — |
| A stale attempt is rejected before the barrier | executor | `test/graph_interrupt_test.rb` — `test_stale_attempt_result_is_rejected_before_barrier_use` | — |
| A successful sibling is not re-executed after restart | SQLite checkpointer | `test/sqlite_checkpoint_test.rb` — `test_successful_sibling_is_not_reexecuted_after_restart_and_resume` | — |
| A fork binds a new execution to an explicit checkpoint | request inbox | `test/sqlite_request_inbox_test.rb` — `test_fork_binds_new_execution_to_an_explicit_historical_checkpoint` | — |

## ADR-022 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| A system-prompt "always plan first" | Not enforceable and cannot prove which plan authorized an action |
| Plan only high-risk actions | The risk classifier becomes the hole; the gate must be structural |
| Gate effects only and let reads run freely *(retrospective, 2026-10-01)* | Credible and cheaper; lost because reads can still leak context and steer later action — but the shipped work loop does this today, so it is the open question below |

## ADR-022 — Reopen when

The work-loop divergence must be resolved: either this ADR narrows to "effect-bearing actions"
(with reads governed by approval policy and egress), or the work loop gates reads behind a
discovery plan. A loosening ADR must show that every ungated tool is read-only by local
classification and state what an injected read can still leak.

## ADR-022 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| No execution when no plan passes review | `gems/tamoz-agent-kernel/lib/tamoz/agent/deliberation.rb` | `test/agent_runtime_test.rb` — `test_never_executes_when_no_plan_passes_review` | Durable deliberation path |
| A semantic reviewer can force replanning before action | same | `test/agent_runtime_test.rb` — `test_semantic_reviewer_can_force_replanning_before_action` | — |
| Read-only work discovers before planning | session routing | `test/agent_durable_routing_test.rb` — `test_read_only_work_uses_durable_discovery_before_read_only_plan` | — |
| Work loop: mutations before an accepted plan are refused; widening scope returns to review | `gems/tamoz-agent-session/lib/tamoz/agent/work_gate.rb` (`PLAN_BOUND_TOOLS`) | `test/work_loop_test.rb` — `test_mutations_before_an_accepted_plan_are_refused_and_fed_back`, `test_widening_the_scope_goes_back_to_review_and_narrowing_does_not` | Only `apply_patch`, `create_file`, `run_check` are plan-bound |

## ADR-023 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Live adoption of improvements by the running agent | It can change its evaluator or permissions and hide regressions |
| Promote what repeated ("worked twice") *(retrospective, 2026-10-01)* | Frequency is not a holdout; repetition does not make a claim true |
| Auto-approve low-risk candidates | The risk label becomes the hole; the human gate on capability/security/evaluator/prompt/code stays |

## ADR-023 — Reopen when

Never for live self-mutation. Reopen the human gate only if a candidate class can be shown to be
unable to widen authority or change the evaluator by construction, with a test for each.

## ADR-023 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Generator cannot read holdout or evaluator output | `tamoz-agent-improvement` | `test/improvement_candidate_test.rb` — `test_generator_cannot_read_the_holdout_or_the_evaluator_output` | Heuristic candidates only |
| A candidate cannot evaluate or promote itself | same | `test/improvement_candidate_test.rb` — `test_a_candidate_cannot_evaluate_or_promote_itself` | — |
| Evaluator tampering is refused | same | `test/improvement_candidate_test.rb` — `test_evaluator_tampering_is_refused` | — |
| Holdout regression refuses promotion; rollback is byte-identical | same | `test/heuristic_promotion_controls_test.rb` — `test_overfit_candidate_is_refused_on_holdout_regression`, `test_rollback_restores_the_prior_epoch_byte_identically` | Deterministic tests; no real-model improvement result |
| Every human-gate class is enforced | same | `test/improvement_candidate_test.rb` — `test_every_human_gate_class_is_enforced` | — |
| Profile/skill/config approval binds the exact candidate and actor | `CandidateLifecycle` | `test/agent_improvement_lifecycle_test.rb` — `test_approval_digest_binds_the_exact_candidate_and_actor` | No holdout for these kinds |

## ADR-024 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| "Smart" as an unmeasured product claim | Rewards confident prose over correct, efficient outcomes |
| Count deterministic scenario passes as capability *(retrospective, 2026-10-01)* | They test the harness, not the model's judgment |

## ADR-024 — Reopen when

The protocol's metrics stop separating good runs from bad ones (for example, every arm scores the
same), or a provider class appears that the protocol cannot pin.

## ADR-024 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The protocol is frozen and pinned | `documentation/benchmark/BENCHMARK_PROTOCOL.json` | `test/benchmark_protocol_test.rb` — `test_committed_sha256_pin`, `test_all_eleven_stop_rules_are_frozen` | Pins the protocol; does not produce a result |
| Fixture runs are labeled plumbing, not capability | run-kind boundary in `documentation/benchmark/README.md` | `test/benchmark_report_test.rb` | No mechanical check that prose never overclaims |

## ADR-025 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Evaluation as scattered test files | Cannot own corpora, baselines, judge lineage, or release evidence |
| One evals gem with harness and verifier together *(retrospective, 2026-10-01)* | The verifier must load without harness dependencies; the split keeps it minimal |

## ADR-025 — Reopen when

A runtime feature needs evaluation results at run time (for example, live canary gating), which
would put an evaluator in the runtime's path.

## ADR-025 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Only the runner depends on `tamoz-evals` | gemspecs | `test/packaging_test.rb`; source inspection of `gems/*/*.gemspec` | — |
| The evals gem loads only the verifier boundary | `tamoz-evals` | `test/dependency_isolation_test.rb` — `test_evals_loads_the_verifier_boundary_only` | — |
| The verifier enforces the artifact contract | `tamoz-evals` | `test/evals_verifier_test.rb` | "Safety is never weighted" and "every evaluator change starts a lineage" are design rules with no mechanical check |

## ADR-026 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| One vector store for everything | Erases authority, lifecycle, and evaluation differences |
| One store where every record carries a confidence score, and recall weights by it *(retrospective, 2026-10-01)* | Credible and simpler; lost because a score cannot say *why* a record is trusted or *who* promoted it, and a high-scoring claim would still be injected as if it were evaluated behavior |

## ADR-026 — Reopen when

A real workload shows records that fit none of the three levels, or consolidation never promotes
anything in practice.

## ADR-026 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Unobserved episodes admit only as reported | `tamoz-agent-memory` admission | `test/memory_engine_test.rb` — `test_episodes_without_independent_observation_admit_only_as_reported` | — |
| No model call decides admission | same | `test/memory_engine_test.rb` — `test_no_model_call_decides_admission` | — |
| Consolidation preserves preimages | consolidation | `test/memory_engine_test.rb` — `test_consolidation_preserves_preimage_and_failure_keeps_prior_knowledge` | — |
| Lifecycle transitions are exact | lifecycle | `test/memory_engine_test.rb` — `test_lifecycle_transitions_and_eligible_state_set_are_exact` | — |
| Wisdom promotion is gated | `gems/tamoz-agent-memory/lib/tamoz/agent/memory/wisdom.rb` | source inspection | Pipeline tests live in the improvement gem (ADR-023) |

## ADR-027 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Relevance-first retrieval, then model-side filtering | The unauthorized record has already crossed the boundary |
| Consolidate by majority or averaging *(retrospective, 2026-10-01)* | Destroys the disagreement a later decision needs |

## ADR-027 — Reopen when

A recall path is found that bypasses `Memory::Access`, or deletion receipts are needed for artifacts
memory does not own.

## ADR-027 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Access sees only this owner and workspace | `Memory::Access` | `test/memory_access_test.rb` — `test_find_sees_only_this_owner_and_workspace_while_eligible` | — |
| No gem reaches past the facade | boundary test | `test/memory_boundary_test.rb` — `test_no_gem_outside_memory_reaches_into_its_storage_or_scopes` | Source scan |
| Sensitive records are never indexed; other scopes are never returned | retrieval | `test/memory_spec_test.rb` — `test_b4_sensitive_never_indexed_and_other_scopes_never_returned` | Surface-level filtering has no dedicated test |
| Sensitive records are never injected or decrypted | repository adapter | `test/memory_repository_adapter_test.rb` — `test_sensitive_records_are_matched_never_injected_never_decrypted` | — |
| Correction and deletion leave recall and index | lifecycle | `test/memory_engine_test.rb` — `test_correction_removes_bad_record_from_active_recall_and_index`, `test_deletion_emits_receipt_and_propagates_to_index` | Derived artifacts outside memory are not covered |

## ADR-028 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Free-form "try something else" | Cannot prove authority, effect state, recovery, or bounded harm |
| Retry with backoff only *(retrospective, 2026-10-01)* | Duplicates non-idempotent effects and never fixes a logical failure |

## ADR-028 — Reopen when

Escalation volume shows healing never fires in practice, or a verifier is found that the
remediating model can influence.

## ADR-028 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Recovery only through the oracle | `tamoz-agent-healing` remediation | `test/healing_remediation_test.rb` — `test_full_lifecycle_recovers_only_through_the_oracle`, `test_oracle_mismatch_never_recovers` | Deterministic scenarios |
| Scope intersection refuses out-of-authority targets | same | `test/healing_remediation_test.rb` — `test_scope_intersection_refuses_a_target_outside_authorized_resources` | — |
| Unknown effects reconcile then escalate | same | `test/healing_remediation_test.rb` — `test_effect_unknown_reconciles_then_escalates_without_an_executor` | — |
| Open circuit stops before classification | same | `test/healing_remediation_test.rb` — `test_open_circuit_terminates_before_classification` | — |
| Never-mutate classes never reach a mutating family | matrix | `test/healing_matrix_test.rb` — `test_never_mutate_classes_never_reach_a_mutating_family` | — |
| A rule with total abstention cannot be promoted | `gems/tamoz-agent-healing/lib/tamoz/agent/healing/promotion_gate.rb` | `test/healing_matrix_test.rb` — `test_promotion_gate_rejects_total_abstention_and_never_mutate_leak` | — |

## ADR-029 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Implement JSON-RPC/MCP inside Tamoz | Duplicates a fast-moving standard and couples graph correctness to protocol churn |
| Defer MCP until after v0.1 (the retired ADR-012) | External tools were needed now, and the SDK made the edge cheap |

## ADR-029 — Reopen when

The official SDK lags the protocol in a way that blocks a needed feature, or its security posture
falls behind (for example, unpatched transport issues).

## ADR-029 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Loads only core and the official SDK | `tamoz-mcp` | `test/dependency_isolation_test.rb` — `test_mcp_loads_only_core_and_the_official_sdk` | — |
| Catalogs are immutable with exact digests; protocol range fails closed | `tamoz-mcp` catalog | `test/mcp_catalog_test.rb` — `test_compile_produces_immutable_catalog_with_exact_digests`, `test_protocol_outside_configured_range_fails_closed` | — |
| Credentials never appear in errors | same | `test/mcp_catalog_test.rb` — `test_credential_values_never_appear_in_errors_or_stderr_metadata` | — |
| A crash mid-call is unknown and never retried | session + effect journal | `test/agent_mcp_adversarial_test.rb` — `test_crash_mid_call_is_typed_unknown_and_never_retried` | — |
| Elicitation is a durable interrupt | `tamoz-mcp` elicitation | `test/mcp_elicitation_test.rb` — `test_build_produces_the_durable_interrupt_descriptor_shape` | — |

## ADR-030 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Import MCP annotations or skill `allowed-tools` as permissions | Content from another trust boundary can only request or narrow |
| One catalog per source with its own policy *(retrospective, 2026-10-01)* | Authority logic drifts per source; the intersection rule needs one place |

## ADR-030 — Reopen when

A fifth source kind is needed, or a source offers authenticated, operator-pinned capability
metadata that could safely pre-fill classification.

## ADR-030 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Four sources dispatch through one protocol | `gems/tamoz-tools/lib/tamoz/tools/capability_host.rb` | `test/capability_closed_world_test.rb` — `test_four_built_ins_dispatch_through_one_protocol` | — |
| Descriptor digests cover every field; unknown classes fail closed | descriptor contract | `test/capability_descriptor_contract_test.rb` — `test_definition_digest_is_verified_against_all_descriptor_fields`, `test_unknown_effect_class_and_policy_values_fail_closed` | — |
| A widened profile is refused for a bound thread | worker runtime | `test/agent_worker_profile_digest_test.rb` — `test_a_widened_on_disk_profile_is_refused_for_a_bound_thread` | — |

## ADR-031 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Model calls or business execution in a timer callback | Timers are not durable; crash and duplicate semantics become dishonest |
| An external cron that runs the CLI *(retrospective, 2026-10-01)* | Loses occurrence identity and dedup; a double fire is two tasks |

## ADR-031 — Reopen when

A schedule needs sub-second latency the inbox path cannot meet.

## ADR-031 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Claim → create → enqueue is atomic | `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb` | `test/sqlite_schedule_store_test.rb` — `test_put_schedule_cas_on_revision_and_materialize_due_is_atomic` | — |
| Occurrences dedup on identity | same | `test/sqlite_schedule_store_test.rb` — `test_materialize_due_dedups_on_occurrence_identity` | — |
| Restart survival; separate completion state | same | `test/sqlite_schedule_store_test.rb` — `test_restart_survival_and_completion_state_machine` | — |

## ADR-032 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Host-timezone cron, run missed jobs on startup, inherit current permissions | DST surprises, restart storms, delayed privilege escalation |
| Re-check authority only at schedule creation *(retrospective, 2026-10-01)* | A later revocation would not apply to future runs |

## ADR-032 — Reopen when

Cron is implemented (this ADR then becomes Complete), or a run-time intersection is found to widen
any grant.

## ADR-032 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Grants intersect at run time | `gems/tamoz-scheduler/lib/tamoz/scheduler/grant_intersector.rb` | `test/scheduler_values_test.rb` | — |
| Misfire and overlap policies behave as stored | `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb` | `test/sqlite_schedule_store_test.rb` — `test_misfire_skip_delivers_only_the_latest_and_records_older_skipped`, `test_overlap_forbid_skips_the_next_occurrence_while_one_is_in_flight` | — |
| An unattended worker never grants its own approval; approvals do not carry over | worker | `test/agent_unattended_policy_test.rb` — `test_a_worker_left_running_never_grants_its_own_approval`, `test_an_approval_does_not_carry_to_the_next_occurrence` | — |
| Cron/IANA | — | `documentation/overview/compatibility.md` records the gap | Not built |

## ADR-033 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| A Tamoz-only skill DSL | Gives up portability and creates an executable extension surface |
| Skills that bundle runnable tools *(retrospective, 2026-10-01)* | Turns every skill install into a code install |

## ADR-033 — Reopen when

The open format adds an execution model Tamoz users need, or a portable skill can no longer express
what Tamoz needs in flat metadata keys.

## ADR-033 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Portable format conformance | `gems/tamoz-skills/lib/tamoz/skills/frontmatter.rb` | `test/skills_spec_conformance_test.rb` | — |
| Path escape, links, and YAML tricks are refused at compile | `tamoz-skills` walk and frontmatter | `test/agent_skills_adversarial_test.rb` — `test_a2_symlink_to_a_file_outside_the_tree_is_rejected_and_never_indexed`, `test_a8_ruby_object_tag_in_frontmatter_is_rejected_without_materialising_anything` | — |
| Loads are recorded with their tree digest | session | `test/skills_reachability_test.rb` — `test_a_model_load_is_recorded_with_its_tree_digest` | — |
| Scripts are never readable as resources | `tamoz-skills` resources | `test/agent_skills_adversarial_test.rb` — `test_a25_reading_a_script_is_refused` | — |

## ADR-034 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Watch mutable skill directories and load the newest bytes | Unreproducible; enables silent shadowing and same-version swaps |
| Trust a `version` field in frontmatter *(retrospective, 2026-10-01)* | Self-declared; nothing binds it to content |

## ADR-034 — Reopen when

Comparative skill evaluation is built (this becomes Complete), or a signed-skill ecosystem makes
author identity verifiable.

## ADR-034 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Installed exactly as staged by a named non-creator | `gems/tamoz-skills/lib/tamoz/skills/candidates.rb` | `test/skills_candidates_test.rb` — `test_the_creator_cannot_approve_and_an_approver_must_be_named`, `test_a_candidate_changed_after_staging_is_refused` | — |
| Only digested files are installed | same | `test/skills_candidates_test.rb` — `test_only_the_digested_files_are_installed` | — |
| Loads record the tree digest | session | `test/skills_reachability_test.rb` — `test_a_model_load_is_recorded_with_its_tree_digest` | — |

## ADR-036 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Invoke the agent per event, or put raw windows in the prompt | Maximizes cost and staleness; moves deterministic semantics into probabilistic cognition |
| Rename token streaming as "bidirectional streaming" and attach sensor callbacks to a chat | No temporal truth, bounded state, or recovery |

## ADR-036 — Reopen when

A use case needs cognition latency below what admission plus one episode allows.

## ADR-036 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A tampered snapshot fails before any model call | `gems/tamoz-stream/lib/tamoz/stream/situation_snapshot.rb` | `test/stream_situation_snapshot_test.rb` — `test_a_tampered_snapshot_fails_before_any_model_call` | — |
| Snapshot mismatch terminates the episode | episode worker | `test/stream_invariants_test.rb` — `test_invariant_2_snapshot_mismatch_terminates_before_any_model_call` | — |
| The episode path computes no stream-plane concept | `tamoz-stream` | `test/stream_invariants_test.rb` — `test_invariant_1_the_episode_path_computes_no_stream_plane_concepts` | Admission/reduction is in the Go repository, not checked here |

## ADR-038 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Actuator tools with a confirmation prompt | Leaves injection, stale state, duplicates, and approval fatigue uncontrolled |
| Let the model pick a risk class with the intent *(retrospective, 2026-10-01)* | A compromised plan would lower its own gate |

## ADR-038 — Reopen when

Never for direct model actuation. Revisit the intent catalog's shape if a domain's actions cannot be
typed ahead of time.

## ADR-038 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A missing or forged intent catalog fails before any model call | `gems/tamoz-stream/lib/tamoz/stream/decision_builder.rb` | `test/stream_episode_intent_authority_test.rb` — `test_gate1_a_forged_intent_catalog_digest_fails_closed_before_any_model_call` | — |
| The decision carries the catalog-declared risk | same | `test/stream_episode_intent_authority_test.rb` — `test_the_decision_carries_the_catalog_declared_risk` | — |
| The worker names no hardware mechanism | `tamoz-stream` | `test/tamoz_brain_hardware_boundary_test.rb` — `test_the_brain_names_no_hardware_mechanism` | Revalidation and dispatch are in `agentic-stream`, not checked here |

## ADR-039 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Position Tamoz as a robot or safety controller | No real-time semantics, no certification, and a model cannot be the final barrier |
| Allow R4 control behind human approval *(retrospective, 2026-10-01)* | Approval fatigue makes the human a rubber stamp at exactly the wrong moment |

## ADR-039 — Reopen when

Never by ADR alone: moving Tamoz into safety-critical control would mean retiring this product claim
and pursuing certification, not loosening a rule.

## ADR-039 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The worker names no hardware mechanism | `tamoz-stream` | `test/tamoz_brain_hardware_boundary_test.rb` — `test_the_brain_names_no_hardware_mechanism` | Deployment-level interlocks cannot be tested from this repository |
| The episode path has no effectful reference | `gems/tamoz-stream/lib/tamoz/stream/capability_host.rb` | `test/stream_episode_capability_host_test.rb` — `test_dependency_direction_episode_path_has_no_effectful_reference` | — |

## ADR-040 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| A repository per gem from the start | Multiplies coordination before ownership diverged |
| One gem for everything *(retrospective, 2026-10-01)* | No dependency boundary; the graph engine would load agent and provider code |

## ADR-040 — Reopen when

Two gems need different owners or release cadences that one repository's CI cannot serve.

## ADR-040 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Each gem loads only its declared closure | gemspecs | `test/dependency_isolation_test.rb` | Covers the gems listed in that test |
| Each gem packages and runs from its release files alone | packaging | `test/packaging_test.rb` — `test_every_gem_is_strict_valid_and_contains_only_release_files` | — |

## ADR-041 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| One comms gem with a lazily required Telegram backend | Untested seam; HTTP in the contract's load graph |

## ADR-041 — Reopen when

ADR-014 opens adapter registration to third parties.

## ADR-041 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The contract gem loads core only, no HTTP | `tamoz-comms` | `test/dependency_isolation_test.rb` — `test_comms_loads_core_only_and_no_http_or_agent` | — |
| Transport and store contracts are structural | `tamoz-comms` | `test/comms_seams_test.rb` — `test_transport_contract_is_structural`, `test_comms_store_contract_is_structural_and_versioned` | — |
| The null sink discards without raising | same | `test/comms_seams_test.rb` — `test_null_sink_discards_events_without_raising` | — |

## ADR-042 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| The worker performs channel sends | One process would hold the model and transport credentials and the workspace |
| Separate databases joined by a queue *(retrospective, 2026-10-01)* | No single transaction for admission plus enqueue; duplicate or lost turns on crash |

## ADR-042 — Reopen when

A deployment needs the gateway on another host, or the shared-database residual risk becomes
unacceptable (then separate OS users or a narrow write API are the candidates).

## ADR-042 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The gateway authenticates its transport before polling | `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb` | `test/comms_gateway_test.rb` — `test_start_authenticates_the_transport_before_polling` | — |
| A replayed update creates no second request | gateway + store | `test/comms_gateway_test.rb` — `test_a_replayed_update_does_not_create_a_second_request` | — |
| The packaged gateway runs with an injected transport and store | packaging | `test/packaging_test.rb` — `test_packaged_comms_gateway_runs_with_injected_transport_and_store` | "Never loads a model credential" is source inspection, not a test |

## ADR-044 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| An exporter plugin API | Unversioned egress with no conformance gate |
| Fold the OTLP exporter into the contract gem | Puts HTTP in the load graph of every gem that records a signal |

## ADR-044 — Reopen when

ADR-014 opens adapter registration.

## ADR-044 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The recorder does not raise over a malformed payload | `tamoz-core` instrumentation | `test/core_instrumentation_test.rb` — `test_malformed_payload_under_a_null_notifier_does_not_raise` | With a notifier attached it does raise (`test_malformed_payload_with_a_notifier_still_raises`) |
| The catalog is closed and versioned | `tamoz-observability` catalog | `test/observability_catalog_test.rb` — `test_attribute_set_change_without_a_version_bump_raises` | — |
| Exporter egress rejects untrusted destinations and redirects | `tamoz-otel` | `test/otel_test.rb` — `test_egress_policy_rejects_untrusted_destinations`, `test_http_exporter_does_not_follow_redirects_or_use_proxy_environment` | — |

## ADR-045 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| A durable telemetry table in the runtime database | A second writer of overlapping truth that drifts and contends with the fenced writer |
| An unbounded journal *(retrospective, 2026-10-01)* | Fills the disk on the host that also holds the runtime database |

## ADR-045 — Reopen when

An operator needs telemetry retention the durable record cannot reconstruct.

## ADR-045 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The journal rotates, keeps a cap, and survives reopen | `gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb` | `test/observability_runtime_test.rb` — `test_journal_cap_survives_reopen_and_one_file_retention` | — |
| Trace identity derives from durable identity | `tamoz-observability` correlation | `test/observability_correlation_test.rb` — `test_trace_id_follows_turn_identity` | — |
| No telemetry table in the runtime store | `tamoz-sqlite` | source inspection | No mechanical test |

## ADR-046 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Capture by default, scrub at export | Cannot prove what never reached the journal |
| No content capture ever *(retrospective, 2026-10-01)* | Makes production debugging impossible |

## ADR-046 — Reopen when

A content class is found that the classification ranks cannot express.

## ADR-046 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Default emits digest and size only | `gems/tamoz-observability/lib/tamoz/observability/content_policy.rb` | `test/observability_runtime_test.rb` — `test_default_policy_emits_digest_and_size_without_content` | — |
| Restricted capture is refused at load | same | `test/observability_runtime_test.rb` — `test_restricted_policy_refuses_capture_at_load` | — |
| Enabled content is bounded; policy recorded | same | `test/observability_runtime_test.rb` — `test_enabled_content_is_bounded_and_policy_is_recorded` | — |
| A secret never reaches a signal | producer | `test/observability_runtime_test.rb` — `test_secret_is_rejected_before_it_can_reach_a_signal` | — |

## ADR-047 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Sampling at record time against an in-memory window | A paused turn outlives the window; safety evidence is dropped when loudest |
| Unbounded queues so nothing drops *(retrospective, 2026-10-01)* | Moves the failure to memory exhaustion of the process that runs the agent |

## ADR-047 — Reopen when

Export volume forces sampling (then define it at export), or a safety-bearing signal is found
dropped without a counted reason.

## ADR-047 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Safety-bearing flags are seeded in the catalog | `gems/tamoz-observability/lib/tamoz/observability/catalog.rb` | `test/observability_catalog_test.rb` — `test_seeded_safety_bearing_flags` | — |
| Bulk saturation is counted | `gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb` | `test/observability_runtime_test.rb` — `test_bulk_saturation_is_counted_and_metric_cardinality_is_rejected` | The reserved-lane synchronous fallback is source inspection only |
| No record-time sampling exists | recorder | source inspection (no sampling code in the observability or otel gems) | — |

## ADR-048 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Keep `ruby_llm` behind a Tamoz-owned projection *(retrospective, 2026-10-01)* | Credible; lost because the receipt needs exact wire bytes the SDK does not expose, and two message models must be kept in sync |
| One adapter per native protocol *(retrospective, 2026-10-01)* | Multiplies credential, failure, and projection paths per provider |
| A compatibility alias for the retired `RubyLLMModel` | Nothing shipped depended on it (ADR-059) |

## ADR-048 — Reopen when

A needed provider capability is unreachable through the OpenAI-compatible surface and OpenRouter.

## ADR-048 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Profile-named credential only; no generic fallback | `gems/tamoz-agent-kernel/lib/tamoz/agent/model_client_factory.rb` | `test/model_client_factory_test.rb` — `test_factory_requires_the_profile_credential_without_generic_fallback` | — |
| Native protocols and unknown providers fail closed | same | `test/model_client_factory_test.rb` — `test_native_protocols_and_unknown_providers_fail_closed` | — |
| Configuration binds without the secret | same | `test/model_client_factory_test.rb` — `test_factory_binds_profile_and_explicit_endpoint_configuration_without_secret` | — |
| Receipt identity changes with request and provider configuration | `gems/tamoz-agent-kernel/lib/tamoz/agent/model_receipt.rb` | `test/agent_model_receipt_test.rb` — `test_logical_key_changes_with_provider_configuration` | — |
| No retry of a received failure | `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_transport.rb` | `test/model_transport_parity_test.rb` — `test_transport_does_not_retry_a_received_failure` | — |
| The graph loads no model, eval, or HTTP package | `tamoz-graph` | `test/dependency_isolation_test.rb` — `test_graph_loads_no_model_eval_or_adapter_package` | — |

## ADR-049 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Hard revert to deny-only | Fixes the defect but bakes a transport rule into code; the next wanted change needs a rewrite |
| Keep approve-everything without an evidence check | Any chat identity releases any effect |
| Gate on tool effect class only | Same tool differs in risk by argument |
| Let the model declare an action's risk | A compromised plan would lower its own gate |

## ADR-049 — Reopen when

Any of: chat approval is used for an action that later proves harmful; the operator wants
destructive or publishing actions back behind `filesystem_operator`; or a second chat transport is
added. A loosening beyond today's policy (for example, approving without a bound correspondent) needs
a new ADR with a blast-radius table per tier.

## ADR-049 — Verification

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

## ADR-050 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| A threshold-action engine inside observability | An unaudited authority path |
| Auto-restart or auto-approve on an alert | Grants authority from a measurement |
| Act on an in-memory alert window | A paused turn outlives the window |

## ADR-050 — Reopen when

Never for a general hook. Any specific automated effect needs a new ADR that names the effect, routes
it through ADR-022 or ADR-028, and proves the non-degraded-window precondition with a fault-injection
test.

## ADR-050 — Verification

Not implemented. Phases 1–4 (observer-only) are in `gems/tamoz-observability`; no alerting or
actuator code exists there today.

## ADR-052 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Keep one `tamoz-agent` gem | No dependency boundary: loading memory loaded the CLI and providers |
| A new gem per concern, always (the 2026-08-26 rule) | Optimizes package count, not isolation; a module behind a guarded facade gives the same isolation at less release cost |
| Split by layer (models, services) | Every feature change crosses every gem |

## ADR-052 — Reopen when

Release overhead (version bumps, matrix upkeep) becomes a measurable drag, or a boundary test is
found that does not fail on a real leak.

## ADR-052 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Gems load only their declared closure | gemspecs | `test/dependency_isolation_test.rb` | — |
| No gem reaches past memory, skills, research, approval, or profile facades | boundary tests | `test/memory_boundary_test.rb`, `test/skills_boundary_test.rb`, `test/research_boundary_test.rb`, `test/approval_boundary_test.rb`, `test/profile_boundary_test.rb` | Other gems are unguarded |
| File staging, private directories, and locks go through core facades | `tamoz-core` | `test/file_facades_boundary_test.rb` | — |

## ADR-053 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Policy spread across core, agent, comms, and sqlite | Rule sites drift; a change needs Ruby edits in four gems |
| Policy as Ruby methods | Needs a code change and release to reclassify; cannot be simulated or digest-pinned |
| Keep the `--all` flag | All or nothing |
| A compatibility layer for the old seams | Two policy paths to audit |

## ADR-053 — Reopen when

A policy decision needs information the request description does not carry (for example, the content
of a diff), or a profile needs to change evidence levels (today only `base.yaml` can).

## ADR-053 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Policy documents load only if their simulations pass | `gems/tamoz-approval/lib/tamoz/approval/policy_document.rb` | `test/approval_policy_document_test.rb` | — |
| No gem outside approval reads its stores | boundary | `test/approval_boundary_test.rb` — `test_no_gem_outside_approval_reads_its_stores` | — |
| Bound sessions keep their revision; reload never leaks | `gems/tamoz-approval/lib/tamoz/approval/engine.rb` | `test/approval_reload_test.rb` — `test_bound_session_keeps_old_rev_after_reload`; `test/approval_mode_switch_test.rb` — `test_rebind_never_redecides_an_already_recorded_decision` | — |
| Grant keys are argv-aware | engine | `test/approval_grant_key_test.rb` | — |
| A denial is fed back to the model | work loop | `test/work_loop_test.rb` — `test_an_asked_edit_pauses_for_approval_and_a_denial_is_fed_back` | — |

## ADR-054 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| A new source mechanism | Widens the trust surface the catalog must reason about |
| An unreserved MCP server named websearch | An operator's server could silently replace the governed one |
| A raw HTTP tool | No egress boundary, no application trust assignment |

## ADR-054 — Reopen when

Query-content exfiltration is observed, or a second web capability (for example, a browser) needs
the same governance.

## ADR-054 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| The id `websearch` is reserved | `gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb` | `test/agent_worker_mcp_test.rb` — `test_the_websearch_id_cannot_be_claimed_by_a_generic_server` | — |
| Egress is pinned; changed egress on resume stops | `gems/tamoz-mcp-websearch/lib/tamoz/mcp/websearch.rb` | `test/websearch_egress_test.rb` — `test_session_record_pins_the_canonical_egress_declaration`, `test_resume_with_changed_egress_stops_typed` | — |
| Websearch loads only its declared closure | packaging | `test/dependency_isolation_test.rb` — `test_websearch_loads_only_its_declared_tamoz_closure` | — |

## ADR-055 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Keep the continuous plane in Ruby `tamoz-stream` | A throughput/temporal system and a durable-cognition system in one runtime served neither |
| Two processes, two languages, one monorepo *(retrospective, 2026-10-01)* | Credible: it keeps the authority boundary; lost on toolchain and release-cadence ownership, not on safety |
| Make Tamoz the client and authority | Puts authority in the LLM-bearing process |
| A shared database instead of a sealed snapshot | A live read reintroduces staleness and an ambient trust surface |

## ADR-055 — Reopen when

The proto changes faster than coordinated releases can follow, or the worker must accept episodes
from more than one local caller (then add real transport authentication first).

## ADR-055 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Tool surface is exactly the allowlist; injection cannot bind a denied tool | `gems/tamoz-stream/lib/tamoz/stream/capability_host.rb` | `test/stream_episode_capability_host_test.rb` — `test_the_surface_is_exactly_the_permitted_allowlist`, `test_an_injected_instruction_cannot_bind_a_denied_capability` | Adapter internals are trusted |
| Tool context never carries effects or store | same | `test/stream_episode_capability_host_test.rb` — `test_the_context_passed_to_a_tool_never_carries_effects_or_store` | — |
| Tokens never persist or cross the wire | worker | `test/stream_token_custody_test.rb` — `test_the_token_never_enters_the_durable_payload`, `test_the_token_never_crosses_in_a_wire_event` | — |
| Serves over Unix socket or TCP, not both | `gems/tamoz-stream/lib/tamoz/stream/worker_server.rb` | `test/stream_worker_server_test.rb` — `test_the_server_refuses_both_or_neither_transport` | Both bind insecure ports; no TLS |
| Shared contract vectors reproduce exactly | `tamoz-stream` | `test/stream_invariants_test.rb` — `test_invariant_9_every_shared_contract_vector_reproduces_exactly` | The Go side is in a sibling repository and not checked here |

## ADR-056 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Keep skills in `tamoz-tools` behind a module facade | Credible; lost because the lint, bundled skills, and operator snapshot have callers that do not need the toolbox, and the boundary test is simpler at a gem edge |

## ADR-056 — Reopen when

The skills surface shrinks back to what one caller needs.

## ADR-056 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| No file outside the gem names an inner constant | `gems/tamoz-skills/lib/tamoz/skills.rb` | `test/skills_boundary_test.rb` — `test_no_file_outside_the_gem_names_an_inner_constant` | — |
| The gem loads only core | same | `test/dependency_isolation_test.rb` — `test_skills_loads_only_core` | — |

## ADR-057 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Cancel the graph context's token on a user stop | Leaves the request `running`; recovery resumes the stopped work |
| Raise an exception into the running node | Loses effect state mid-node and can be rescued by user code |
| Kill the worker thread | Unsafe in Ruby; can leave a half-committed barrier |

## ADR-057 — Reopen when

A user needs a stop to interrupt a long-running tool call immediately, or more than one process can
run turns for the same thread.

## ADR-057 — Verification

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

## ADR-058 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Domain modules in Ruby | Lets special cases fake generality; a new domain is a code change |
| Unpinned JSON | The Go side and the benchmark could drift without anyone noticing |

## ADR-058 — Reopen when

Domain data needs logic the loader cannot express as data (then extend the data schema, not the
loader).

## ADR-058 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A novel domain produces a decision with zero new Ruby | `test/support/domain_loader.rb` | `test/stream_episode_intent_authority_test.rb` — `test_gate4_a_novel_domain_produces_a_decision_with_zero_new_ruby` | — |
| A family is built for every discovered domain | same | `test/benchmark_families_test.rb` — `test_a_family_is_built_for_every_discovered_domain` | — |
| The cross-repo digest is pinned | intent catalog | `test/agent_intent_catalog_test.rb` — `test_the_aquaculture_catalog_digest_matches_the_pinned_cross_repo_vector` | The Go side is not checked here |
| The protocol SHA is pinned | `documentation/benchmark/BENCHMARK_PROTOCOL.json` | `test/benchmark_protocol_test.rb` — `test_committed_sha256_pin` | No test fails on a domain literal in Ruby |

## ADR-059 — Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Write upgrade paths for every schema change | Pays for compatibility nobody needs yet, in the safety-critical store |
| Reset migration numbering on each schema change | Breaks the checksum and manifest pins that catch an edited migration |

## ADR-059 — Reopen when

The first public release (1.0, or earlier if external users run Tamoz with data they need to keep).

## ADR-059 — Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Applied migrations cannot be edited | `tamoz-sqlite` kernel | `test/sqlite_kernel_test.rb` — `test_migration_checksum_tampering_is_rejected` | — |
| No compatibility migration for session records | session records | `test/agent_session_records_test.rb` — `test_version_one_session_record_is_rejected_without_compatibility_migration` | — |
| No legacy readers | — | contradicted by `test/legacy_session_resume_test.rb` — `test_a_current_build_reads_the_old_database` | Open: delete that tolerance or narrow this rule |
