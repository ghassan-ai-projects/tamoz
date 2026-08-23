# Session handoff — step 12 (final sweep) — 2026-08-23

Read this first in a fresh session. It is the exact continuation point.

## Where we are

All 12 steps of `05-implementation-plan.md` have been implemented and committed
through `54cc999`. Step 12 (final sweep + gates) is **in progress, uncommitted**:
40 modified/new files sit in the working tree on branch `redesign-approval-policy`.

Owner decision ratified this session: **land all remaining work, then run the
gates** (`rake ci`, rubocop, enola re-check); anything still red afterwards gets an
honest `docs/LIMITATIONS.md` entry instead of being crammed.

## What this session added (all tested green unless noted)

### The external audit's findings — ALL FIXED
Source: `10-implementation-audit.md` (F1–F8). Verified each claim against code first.

- **F1** duplicated argv/target projection → new single home
  `gems/tamoz-agent/lib/tamoz/agent/request_projection.rb`
  (`Tamoz::Agent::RequestProjection`), required from `agent.rb`; both
  `session_effects.rb` and `runtime.rb` delegate; redundant `private` removed.
- **F2** unreachable `workspace_write :session` → `policy/base.yaml` now has
  `grant_keys: { workspace_write: [verb, target_root] }` (root = blast radius;
  tool deliberately excluded so any write under the same top-level root matches).
  New engine test `test_workspace_write_session_grant_remembers_the_root`.
- **F3** validator converse gap → `PolicyDocument#validate_tiers!` and
  `validate_tool_tiers!` now refuse any tier/tool advertising `:session` without a
  mintable grant key ("advertises :session"). Negative test added in
  `approval_policy_document_test.rb` (23 runs green).
- **F4** dead `:once` grant persistence → `engine.resolve` inserts only `:session`
  grants; comment updated ("SESSION grant row").
- **F5** cross-process double insert → unique index
  `idx_tamoz_approval_grants_session ON (session_id, policy_rev, key, scope)` +
  `ON CONFLICT DO NOTHING` in the sqlite grant store.
- **F6** reload TOCTOU → `worker_runtime.sync_approval_policy` adopts the reloaded
  document only if its `policy_rev` equals the pointer rev.
- **F7** migration collapse → **CURRENT_VERSION is now 17**; MIGRATION_17 holds the
  final approval schema (grants + unique index, decisions with `step_scope`,
  reuse index, mode-switches table); MIGRATION_18/19 deleted; `MIGRATIONS` registry
  rebuilt (it was accidentally removed with the collapse slice — restored after
  MIGRATION_17_CHECKSUM); MIGRATION_1's request-inbox CHECK widened to include
  `'mode_switch'`. Pins updated in `sqlite_approval_stores_test.rb` (17 / `(1..17)`).
  **Gotcha that cost an hour:** a squiggly heredoc terminator must be bare `SQL`;
  putting the array separator comma on the terminator line (`SQL,`) breaks parsing —
  commas go on the opener (`<<~SQL.freeze,`).
- **F8** lane_ask cache keyed `[lane_key, policy_rev]`, no TTL.

### Step-12 sweep items fixed
- `test/memory_store_test.rb`: both upgrade harnesses rebuilt as GENUINE old DBs via
  new helper `build_legacy_database(path, through: N)` (executes real
  MIGRATION_1..N constants + real checksums into `tamoz_schema_migrations`,
  sets application_id/user_version, chmod 600). v1 harness seeds a real codec-dumped
  payload. Suite: 16 runs / 112 assertions, 0F 0E.
- `test/fixtures/legacy_session_v1.sqlite3` REGENERATED (schema checksums changed):
  `script/generate_legacy_session_fixture` now also adds `tamoz-approval`,
  tamoz-tools/observability/comms/mcp to its load path, and RE-SEALS every
  checkpoint row to digest_version 1 + graph_version "1" with a legacy-rule
  definition digest inside the payload too (a reader cross-checks column vs payload
  before the identity guard). Uses a SimpleDelegator-wrapped definition bound to a
  legacy CheckpointCodec. `legacy_session_resume_test` 5/28 green. Fixture files
  chmod 644.
- Child-process load-path lists were missing `tamoz-approval` everywhere (new
  dependency edge): fixed in `test/agent_session_kill_matrix_test.rb`,
  `test/agent_acceptance_workflow_test.rb`, `test/sqlite_crash_recovery_test.rb` (×2),
  `test/agent_profile_machinery_test.rb`, `test/sqlite_scenario_driver_test.rb`,
  `test/agent_worker_test.rb`, and gems/tamoz-evals `agent_smoke_corpus.rb`
  (CliSubprocessHarness::LOAD_PATHS).
- `request_projection.rb` chmod 644 (packaging test warned "not world-readable").
- `test/support/domain_loader.rb`: dropped stale `approval_required` key from the
  profile document (post-redesign profiles don't carry it;
  `authority_validator` refuses it). Fixes stream_episode_witness/end_to_end setup
  errors — NOT YET RERUN.
