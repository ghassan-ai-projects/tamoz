# 08 — Implementation bars (operational)

**Status:** working — derived from `00-acceptance-bar.md` and `05-implementation-plan.md`.
**Purpose:** concrete per-phase finish line for the coding pass. Each phase is graded
against the global invariants (`00` §4), hard-zeros (`00` §5), and the scenarios mapped
to it in `06-acceptance-scenarios.md`.

## Finish line (whole program)

The redesign is done when:

1. `gems/tamoz-approval` exists and answers every approval decision via
   `Tamoz::Approval::Engine#decide` reading digest-pinned YAML policy data.
2. Reclassifying a tool is a YAML edit in `gems/tamoz-approval`; zero Ruby changes in
   `tamoz-core` / `tamoz-agent`.
3. Every mapped acceptance scenario in `06-acceptance-scenarios.md` passes.
4. The grep sweep in step 12 returns zero live references to deleted symbols outside
   this `docs/` folder and `CHANGELOG.md`.
5. The `enola` delta against the step-1 baseline is exactly: one new gem, expected
   edges added, tools→agent classification coupling gone, no new cycle.
6. Every step has a one-line evidence note (date, commands, files, plumbing vs real).

## Phase bars

### Phase 1 — Gem scaffold: values, errors, `Answer`

**Goal:** `gems/tamoz-approval` exists, packages, carries immutable interface vocabulary.
No behavior changes anywhere.

**Finish line:**
- [ ] All files in `05` step 1 created/modified.
- [ ] `bundle exec ruby -Itest test/approval_values_test.rb test/approval_answer_test.rb` green.
- [ ] `bundle exec rake ci` green.
- [ ] Public API pins updated (`test/public_api_test.rb`, `docs/public-api.json`,
  `documentation/reference/public-api.md`).
- [ ] `packaging_test.rb` green with the new gem if it pins inventory.
- [ ] One-line evidence note appended to this file.

### Phase 2 — Policy data + `PolicyDocument` loader/validator

**Goal:** All policy content exists as data; loader parses, validates, digests, runs
`simulations:` before activation.

**Finish line:**
- [ ] `policy/base.yaml` + `policy/profiles/{implement,review,unattended}.yaml` created.
- [ ] Loader validates schema, matcher set, scopes, evidence symbols, simulations.
- [ ] Old profile keys rejected loudly.
- [ ] `test/approval_policy_document_test.rb` green; hard-zero scenarios O-1, E-2, SIM-1,
  L-2, M-2 pass.
- [ ] `bundle exec rake ci` green.
- [ ] Digest stability asserted against content, never hardcoded hex.

### Phase 3 — `Engine`, ports, in-memory stores

**Goal:** Whole decision interface works in-process: canonicalization, evaluation,
grants, resolution, simulation, reload.

**Finish line:**
- [ ] `Engine`, `GrantStore`, `DecisionLog` ports + in-memory implementations created.
- [ ] Deny-first ordering, tier defaults, fallback ask, `read_only ⇒ read`, grant-key
  grammar, idempotent resolve all tested.
- [ ] Scenarios C-1..C-8, O-1, G-1..G-6, RS-1..RS-4, L-3, L-4, L-5, LG-1, LG-2 pass.
- [ ] Hard-zeros C-3, C-7, G-2, G-3, RS-1, L-5 pass.
- [ ] `bundle exec rake ci` green.

### Phase 4 — Comms prep: expose evidence symbol set

**Goal:** Comms exposes its lattice members as plain symbols for boot wiring.

**Finish line:**
- [ ] `AuthorityEvidence.members` exposed.
- [ ] `test/comms_authority_evidence_test.rb` extended and green.
- [ ] `bundle exec rake ci` green.

### Phase 5 — `tamoz-sqlite`: migration 17 + store implementations

**Goal:** Durable homes for grants, decisions, active-policy rev; stream receipts gain
`expires_at`.

**Finish line:**
- [ ] Migration 17 created with checksum; `CURRENT_VERSION` bumped; manifest/checksum
  convention followed.
- [ ] SQLite implementations of grant store, decision log, active-policy store created.
- [ ] `test/sqlite_approval_stores_test.rb` green; hard-zeros L-5, M-4 pass.
- [ ] `bundle exec rake ci` green; `ci_full` (both locales) run because durability touched.

### Phase 6 — Boot wiring + reload delivery

**Goal:** Worker runtime constructs one durable `Engine`; one-shot runtime constructs
its own in-memory engine; reload delivery loop exists end to end.

**Finish line:**
- [ ] `worker_runtime.rb`, `session_effects.rb`, `agent.rb`, `runtime.rb`, `worker.rb`,
  CLI reload command wired.
