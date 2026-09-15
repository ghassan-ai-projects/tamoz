# F23 `tamoz-agent-improvement` — IMPROVE: the bounds, holdout isolation, and one-transition-engine discipline are real, but the "human gate" is an unbound string, a promotion is recorded from a promoter-supplied report resolver, and the promotion gate can be cleared by a forged report produced inside this gem

Row / queue / baseline: `F23` | W4A | branch `audit-15-09`, HEAD `582ae55`, checkpoint date 2026-09-15 | analyst F23 (read-only) | budget ~40 min, elapsed ~48 min

## Scope and source map

`tamoz-agent-improvement` is a 13-file gem: 12 sources, **1860 lines**, plus an 18-line gemspec. Every file was read end to end.

| File | Lines | Role |
|---|---|---|
| `lib/tamoz/agent_improvement.rb` | 26 | require graph; the gem's whole public load surface |
| `lib/tamoz/agent/improvement/version.rb` | 9 | version constant |
| `lib/tamoz/agent/improvement/errors.rb` | 60 | 9 typed failures; policy/integrity failures propagate |
| `lib/tamoz/agent/improvement/provenance.rb` | 248 | the 8-axis candidate provenance record and its completeness test |
| `lib/tamoz/agent/improvement/heuristic.rb` | 163 | the one bounded candidate value + insert-only `apply` |
| `lib/tamoz/agent/improvement/generator.rb` | 209 | the trajectory-only generator and its grant refusal |
| `lib/tamoz/agent/improvement/evaluation_report.rb` | 239 | the seal, the structural gates, `decide`, `assert_human_gate!` |
| `lib/tamoz/agent/improvement/monitor.rb` | 79 | post-activation observation using the promotion gates |
| `lib/tamoz/agent/improvement/promotion.rb` | 365 | the behavior-epoch promotion and rollback |
| `lib/tamoz/agent/improvement/candidate_proposal.rb` | 72 | the profile/skill/config candidate handoff |
| `lib/tamoz/agent/improvement/candidate_policy.rb` | 119 | fail-closed candidate artifact policy, narrowing proof |
| `lib/tamoz/agent/improvement/candidate_lifecycle.rb` | 271 | the 4-stage durable effect lifecycle, approval digest |
| `tamoz-agent-improvement.gemspec` | 18 | deps: `tamoz-agent-kernel`, `tamoz-agent-memory` only |

Adjacent sources read because this row's gates cannot be judged without them: `gems/tamoz-evals-runner/lib/tamoz/evals/harness/heuristic_paired_evaluation.rb` (160), `.../heuristic_corpus.rb` (131), `gems/tamoz-agent-memory/lib/tamoz/agent/memory/behavior_transition.rb` (172), `.../transition_registry.rb` (376), `.../wisdom.rb`, `gems/tamoz-agent-session/lib/tamoz/agent/session_memory.rb`, `gems/tamoz-tools/lib/tamoz/tools/{toolbox,path_resolver,tool_catalog}.rb`, `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb`, `gems/tamoz-evals/lib/tamoz/evals/canonical_json.rb`, `gems/tamoz-approval/policy/base.yaml`.

**Entry seam.** Two, and they do not share a gate.

1. `Improvement::Promotion#promote` (`promotion.rb:38`) — records a `kind: :heuristic_promotion` transition through the P11-W-owned `Memory::TransitionRegistry`. This is the behavior-epoch path and the one that puts bytes in front of the model.
2. `Improvement::CandidateLifecycle` (`candidate_lifecycle.rb:46-132`) — the profile/skill/config candidate path, four `EffectDispatcher.run` stages `apply → restart_health_verify → activate → rollback`.

**Dependency direction is honest and narrow.** `agent_improvement.rb:6-7` requires only `tamoz/agent_kernel` and `tamoz/agent_memory`; the gemspec declares exactly `tamoz-agent-kernel` and `tamoz-agent-memory` (`tamoz-agent-improvement.gemspec:14-17`). No production gem requires this gem: probing `Tamoz.const_defined?(:Approval)` after `require "tamoz/agent_improvement"` returns `false`, and a repo-wide grep for `Improvement::Promotion` / `CandidateLifecycle` outside this gem's `lib/` finds only two test files (`test/improvement_candidate_test.rb:539`, `test/agent_improvement_lifecycle_test.rb:7`). The row's producer surface is therefore, at HEAD, reachable only from tests.

**Prior findings carried forward by name.** `FINDINGS.md:14` `F07-REL-01` (`tamoz-sqlite` `RequestInboxClaimer`) and `FINDINGS.md:13` `CF04-REL-01` (`EffectDispatcher` terminal-receipt selection) are the two seams the lifecycle path rides; neither is re-litigated here. `FINDINGS.md:11-12` `F21-SEC-01`/`F25-SEC-01` own the profile-authority binding that `candidate_policy.rb` consumes; F23-R3 below is adjacent to but distinct from them.

**Prior-art lead checked, not assumed.** Row control named top-100 finding **082** (`autonomy_case.rb`, "vacuous hard-counter gate") as the pattern to test for here. It is **not** the same vacuity, and I reject the analogy: `EvaluationReport::assert_paired!` (`evaluation_report.rb:136-164`) is harsher than the harness that feeds it — it re-derives `paired_task_digest` from the two per-partition digests (`:157-163`) and refuses an identical development/holdout set (`:152-155`). No byte-invariance failure is established.

## Behavior path

**A. Generation (deterministic, provider-free, no model call).**

1. `Generator#initialize` (`generator.rb:46-58`) raises `HoldoutIsolationError` if `toolbox.action_capable?` (`:47-50`), then resolves `protected_paths` and calls `assert_isolated!` (`:63-74`), which refuses any protected path equal to or under the grant root.
2. `Generator#generate` (`:101-120`) refuses a second candidate per instance (`:102-105`), refuses a corpus above `MAX_TRAJECTORIES = 256` (`:35`, `:107-109`), reads every trajectory through `toolbox.execute("read_file", …)` (`:90`), keeps only `entry["verified"] == true` (`:112`), and returns `nil` when the evidence floor is not met (`:113,116`).
3. `strongest_candidate` (`:144-169`) ranks ordered `(precursor, subject)` tool pairs on the same path (`:189-205`), floors at `MIN_TRIALS=3`, `MIN_SUPPORT=3`, `MIN_CONFIDENCE=0.8` (`:32-34`, `:151-154`), and builds exactly one `Heuristic` with `surface: :planning` (`:156-168`).
4. `Heuristic#assert_bounded!` (`heuristic.rb:48-70`) enforces surface ∈ `planning/routing/verification`, precursor ∈ `INSERTABLE_TOOLS` (`:37` — `read_file`, `list_directory`, `search_text` only), `support <= trials`, ≤ `MAX_STATEMENT_BYTES = 512` (`:38`), and `secret_shaped?` on the statement (`:66-68`).
5. `Provenance#assert_complete!` (`provenance.rb:82-93`) walks the 8 declared axes (`:38-41`) and every declared sub-key (`:45-55`), then verifies trajectories are `verified` and `partition == "train"` (`:174-181`), that train/holdout id sets are disjoint and every source is inside `train_ids` (`:189-209`), that the surface is valid, the version is not a no-op, the activation scope is exactly `first_intake_of_thread`, and `rollback_target.behavior_version == behavior_version_before` (`:211-231`), and that evaluator ≠ generator (`:236-244`).

**B. Evaluation (deterministic, no model call, no subprocess).**

6. `HeuristicPairedEvaluation#evaluate` (`heuristic_paired_evaluation.rb:54-65`) scores `development` with the corpus tasks and `holdout` with either the corpus holdout or the injected regression tasks (`:56`), seals with the production sealing function (`:58`, `report_module.sealed`), and writes the artifact into the evaluator's own partition (`:61-63`).
7. `score_partition` (`:96-105`) digests the task list once and gives **both** arms that same digest (`:97-104`), so the pairing check is honest about what it measures.
8. `satisfies?` (`:131-141`) applies one of two oracles: `read_before_patch` (`:143-155`) or `bounded_plan` (`steps.length <= step_budget`).

**C. Promotion.**

9. `Promotion#promote` (`promotion.rb:38-65`) runs eight ordered checks: `candidate.assert_bounded!` (`:47`), `EvaluationReport.verify!` (`:48`), `assert_evidence_resolves!` (`:49`), `assert_not_self_promoting!` (`:50`), `EvaluationReport.assert_human_gate!` (`:51`), `decide`+`assert_decision_passed!` (`:53-54`), `provenance.assert_complete!` (`:56`), `assert_provenance_binds!` (`:57`), `assert_one_live_heuristic!` (`:58`), then `before`/`after` from `@registry.active` and `provenance.affected_behavior` with `assert_forward!` (`:60-62`).
10. `record_promotion` (`:342-361`) calls `@registry.record(kind: :heuristic_promotion, …)` and returns `"activated" => false` — the transition is `:recorded` and pending.
11. Activation happens elsewhere: `SessionMemory#claim_behavior_transition` (`session_memory.rb:25-36`) claims at first intake, `SessionMemory#finalize_behavior_claim` (`:72-82`) finalizes after the intake checkpoint commit. `TransitionRegistry#finalize` `cas_control`s the active version/snapshot **before** `activate_row` (`transition_registry.rb:191-197`).

