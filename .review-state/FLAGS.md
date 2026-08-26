# Owner FLAGs — clean-code review loop (running log)

Collected verbatim from analyzer/fixer reports. These are OUT OF SCOPE for the refactor loop
(cross-file, cross-gem, contract, or behavior decisions) and belong to the owner.
Format: rank · file · flag.

## From analysis phase

1. migrator.rb — test/memory_store_test.rb:29 re-implements the checksum rule inline; after the
   `migration_checksum` seam lands, switch the test to it (cross-file, owner decision).
2. worker.rb — `session.app.durable_runner` Demeter chain ×2; two spellings of the runtime seam
   (`@runtime.*` wrappers vs direct `@runtime.checkpoints`/`schedule_store` reach-throughs).
3. worker_runtime.rb — four durable writers bypass `durable` (error identity → owner decision);
   `close_approval_session` nil crash on early teardown; ClassLength TODO exclusion absorbing growth.
4. comms_store.rb — `turn_payload` has three repo-wide spellings (`TurnContext.task` canonical +
   two thin wrappers); `disposition_only` naming is a cross-gem contract change.
5. openclaw_comms_runner.rb — `message_id_by_update_id` fact key doesn't match its content
   (artifact bytes); `leg_delivery_state` duplicated into a test file; file carries ~79 live
   rubocop offenses incl. 12 over-length drivers with no TODO entry (medium-risk split).
6. openclaw_durable_cli_adapter.rb — metric-catalog family (~649–805) split-worthy but out of
   scope this pass; `Tamoz::SQLite.const_get(:Wire, false)` (~1005) load-order suspicion;
   `EffectPoller#poll(**)` silently drops interface kwargs.
7. situation_request.rb — filename matches no class inside it; duplicate identity-emptiness check
   with divergent error bytes (owner picks); `wall_time` enforced but never propagated (known G6);
   `identity_for` ad hoc Struct already flagged in repo-quality-audit missing-abstractions.
8. gateway.rb — `start_text` ignores the `/start` code argument on bound conversations
   (answers START_PAIRED_REPLY without checking pending challenges) — confirm intended;
   public loop API untouched by candidates.

## Environment findings (orchestrator)

- RuboCop result cache under this sandbox reads a poisoned shared cache and silently reports
  false "no offenses" (cached run on gateway.rb: "0 files inspected"; uncached: 22 real
  offenses). All loop invocations use `--cache false`.
- Uncached repo-wide rubocop currently reports ~1023 offenses / 850 files that the committed
  `.rubocop_todo.yml` does not cover (todo last regenerated 2026-08-24) — the documented
  "gate = 0" holds only with a healthy cache. Worth an owner-side todo regeneration.

## Known-red watch (not caused by the loop)

- SubprocessRunnerTest#test_invalid_intervention_decision_fails_even_after_deadline — flaked once
  under parallel rake ci after batch 1; proven unrelated: green solo at pre-loop HEAD, green solo
  at loop HEAD, green full-gate re-run. Deadline-timing sensitive under parallel load only.

## Orchestrator discipline (self-corrections)

- Batch-3 rank bindings drifted (+2) because they were derived from the pre-corpus-filter LOC
  list instead of queue.tsv; detected before fixes launched, candidate reports renumbered to true
  ranks. Rule going forward: every binding string is generated from queue.tsv rows only.

## From analysis phase (wave 3)

9/17. cli_worker_commands/cli.rb — `stringify` spelled with different semantics across
   tamoz-agent-cli vs sqlite/stream verification stores (cross-gem §3.1 rename).
10/18. episode_nodes.rb — six zero-caller methods above `private` (§6 narrow-API call);
   test/benchmark_controls_test.rb:276 pins private ground_evidence! via allocate.send.
11/20. circuit/record.rb — `with_*` transitions violate §3.1's yield rule (cross-gem rename);
   `met_conditions` vs stored `conditions_met` near-collision; seven public methods with zero
   repo callers.
12/9b. cli.rb — cross-file boolean params (`read_only:`, `interactive:`); three spellings of the
   effect-resolution answer vocabulary.
13/10b. session.rb — build_definition public-surface narrowing; verify_profile_binding! vs
   enforce_* spelling (cross-gem comment pointers); 19-kwarg constructor.
14/15. checkpoint_codec.rb — public `load(bytes, validate_identity:)` boolean threads through
   tamoz-sqlite store surface; M1 four-codec split stays open under cohesion exception.
15/16. readiness.rb — schema_error noun-name vs raise semantics (~26 sites).

## Orchestrator discipline (self-corrections), cont.

- Misattributed a failed-agent notice to rank 14 and reverted schedule_store.rb mid-run; the real
  failure was rank 10's fixer (empty closing message). Rank 14's agent recovered, re-applied
  byte-exact, re-gated. Lesson: cross-check agents.txt id->rank BEFORE any tree intervention on
  an "orphaned" diff.