- [ ] Two engines: worker uses SQLite stores; one-shot uses in-memory stores.
- [ ] Reload validates in CLI process before writing active-policy row.
- [ ] Scenarios L-1, L-2 pass; hard-zero L-2 passes.
- [ ] `bundle exec rake ci` green.

### Phase 7 — Pipeline A convergence + classification-chain deletions

**Goal:** Durable session asks the engine; complete nine-method `approval_required?`
chain, old constants, profile keys, `--all` flag deleted in one commit.

**Finish line:**
- [ ] `session_steps.rb` calls `engine.build_request` + `engine.decide`.
- [ ] `:ask` uses existing interrupt path with `Decision`; `:deny` returns structured
  tool result; `:allow` executes.
- [ ] `worker.rb` resume path calls `engine.resolve`; poll pass enforces timeouts.
- [ ] `cli.rb` interactive path calls `engine.resolve` with scope follow-up.
- [ ] Nine-method chain deleted; `DEFAULT_APPROVAL_REQUIRED` deleted; profile keys and
  validators deleted; `--all` option and guard deleted.
- [ ] No two policy owners in tree at any commit.
- [ ] Scenarios C-1..C-8, O-1, G-1..G-6, RS-1..RS-4, D-1, D-2, T-1..T-3, V-2, LG-1,
  LG-2, L-3, L-4, M-1, M-2 pass; hard-zeros C-3, C-7, G-2, G-3, G-4, RS-1, D-1, M-1,
  M-2 pass.
- [ ] `bundle exec rake ci` green.

### Phase 7B — Mid-session mode switch

**Goal:** One session's approval profile can be rebound live, bounded and audited.

**Finish line:**
- [ ] `policy/profiles/{plan,auto}.yaml` created (+ optional `bypass.yaml`).
- [ ] `Engine#rebind_session` added; decision log records mode switch.
- [ ] `submit_mode_switch` durable message, poll-pass apply, CLI one-shot path wired.
- [ ] Scenarios MS-1..MS-6 pass; hard-zeros MS-4, MS-5 pass.
- [ ] `bundle exec rake ci` green; `ci_full` (both locales) run.

### Phase 8 — Comms: evidence from decision, constant deleted

**Goal:** Prompt pins `decision.required_evidence`; `ApprovalPolicy` constant deleted.

**Finish line:**
- [ ] `approval_prompt.rb` uses caller-supplied evidence symbol.
- [ ] `ApprovalPolicy` constant file deleted.
- [ ] All three reference sites updated in agent.
- [ ] Scenarios E-1, E-2 pass; hard-zero E-2 passes.
- [ ] `bundle exec rake ci` green.

### Phase 9 — Pipeline B convergence + `ApprovalDeniedError` deleted + tamoz-evals

**Goal:** One-shot runtime uses engine; denial is data everywhere.

**Finish line:**
- [ ] `runtime.rb` one-shot path calls `engine.build_request` + `engine.decide`.
- [ ] `ApprovalDeniedError` definition, raise, and all rescues deleted.
- [ ] Eval harness + smoke corpus updated for denial-as-result.
- [ ] Scenarios D-3, V-1 pass; hard-zero D-3 passes.
- [ ] `bundle exec rake ci` green; eval smoke suite for `07_denied_approval` green.

### Phase 10 — Scheduler: informational hash deleted, profile name in

**Goal:** Schedules name an approval profile; dead scheduler hash removed.

**Finish line:**
- [ ] `schedule.rb` `approval_policy` hash field deleted.
- [ ] `cli_schedule_commands.rb` takes optional profile name, propagated to run config.
- [ ] Targeted scheduler + CLI schedule tests green.
- [ ] `bundle exec rake ci` green.

### Phase 11 — Stream: receipt TTL injected at subscriber boot

**Goal:** Stream approval receipts expire; TTL injected as plain integer from run config.

**Finish line:**
- [ ] `approval_relay.rb` documents/expands receipt port `expires_at` semantics.
- [ ] `bin/tamoz-stream-subscriber` injects TTL from run config.
- [ ] SQLite receipt store honors `expires_at` column.
- [ ] `test/stream_invariants_test.rb` glob untouched and green.
- [ ] `bundle exec rake ci` green.

### Phase 12 — Docs + final sweep

**Goal:** Documentation matches reality; final consistency sweep.

**Finish line:**
- [ ] ADR, design docs, README, AGENTS.md updated.
- [ ] Grep sweep clean for deleted symbols.
- [ ] Public API pins consistent.
- [ ] `test/packaging_test.rb` green.
- [ ] Every scenario in `06` passes on final re-run.
- [ ] `enola generate_snapshot` + `diff_snapshot` against baseline shows expected delta.
- [ ] `bundle exec rake ci` green; `ci_full` (packaging/evidence slice) green.

## Evidence log