**D. Rollback.**

12. `Promotion#rollback` (`promotion.rb:75-135`) requires an `active_transition_id` (`:77-80`) whose `kind` is `:heuristic_promotion` (`:82-86`), a non-empty `rollback_target.snapshot_digest` (`:88-94`), a snapshot still readable (`:96-101`), the human gate (`:103-106`), then records a **fresh** transition whose snapshot is the prior epoch (`:117-126`) and whose version is `successor_version` (`:109`).
13. `assert_rolled_back_byte_identical!` (`:142-168`) re-reads the active snapshot from the Store, re-renders the delimited injection region with the same shape `SessionPlanningContext#add_behavior_snapshot` builds (`session_planning_context.rb:557-564`), and compares digests over bytes.

**E. Candidate lifecycle (profile/skill/config).**

14. `validate!` resolves the artifact by `proposal.to_digest` (`candidate_lifecycle.rb:136-145`), checks `profile_id`/`digest`/`scope` match (`:147-154`), runs `CandidatePolicy.validate!` (`:64-66`), and deep-freezes the canonical form.
15. `approval_request` (`:72-87`) recomputes the artifact, checks it is unchanged (`:74`), refuses actor == `proposal.created_by` (`:164-169`), and digests `{proposal_digest, candidate_digest, candidate_content_digest, operation, actor, authority_digest}` (`:29-43`).
16. `approve!` (`:89-103`) requires the exact `approval_digest` **and** `evidence == "human:#{actor}"`.
17. Each stage runs through `EffectDispatcher.run(operation: "improvement.#{stage}", safety: :reconcilable, call_index: EFFECT_CALLS[stage], reconcile:)` (`:183-198`), with `EFFECT_CALLS = {apply: 4100, restart_health_verify: 4101, activate: 4102, rollback: 4103}` (`:13`).

## Lens: correctness

**What holds.** The insert-only contract of `Heuristic#apply` is exact. Probe: a 2-step plan `[apply_patch lib/x.rb, read_file lib/y.rb]` yields 3 steps whose non-`origin` projection `== steps` (`heuristic.rb:114-138`); a plan that already reads the target is returned unchanged (`:128-133`), which `test/improvement_candidate_test.rb:323-333` pins. `apply` caps insertions at `MAX_INSERTIONS = 8` (`:39`, `:129`) and never mutates an input hash (it appends the original `step` object, `:135`).

The evidence floor is real, not documented: `strongest_candidate` returns `nil` rather than a weaker heuristic when the floor is missed (`generator.rb:113,116,151,154`), and the ranking is deterministic on hash order because the tiebreak includes the sorted pair name (`:186`).

`decide` (`evaluation_report.rb:199-211`) is strictly-margin-based and cannot be satisfied by a flat comparison: `development` must be **strictly** positive (`:203`) and `holdout` must be non-negative (`:204`). Probe: dev `1→3`, hold `1→2` → `passed=true`; dev `0→0` → `passed=false` with reason `"development margin 0 is not an improvement"`.

**What does not hold — the promotion gate can be cleared by a report produced inside this gem.** See **F23-COR-01**. I built a promotion from *only* this gem's public API over an in-memory `BehaviorTransition` history: `EvaluationReport.sealed` is `module_function` (`evaluation_report.rb:59,67-70`), `paired_task_digest` is `module_function` (`:169`), and the six keys `verify!` requires (`:52-55`) are all constructible from public values. Probe `/tmp/f23_probe_promote.rb` output:

```
baseline active: tamoz.agent.session/2
!! PROMOTED with a forged report + promoter-supplied resolver: activated=false tx=bfe6c4a00ec37bff
   reserved_version=2 decision={"development_margin"=>8, "holdout_margin"=>8, "passed"=>true, "reasons"=>[]}
```

Real evaluator data on the same corpus is `development_margin => 2`, `holdout_margin => 1` (`test/improvement_candidate_test.rb:373-374`). No corpus, no trajectory, no holdout partition, and no scorer were involved.

**What does not hold — rollback discards without proof.** See **F23-COR-02**. `rollback` targets `current.rollback_target.snapshot_digest` (`promotion.rb:88-89`), i.e. the snapshot that preceded the heuristic epoch, not the heuristic's own bytes. The `injection_digest` it returns (`:133`) is computed over the *restored* snapshot, so `assert_rolled_back_byte_identical!` proves only that the restored bytes equal the target — never that they equal "heur.A's epoch removed". No code marks the superseded heuristic row `:rolled_back`: `BehaviorTransition::STATUSES` lists the symbol (`behavior_transition.rb:22`) and the Data member exists (`:40`), but a repo-wide grep finds no writer for it outside `CandidateLifecycle#stage_result_phase`'s unrelated phase map (`candidate_lifecycle.rb:227`).

**What does not hold — a partially completed activation is not retried and not rolled back.** See **F23-REL-01**.

**Measured boundary (correctness, not a defect).** `evaluation_report.rb:188-191` refuses `passed > total` but nothing compares the two arms' `total`, and `verify!` never reads the per-task `outcomes` map that the harness writes. Probe `/tmp/f23_probe_gate.rb`: a hand-built report with **no** `outcomes` key at all verifies and decides normally. `total` is a self-reported integer. This is `info` (**F23-INF-02**) rather than `major` because the seal means a fabricated report must come from the evaluator's own partition, which `tamoz-evals` (a non-production gem) owns — so the real exposure is the missing absolute-score floor below, not arm-total tampering.

## Lens: security and authority

**What holds.**

- **The human gate is not hardcoded to pass and cannot be dropped by a typo.** `assert_human_gate!` (`evaluation_report.rb:220-235`) refuses an unknown class (`:222-225`) and requires `HUMAN_GATE_PREFIX = "human:"` plus at least one non-prefix character (`:50`, `:228-233`). `HEURISTIC_GATE_CLASSES = %w[prompt_hierarchy]` is a non-empty, declared class (`:48`), and the heuristic *is* injected into the planning prompt (`Heuristic#snapshot` `heuristic.rb:75-82` → `BehaviorTransition` snapshot → `session_planning_context.rb:557-564`), so the class is truthful and the gate is **not vacuous by omission**. Probe: `nil`, `"auto-approved"`, and `"human:"` are all refused for all 8 classes.
- **No bypass flag in this gem.** Repo-wide grep: the only production caller of `TransitionRegistry#record` inside this gem is `promotion.rb:343`; `gems/tamoz-approval/policy/*` contains **zero** occurrences of `improvement`, `heuristic`, `candidate`, or `promotion` (grep), and there is no action id in `base.yaml` for this path. Nothing here can flip an approval verdict.
- **Holdout isolation is enforced by the toolbox capability, not by convention.** Probes `/tmp/f23_probe_isolation.rb` and `/tmp/f23_probe_leak.rb`: absolute holdout path → `ToolPolicyError: path must be relative to the workspace root`; `../protected/holdout/<file>` via `read_file`/`list_directory`/`search_text` → `ToolPolicyError: path escapes the workspace root`. The confinement is `PathResolver#reject_lexical_escape!` / `#reject_realpath_escape!` (`path_resolver.rb:100-111`), which the generator does not own.
- **Generator capability floor.** `Generator#initialize` refuses a mutation-capable toolbox (`generator.rb:47-50`) and an over-broad grant at construction (`:63-74`) — *before* the grant is declared in `protected_paths`. Probe: a generator with `protected_paths: []` and `..` traversal is still refused by the grant.

