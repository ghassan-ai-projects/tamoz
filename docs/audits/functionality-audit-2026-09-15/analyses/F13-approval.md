# F13 `tamoz-approval` — IMPROVE

Row / queue / baseline (commit, date) / analyst / budget
- Row: **F13** — `tamoz-approval` — policy-as-data approval engine, grants, decisions, and durable log
- Queue: gem rows, primary queue (`COVERAGE.md:81`, status `pending`)
- Baseline: `/Users/ghassan/my-projects/tamoz`, branch `audit-15-09`, HEAD `582ae5566de1ae073aea82b69bb2bbf444494d3b`
- Date: 2026-09-15
- Analyst: independent read-only functionality analyst (`audit_f13_approval`)
- Budget: 45 minute cap requested; no implementation or commit

## Scope and source map

The review followed the approval value path from policy files through the engine,
the durable SQLite ports, and production callers. The current synthesized findings
were checked for overlap before recording new F13 findings; no F13 finding is
already accepted there.

| File | Role |
|---|---|
| `gems/tamoz-approval/lib/tamoz/approval/policy_document.rb` | YAML loading, profile overlays, normalization, digest, schema checks |
| `gems/tamoz-approval/lib/tamoz/approval/evaluator.rb` | deny-first evaluation, decision and grant-offer construction |
| `gems/tamoz-approval/lib/tamoz/approval/engine.rb` | request canonicalization, decision/replay, grant minting, reload, session binding, mode switches, teardown |
| `gems/tamoz-approval/lib/tamoz/approval/decision_log.rb` | durable log and mode-switch port plus memory implementation |
| `gems/tamoz-approval/lib/tamoz/approval/grant_store.rb` | exact grant lookup, insert, and session teardown port |
| `gems/tamoz-approval/policy/base.yaml` and `policy/profiles/*.yaml` | policy data and profile overlays |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/approval_decision_log.rb` | SQLite decisions, resolutions, and mode-switch records |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/approval_grant_store.rb` | SQLite grant lookup/insert/delete |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/approval_active_policy.rb` and `migrator.rb` | active reload pointer and approval tables |
| `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb` | runtime profile boot, reload polling, session binding, SQLite engine construction |
| `gems/tamoz-agent/lib/tamoz/agent/worker.rb` | production decision resolution, mode switches, schedule materialization, worker teardown |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb` and `runtime/step_execution.rb` | durable and one-shot approval callers |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb`, `cli.rb`, and `cli_schedule_commands.rb` | reload, interactive resolution, and scheduled-work entry points |
| `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb` and `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb` | persisted schedule approval profile and materialization boundary |
| `documentation/adr/approval-policy-redesign/00-acceptance-bar.md` and `03-redesign-adr.md` | normative scope, revision, grant, reload, and durable-log contracts |

## Behavior path

1. `PolicyDocument.load` safe-loads the base YAML, normalizes fields, computes a
   digest over normalized policy data, validates it, and runs its simulations
   (`policy_document.rb:18-40`, `328-348`). `load_profile` loads the base and
   overlays a named profile, then recomputes the effective revision
   (`policy_document.rb:42-50`, `85-107`).
2. `Engine#build_request` is the canonicalization seam. `#decide` selects the
   session-bound document, delegates deny-first evaluation to `Evaluator`, checks
   for a live session grant, and appends the decision record
   (`engine.rb:27-53`; `evaluator.rb:15-25`).
3. For an ask, `Evaluator` creates a `GrantOffer` from the tool/tier scopes and
   grant-key projection (`evaluator.rb:82-124`). `Engine#resolve` validates the
   answer, checks the decision and offered scope, records the resolution, and
   inserts a `:session` grant (`engine.rb:73-100`, `243-256`).
4. The SQLite decision log records the decision/resolution in one transaction per
   operation, while the SQLite grant store writes the session grant in a separate
   transaction (`approval_decision_log.rb:31-52`, `63-87`; `approval_grant_store.rb:18-45`).