| Phase | Date | Command(s) | Files / no-change | Plumbing vs real |
|-------|------|------------|-------------------|------------------|
| 1 | 2026-08-23 | `bundle exec ruby -Itest test/approval_values_test.rb test/approval_answer_test.rb` (green); `bundle exec ruby -Itest test/public_api_test.rb` (green); `bundle exec ruby -Itest test/benchmark_protocol_test.rb` (green); `bundle exec ruby -Itest test/documentation_surface_test.rb` (green) | Created `gems/tamoz-approval/` scaffold + tests; wired Gemfile/test_helper/public API pins; regenerated dependency review + benchmark protocol | Plumbing |
| 2 | 2026-08-23 | `bundle exec ruby -Itest test/approval_policy_document_test.rb` (green); `bundle exec ruby -Itest test/public_api_test.rb` (green); `bundle exec ruby -Itest test/packaging_test.rb -n test_every_gem_is_strict_valid_and_contains_only_release_files` (green); `enola check` (PASS) | Created `policy/base.yaml` + profiles; `PolicyDocument` loader/validator; `Evaluator`; public API pins updated | Plumbing |
| 3 | 2026-08-23 | `bundle exec ruby -Itest test/approval_engine_test.rb` (20 green); `...approval_resolve_test.rb` (16 green); `...approval_reload_test.rb` (8 green); `...approval_grant_key_test.rb` (4 green); `...approval_values_test.rb`/`..._answer_test.rb`/`..._policy_document_test.rb`/`public_api_test.rb` (green) — one file per invocation (`ruby -Itest a b c` runs only the first) | Engine + GrantStore/DecisionLog ports + memory impls; Canonical digest module; PolicyDocument tier_for/verb_for mapping home; pins updated. Full `rake ci` deferred to phase 12 per owner directive. Deferred: session-deadline-derived expires_at (phase 7 owns deadlines), RS-3 expired-id half (phase 7 timeouts), reload(String-path) kept as tested superset of the amendment's document form, port style stays abstract classes (house uses contract modules — noted, not forked behaviorally). Grant-hit allows log under derived id `<decision_id>/grant` with rule_id `engine.grant_hit`; expiry is Engine-owned epoch-ms from an injected wall clock; failed resolutions leave zero grant rows | Plumbing |
| 4 | 2026-08-23 | `bundle exec ruby -Itest test/comms_authority_evidence_test.rb` (6 green); comms gateway/evidence suites re-run green; `public_api_test.rb` green with `AuthorityEvidence.members` pin | `AuthorityEvidence.members = LEVELS.map(&:to_sym).freeze`; pin added to all three surfaces. Additive only — consumer lands in phase 6 boot wiring. Follow-up fix commit c944e89 closed the correctness-review majors against phase 3 (fallback-scope hard-zero, all-targets grant key, resolve atomicity) with regression tests | Plumbing |
| 5 | 2026-08-23 | `bundle exec ruby -Itest test/sqlite_approval_stores_test.rb` (10 green); `test/dependency_review_test.rb` (8 green); approval+comms suites re-run green after the review-fix commit; `requirements_manifest_test.rb` 10/11 (sole failure is audit-doc staleness, see note) | MIGRATION_17 (approval grants/decisions/active-policy tables, checksummed + manifest-pinned); SQLite GrantStore/DecisionLog/ActivePolicy adapters bound on the adapter; grant-key text owned by `Grant.key_text` on both insert and lookup (order-insensitive, pinned by test); decision log reconstructs the full Decision incl. reason/offer from columns; receipt store gains clock-injected `expires_at` value-field expiry (08 amendment); tamoz-sqlite gemspec declares the tamoz-approval edge; requirements manifest regenerated for MIG-17 and the stale CLI-parser/MIG-16-evidence rows fixed in its generator. DEFERRED per owner no-full-suite directive: `script/generate_requirements_audit` (runs every named test) and `ci_full` both locales move to the phase-12 end gates — until then the manifest gate is red only on that audit staleness | Real (durable schema) |

## Amendments from pre-implementation gap review

The following clarifications/fixes to `05-implementation-plan.md` were identified by the
gap and completeness subagents and are binding on implementation.

### Phase 1
- Add `Grant = Data.define(:key, :scope, :session_id, :policy_rev, :expires_at_ms)`
  to the interface vocabulary (`gems/tamoz-approval/lib/tamoz/approval/grant.rb`).

### Phase 2
- Define loader API explicitly: `PolicyDocument.load(path, evidence_symbols:)` and
  `PolicyDocument.load_profile(base_path, name)`.
- Provide a minimal `Simulator` callable/port so `simulations:` can run before the
  full `Engine` exists; step 3's `Engine` implements the same contract.
- Old operator-profile keys (`tools.approval_required`, `unattended.*`) are rejected
  in Phase 7 (operator profile loader), not here.
- Public API pins updated for `PolicyDocument`.