- codec C6 rename left two stale comment-only mentions of the old name in
  test/agent_non_ascii_session_test.rb (~184/~244) — cosmetic; batch for owner/wrap-up.

## From analysis phase (wave 4)

16/21. runtime.rb — run_routed_discovery/execute_routed_read_only_plan hide their return;
   action_plan_recorded? mutates+emits under a predicate name; verify() long positional list;
   ~40x event-block forwarding boilerplate spans plan_review.rb+step_execution.rb; mutable
   action_state hash vs §5 (structural, out of pass scope).
17/23. selector_control.rb — seven "private" methods are hidden cross-file surface via .send
   from Stopper/Intervention reopenings (+ test sends :build_expectation); validator-quintet
   spelling copy-pasted across sibling harness files (repo-wide alignment owner call).
18/24. subprocess_runner.rb — wait_for_child positional 4-tuple could be Data.define; C1/C3
   touch the timing-sensitive deadline path (validate solo).
19/10b. session.rb — C5 rename leaves two stale prose mentions in
   docs/repo-quality-audit-2026-08-20/incorrect-existing-usage.md (docs untouched by fixers).

## From analysis phase (wave 5-6)

20/29. executor.rb — graph_interrupt_test.rb:131 pins private validate_outcome! via __send__
   (§3.1 verb misuse + boolean pending: flag need owner decision with test updated in-commit).
21/30. profile.rb — hash.delete("adoption") (~397) looks like residual pre-registry tolerance;
   permissions:/suggestion: boolean keywords on cross-gem surface are §4 two-behavior methods.
22/31. verifier.rb — evidence-vs-result status rule tables are deliberate mirrors (third-surface
   call); Verifier::DIGEST_DOMAINS reached by test while RESULT_DECISIONS/Verification unused.
23/32. openclaw_comms_fixture.rb — misleading cross-file submit name; fixture bypasses seams
   (instance_variable_set/@delivery_sink, adapter.__send__(:read)); drain hardcodes allowlist
   descriptor under possible pairing mode.

## Known-red watch (parallel-session environment)