5. A worker creates the durable engine with the configured base path and profile
   (`worker_runtime.rb:1179-1192`), binds stable profile session keys, and resolves
   approval answers without passing expiry or actor evidence
   (`worker_runtime.rb:1171-1176`; `worker.rb:491-500`). The session and one-shot
   paths also funnel through `Engine#resolve` (`session_effects.rb:362-380`,
   `runtime/step_execution.rb:151-165`).
6. Reload is delivered through an active SQLite pointer. The CLI writes only the
   base path and revision (`cli_worker_commands.rb:396-414`; `approval_active_policy.rb:5-8`,
   `15-35`), and the worker loads that path with `PolicyDocument.load`, not the
   selected profile (`worker_runtime.rb:756-774`).
7. A schedule accepts and displays `approval_profile`, but schedule materialization
   passes only a task template to the request inbox (`cli_schedule_commands.rb:50-52`,
   `84-96`; `worker.rb:147-165`; `schedule_store.rb:413-432`). The worker then
   chooses the approval session from runtime config (`worker_runtime.rb:700-706`,
   `1030-1057`, `1171-1185`).

## Lens judgments

| Lens | Judgment | Evidence |
|---|---|---|
| Correctness | reviewed | The core data path is covered by focused tests, but schedule approval profiles and reload profile overlays are not carried across their production boundaries. |
| Security / authority | reviewed | The normal path is deny-first and policy-backed, but a tool override can bypass the no-session tier rule and the scope vocabulary is open. |
| Reliability / durability | reviewed | Decision resolution and mode-switch persistence have failure windows; crash cleanup does not fully enforce session grant lifetime. |
| Observability / evidence | reviewed | Structural decisions and digests are durably recorded. Resolution `actor_evidence` is nullable and all inspected production callers omit it; this remains an evidence-quality gap rather than a separate severity finding because channel enforcement is outside this gem. |
| Scalability / resource bounds | reviewed | The decision table is append-only with no retention or compaction seam; this is recorded as an informational contract gap. |
| Maintenance / architecture | reviewed | `tamoz-approval` keeps the intended core-only dependency direction and one Engine seam. The schedule and reload defects are cross-gem contract drift, not duplicate engines. |

## Tests, contracts, and probes

All test commands used the pinned Ruby and one test file per command. Every listed
test passed. The inline probes used the exact wrapper
`rbenv exec bundle exec ruby -Itest <<'RUBY' ... RUBY`; they created only temporary
files outside the repository and printed the result maps below.

| Exact command | Result |
|---|---|
| `rbenv exec bundle exec ruby -Itest test/approval_policy_document_test.rb` | 23 runs, 66 assertions, 0 failures, 0 errors, 0 skips |
| `rbenv exec bundle exec ruby -Itest test/approval_engine_test.rb` | 26 runs, 95 assertions, 0 failures, 0 errors, 0 skips |
| `rbenv exec bundle exec ruby -Itest test/approval_mode_switch_test.rb` | 11 runs, 30 assertions, 0 failures, 0 errors, 0 skips |
| `rbenv exec bundle exec ruby -Itest test/sqlite_approval_stores_test.rb` | 10 runs, 45 assertions, 0 failures, 0 errors, 0 skips |
| `rbenv exec bundle exec ruby -Itest test/agent_approval_boot_test.rb` | 5 runs, 18 assertions, 0 failures, 0 errors, 0 skips |
| `rbenv exec bundle exec ruby -Itest test/approval_resolve_test.rb` | 16 runs, 62 assertions, 0 failures, 0 errors, 0 skips |
| `rbenv exec bundle exec ruby -Itest test/approval_reload_test.rb` | 8 runs, 15 assertions, 0 failures, 0 errors, 0 skips |
| `rbenv exec bundle exec ruby -Itest test/agent_schedule_test.rb` | 9 runs, 65 assertions, 0 failures, 0 errors, 0 skips |
| `rbenv exec bundle exec ruby -Itest test/agent_mode_switch_kill_matrix_test.rb` | 2 runs, 17 assertions, 0 failures, 0 errors, 0 skips |
| `rbenv exec bundle exec ruby -Itest test/agent_mode_switch_test.rb` | 4 runs, 45 assertions, 0 failures, 0 errors, 0 skips |
| `rbenv exec bundle exec ruby -Itest test/approval_grant_key_test.rb` | 4 runs, 8 assertions, 0 failures, 0 errors, 0 skips |
| `rbenv exec bundle exec ruby -Itest test/approval_values_test.rb` | 6 runs, 30 assertions, 0 failures, 0 errors, 0 skips |