### Phase 3
- `resolve(decision_id:, answer:, scope:, actor_evidence:)` — actor evidence
  validated against injected symbol set and written to the log.
- Add `Engine#bind_session(session_id) -> policy_rev` to pin a rev for the session
  life; grants/decisions key on the bound rev.
- Clarify `reload(document) -> String` (load from path is Phase 6; `Engine#reload`
  takes a loaded `PolicyDocument`).
- Public API pins updated for `Engine`, `GrantStore`, `DecisionLog`, `Grant`.

### Phase 4
- Public API pins updated for `AuthorityEvidence.members`.

### Phase 5
- Stream receipt expiry is a value-field in the existing key-value receipt store,
  not a new column; `ApprovalReceiptStore#fetch` returns `nil` for expired receipts.
- Define adapter bind methods:
  `Adapter#bind_approval_grant_store`,
  `Adapter#bind_approval_decision_log`,
  `Adapter#bind_approval_active_policy`.
- Define active-policy store: `ApprovalActivePolicy#read -> {path, rev}`,
  `ApprovalActivePolicy#write(path, rev)`.
- Identify and run the checksum/manifest regeneration script in this commit.

### Phase 6
- Add `approval_policy_path` and `approval_profile` to runtime config.
- Add `:engine` to `NodeConfiguration` and read it from `SessionEffects`.
- Add `WorkerRuntime#engine` (or `approval_engine`) accessor for poll-pass reload.
- `tamoz approve reload <path>` (or equivalent mutually-exclusive `--reload` flag)
  validates in CLI process before writing the active-policy row.
- Update `Tamoz::Agent.build` to construct the one-shot in-memory engine and pass it
  to `Runtime.new`.

### Phase 7
- Add `:engine` to `NodeServices` (or expose via `SessionEffects`) so `SessionSteps`
  can call `engine.build_request`/`decide`.
- Provide a `CapabilityBinding#describe(tool, arguments) -> {effect_class:, targets:}`
  seam (or equivalent) so `SessionSteps` can feed `build_request`.
- Interrupt descriptor carries the full `Decision` under key `decision:`.
- `:deny` graph-node update continues the turn as
  `{observations: [denial_observation], next_node: 'evaluate'}`.
- Worker `apply_decision` resolves via `engine.resolve` using engine `Decision#id`
  and a scope field threaded through the prompt/decision record.
- Interactive CLI `answer_for`/`map_answer` replaced with a flow that asks
  "remember for this session? [y/N]" for `:session`-offered decisions and resolves
  in-process before `session.resume`.
- Session teardown hook calls `grant_store.delete_by_session(session_id)`.
- `Deliberation.action_signature` stops using the deleted `approval_required?` chain.
- Expanded deletion inventory beyond the nine-method chain:
  - `profile/fields.rb`, `profile.rb`, `cli_profile_commands.rb`,
    `from_authority` replay path drop `tools.approval_required`/`unattended.*` fields.
  - `Toolbox#initialize`, `ToolCatalog#initialize`, `ToolPolicyNormalizer` drop
    `approval_required` parameters/attributes/normalization.
- Grep checklist before commit: `def approval_required\?`, `approval_required\?`,
  `DEFAULT_APPROVAL_REQUIRED`, `tools.approval_required`, `unattended_approval_required`.

### Phase 7B
- Engine holds base path/loader so `rebind_session(profile_name, session_id)` can
  load a profile overlay.
- Mode switch uses a distinct durable control message (not a normal turn request),
  drained and applied exactly once in the worker poll pass.
- `DecisionLog#append_mode_switch(switch_id:, actor:, session_id:, from_rev:, to_rev:)`
  idempotent on `switch_id`.
- One-shot mode switch via `Runtime#rebind_approval_profile(profile_name)`.
- Public API pins updated for `rebind_session` / `mode_switch` surface.

### Phase 8
- Remove `require_relative 'approval_policy'` from `approval_prompt.rb`.
- Update every `ApprovalPrompt.build` caller and test with `required_evidence:`.
- Public API pins updated for deleted `Comms::ApprovalPolicy`.

### Phase 9
- Also update tests:
  `test/agent_repair_evaluation_test.rb`,
  `test/agent_change_evaluation_test.rb`,
  `test/agent_cli_test.rb` for denial-as-result.
- One-shot `:ask` resolves with `:once` (no session grants in ephemeral runtime).

### Phase 10
- Add `approval_profile` field to `Schedule`, thread through `WorkerRuntime#build_session`,
  default `implement`.

### Phase 11
- `ApprovalReceiptStore` expiry check lands in Phase 5; this phase verifies subscriber
  TTL injection only.
- Subscriber adds `--approval-ttl-seconds` (or config equivalent) and passes TTL to
  the receipt store on write.

### Phase 12
- Grep terms include `approval_required\?` and `DEFAULT_APPROVAL_REQUIRED`.