**What does not hold — the human gate is an unbound string, and the approval policy data seam is not on the path.** See **F23-SEC-01** (the row's critical finding). `assert_human_gate!` takes `(gate_classes:, evidence:)` and nothing else (`evaluation_report.rb:220`) — the candidate digest, the report seal, the snapshot digest, and the actor are all absent from its signature. Probe `/tmp/f23_probe_human.rb`: `"human:anybody"`, `"human:1"`, `"human:x"`, `"human:the_candidate_itself"` are **all accepted**, and the identical string `"human:operator-1"` passes the gate for two structurally different candidates with different report seals.

`assert_not_self_promoting!` (`promotion.rb:240-262`) is genuinely stronger — it refuses actor == `generator_principal`, actor == `evaluator_principal`, actor == `candidate.heuristic_id`, actor == `candidate.digest`, and refuses a report whose `generator_principal` disagrees with the candidate's (`:257-261`). But it compares the same `String(actor)` the caller supplied (`:241`), so it raises the cost of self-promotion from "type a prefix" to "type a prefix and a name that differs from two strings in a document you are also supplying". It does not reach the approval seam either.

`CandidateLifecycle` is materially tighter on binding — `approval_digest` covers the proposal, candidate, candidate-content, operation, actor, and authority digests (`candidate_lifecycle.rb:29-43`), `approve!` requires the exact digest **and** `evidence == "human:#{actor}"` (`:92-97`), and `validate_actor!` refuses the creator (`:164-169`). It is still not approval-policy-backed: the gem has no reference to `Tamoz::Approval` (grep).

**Adjacent finding (assigned here, own seam).** `CandidatePolicy#policy_without_surface` (`candidate_policy.rb:93-95`) excludes `allow_changes` from the policy comparison, combined with the `return false if !current['allow_changes'] && candidate['allow_changes']` guard on line 86. The strongest field in the policy — whether the write tools exist at all — is therefore compared by a hand-rolled boolean guard rather than by the digest machinery used for the other protected fields. See **F23-SEC-03** (minor).

## Lens: reliability and durability

**What holds.**

- **Every lifecycle stage is a durable, separately-identified effect.** `run_effect` (`candidate_lifecycle.rb:183-198`) routes all four stages through `EffectDispatcher.run` with distinct `call_index` values (`:13`) and a `reconcile` callable, satisfying `validate_run_contract!`'s requirement that a `:reconcilable` effect have a reconciler (`effect_dispatcher.rb:69-76`). This is **not** an FX-rule violation: this gem makes **no model call at all** — `generator.rb:3` requires nothing, `generate` is pure ranking over `Toolbox#execute("read_file", …)` results, and the regression probe over 14 candidate tests ran in 0.13 s with no provider configured. `tamoz-agent-improvement.gemspec:14-17` declares no model/provider dependency.
- **Unknown outcomes block the next phase.** Probe (`test/agent_improvement_lifecycle_test.rb:49-64`, run green): `apply` → `:unknown` sets `phase = :unknown` and `restart_health_verify!` raises `CandidateUnknownError` (`candidate_lifecycle.rb:223-224,177-181`).
- **Promotion never activates in place.** `record_promotion` returns `"activated" => false` (`promotion.rb:359`) and every promotion test asserts `refute follow_up.fetch("activated")` (`test/improvement_candidate_test.rb:625`).
- **Rollback is refused rather than approximated** when the prior snapshot digest is empty (`promotion.rb:88-94`) or unreadable (`:96-101`).
- **Rollback idempotence is content-addressed.** `candidate_digest` for a rollback digests `["rollback", transition_id, before, target_digest]` (`:113-115`), so `transition_id = sha256(kind + candidate_digest)` (`behavior_transition.rb:147-149`) makes a repeated rollback the same row.
- **One-live-heuristic serialization is partly structural.** `TransitionRegistry#record` refuses when `pending_transition_id` is set (`transition_registry.rb:69-70`), and the control-record CAS refuses a concurrent second pipeline (`:87-94`). Probe `/tmp/f23_probe_stale.rb`: recording two competing promotions from one baseline yields `BehaviorTransitionClaimConflictError` on the second, and a rollback cannot even be recorded while a promotion is pending.

**What does not hold — a partially completed activation is unrecoverable.** See **F23-REL-01**.

**What does not hold — the rollback lane is closed off by a superseding epoch, permanently.** Probe `/tmp/f23_probe_wipe2.rb`: with `session/3` = heuristic and `session/4` = a later `kind: :wisdom_promotion`, `Promotion#rollback` raises `RollbackIntegrityError: the active transition <tx> is not a heuristic promotion` (`promotion.rb:82-86`), while `assert_one_live_heuristic!` (`:304-331`) still counts the `session/3` row as live. `Promotion` exposes no `rollback_hidden`/`rollback_to(id)` operation. The combined state — a live heuristic epoch that `rollback` refuses to undo and that blocks every future promotion — is reachable from the public API of this gem plus the shared P11-W registry, and is not represented by any test. In the intended single-lane usage (`test/improvement_candidate_test.rb:558-577` seeds the baseline, then the heuristic is always the newest epoch) it cannot occur, which is why it is `info` (**F23-INF-01**) rather than `major`: the trigger is a competing promotion through the shared seam, which is P11-W's lane, not this row's.

**Measured, not a finding.** A `:failed` effect is terminal at both journal implementations — `EffectJournal#replay_decision` maps any non-`:succeeded` terminal status to itself (`effects_journal.rb:114-118`), and the durable `EffectPreparation#prepare` maps `'failed'` to `action = :failed` (`effect_preparation.rb:158-159`). So the retry in F23-REL-01 cannot double-apply; the harm is a stuck candidate, not a duplicate effect.

## Lens: observability and evidence

**What holds.** The proof surface is unusually complete for a producer gem.

- **The evidence resolver is checked for present-but-unresolvable.** `assert_evidence_resolves!` (`promotion.rb:209-227`) refuses a non-callable resolver (`:210-213`), refuses a non-Hash resolution (`:216-220`), re-verifies the resolved artifact through the same `verify!` (`:222`), and refuses a seal mismatch (`:223-226`). Probe: `nil` from the resolver raises `EvaluatorTamperError` with the message "a candidate cannot supply its own evaluation evidence".
- **The decision is recorded, not just gated.** `record_promotion` returns `decision` alongside the transition (`:356`), and the transition row carries `promotion_evidence_digest` and `human_gate_evidence` (`:349-350`), both persisted by the shared registry (`behavior_transition.rb:73-74`).
- **Byte-level post-activation proof exists and is over rendered bytes.** `assert_rolled_back_byte_identical!` (`:142-168`) compares the delimited injection region, not record values (`:156-161`).
- **The monitor reuses the promotion gates verbatim.** `Monitor#initialize` calls `EvaluationReport.verify!` and `decide` (`monitor.rb:34-35`) and `observe` refuses a report over a different `paired_task_digest` as `EvaluatorTamperError` rather than downgrading it to a metric (`:51-57`). A broken seal propagates (`:52`), which is the right call.
- **Provenance is required, not optional.** `Promotion#promote` calls `provenance.assert_complete!` (`promotion.rb:56`) and `assert_provenance_binds!` (`:57`) refuses a provenance describing a different candidate, snapshot, report, principals, or rollback baseline (`:267-295`).

**What does not hold.** The recorded `human_gate_evidence` is an unverifiable string (`human:operator-1` in every test, e.g. `test/improvement_candidate_test.rb:542`), so the durable audit trail cannot distinguish "an operator approved this exact candidate through an approval flow" from "the promoter typed a prefix". That is the observability half of F23-SEC-01 and is not filed separately.

**Info.** The `promotion_evidence_digest` written into the transition (`promotion.rb:349`) proves *which bytes* the promoter presented to the resolver, not *that a distinct evaluator partition held them*. The distinction is invisible in the row.

## Lens: scalability and resource bounds

**What holds — every loop in the generation/selection path is bounded at the seam that owns it.**

| Bound | Value | Enforced at |
|---|---|---|
| candidates per generator phase | 1 | `generator.rb:29,102-105` |
| trajectories per generation | 256 | `generator.rb:35,107-109` |
| minimal support / trials / confidence | 3 / 3 / 0.8 | `generator.rb:32-34,151-154` |
| insertions per plan | 8 | `heuristic.rb:39,129` |
| statement bytes | 512 | `heuristic.rb:38,60-62` |
| live heuristics | 1 | `promotion.rb:28,304-331` |
| transition rows scanned by the liveness gate | 64 | `promotion.rb:305` |
| behavior snapshot bytes | 4096 | `behavior_transition.rb:20`; enforced `transition_registry.rb:267` |
| effect attempts | 3 | `effect_dispatcher.rb:142` |
| effect stages, each distinct | 4 | `candidate_lifecycle.rb:13` |
| human-gate classes / gate classes | 8 / 1 | `evaluation_report.rb:40-43,48` |
| path argument bytes | 4096 | `path_resolver.rb:24,43` |

**What stops an unbounded generation loop:** `generate` increments `@generated` **before** returning (`generator.rb:118`) and refuses the next call when `@generated >= 1` (`:102-105`), and `strongest_candidate` returns `nil` rather than a weaker candidate when the floor is missed (`:113,116,151`). There is no `while`/`loop`/`retry` anywhere in the gem (grep). The limit is per-instance, not per-process or per-tenant — see **F23-SCA-01** (minor).

**Correctness under truncation / bounded output:** `toolbox.execute("read_file", …)` bounds output at the tool layer; `Generator#read_trajectory` splits on the `content:\n` delimiter and calls `Tamoz::Core.parse_json_strict` (`generator.rb:90-93`), so a truncated body raises rather than producing a partial trajectory. `Heuristic#apply` on a non-Array returns the input unchanged (`heuristic.rb:115`) and skips non-Hash entries (`:121-124`), so a malformed plan degrades to a no-op rather than an exception.

**Not evidenced.** No load, soak, or concurrency measurement exists for this gem, and the one multi-writer scenario that matters is owned by `Memory::TransitionRegistry` (probed above for the two-writer case only). What would prove it: a concurrent two-promotion test over one SQLite engine asserting exactly one `:activated` heuristic row.

## Lens: maintenance and architecture

**What holds.**

- **One activation mechanism, honestly declared.** The class comment (`promotion.rb:11-23`) states that every state change goes through the P11-W-owned `TransitionRegistry`, and that is literally true: the only `record` call in the promotion path is `promotion.rb:343`. `BehaviorTransition::KINDS` already contains `:heuristic_promotion` (`behavior_transition.rb:21`), so this gem added no engine.
- **The seal and the gates live in production code, the runner in `tamoz-evals`.** `evaluation_report.rb:12-17` documents that `tamoz-evals` calls `seal` and `tamoz-agent` calls `verify!`, and that no production gem depends on `tamoz-evals`. Verified: the gemspec declares neither.
- **Vocabulary is consistent** with the repo's `validate` / `verify` / `assert` discipline: `assert_bounded!`, `assert_complete!`, `assert_isolated!`, `assert_evidence_resolves!`, `assert_not_self_promoting!`, `assert_provenance_binds!`, `verify!`, `validate!`.
- **Errors are typed and specific** — 9 classes in `errors.rb`, each naming the contract it enforces (`:17-57`), and policy/integrity failures propagate rather than becoming values (`:15-16`).

**What does not hold — the doc contradicts the code on the exact point the row was asked to check.** See **F23-MNT-01** (major). `documentation/limitations.md:88-94` states that for skills "**There is no install, update, or self-improvement pipeline**: no quarantine staging, no provenance checks on a downloaded artifact, no atomic activation of a new-digest". The gem implements `scope: 'skill'` (`candidate_proposal.rb:13`), a provenance record with content-addressed artifact digests (`provenance.rb:49,121-124`), a staged lifecycle with `apply → restart_health_verify → activate` under durable effects (`candidate_lifecycle.rb:105-125`), and an atomic digest activation via `adoption_registry.activate(@proposal.profile_id, @proposal.to_digest)` (`:239`). I answered the row's question directly: **the gem promotes nothing that is installed anywhere** — it records a `Profile::Transition` (`candidate_proposal.rb:60-65`) or an adoption-registry entry, and `promote!` returns `'activated' => false` (`:66`). So the *limitations* claim holds for the executable artifact (a skill tree on disk is never written), while the *design/README* claims of a candidate lifecycle do not hold as wired code. The contradiction is in the documentation pair, and it is fixed by one sentence, not by new machinery.

**Adjacent, minor.** `tamoz-agent-improvement.gemspec:14-17` declares no `tamoz-approval` dependency while `promotion.rb`, `candidate_proposal.rb`, and `candidate_lifecycle.rb` all gate on a `human:` artifact whose meaning lives in the approval domain. That is the ownership half of F23-SEC-01. Filed as **F23-MNT-02** (minor) because the dependency omission is itself the symptom, not a second defect.

## Tests and contracts

All commands run one file per command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`.

| Command | Result |
|---|---|
| `ruby -Itest test/improvement_candidate_test.rb` | **14 runs, 284 assertions, 0 failures, 0 errors, 0 skips** (0.13 s) |
| `ruby -Itest test/agent_improvement_lifecycle_test.rb` | **6 runs, 13 assertions, 0 failures, 0 errors, 0 skips** (0.006 s) |
| `ruby -Itest test/memory_engine_test.rb` | **26 runs, 164 assertions, 0 failures, 0 errors, 0 skips** (0.57 s) |
| `ruby -Itest test/public_api_test.rb` | **3 runs, 1051 assertions, 0 failures, 0 errors, 0 skips** (0.002 s) |
| `ruby -Itest test/agent_phase4_capability_test.rb` | **7 runs, 31 assertions, 0 failures, 0 errors, 0 skips** (0.009 s) |

`ls test/ | grep -iE "improve|candidate|promot"` → exactly two files: `agent_improvement_lifecycle_test.rb`, `improvement_candidate_test.rb`. Both were run. `grep -rln "Improvement" test/` adds `agent_phase4_capability_test.rb` and `public_api_test.rb`, both run above.

**What the suite proves.** Every gate is proven by attempting the violation, not by inspection: provenance axis-by-axis (`:94-130`), boundary lies (`:132-159`), unverified sources and self-evaluation (`:161-206`), holdout reads refused at the capability boundary including relative traversal (`:237-284`), over-broad grant refused (`:286-311`), insert-only and mutation refusal (`:313-351`), arm pairing (`:355-386`), six distinct evaluator-tamper attempts including a **re-sealed** forged body (`:388-441`), self-promotion (`:443-467`), all 8 human-gate classes plus a misspelled class (`:469-502`), rollback byte-identity (`:635-663`), and the monitor's different-task-set refusal (`:667-706`).

**What the suite does not test (each is the "not found" behind a finding above).**

- No test constructs an evaluation report with this gem's own public API, so F23-COR-01 is untested: `grep -n "sealed(" test/improvement_candidate_test.rb` matches only `:421,429,437` (re-sealing a **real** harness report) and `:680,702` (monitor fixtures derived from a real report).
- No test exercises the `verify!` path with a promoter-supplied resolver that has never seen a real evaluator partition: the test resolver at `:534-538` returns the report it was handed.
- No test asserts that the human-gate artifact is bound to the candidate digest, because `assert_human_gate!` cannot express that assertion (`evaluation_report.rb:220`).
- No test covers `partial completion of `activate`` — `agent_improvement_lifecycle_test.rb:84-107` drives the happy path only, and `:49-64` covers `:unknown`, not `:failed`.
- No test covers a rollback after a competing epoch landed on top of the heuristic.

**Not run (reason).** `rake ci` / `rake ci_full` (excluded by the brief). The eval-runner suites (`test/benchmark_harness_test.rb`, `test/experience_harness_test.rb`) were not run: they are not this row's surface and the paired evaluation was exercised through `improvement_candidate_test.rb`, which drives `Harness::HeuristicPairedEvaluation` directly.

## Findings

### F23-SEC-01 — The promotion human gate is an unbound string; the approval policy data seam is not on the path (critical)

| Field | Content |
|---|---|
| Severity | `critical` |
| Confidence | `high` |
| Status | `open` |

**Observable behavior at risk.** `Improvement::Promotion#promote` refuses to record a behavior-epoch transition only when a caller-supplied Ruby `String` fails to start with `"human:"` and have a suffix, or is empty. Any such string promotes any candidate, and the artifact is bound to nothing — not the candidate digest, not the report seal, not the snapshot digest, not the promoting actor. The transition row then equates the only live heuristic in v1 with an unverified assertion.

**Owning seam.** `Improvement::EvaluationReport.assert_human_gate!` (`evaluation_report.rb:220-235`), consumed by `Promotion#promote` (`promotion.rb:51`) and `CandidateProposal#promote!` (`candidate_proposal.rb:45-48`).

**Source evidence.**
- `gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/evaluation_report.rb:220` — signature is `assert_human_gate!(gate_classes:, evidence:)`; no digest, no actor, no report.
- `.../evaluation_report.rb:228-233` — the entire check is `text.start_with?(HUMAN_GATE_PREFIX) && text.length > HUMAN_GATE_PREFIX.length`.
- `.../evaluation_report.rb:50` — `HUMAN_GATE_PREFIX = "human:"`.
- `.../promotion.rb:51` — `EvaluationReport.assert_human_gate!(gate_classes:, evidence: human_gate_evidence)` with `human_gate_evidence:` a bare keyword parameter (`:42`).
- `.../promotion.rb:350` — the string is persisted verbatim as `human_gate_evidence:` on the transition row.
- `.../candidate_proposal.rb:45-48` — the same prefix test, no digest.
- `gems/tamoz-agent-improvement/tamoz-agent-improvement.gemspec:14-17` — no `tamoz-approval` dependency; grep finds no `Tamoz::Approval` reference anywhere in the gem.
- `gems/tamoz-approval/policy/base.yaml` — grep for `improvement|heuristic|candidate|promotion` returns **zero** matches; the policy tiers are `read/workspace_write/local_execute/network/external_publish/destructive` with no action id for this path.
- Contrast, same repo: `gems/tamoz-agent-memory/lib/tamoz/agent/memory/wisdom.rb:105-123` also only prefix-checks the evidence, but pairs it with `human_gate.fetch(:required) == true` for sensitive classes (`:109-113`). Neither reads approval state.

**Probe.** `/tmp/f23_probe_human.rb`:
```
"human:anybody" -> accepted=true
"human:1"       -> accepted=true
"human:x"       -> accepted=true
"human:the_candidate_itself" -> accepted=true
assert_human_gate! parameters: [[:keyreq, :gate_classes], [:keyreq, :evidence]]
gate passes for candidate A with 'human:operator-1': true
gate passes for candidate B with 'human:operator-1': true
```
`/tmp/f23_probe_reverify.rb`: promotion #1 recorded with `human:operator-1`; a second, structurally different report (`forged2 seal differs? true`) reuses the identical artifact string with no refusal.

**Test/contract evidence.** `test/improvement_candidate_test.rb:469-502` proves the gate refuses `nil`, `"auto-approved"`, `"human:"`, and a misspelled class — i.e. it proves exactly the prefix check that is insufficient. No test asserts a digest binding, because the API cannot express one. `test/agent_improvement_lifecycle_test.rb:27-47` proves `CandidateLifecycle` binds the digest (`approval_digest`), which is why the lifecycle path is materially tighter and the promotion path is the exposed one.

**Scanner signal.** `grep -rn "human_gate_evidence"` shows every production call site passing a string literal; no producer derives it from an approval decision.

**Independent judgment.** I confirmed the gate is not vacuous in the "empty class list" sense (the class list is a non-empty constant and the heuristic does touch the prompt) and that no bypass flag or hardcoded verdict exists in this gem. I rejected the narrower reading that the gate is "human-gated because a human must type the prefix": a value the promoting caller composes, that no component validates against approval state, and that is not bound to the artifact it authorizes, is an assertion, not a gate. This is the row's security seam and it is the highest-severity item.

**Root cause (five whys).**
1. A promotion can be recorded with only an assertion of human approval. — Because the gate compares a string prefix.
2. The gate compares a string prefix. — Because its only inputs are `gate_classes` and `evidence`; there is no digest or actor to bind against.
3. There is no digest to bind against. — Because the approval artifact is a free-form `String` on the caller's keyword interface rather than a resolved policy decision object.
4. It is a free-form string. — Because this gem never enters the approval domain: it declares no `tamoz-approval` dependency and contains no reference to `Tamoz::Approval`.
5. The approval domain was never made a dependency. — Because "human-gated" was implemented as a schema convention in a gem whose declared deps are only `tamoz-agent-kernel` and `tamoz-agent-memory`, so the repo's "approval policy is data too" contract (AGENTS.md) had no seam here to attach to. **Controllable cause:** the missing approval seam at this gem's promotion boundary. **Contract that would prevent recurrence:** a promotion's human gate must be a resolved approval-policy decision whose evidence is bound to the exact candidate digest and report seal.

**Recommendation (smallest credible action at the existing seam).** Extend `EvaluationReport.assert_human_gate!` to take the artifact it authorizes — e.g. `assert_human_gate!(gate_classes:, evidence:, digest:)` — and require the evidence to be the already-existing `CandidateLifecycle.approval_digest` (`candidate_lifecycle.rb:29-43`), which does cover proposal, candidate, candidate-content, operation, actor, and authority digests. `Promotion#promote` already has `candidate.digest` and `EvaluationReport.seal(body)` in hand at the call site (`promotion.rb:49-51`), so the binding is one argument and one comparison; the approval-policy lookup itself belongs to `tamoz-approval` and should be a follow-up owned by that gem, not invented here.

**Disposition.** Open — coordinator to decide whether the binding lands inside this gem (one extra argument) or waits on an approval-policy action id.

### F23-COR-01 — A promotion can be recorded from a forged-but-correctly-sealed report produced inside this gem, with the resolver supplied by the promoter (major)

| Field | Content |
|---|---|
| Severity | `major` |
| Confidence | `high` |
| Status | `open` |

**Observable behavior at risk.** `EvaluationReport.seal`, `EvaluationReport.paired_task_digest`, and the seal-verification path are all `module_function`s of this gem, so a caller can construct a fully-verifying report from public values alone; `Promotion#promote` then satisfies `assert_evidence_resolves!` with a resolver the same caller supplies. The resulting promotion is indistinguishable, in the transition row, from one backed by a real evaluator run: identical `promotion_evidence_digest` shape, identical `decision.passed`, identical `activated => false`.

**Owning seam.** `Improvement::Promotion#assert_evidence_resolves!` (`promotion.rb:209-227`) and the `module_function` seal surface at `evaluation_report.rb:59-70,169-173`.

**Source evidence.**
- `.../evaluation_report.rb:3-5` — `require "digest"`, `require "json"`; no keyed material.
- `.../evaluation_report.rb:59` — `module_function` governs the whole module body, so `seal`, `paired_task_digest`, `decide`, and `assert_human_gate!` are all publicly callable.
- `.../evaluation_report.rb:63-70` — `seal(body)` = `Tamoz::Core.digest(SEAL_DOMAIN, body)`; `sealed(body)` is public and returns a verifying artifact.
- `.../evaluation_report.rb:52-55` — the six required keys are `format_version`, `candidate_digest`, `generator_principal`, `evaluator_principal`, `paired_task_digest`, `development`, `holdout` — every one a public value.
- `.../promotion.rb:44-45` — `evidence_resolver:` is a caller-supplied callable; `gate_classes:` is a caller-supplied keyword.
- `.../promotion.rb:209-227` — `assert_evidence_resolves!` refuses a non-callable (`:210-213`) and a non-Hash result (`:216-220`), then compares seals (`:222-223`). A resolver that returns the caller's own report satisfies it perfectly.
- `.../promotion.rb:200-208` — the code comment already concedes the mechanism: "the seal is a digest and not a keyed MAC … anyone able to CONSTRUCT a report could also seal it". The comment asserts that resolution is what makes the gate real; at this seam, resolution is a parameter.

**Probe.** `/tmp/f23_probe_promote.rb`, using only public API plus an in-memory `BehaviorTransition` history (no corpus, trajectory, holdout, or scorer):
```
baseline active: tamoz.agent.session/2
!! PROMOTED with a forged report + promoter-supplied resolver: activated=false tx=bfe6c4a00ec37bff
   reserved_version=2 decision={"development_margin"=>8, "holdout_margin"=>8, "passed"=>true, "reasons"=>[]}
```
The same corpus produces `development_margin => 2, holdout_margin => 1` for the real harness (`test/improvement_candidate_test.rb:373-374`). `/tmp/f23_probe_vacuous.rb` confirms a report with **no** per-task `outcomes` key verifies and decides normally.

**Test/contract evidence.** `test/improvement_candidate_test.rb:388-441` is a strong six-case tamper suite, and cases (4) and (5) expressly handle re-sealing — but every forged body is derived from a **real** harness report (`:418`, `:426`), so the suite never exercises construction from scratch. `:534-538` is the production-shaped resolver the tests use; it returns the report it was handed. Not found: a negative test asserting that a report not written by the evaluator's partition cannot promote.

**Scanner signal.** `grep -n "sealed(" test/improvement_candidate_test.rb` → `:421,429,437,680,702`, all derived from harness output.

**Independent judgment.** I confirmed the seal is genuinely strong against *editing* (a single per-task outcome flip breaks it, `:393-408`) and that `assert_paired!` re-derives the pairing digest rather than trusting it (`evaluation_report.rb:157-163`), which I verified by probe. I therefore rejected the framing that the seal is broken: the defect is that *creating* a valid seal requires no privileged material, so the seal cannot carry the trust that `Promotion` places on it once the resolver is also a parameter.

**Root cause (five whys).**
1. A forged report promotes. — Because the seal is recomputable by the caller.
2. The seal is recomputable. — Because `seal` is a public `module_function` over canonical bytes with no keyed input.
3. It is public and unkeyed. — Because the seal was designed as an integrity check against *editing a stored artifact*, not as an authentication of *who produced it*.
4. The role of authentication was pushed to resolution. — Because `tamoz-evals` owns the evaluator partition and this gem must not depend on it.
5. The resolution step was left as a parameter instead of a contract. — Because nothing in the required dependency set can *be* the evaluator's protected partition, so `evidence_resolver:` became an injection point the promoting caller can satisfy. **Controllable cause:** promotion trusts a caller-supplied resolution result instead of a resolving authority the promoting caller cannot supply. **Contract that would prevent recurrence:** a promotion must prove the report came from an authority the promoter does not control.

**Recommendation (smallest credible action at the existing seam).** Keep the seal and keep `assert_evidence_resolves!`, and narrow *who* may supply the resolver: have `Promotion.new` take the resolver as a construction-time collaborator bound to the evaluator principal (`promotion.rb:30-33`), and refuse a resolver whose resolved artifact names a `generator_principal`/`candidate_digest` other than the candidate's — or, more simply, have this gem derive the resolver from the existing `BehaviorTransition::EVIDENCE_NAMESPACE` (declared but unused by this gem, `behavior_transition.rb:16`), which is the durable seam already shaped for exactly this artifact. Both are one-argument changes; nothing new is required.

**Disposition.** Open — this is the row's second security-adjacent item and should be coordinated with F23-SEC-01, which shares the same "trust a caller-supplied value" root.

### F23-COR-02 — Rollback restores the pre-promotion epoch and never marks the heuristic epoch undone; the byte-identity proof is relative to the rollback's own target (major)

| Field | Content |
|---|---|
| Severity | `major` |
| Confidence | `high` |
| Status | `open` |

**Observable behavior at risk.** `Promotion#rollback` does not undo the heuristic epoch and revert to the state immediately before it; it records a *new* epoch whose snapshot is `current.rollback_target.snapshot_digest` — the snapshot that preceded the heuristic. Because the allocator only moves forward (`successor_version`, `promotion.rb:189-197`), the version after a rollback is strictly greater than the version the heuristic introduced, so `assert_forward!` (`:333-340`) and `assert_rolled_back_byte_identical!` (`:142-168`) both pass while the served region is the pre-promotion bytes. The heuristic transition row keeps `status: activated` and `rolled_back_at: nil`.

**Owning seam.** `Improvement::Promotion#rollback` (`promotion.rb:75-135`).

**Source evidence.**
- `.../promotion.rb:82,88-89` — `current = @registry.transition(active_transition_id)`; `target_digest = current.rollback_target["snapshot_digest"]`.
- `gems/tamoz-agent-memory/lib/tamoz/agent/memory/transition_registry.rb:104` — `rollback_target: { 'behavior_version' => before, 'snapshot_digest' => control.active_snapshot_digest }`, i.e. the **prior** epoch by construction.
- `.../promotion.rb:109,117-122` — the rollback records `behavior_snapshot: snapshot` (the prior bytes) with `behavior_version_after: successor_version(before)`.
- `.../promotion.rb:133` — `"injection_digest" => self.class.injection_digest(snapshot)`, computed over the *restored* snapshot.
- `.../promotion.rb:142-161` — the assertion re-reads the active snapshot and compares it to `expected_snapshot_digest` and `expected_injection_digest`, both of which the caller obtained from the rollback result. The comparison is target-relative.
- `.../promotion.rb:304-331` — `assert_one_live_heuristic!` excludes a candidate from "live" only when a row with `candidate_id` `"rollback.<candidate_id>"` exists (`:306-314,322`), i.e. the liveness bookkeeping keys on the rollback *row*, not on the heuristic row's own `status`.
- `gems/tamoz-agent-memory/lib/tamoz/agent/memory/behavior_transition.rb:22,40` — `STATUSES` declares `:rolled_back` and `Transition` carries `rolled_back_at`; grep finds no writer for either outside `status: :activated` in `activate_row` (`transition_registry.rb:352-372`).

**Probe.** `/tmp/f23_probe_rollback_scope.rb`:
```
active after promotion: version=tamoz.agent.session/3 snapshot=sha256:9dd7be6575f
heuristic row rollback_target: {"behavior_version"=>"tamoz.agent.session/2", "snapshot_digest"=>"sha256:8013ffc2..."}
row status now: activated
```
`/tmp/f23_probe_stale.rb` shows the same shape for the one-epoch case.

**Test/contract evidence.** `test/improvement_candidate_test.rb:635-663` asserts `byte_identical` after a rollback, but the expected digests come from the rollback it just performed (`:651-652`), so the test pins target-relative identity, not "the heuristic's bytes are gone". `:579-633` asserts the follow-up promotion and `reserved_version == 4`, which is exactly the forward-only allocator behaviour described above. Not found: a test asserting the heuristic row is terminal after rollback, or that the restored region equals the epoch *before the heuristic*.

**Scanner signal.** `grep -rn "rolled_back"` across both gems returns only the constant, the Data members, this gem's phase map, and the liveness-gate filter — no writer.

**Independent judgment.** I confirmed the *bytes* are right: a rollback does restore the prior region and the proof compares rendered bytes rather than record values, which is better than the record-value comparison the doc-comment warns about. I rejected "rollback is broken": in the intended single-heuristic-lane usage the target and the pre-heuristic epoch coincide, and the served region is correct. The gap is in the *claim* and in the *ledger*: the heuristic epoch's row is never closed, so "what is live" is derived from the existence of a differently-shaped row rather than from the transition's own status, and the byte-identity proof cannot distinguish "restored the prior epoch" from "removed the heuristic".

**Root cause (five whys).**
1. A rolled-back heuristic row still reads `activated`. — Because `activate_row` only ever writes `:activated` and nothing writes `:rolled_back`.
2. Nothing writes `:rolled_back`. — Because the rollback is modelled as a fresh forward transition and the *undone* row is not updated.
3. The undone row is not updated. — Because the design treats the rollback as a new epoch that supersedes rather than a mutation of the old row (DR-1 §7), which is defensible for the allocator.
4. But the liveness gate then needs another way to know a candidate is not live — and it found one, via a `rollback.` prefix scan.
5. The prefix scan is a derived proxy for a status the record already has a field for. — **Controllable cause:** the transition row's own terminal status is not used as the source of truth for "live". **Contract that would prevent recurrence:** a rollback must mark the transition it undoes terminal, and byte-identity must be stated against the epoch being removed.

**Recommendation (smallest credible action at the existing seam).** Two lines at `promotion.rb:117-126`: pass the undone `transition_id` into the recorded rollback (or set it on the row immediately after) and have `TransitionRegistry` write `status: :rolled_back, rolled_back_at:` on that row, then read "live" from `status` in `assert_one_live_heuristic!` (`:315-325`) instead of the `rollback.` prefix scan. Keep `assert_rolled_back_byte_identical!` but state it against the pre-heuristic snapshot digest captured *before* the promotion, so the proof is not relative to the rollback's own output.

**Disposition.** Open — overlaps `FINDINGS.md:13` `CF04-REL-01` in domain (effect/transition terminal-state selection) but not in seam; the coordinator should record the overlap explicitly rather than merging.

### F23-REL-01 — A partially completed activation is not retried and is not rollback-able; the candidate is stranded in `:verified` (major)

| Field | Content |
|---|---|
| Severity | `major` |
| Confidence | `medium` (the in-gem half is directly probed; the durable half is read from two journal implementations, not executed end to end) |
| Status | `open` |

**Observable behavior at risk.** If `activate!`'s `perform` raises after the underlying transition was recorded, `EffectDispatcher` records the attempt terminal `:failed` and returns `Outcome(status: :failed)`; `run_effect` then sets `@phase` to `stage_result_phase(:activate, :failed)`, which returns the *current* phase `:verified`. A retry of `activate!` reaches `EffectDispatcher.run` with the same `call_index` (4102) and the same request, the journal replays `:failed`, and `perform` is never called again. The candidate is permanently `:verified`: it can neither activate nor roll back, because `rollback!` requires `phase == :active` (`:128`).

**Owning seam.** `Improvement::CandidateLifecycle#stage_result_phase` (`candidate_lifecycle.rb:223-228`) and `CandidateLifecycle#activate!` (`:120-125`).

**Source evidence.**
- `.../candidate_lifecycle.rb:120-125` — `activate!` requires `:verified`, takes `approval_for(:apply)`, and runs stage `:activate`.
- `.../candidate_lifecycle.rb:187-196` — `outcome = @effect_runner.run(…) { perform.call }`; the return value is a status-bearing outcome; `@phase = stage_result_phase(stage, outcome.status)`.
- `.../candidate_lifecycle.rb:223-228` — `return :unknown if status == :unknown; return @phase unless status == :succeeded`. `:failed` therefore falls through to `@phase`.
- `.../candidate_lifecycle.rb:128-132` — `rollback!` calls `require_phase!(:active, :rollback)`; `:verified` fails `require_phase!` (`:177-181`).
- `.../candidate_lifecycle.rb:236-245` — `profile_activation`'s lambda calls `adoption_registry.activate(...)` **then** `@proposal.promote!(registry: transition_registry, …)`, so a raise in `promote!` leaves the adoption registration in place with no transition.
- `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:179-203` — a raised `Tamoz::Tools::ToolError` is caught and routed to `complete_exceptional_attempt(..., status: :failed)` (`:184-193`); the outcome is `recorded_outcome(:failed, …)` (`:162-172`).
- `gems/tamoz-agent/lib/tamoz/agent/runtime/effects_journal.rb:114-118` — `replay_decision` maps a terminal non-`:succeeded` status straight back to that status, so a replay returns `:failed` without re-executing.
- `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_preparation.rb:158-159` — `when 'failed', 'abandoned' then action = :failed`.
- `.../effect_preparation.rb:185-214` — only the `'prepared'` and the `read_only`/`idempotent` `'running'` branches grant a fresh attempt; `:reconcilable` goes to `action = :reconcile` (`:216-227`).

**Probe.** `/tmp/f23_probe_partial.rb` with an `EffectRunner` double that returns `:failed`-shaped outcomes for a raising `perform`:
```
activate raised Tamoz::Core::ToolError: activation crashed after recording the transition
phase after a FAILED activation: :verified
```
`test/agent_improvement_lifecycle_test.rb:49-64` is the sibling case and it is handled correctly: `:unknown` → `phase = :unknown` → the next stage raises `CandidateUnknownError`. The `:failed` branch has no equivalent.

**Test/contract evidence.** `test/agent_improvement_lifecycle_test.rb` — 6 runs, 13 assertions, 0 failures, all green. It covers the happy path (`:66-107`) and `:unknown` (`:49-64`). No test drives a `:failed` outcome for any stage. Not found: a test asserting the phase after a failed `activate`.

**Scanner signal.** `grep -n ":failed" gems/tamoz-agent-improvement/` returns nothing — the gem has no branch for the status its own effect runner can return.

**Independent judgment.** I confirmed the safe half: a `:failed` effect is terminal at both journal implementations, so the retry cannot double-apply — the harm is a stuck candidate, not a duplicate effect, which is why this is `major` and not `critical`. I confirmed `:unknown` is handled correctly and deliberately. I could not execute the durable end-to-end path (no SQLite-backed effect journal is wired into `CandidateLifecycle` by any test or production caller at HEAD), so the journal half is read, not run; the in-gem half — that `:failed` leaves the phase unchanged and that `rollback!` then refuses — is directly probed.

**Root cause (five whys).**
1. A failed activation leaves the candidate unusable. — Because the phase stays `:verified` and rollback requires `:active`.
2. The phase stays `:verified`. — Because `stage_result_phase` handles `:unknown` and `:succeeded` and lumps `:failed` with "no change".
3. `:failed` is lumped with no-change. — Because the method was written against a two-outcome model (`:unknown` blocks, everything else is either done or retryable).
4. The effect runner has three failure outcomes, not two. — Because the dispatcher distinguishes `:failed` (terminal, proven not applied) from `:unknown` (ambiguous) and the lifecycle only modelled the second.
5. Only the ambiguous case was modelled. — Because "unknown must never continue" was the invariant that got designed, and "proven failure must be allowed to retry or to be abandoned explicitly" was not. **Controllable cause:** the lifecycle has no terminal state for a proven-failed stage. **Contract that would prevent recurrence:** a stage that returns a terminal non-success status must either be retryable by construction or must move the candidate to a terminal refused state that permits rollback.

**Recommendation (smallest credible action at the existing seam).** Add one branch to `stage_result_phase`: map `:failed` to a `:failed` phase (a one-word addition to the same hash pattern already used at `:227`), and let `rollback!` accept `:failed` alongside `:active` in its `require_phase!`. Two lines plus one test that drives a `:failed` outcome, which `test/agent_improvement_lifecycle_test.rb`'s `EffectRunner` can already produce via `next_status`.

**Disposition.** Open — cheapest of the four majors to close and directly testable with the existing double.

### F23-MNT-01 — `limitations.md` states there is no skill self-improvement pipeline while this gem implements `scope: 'skill'` end to end (major, documentation)

| Field | Content |
|---|---|
| Severity | `major` |
| Confidence | `high` |
| Status | `open` |

**Observable behavior at risk.** A reader of `documentation/limitations.md` concludes no skill installation/update/self-improvement path exists and treats the boundary as closed; a reader of `README.md:42` and `documentation/design/self-healing.md:13` concludes the candidate pipeline exists. Both cannot be acted on together, and the code sits between them. Concretely: the gem accepts a `skill` candidate, records content-addressed provenance and a staged durable lifecycle for it, and its own test `test/agent_improvement_lifecycle_test.rb:9-25` exercises `scope: 'config'` a single step away from the same shape.

**Owning seam.** The documentation pair — `documentation/limitations.md:88-94` against `README.md:42` + `documentation/design/self-healing.md:13` — with the code truth at `candidate_proposal.rb:13` and `candidate_lifecycle.rb:105-125`.

**Source evidence.**
- `documentation/limitations.md:88-94` — "Skills are compiled from operator-configured directories into immutable, content-addressed snapshots, and their content grants no authority. **There is no install, update, or self-improvement pipeline**: no quarantine staging, no provenance checks on a downloaded artifact, no atomic activation of a new-digest."
- `README.md:42` — "`tamoz-agent-improvement` | Bounded self-improvement: candidate provenance, heuristic generator, paired evaluation reports, **human-gated promotion/rollback**".
- `documentation/design/self-healing.md:13` — "Systemic improvement | candidate pipeline + evaluation | propose and evaluate prevention or a better rule | **only through behavior promotion**".
- `gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/candidate_proposal.rb:13` — `SCOPES = %w[profile skill config].freeze`.
- `.../candidate_lifecycle.rb:105-132` — the four stages `apply!`, `restart_health_verify!`, `activate!`, `rollback!`.
- `.../candidate_lifecycle.rb:236-245` — `adoption_registry.activate(@proposal.profile_id, @proposal.to_digest)` then `@proposal.promote!(…)`.
- `.../candidate_lifecycle.rb:60-70` + `candidate_policy.rb:20-27` — **the de-facto bound**: only `scope == 'profile'` may carry any authority-shaped content; a `skill` or `config` candidate carrying `authority` is refused (`candidate_policy.rb:24-26`).

**Test/contract evidence.** `test/agent_improvement_lifecycle_test.rb:9-25` builds a `scope: 'config'` proposal; `:109-119` asserts secret-shaped and authority-declaring candidates are refused. No test exercises `scope: 'skill'`. Not found: any test or production caller that installs, writes, or activates a skill artifact.

**Independent judgment.** I answered the row's explicit question. **The gem promotes nothing that is installed anywhere.** Nothing writes a skill tree to disk; nothing writes the runtime skill snapshot (`Tamoz::Tools::Skills::Snapshot`); the only write is a `Profile::Transition` row (`candidate_proposal.rb:60-65`) or an adoption-registry entry (`candidate_lifecycle.rb:239`), and `promote!` returns `'activated' => false` (`candidate_proposal.rb:66`). So the *limitations* claim is true about the executable artifact (a skill tree is never installed or updated) and the *README/design* claim is true only in the sense that a candidate record can be produced and evaluated — the two documents describe different halves and neither says which half. I confirmed the code-side bound that makes the limitations claim safe: non-`profile` scopes are refused any authority by `candidate_policy.rb:23-26`. This is a documentation contradiction with a real reader consequence, not a code defect, so it is `major` under BAR.md's "maintainability" band rather than `critical`.

**Root cause (five whys).**
1. Two documents contradict each other about whether the pipeline exists. — Because they describe different halves of the same path.
2. They describe different halves. — Because `limitations.md` is scoped to the *executable artifact* (a skill tree the runtime loads) and the README/design are scoped to the *candidate record* the gem produces.
3. Neither says which half it means. — Because the two were written by different workstreams against different DoDs (invariant 43 for the limitation, plan §7 for the candidate pipeline).
4. No document owns the boundary statement. — Because the gem's own README (`gems/tamoz-agent-improvement/README.md`) is not cited by either.
5. **Controllable cause:** the boundary between "a candidate is produced, evaluated, and recorded" and "an artifact is installed and executed" is stated nowhere as one sentence. **Contract that would prevent recurrence:** one owner document states the three-part bound — promote what (non-executable artifacts), install what (nothing, at HEAD), activate what (a `Profile::Transition` at the next thread boundary).

**Recommendation (smallest credible action at the existing seam).** One sentence in `documentation/limitations.md` § "Skill installation and update (invariant 43)" naming what the candidate pipeline *does* implement (candidate provenance, paired evaluation, staged durable lifecycle, digest-bound operator approval) and what it explicitly does not (no artifact is installed, written to disk, or loaded as executable content; promotion records a next-boundary transition and returns `activated: false`). No code change.

**Disposition.** Open — documentation-only; the coordinator may route it to the docs owner instead of this row.

### F23-SCA-01 — Every generation bound is per-instance and per-call; nothing bounds generator instances, candidates, or evaluation rounds per tenant (minor)

**Observable behavior at risk.** `ONE_CANDIDATE_LIMIT = 1` is enforced on `@generated` (`generator.rb:29,57,102-105`), a counter on one object. Nothing bounds how many `Generator` instances a process constructs, how many candidates exist across instances, how many evaluation reports are written into the evaluator partition, or how many promotion attempts are made. `assert_one_live_heuristic!` bounds *live* heuristics (`promotion.rb:28,304-331`), and its comment (`:297-303`) states the intended rule — a rolled-back candidate is not live, so a follow-up round may promote the next — but the rule has no per-tenant round counter.

| Field | Content |
|---|---|
| Severity | `minor` |
| Confidence | `high` |
| Status | `open` |

**Owning seam.** `Improvement::Generator#generate` (`generator.rb:101-120`).

**Source evidence.** `generator.rb:29,57,102-105` (`@generated`), `:118` (`@generated += 1` before returning, so a candidate that fails `assert_bounded!` on line 119 still consumes the budget — correct), `:46-58` (no cross-instance registry); `promotion.rb:305` (`limit: 64` rows scanned, which silently caps the liveness view on a busy store); `tamoz-agent-improvement.gemspec:14-17` (no factory or registry dependency).

**Test/contract evidence.** `test/improvement_candidate_test.rb:226-229` proves the second call on the *same* generator is refused; `:579-633` proves a follow-up round is allowed after a rollback. Not found: any test or API for a per-tenant or per-process bound.

**Independent judgment.** Confirmed the bound is real and correctly placed for the DoD ("at most one bounded heuristic candidate" per generating task) and that the loop is stoppable. Also confirmed `promotion.rb:305`'s `limit: 64` is a view bound, not a correctness bound: `assert_one_live_heuristic!` is a safety gate that becomes weaker as the transition namespace grows past 64 rows, because a live row outside the page is invisible. `minor` because v1 admits at most one live heuristic, so 64 rows is far above the reachable state; the note is for the next phase.

**Recommendation (smallest credible action at the existing seam).** None required for v1. If a bounded-rounds contract is wanted, the existing seam is `assert_one_live_heuristic!` (`promotion.rb:304`) — the store already holds every transition row and already distinguishes `rollback.` rows, so a per-tenant `recorded|claimed|activated` count is one extra filter, not new machinery. Record `limit: 64` explicitly as a known view bound in the row's blind spots either way.

**Disposition.** Open — informational for the next phase; no action requested for v1.

### F23-INF-01 — A superseded heuristic epoch cannot be rolled back and blocks all further promotion (info)

**Observable behavior at risk.** If any non-heuristic behavior epoch lands on top of an activated heuristic epoch, `Promotion#rollback` refuses (`RollbackIntegrityError`, `promotion.rb:82-86`) while `assert_one_live_heuristic!` still counts the heuristic row live (`:315-325`), so no further heuristic can be promoted either. Probe `/tmp/f23_probe_wipe2.rb` produces exactly this refusal on a three-epoch history. Not a defect at HEAD: no production caller invokes `Promotion`, and the intended usage always has the heuristic newest. It is recorded because the combined state is reachable through this gem's public API plus the shared P11-W registry and is represented by no test.

| Field | Content |
|---|---|
| Severity | `info` |
| Confidence | `high` |
| Status | `open` |

**Recommendation.** None for v1. The natural seam, when a second heuristic lane opens, is `Promotion#rollback`'s target selection (`promotion.rb:76-88`): accept an explicit `transition_id` to undo, subject to the same snapshot proof, instead of reading `active_transition_id`.

### F23-INF-02 — The promotion decision has no absolute-score floor; the pair-margin is the entire gate (info)

`EvaluationReport.decide` (`evaluation_report.rb:199-211`) passes when `development_margin > 0` and `holdout_margin >= 0`. Probe `/tmp/f23_probe_gate.rb`: a report with `total = 1` on both partitions, baseline `0/1`, candidate `1/1` decides `passed=true`. A candidate that wins one task in a one-task partition promotes. `assert_arm!` enforces `total.positive?` (`:185-187`) but no minimum total, and `verify!` never reads the per-task `outcomes` map the harness writes (`heuristic_paired_evaluation.rb:112-117`), so `total` is a self-reported integer. In production the corpus is a fixture the evaluator owns and the injected regression case exists precisely to make the heuristic lose on holdout (`heuristic_paired_evaluation.rb:50-53`), which is why this is `info` and not `major` — but the gate itself has no floor, and the earlier lead that the *pairing* check was vacuous is disproved: `assert_paired!` re-derives `paired_task_digest` from both partition digests (`:157-163`) and refuses an identical development/holdout set (`:152-155`), which I verified by probe (`/tmp/f23_probe_vacuous.rb`: differing object insertion order canonicalizes to one digest — `CanonicalJSON.normalize_object` sorts keys, `canonical_json.rb:70-75` — but equalizing the digests does not pass the gate unless the two sets are byte-identical, and any byte difference produces a different digest).

| Field | Content |
|---|---|
| Severity | `info` |
| Confidence | `high` |
| Status | `open` |

**Recommendation.** None at HEAD; if a floor is wanted it belongs in `assert_arm!` (`evaluation_report.rb:175`) as one more predicate, and the `outcomes` map would be the honest input.

### F23-SEC-03 — `CandidatePolicy` compares `policy.allow_changes` with a hand-rolled guard that the pinned catalog digest cannot substitute for (minor)

**Observable behavior at risk.** `policy_without_surface` (`candidate_policy.rb:93-95`) excludes `allow_changes` from the policy comparison, and `narrower_policy?` (`:85-91`) replaces it with `return false if !current['allow_changes'] && candidate['allow_changes']`. That guard is correct — it is the one line that catches widening — but it means the strongest field in the policy is checked by a boolean expression while the remaining fields are compared by digest. The excluded key is `tool_catalog_digest`-shaped: probe `/tmp/f23_probe_digest_gap.rb` shows a `Toolbox` built with `allow_changes: false` and one with `allow_changes: true` and the same `allowed_tools` produce the **identical** `catalog_digest` (`sha256:4344901f…`), because `ToolCatalog#descriptions_for` keeps only names in `@allowed_tools` (`tool_catalog.rb:59-70`). So the pin at `session_options.rb:149-156` cannot distinguish the two either, and this comparison is the only thing standing between a candidate and a write-capable toolbox.

| Field | Content |
|---|---|
| Severity | `minor` |
| Confidence | `medium` (the exclusion and the digest collision are both proven; whether the candidate path *needs* `allow_changes` to round-trip is not, because no production caller invokes `CandidateLifecycle`) |
| Status | `open` |

**Source evidence.** `candidate_policy.rb:86,93-95`; `candidate_policy.rb:67` (the `immutable` list that deliberately omits it); `gems/tamoz-tools/lib/tamoz/tools/tool_catalog.rb:44-52,59-70`; `gems/tamoz-agent-session/lib/tamoz/agent/session_options.rb:149-156`.

**Test/contract evidence.** `test/agent_improvement_lifecycle_test.rb:109-119` asserts an authority-declaring config candidate is refused, but no test drives a *profile* candidate through `validate_profile!` / `assert_narrower!`. Not found: any test of `CandidatePolicy.validate_profile!`.

**Independent judgment.** The guard at line 86 does refuse widening, so no live bypass is demonstrated; the finding is that the field is compared outside the digest machinery because it *must* be — excluding it is required for relocation between profiles with different `allowed_tools`, since the catalog pin cannot separate the two cases. The record should say that plainly rather than presenting `allow_changes` as structured like the other protected fields.

**Recommendation (smallest credible action at the existing seam).** Move the `allow_changes` guard out of the `return false if` prefix and into the comparison body next to the `immutable` loop at `candidate_policy.rb:67`, so every protected field is checked in one place and the exclusion at `:94` reads as the deliberate exception it is. Cosmetic; no behaviour change.

**Disposition.** Open — `minor`, `medium` confidence because the production caller is absent at HEAD.

## Blind spots

- **No production caller exercises either entry seam.** Repo-wide grep finds `Improvement::Promotion` and `CandidateLifecycle` only in this gem's `lib/` and two test files. Everything above is verified against the unit surface and its probes, not against a running agent. If a caller lands later, the ordering in `Promotion#promote` (`promotion.rb:47-64`) and the phase machine in `CandidateLifecycle` are the two places I would re-read first.
- **The durable effect path for `CandidateLifecycle` was read, not executed.** `EffectDispatcher.run` is called with `safety: :reconcilable` (`candidate_lifecycle.rb:188`), so a real run needs a `context` exposing `effects` (`effect_dispatcher.rb:46,69-76`) over a SQLite effect journal. `test/agent_improvement_lifecycle_test.rb:150-168` substitutes a double. That is why F23-REL-01 is `medium` confidence: the in-gem phase behaviour is probed, the journal's `:failed`-is-terminal behaviour is source-read at both implementations (`effects_journal.rb:114-118`, `effect_preparation.rb:158-159`).
- **`tamoz-evals-runner`'s `HeuristicPairedEvaluation` and `HeuristicCorpus` were read, not executed in isolation.** They were exercised through `test/improvement_candidate_test.rb` (which drives them for real, 284 assertions). I did not run `test/benchmark_harness_test.rb` or `test/experience_harness_test.rb`; neither is this row's surface.
- **`Memory::TransitionRegistry` line-level concurrency was not stressed.** Probes covered the two-writer and pending-then-record cases (`/tmp/f23_probe_stale.rb`); lease expiry, fence changes, and `release_or_finalize` (`transition_registry.rb:229-251`) were read but not executed. Row F07 owns that file.
- **`Profile::TransitionRegistry` and the adoption registry were not read.** `CandidateLifecycle#profile_activation` depends on both (`candidate_lifecycle.rb:236-245`), and `validate_profile_registries!` only checks that they respond to `record`/`activate` (`:263-267`). Their own contracts are outside F23.
- **`promotion.rb:305`'s `limit: 64`** is an unbounded-growth caveat on a safety gate (F23-SCA-01) that I could not turn into a reachable state within v1's one-live-heuristic bound.
- **The `human:` prefix convention is repo-wide.** `gems/tamoz-agent-memory/lib/tamoz/agent/memory/wisdom.rb:105-123` uses the same prefix check for `wisdom_promotion`. I did not audit that path; if F23-SEC-01's binding is added here, the coordinator should decide whether P11-W's lane gets the same treatment rather than leaving two conventions.

## Verdict

**IMPROVE** — 1 critical, 4 major, 2 minor, 2 info. Verdict is `IMPROVE` on the accepted-critical threshold alone (BAR.md: a functionality is `IMPROVE` when it has at least one accepted critical/major finding).

Counts: `critical` = 1 (F23-SEC-01), `major` = 4 (F23-COR-01, F23-COR-02, F23-REL-01, F23-MNT-01), `minor` = 2 (F23-SCA-01, F23-SEC-03), `info` = 2 (F23-INF-01, F23-INF-02). The JSON `counts` is authoritative and matches this line.

What is genuinely good and should not be lost in the fix: the capability boundary that keeps the holdout unreadable is enforced by `PathResolver` and not by this gem's own conventions; the generation, insertion, snapshot, and attempt loops are bounded at the seam that owns each; the paired-evaluation gates are harsher than the harness that feeds them (they re-derive the pairing digest and refuse an identical development/holdout set), so the earlier "vacuous hard-counter gate" pattern does **not** reproduce here; no model call is made anywhere in this gem, so the FX rule has nothing to bind; and the promotion path did not add a second activation engine — it rides the P11-W `TransitionRegistry` with a kind that already existed. The four majors are all one-seam, small fixes at code that already has the right shape.

Per BAR.md, this is a read-only package: nothing above has been changed, and no finding is closed by this report.