Focused probes and results:

- A temporary policy with a `network` tool override of `grant_scopes: [once,
  session]` loaded successfully and evaluated as `{:tier=>:network,
  :verdict=>:ask, :scopes=>[:once, :session], :key=>{:verb=>"execute",
  :tool=>"send_http", :target_root=>["workspace"]}}`. This is the tool-level
  validator bypass in `F13-SEC-01`.
- A temporary policy with `grant_scopes: [once, session, lifetime]` loaded and
  resolved `:lifetime`, producing `{:scopes=>[:once, :session, :lifetime],
  :resolved_scope=>:lifetime, :expires_at_ms=>nil}`. This is `F13-SEC-02`.
- A `MemoryGrantStore` that raised on its first insert produced
  `{:first_error=>"RuntimeError: simulated grant-store outage",
  :resolution_logged=>true, :second_scope=>:session, :insert_attempts=>1,
  :grant_store_lookup_after_replay=>false}`. This is `F13-REL-01`.
- A decision log that raised on `record_mode_switch` produced
  `{:error=>"RuntimeError: simulated decision-log outage",
  :in_memory_rev_after_error=>"<auto revision>", :durable_switch=>nil}` while
  the prior revision was still `<implement revision>`. This is `F13-REL-02`.
- Loading `review`, deciding `create_file`, reloading a plain base document, and
  deciding for a new session produced
  `{:before_profile=>"review", :before_verdict=>:ask, :after_profile=>nil,
  :after_verdict=>:allow}`. This is `F13-COR-02`.
- A SQLite temporary database was resolved by one engine, closed without session
  teardown to model a crash, and reopened by a second engine with the same
  `profile:default` session key. It produced
  `{:grant_expires_at_ms=>nil, :replay_verdict=>:allow,
  :replay_rule=>"engine.grant_hit"}`. This is `F13-SEC-03`.
- The public CLI scheduled a write with `--approval-profile review` while the
  runtime was configured `auto`; the occurrence completed and changed the file
  with `:pending_approvals=>0`. Reversing the setup, a schedule with
  `--approval-profile auto` under runtime `review` parked with
  `:pending_approvals=>1` and `events=>["request.paused"]`. These are two
  directions of `F13-COR-01`.

The passing schedule test only asserts that the field is stored and displayed
(`test/agent_schedule_test.rb:62-75`); it does not exercise an occurrence under
the named approval profile. The passing tier-level network test likewise does not
exercise a tool-level override (`test/approval_policy_document_test.rb:178-190`).

## Findings

### F13-COR-01 — Persisted schedule approval profiles are ignored at execution

- **Severity:** major; **confidence:** high; **status:** open
- **Owner seam:** `tamoz-agent-cli` schedule enqueue → `tamoz-agent` schedule materialization and approval-session binding
- **Impact:** `--approval-profile` is presented as the approval profile for occurrences, but the worker uses the runtime's global profile. A schedule declared `review` can execute under `auto`; a schedule declared `auto` can unexpectedly park under `review`.
- **Citations:** `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb:35-40`, `205-220`; `gems/tamoz-agent-cli/lib/tamoz/agent/cli_schedule_commands.rb:50-52`, `84-96`; `gems/tamoz-agent/lib/tamoz/agent/worker.rb:147-165`, `261-267`; `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:413-432`, `670-677`; `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:700-706`, `1030-1057`, `1171-1185`.