- `script/generate_requirements_audit` needed `chmod +x`.

## Remaining work (exact)

### B1 — rewrite `test/agent_digest_resolution_test.rb` for the engine API (~30 min)
- Its `runtime(root, model, approval:)` helper passes `approval:` to
  `Tamoz::Agent.build`, which no longer accepts it → ArgumentError cascade (5F/7E).
- Drop the kwarg. Give `build_session` an explicit review-profile engine so
  apply_patch ASKS again (preserves the mutation test's meaning):
  `approval_engine: Tamoz::Agent.build_approval_engine(profile_name: 'review')`.
- DELETE `test_runtime_approval_callback_mutation_refuses_the_patch_fail_closed`
  (the callback API is gone; its invariant lives on in
  `test_session_mutation_between_approval_and_dispatch_is_refused_fail_closed`).
- With review profile, `approvals.first.fetch("tool")` becomes `"apply_patch"` again.

### B2 — kill-matrix child needs operator resolution (~30 min)
`test_every_declared_seam...` fails at K7.after_effect_start_before_publication:
post-redesign an unknown effect BLOCKS demanding `Session#resolve_effect`
(session_evidence.rb:206). The child's resume loop only approves interrupts.
Fix in the CHILD script (inside the test file): when `view.blocked`, attest truth by
re-running the configured check command and calling
`session.resolve_effect(thread:, effect_key: view.blocked.fetch("effect_key"),
status: ok ? :succeeded : :failed, actor: "...", evidence: {"how" => "re-ran check"})`.
This mirrors what the CLI operator does (cli.rb "resolve_effect").

### B3 — stale-bytes refusal should be FATAL, not repairable (~20 min + review)
Absent-digest killed-between-approval-and-dispatch scenario now ends status
"completed" (repairable refusal → repair loop exhausts) instead of "failed".
`gems/tamoz-tools/lib/tamoz/tools/patch_preparation.rb:28` raises ToolArgumentError
"file changed: ...". Make THIS refusal non-repairable (ToolError has `repairable?`;
effect_dispatcher records it) so approved-but-changed bytes stop typed per D-8
committed-intent contract. Per owner rule this behavior change deserves the
four-lens review pass before commit.

### Bucket A leftovers (mechanical)
- `test/agent_non_ascii_session_test.rb` canonicality map: add
  `"tamoz-evals/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb"=>1`
  (inventory moved; update expected map + coverage note).
- `documentation_surface_test` / `docs/LIMITATIONS.md`: add INV-18 disclosure entry
  (test tells you exactly this).
- Rerun after domain_loader fix: stream_episode_witness_test,
  stream_episode_end_to_end_test.
- UNDIAGNOSED: `sqlite_raw_oracle_test` (7F/1E) — likely shares child-load-path or
  evals-harness roots; not yet investigated. Check
  `gems/tamoz-evals/.../sqlite_selector_control_intervention.rb` spawn paths.

## Then the gates
1. Regenerate manifest + audit: `ruby script/generate_requirements_manifest` then
   `ruby script/generate_requirements_audit` (background ~10 min; exit 1 until clean).
2. `rubocop` (deferred-debt pass over our diff).
3. `rake ci` (+ ci_full packaging/evidence slice per gate policy).
4. enola: `generate_snapshot` + `diff_snapshot` vs baseline (structural change:
   RequestProjection module added; prior check was PASS pre-collapse).
5. Evidence rows for step 12 (+ audit F1–F8) in `08-implementation-bars.md`.
6. Commits (suggested split): (a) audit fixes F1–F8 + tests; (b) migration collapse
   + fixture regen; (c) step-12 docs/sweep (README/AGENTS/ADR-049/comms.md/
   security-model/cli.md/CHANGELOG/[Unreleased]/03-redesign Status/handbook
   provenance f21808d..6096996 — all already edited, uncommitted);
   (d) B1–B3 behavioral fixes.

## Environment facts
- `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"; eval "$(rbenv init -)"` mandatory.
- ONE test file per command; use `bundle exec ruby -Itest test/X_test.rb`.
- Never `bundle install`. workspace-write sandbox; chmod 644 every new file.
- Accepted deviations (do NOT re-fix): Preparation.approval_required FIELD name,
  park reason 'approval_required', healing 'human_approval_required' key,
  capability_host descriptor.approval_policy (MCP admission), corpus audit-string,
  unattended_catalog_digest vestigial dual-key, abstract ports, write-only
  provenance columns. NOTE: the DOMAIN PROFILE `approval_required` key removal is
  different and WAS done (validator rejects it there).
- Goal goal-3dd510f2-2004-4837-a4e5-4307ae3b74dd exists (paused/disarmed, rev 3);
  resume it when continuing. Mark complete only after gates are green.