- rake ci DocumentationTest#test_local_markdown_links_resolve fails on
  docs/gem-boundary-audit-2026-08-25/01-current-inventory.md (untracked dir authored by the
  OWNER'S PARALLEL SESSION in this checkout, not by this loop). Environmental until that session
  finishes; re-check at wrap-up.

## From analysis phase (waves 11-12)

24/61. approval/policy_document.rb — CANDIDATES-ONLY: provably-dead refusal branch in
   validate_tool_tiers! withheld by design (pinned refusal contracts) — owner decides deletion.
25/65. cli_profile_commands.rb — import target-exists error wording ("use --force and confirm")
   vs pinned force-skips-confirmation behavior.
26/69. websearch/egress_policy.rb — dead predicate-named operator_authority? returns String
   "owner", zero callers (API removal decision).
27/59. stream/evidence_client.rb — episode_stream.rb:152 sibling `timestamp` builder should
   follow if build_* vocabulary adopted repo-wide.
28/70. memory_treatment_profile.rb — duplicate aggregate key attribution_incomplete vs
   attribution_incomplete_cells is digest-visible; needs reviewed format change.

## From analysis phase (waves 13-14)

29/78. sqlite/stream verification stores are TWINS — private canonical_episode should become
   encode_episode in BOTH gems as one coordinated commit (one-sided rename would fork the
   concept across the pair). Owner-level.
30/57. improvement/promotion.rb — #rollback ~59 body lines needs >60-line budget; escalate to
   two-agent pipeline if owner wants it this pass.

31/85. agent-capabilities/mcp_source_builder.rb — build_server/append_descriptors are
   caller-free yet public (API-surface removal decision).

32/89. agent-capabilities/mcp_capability_source.rb — public reader mcp_catalogs holds
   {server_id => snapshot_digest}, not catalogs; cross-gem consumers; rename = owner decision.

33/97. observability/metrics.rb — symbol-vs-string label values create duplicate
   prometheus-exposition series; merging is a behavior change.
34/102. stream/verification_store.rb twin rename reserved for owner's coordinated commit.
35/104. docs/code-quality-baseline.json still records 9 offenses for heuristic_corpus.rb vs
   live 0 — stale baseline entry, owner file.

36/105. core/capability/descriptor.rb — validate! ~120 lines exceeds step-down ceilings by
   design; decomposition needs a sanctioned pipeline change.
37/107. sqlite/request_inbox_transitions.rb — dead @staleness ivar never read; fix spans
   request_inbox.rb:25 construction site.
38/109. agent/session_plan_attempt.rb — LATENT BUG: parse_review rescue reads nonexistent
   details.plan_digest (:204) → malformed semantic-review doc raises NoMethodError instead of
   recording the .semantic protocol review. Error-path behavior change, owner decides.
39/111. profile/transition_registry.rb — LEGACY_REGISTRY_SCHEMA_VERSION referenced nowhere
   beyond definition (dead public constant).

40/116. tools/tool_argument_validator.rb — validate_patch_text! `empty:` kwarg vs §4's
   no-boolean-param rule; removal would reorder pinned error precedence.
41/118. sqlite adapter seam reached via __send__ (:acquire_lease/:transaction/:backend_time/
   :validate_lease_in_transaction!) across the gem; adapter-side promotion would delete all
   ManualDispatch sites.
42/115. checkpoint_committer validate_mode! vs store-seam name validate_commit_mode! differ;
   rename spans checkpoint_store.rb.

43/113. graph/memory_checkpointer.rb — literal format_version: 1 vs CHECKPOINT_PROTOCOL_VERSION
   constant; unify = owner call.

44/122. agent-kernel/witness_gateway.rb — records reader exposes live mutable array;
   record_payload is dead public surface (removal = API decision).
45/loop. REGRESSION FIXED at fc3878a: ranks 115+118 (checkpoint committer direct-calls +
   store endless-method shims) broke boundary_source_audit static reachability while all
   per-file gates stayed green. Briefs updated with a tamoz-sqlite reachability rail; the
   audit test joins the per-file gate list for that gem.

46/129. tamoz-observability uses banned-by-§3.1 serialize_* in metrics.rb + content_policy.rb;
   unifying = gem-wide rename.
47/136. repo carries two spellings of raising validators (plain validate_x in observability vs
   validate_x! in healing/tools) — orchestrator-level naming sweep.
48/134. tools/toolbox.rb — boolean kwargs on public initialize + allow_symlinks: on private
   resolve with external __send__ callers; both API-touching.

49/150. concurrency/stream_sink.rb — emit(run_id:) vs emit(task_id:) fallback asymmetry.

50/157. cli_comms_shared.rb pre-existing Metrics/ModuleLength (109/100) — owner accept or
   config suppress; every in-file remedy barred by recorded cohesion exception.

51/163. graph/writer_run_executor.rb — invoke's public request_id: kwarg is unread (dead API);
   removal = cross-gem signature change.
52/165. memory/situation_recaller.rb — projection reads FIRST outcome: ref while verification
   accepts any complete one; coincident only by admission construction.

53/178. evals/schema.rb — dead name=="integer" boolean-exclusion conjunct (TrueClass/FalseClass
   are not Integer subclasses) left untouched; pinned validation internals.
54/180. session_plan_outcomes.rb — plan_rejected_message public but uncalled externally;
   plan-rejection message logic duplicated cross-gem in runtime/plan_review.rb (two-agent dedup).

55/187. sqlite/request_inbox.rb — five private forwarders with zero callers repo-wide
   (incl. send-forms) left in place: dynamic dispatch unprovable + fc3878a history.
56/192. skills/frontmatter.rb — hardcoded "32 pairs" detail is byte-pinned; changing it needs a
   reviewed format decision.
57/186. core/context.rb initialize residual ~55 lines is the pinned kwarg signature.

58/207. profile/check_spec_validator.rb — "unknown check fields" refusal omits the check-name
   prefix every sibling refusal has; unifying changes pinned bytes.
59/process. Tail-wave incident: rank 205 agent died mid-edit leaving an orphaned call-site
   change (definition not yet updated). Reverted to pristine, relaunched fresh. Orchestrator
   now diffs-before-commit even when a report exists but liveness/closing is missing.
60/process. Tail queue append bug (printf arity) mis-formatted 315 rows; rebuilt from
   tail_final.tsv. All 515 queue rows validated: NF==3 && col3 startswith gems/.

61/212. comms/delivery_drainer.rb — next_fence rename must pair with gateway.rb's identical
   helper (cross-file twin).
62/process. Rank-207 regression (missed rename at check_spec_validator.rb:137, NameError)
   caught by rank 215's agent via agent_profile_transition_test; fixed in 25b692d. Lesson:
   rename candidates must grep the FILE ITSELF for every occurrence, not just "both sites"
   claimed from memory.

63/226. memory/wisdom.rb — unused ONE_CANDIDATE_LIMIT constant vs class-doc singleton scope.
64/221. evals/sqlite_scenario_driver.rb — run exceeds the 30-line hard ceiling but every
   shortening path crosses pinned fault-gate arming/error-mask semantics (SERIAL lane).

65/236. memory/surface.rb — searchable_text bound documented as "512 bytes" but code slices
   characters (text[0,512]); index-content decision.

66/231. docs/P6_DURABLE_SESSION_RECOVERY_PLAN.md:69 references route_planner's old private
   name declared_routes (now resolve_routes).

67/246. session_memory.rb — cross-class `memory_owner || 'session'` default duplicated with
   SessionPlanningContext.
68/process. Rank-242 rename grep surfaced .worktrees copies and generated .enola facts as
   false-positive callers — agents correctly excluded non-source matches.

69/252. scheduler/grant_intersector.rb — effective_grant carries allow_narrowed: (§4 boolean
   param) on the pinned authority gate; zero callers pass it; split/rename is a public-API
   change for the owner.