Five whys:

1. The schedule's `approval_profile` is captured and persisted, but `materialize_due_schedules` supplies only `{"task" => task_for(schedule)}` to the schedule store.
2. The schedule store enqueues that template and the thread address; it does not copy the approval profile into the request or a trusted binding.
3. The worker obtains the session from the thread binding, and `bind_approval_session` uses `@directory.approval_profile`, which is runtime-wide.
4. The only current test for this field checks add/show round-trip, so the cross-gem execution contract has no end-to-end assertion.
5. The operator's declared authority policy is therefore not the policy enforced for the scheduled effect, creating both an unexpected park and an unexpected headless write.

**Smallest recommendation:** carry `schedule.approval_profile` into the trusted
thread/session binding at materialization and make the worker load that profile
for the occurrence; add one public CLI integration test in each direction. If the
field cannot be wired now, remove the flag and field until the contract is real.

### F13-COR-02 — Reload drops the configured profile overlay

- **Severity:** major; **confidence:** high; **status:** open
- **Owner seam:** active-policy pointer (`tamoz-agent-cli` / `tamoz-sqlite`) → `WorkerRuntime#sync_approval_policy`
- **Impact:** A runtime booted with `review` or `auto` can silently change effective policy for new sessions after a valid reload. In the reproduced case, `create_file` changed from `:ask` under `review` to `:allow` after reload.
- **Citations:** `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:396-407`; `gems/tamoz-sqlite/lib/tamoz/sqlite/approval_active_policy.rb:5-8`, `15-35`; `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:756-774`, `1179-1192`; `gems/tamoz-approval/lib/tamoz/approval/policy_document.rb:42-50`, `85-107`; `gems/tamoz-approval/policy/base.yaml:42-49`; `gems/tamoz-approval/policy/profiles/review.yaml:1-5`.

Five whys:

1. The CLI validates a base document and writes only `(document.path,
   document.policy_rev)` to the active-policy row.
2. The active-policy schema has no profile name, so the selected profile cannot
   be reconstructed from the pointer.
3. The worker sees a revision change and calls `PolicyDocument.load(pointer.path)`,
   not `load_profile` with the configured profile.
4. `Engine#reload` adopts that base document and new sessions bind the new base
   revision; the old effective overlay is absent.
5. A valid reload therefore changes the authority contract for future sessions
   without an operator selecting a different profile or the revision representing
   the effective policy that was actually loaded.

**Smallest recommendation:** persist the selected profile with the active-policy
pointer, or have the worker reapply the configured profile and compare the
effective revision before `Engine#reload`; test a profile-sensitive reload.

### F13-SEC-01 — Tool overrides can reintroduce `:session` for no-session tiers

- **Severity:** major; **confidence:** high; **status:** open
- **Owner seam:** `PolicyDocument#validate_tool_tiers!`
- **Impact:** A custom policy can map a network, publish, or destructive tool to a
  tool-level `grant_scopes: [once, session]`; the loader accepts it, the evaluator
  offers a session grant, and the engine can persist that grant. This violates the
  no-session authority invariant for opaque or high-risk tiers.
- **Citations:** `gems/tamoz-approval/lib/tamoz/approval/policy_document.rb:209-228`, `239-255`; `gems/tamoz-approval/lib/tamoz/approval/evaluator.rb:82-102`; `gems/tamoz-approval/lib/tamoz/approval/engine.rb:243-256`; `documentation/adr/approval-policy-redesign/00-acceptance-bar.md:67-73`, `98-101`; `documentation/adr/approval-policy-redesign/03-redesign-adr.md:370-376`.

Five whys:

1. `validate_tool_tiers!` takes the entry's override scopes and checks the
   `child_task` special case.
2. Its `next unless scopes.include?(:session) && !NO_SESSION_SCOPE_TIERS.include?(tier)` skips the rest of the loop for a network/publish/destructive tier.
3. The following no-session rejection is therefore unreachable for exactly the
   tiers it is meant to protect.
4. `Evaluator#tool_scopes_for` trusts the entry override and `Engine#mint_grant`
   accepts any scope that appears in the resulting offer.
5. One approval can become session-wide authority for a tier whose policy
   contract explicitly permits only `:once`.

**Smallest recommendation:** reject `:session` for `NO_SESSION_SCOPE_TIERS`
before the `next`, and validate every tool override against the tier's no-session
rule. Add a regression with a network tool entry, not only a tier-level scope.

### F13-SEC-02 — Grant-scope vocabulary is open-ended

- **Severity:** major; **confidence:** high; **status:** open
- **Owner seam:** `PolicyDocument` scope normalization/validation → `Engine#mint_grant`
- **Impact:** YAML can introduce an unsupported scope such as `lifetime`; the
  engine will offer and mint it with no lifecycle or lookup semantics. The
  normative contract defines only `:once` and `:session`, so policy authors can
  create authority values that callers and stores do not understand uniformly.
- **Citations:** `gems/tamoz-approval/lib/tamoz/approval/policy_document.rb:116-142`, `201-255`; `gems/tamoz-approval/lib/tamoz/approval/evaluator.rb:82-102`; `gems/tamoz-approval/lib/tamoz/approval/engine.rb:243-256`; `documentation/adr/approval-policy-redesign/03-redesign-adr.md:375-376`.

Five whys:

1. The loader maps YAML scope strings to symbols without a closed vocabulary.
2. Validation checks whether `:session` is present and whether a matching grant
   key exists, but never rejects another symbol.
3. The evaluator copies the resulting list into `GrantOffer`.
4. `Engine#mint_grant` checks membership in that list and constructs a `Grant`
   with the arbitrary scope; it does not enforce the contract independently.
5. A policy edit can therefore mint an unimplemented authority lifetime, with
   `expires_at_ms` still nil and no consumer-specific semantics.

**Smallest recommendation:** define the supported scope set as policy-schema
data validation (`:once`, `:session`) and reject all other values at load; retain
the Engine membership check as a defense in depth.

### F13-REL-01 — Resolution can commit without a repairable session grant

- **Severity:** major; **confidence:** high; **status:** open
- **Owner seam:** `Engine#resolve` decision-log / grant-store handoff
- **Impact:** A transient grant-store failure after the decision resolution is
  recorded leaves the durable answer present but the lookupable session grant
  absent. Replays return the recorded grant before attempting insertion, so the
  worker repeatedly re-asks instead of converging.
- **Citations:** `gems/tamoz-approval/lib/tamoz/approval/engine.rb:73-100`; `gems/tamoz-approval/lib/tamoz/approval/decision_log.rb:5-11`, `93-112`; `gems/tamoz-sqlite/lib/tamoz/sqlite/approval_decision_log.rb:63-87`; `gems/tamoz-sqlite/lib/tamoz/sqlite/approval_grant_store.rb:18-45`; `documentation/adr/approval-policy-redesign/00-acceptance-bar.md:76-84`.

Five whys:

1. `Engine#resolve` records the answer and grant in `DecisionLog` before calling
   `grant_store.insert`.
2. The SQLite decision update and grant insert are separate transactions.
3. If the insert raises, the resolution remains durable and the caller sees an
   error even though the journal says the answer is settled.
4. A later resolve with the same answer/scope returns `recorded[:grant]` at the
   replay branch before it calls `grant_store.insert` again.
5. `decide` cannot find the missing session row, so the approval path remains
   inconsistent until manual repair or a new decision shape happens to bypass it.

**Smallest recommendation:** make replay of a session resolution idempotently
ensure the grant row exists before returning it, and make the durable adapter
able to commit the resolution and grant together when both are SQLite-backed.

### F13-REL-02 — Mode rebind publishes memory before its durable audit

- **Severity:** major; **confidence:** medium; **status:** open
- **Owner seam:** `Engine#rebind_session` → `DecisionLog#record_mode_switch`, with worker error handling in `Worker#apply_mode_switch`
- **Impact:** If the mode-switch log is unavailable, the current process evaluates
  the session under the new profile even though no switch is durable. A restart
  reconstructs the old mode; the inbox request may also retry after the worker has
  already changed memory.
- **Citations:** `gems/tamoz-approval/lib/tamoz/approval/engine.rb:135-157`, `183-199`; `gems/tamoz-agent/lib/tamoz/agent/worker.rb:988-1033`; `gems/tamoz-approval/lib/tamoz/approval/decision_log.rb:29-43`; `documentation/adr/approval-policy-redesign/00-acceptance-bar.md:135-140`; `documentation/adr/approval-policy-redesign/03-redesign-adr.md:464-498`.

Five whys:

1. `rebind_session` loads the new profile, stores its document, and flips
   `@session_revs` while holding the mutex.
2. It calls `record_switch` only after leaving that critical section.
3. Any non-conflict log failure escapes; the worker's broad rescue emits an error
   and returns `false` without rolling back the in-memory revision.
4. The same session can make approval decisions under the new profile while
   `latest_mode_switch` is nil and a fresh engine cannot reconstruct the change.
5. The durable mode-switch contract is broken at the exact failure boundary that
   should make a restart converge to one policy revision.

**Smallest recommendation:** record the mode switch successfully before exposing
the new in-memory revision, or roll the revision back and leave the request
retryable when audit recording fails; add a failure-injected mode-switch test.

### F13-SEC-03 — Crash cleanup does not bound durable session grants

- **Severity:** major; **confidence:** medium; **status:** open
- **Owner seam:** worker approval-session lifecycle (`WorkerRuntime` / `Worker`) → SQLite `ApprovalGrantStore`
- **Impact:** The worker's normal resolution path mints a nil-expiry `:session`
  grant under a stable `profile:<id>` key. If the worker crashes before cleanup,
  a later worker with the same policy revision and profile key can receive an
  automatic `engine.grant_hit` allow for the old grant.
- **Citations:** `gems/tamoz-agent/lib/tamoz/agent/worker.rb:491-500`, `106-112`; `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:1171-1176`; `gems/tamoz-approval/lib/tamoz/approval/engine.rb:160-179`, `282-296`; `gems/tamoz-sqlite/lib/tamoz/sqlite/approval_grant_store.rb:18-55`; `gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb:1085-1099`; `documentation/adr/approval-policy-redesign/03-redesign-adr.md:375-386`.

Five whys:

1. `resolve_approval_asks` passes `scope` but no `expires_at_ms`, so
   `Engine#mint_grant` stores a nil expiry.
2. `bind_approval_session` names the durable session only as
   `profile:<profile-id>`, which is reused after a process restart.
3. Cleanup runs in `ensure`, but the worker rescues and suppresses cleanup
   errors, and a crash can skip the ensure block entirely.
4. SQLite grants are matched by key, scope, session id, and policy revision; the
   table has no worker epoch or run fence to distinguish the old process.
5. The next worker can therefore treat an old session grant as live, contrary to
   the documented session-lifetime contract, unless process restart is explicitly
   intended to preserve the same logical approval session.

**Smallest recommendation:** rotate a durable session/run epoch in the session
id at worker start, or set a bounded expiry tied to the session budget and revoke
old epochs on startup; make cleanup failure observable rather than silently
discarded. If restart is intentionally the same logical session, document that
exception and add an explicit lifecycle proof.

### F13-SCA-01 — Append-only decision records have no retention seam

- **Severity:** info; **confidence:** high; **status:** unconfirmed
- **Owner seam:** SQLite approval decision-log lifecycle
- **Impact:** Each decision and grant-hit is appended to
  `tamoz_approval_decisions`, and the migration exposes no purge, archive, or
  bounded-retention operation. A long-lived worker can grow this table without
  an operator-visible resource bound.
- **Citations:** `gems/tamoz-approval/lib/tamoz/approval/decision_log.rb:5-11`; `gems/tamoz-approval/lib/tamoz/approval/engine.rb:43-53`, `315-334`; `gems/tamoz-sqlite/lib/tamoz/sqlite/approval_decision_log.rb:31-52`; `gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb:1101-1137`; `documentation/adr/approval-policy-redesign/04-review-simplicity.md:97-100`.

This is recorded as an informational contract/evidence gap, not a claim that a
current run exceeds a measured limit. The review found no load or retention probe.

**Smallest recommendation:** document an operator-owned retention/archival bound
for decision records, or explicitly accept unbounded retention before treating
the append-only table as production-complete.

## Confirmed design facts and overlap

- The policy gem owns decision evaluation and policy content remains in YAML; the
  gem's core-only dependency direction is intact (`gems/tamoz-approval/README.md:5-21`).
  No action-specific verdict, bypass flag, or domain catalog was found hardcoded in
  the F13 path. `read_only ⇒ read`, deny-first evaluation, and no-session tier
  restrictions are structural invariants, not replacement verdict data.
- Deny-first evaluation, exact session grant tuple matching, policy revision
  binding, immutable decision values, and answer conflict detection are present and
  covered by the focused tests. These facts do not close the cross-gem gaps above.
- The current accepted `F05-REL-05` finding owns the scheduler materialization
  wedge; `F13-COR-01` is separate and owns the unconsumed approval-profile field at
  that boundary. `F25-SEC-01` owns widened thread profile authority after restart;
  `F13-COR-02` owns reload's loss of the approval overlay, and `F13-SEC-03` owns
  durable approval-grant lifecycle. They should be challenged together but are not
  duplicate rows.
- The current synthesized systemic theme (`F20-SEC-01`, `F23-SEC-01`, and the
  healing/improvement family) concerns unbound `"human:"` approval strings. F13
  does not duplicate it: the approval engine's answer/evidence validation is a
  separate seam, and the observed nullable actor evidence is recorded as a lens
  note only.

## Blind spots

- No full CI, lint, load, soak, or live-provider run was performed; the requested
  scope was a bounded source review with focused tests and failure-injected probes.
- The schedule probes used the fixture model and public CLI; they prove the
  profile is ignored at the execution seam, not provider behavior.
- The SQLite crash probe closed the adapter without `Engine#close_session` to model
  an ungraceful stop. Whether a product-level restart is intended to preserve the
  same logical approval session is an unresolved contract question; the current
  code and comments claim grants die with the worker/session.
- The retention item has no measured production growth rate and is intentionally
  informational/unconfirmed.
- No challenge agent was run by this analyst. Per the audit bar, all major rows
  remain open pending coordinator challenge.

## Report metadata and format

- Report files are the only repository files owned by this analyst. No production
  code, tests, configuration, root audit document, or existing analysis was edited.
- The companion JSON is `analyses/F13-approval.json` and uses the required row
  schema. Counts are `critical=0`, `major=7`, `minor=0`, `info=1`.

### Concise report format

- **Files changed:** `docs/audits/functionality-audit-2026-09-15/analyses/F13-approval.md`; `docs/audits/functionality-audit-2026-09-15/analyses/F13-approval.json`.
- **Exact commands / pass counts:** the 12 commands in “Tests, contracts, and probes”; 124 runs, 496 assertions, 0 failures, 0 errors, 0 skips. Inline probes are listed there with exact result maps.
- **Deviations:** no broad suite, lint, implementation, or commit; no test file was run with a second test file in the same command.
- **Proof of boundary:** `git diff --name-only` remained empty; `git status --short --untracked-files=all` showed only the coordinator's pre-existing untracked audit tree plus these two new F13 paths. The only non-repository write was the required liveness log under `/tmp/tamoz-agents`.
