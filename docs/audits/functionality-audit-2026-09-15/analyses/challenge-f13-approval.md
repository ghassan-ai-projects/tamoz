# Independent challenge — F13 approval

| Field | Value |
|---|---|
| Row | F13 — `tamoz-approval` approval policy, grants, decisions, and durable log |
| Baseline | `audit-15-09` at `582ae5566de1ae073aea82b69bb2bbf444494d3b` |
| Date | 2026-09-15 |
| Challenger | independent read-only challenge agent |
| Boundary | Only this challenge file and `/tmp/tamoz-agents/challenge_f13_approval.log` were writable |

## Method and source boundary

I read `docs/subagent-orchestration.md`, `README.md`, the audit `BAR.md`,
`COVERAGE.md`, and `FINDINGS.md` before reading `analyses/F13-approval.md` and
`analyses/F13-approval.json`. I re-read every live path cited by the F13 record:

- `gems/tamoz-approval/lib/tamoz/approval/{policy_document,evaluator,engine,decision_log,grant_store,grant,decision}.rb`;
- `gems/tamoz-approval/policy/base.yaml` and `policy/profiles/*.yaml`;
- `gems/tamoz-sqlite/lib/tamoz/sqlite/{approval_decision_log,approval_grant_store,approval_active_policy,migrator,database_kernel}.rb`;
- `gems/tamoz-agent/lib/tamoz/agent/{worker,worker_runtime,runtime/step_execution}.rb`;
- `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb`;
- `gems/tamoz-agent-cli/lib/tamoz/agent/{cli,cli_worker_commands,cli_schedule_commands}.rb`;
- `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb` and
  `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb`;
- `documentation/adr/approval-policy-redesign/{00-acceptance-bar,03-redesign-adr,04-review-simplicity}.md`.

I also checked the existing F05, F07, F09, F10, F20, F21, F22, F23, F24, and
F25 records and their available challenge records for ownership overlap. All
probes below used temporary data under `/tmp`; no source, test, configuration,
or existing audit file was edited.

## Verdict summary

The analyst reproduced five findings accurately. F13-SEC-02 is a real schema
defect but its current consequence is an inert, unsupported grant value, so I
demote it to minor. F13-SEC-03 is real at the durable engine lifecycle seam,
but its stated “normal worker path mints `:session`” reachability claim is false:
the in-tree worker and one-shot paths pass `:once`. I retain major only for the
documented/public session-grant lifecycle contract and mark reachability
medium. F13-SCA-01 is an accepted design choice rather than an open defect.

| Finding | Challenge result | Recommended disposition |
|---|---|---|
| F13-COR-01 | **Reproduce**; stored schedule profile is never consumed | Keep **major**, high, open; owner is the schedule-to-approval binding seam |
| F13-COR-02 | **Reproduce**; reload adopts base policy and drops overlay | Keep **major**, high, open |
| F13-SEC-01 | **Reproduce**; tool override bypasses no-session tier guard | Keep **major**, high, open |
| F13-SEC-02 | **Reproduce**, but repeat authority is not widened by current consumers | **Demote to minor**, high, open; retain as schema hardening |
| F13-REL-01 | **Reproduce** against separate SQLite transactions | Keep **major**, high, open |
| F13-REL-02 | **Reproduce**; retry can complete with no durable audit row | Keep **major**, high for engine seam, open |
| F13-SEC-03 | **Qualify**; direct durable session grant survives crash, normal worker uses once | Keep **major**, medium reachability, open, narrowed to session-grant lifecycle |
| F13-SCA-01 | **Refute as a defect**; retention with the database is explicitly accepted | Record as accepted **info/design fact**, close the defect lead |

The row remains `IMPROVE` because six major findings survive this challenge,
even after the SEC-02 demotion and SCA-01 closure.

## F13-COR-01 — persisted schedule approval profiles are ignored

**Challenge: reproduce. Severity: major, high confidence, open.**

`Schedule` validates, digests, stores, and exposes `approval_profile`
(`gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb:35-40,205-220`). The CLI
accepts `--approval-profile` and places it on the value
(`gems/tamoz-agent-cli/lib/tamoz/agent/cli_schedule_commands.rb:50-52,84-96`).
The worker's materialization call supplies only a task template and the current
worker grant (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:147-165`). The SQLite
store serializes that template and the thread address but has no approval-profile
consumer (`gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:413-432`). The
resulting session is selected from the thread binding and the runtime-wide
approval profile (`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:700-706,
1030-1057,1171-1185`).

I ran the public schedule path, then materialized a due occurrence against a
temporary runtime database. The stored field survived, while the request
payload had no such field:

```text
{:stored_approval_profile=>"unattended", :stored_schedule_thread=>"schedule.nightly",
 :materialized_count=>1, :request_payload=>{"task"=>"X"},
 :request_payload_has_approval_profile=>false, :occurrence_id=>"sha256:..."}
```

This is sufficient to reproduce the boundary defect; it does not depend on a
model response. A control with the default/explicit `implement` profile under a
runtime also configured `implement` is internally consistent, which explains
why ordinary schedule tests pass. It does not make a cross-profile schedule
correct. The reverse direction is the security-relevant case: a schedule
declared `review` can run under runtime `auto`, and an `auto` schedule can park
under runtime `review`.

Threat-model assumptions: an operator (or another trusted schedule producer)
creates a valid schedule with a named approval profile, and the worker later
materializes it in the same runtime directory. The schedule task itself does
not need to be hostile; the authority mismatch is enough.

Five whys:

1. The schedule value captures `approval_profile`.
2. Materialization calls the existing request-template seam with only `task`.
3. The schedule store persists the request and occurrence, but no trusted
   thread/session binding carries the approval profile.
4. `WorkerRuntime#session_for` follows the thread's trusted agent profile and
   `bind_approval_session` reads only `@directory.approval_profile`.
5. The operator-visible schedule contract and the enforced approval contract
   therefore diverge at execution, including an unexpected headless allow.

The owning fix is the schedule-to-session binding, not F05's scheduler claim
and occurrence lease behavior. F05-REL-05 owns a lost consumer wedging an
occurrence; F24 owns CLI surface behavior. F13 owns this unconsumed approval
field and its authority consequence.

## F13-COR-02 — reload drops the configured profile overlay

**Challenge: reproduce. Severity: major, high confidence, open.**

The reload CLI writes only a path and revision
(`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:396-407`). The
active-policy row has only `id`, `policy_path`, `policy_rev`, and timestamp
(`gems/tamoz-sqlite/lib/tamoz/sqlite/approval_active_policy.rb:5-8,15-35`).
`WorkerRuntime#sync_approval_policy` loads the pointer with `PolicyDocument.load`
(`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:756-774`), while boot alone
uses `load_profile` (`worker_runtime.rb:1179-1192`; `policy_document.rb:42-50,
85-107`).

An actual `WorkerRuntime` booted with `review` was given a valid active pointer
to the bundled base document. After sync, a newly built `trusted` session used
the base document, while the already-bound default session correctly retained
the old overlay:

```text
{:initial_profile=>"review", :initial_rev=>"e58a...",
 :bound_default_rev=>"e58a...", :active_pointer_rev=>"543a...",
 :live_profile_after_sync=>nil, :live_rev_after_sync=>"543a...",
 :future_session_profile=>nil, :future_session_rev=>"543a...",
 :future_session_built=>true, :default_session_profile=>"review"}
```

The control matters: session pinning for existing work still holds, so this is
not a claim that reload retroactively changes parked work. The defect is the
silent authority change for future sessions. A valid edit and pointer publish
are enough; no malformed policy or missing test is needed.

Threat-model assumptions: the runtime starts with a configured overlay such as
`review` or `auto`, a valid base document is published through the existing
reload command, and a new session is opened afterward. No attacker needs to
edit the policy between validation and publication.

Five whys:

1. The CLI records the base document's path and revision.
2. The active-policy schema has no profile name or effective-profile digest.
3. Sync loads the path as a base `PolicyDocument` and passes it to `Engine#reload`.
4. The new global document has no overlay, and sessions created after the sync
   bind its revision.
5. A successful reload changes the future-session authority without an operator
   selecting a new approval profile.

F25-SEC-01 owns worker restart reloading a mutable trusted **agent** profile by
   id without its digest. F13-COR-02 owns approval-policy reload losing the
   selected overlay; the sources, bytes, and fixes are different. F21's replay
   digest binding and F22's session guard are adjacent controls, not duplicates.

## F13-SEC-01 — tool overrides reintroduce `:session` for no-session tiers

**Challenge: reproduce. Severity: major, high confidence, open.**

`PolicyDocument#validate_tool_tiers!` takes the entry override scopes, handles
the `child_task` special case, then executes `next` when the tier is one of the
no-session tiers (`gems/tamoz-approval/lib/tamoz/approval/policy_document.rb:
209-228`). The later no-session rejection is unreachable for a `network`,
`external_publish`, or `destructive` entry override. Tier-level validation does
reject the same scope when it is declared on the tier (`:239-255`). The evaluator
preserves a classified tool's override (`evaluator.rb:82-102`), and the engine
accepts any scope present in that offer (`engine.rb:243-256`). This contradicts
the acceptance bar and redesign ADR (`documentation/adr/approval-policy-redesign/
00-acceptance-bar.md:67-73,98-101`; `03-redesign-adr.md:370-376`).

The temporary policy below classified `send_http` as `network`, gave the tool
an override of `[once, session]`, supplied a valid grant key and a target root,
and then used the public engine:

```text
{:loaded=>true, :tool_tier=>:network, :offered_scopes=>[:once, :session],
 :resolved_scope=>:session, :repeat_verdict=>:allow,
 :repeat_rule=>"engine.grant_hit", :grant_rows=>1}
{:tier_level_session_rejected=>true,
 :error=>"tier network grant_scopes may not include :session"}
```

The control demonstrates that the protection is present only at the tier
declaration. The threat model is an operator-authored policy edit or a policy
producer that supplies a conflicting tool override; it does not require a
workspace write or a network provider to be live. A single approved network
question becomes reusable session authority.

Five whys:

1. The validator selects the tool override as the effective scope list.
2. Its `next` condition skips the no-session rejection for the protected tier.
3. The evaluator trusts that list and constructs a session-capable offer.
4. `Engine#resolve` persists the resulting session grant and later lookup uses
   `engine.grant_hit`.
5. One approval can authorize repeated high-risk effects contrary to the
   no-session contract.

F09/F10 own MCP admission, websearch endpoint, egress, and provider wiring.
Neither owns this generic policy schema guard. F13-SEC-02 below is the residual
scope-vocabulary defect; the actual high-risk session authority remains owned by
F13-SEC-01 and must not be counted twice.

## F13-SEC-02 — grant-scope vocabulary is open-ended

**Challenge: reproduce, but qualify severity. Recommended: minor, high
confidence, open.**

Normalization maps arbitrary YAML strings to symbols
(`gems/tamoz-approval/lib/tamoz/approval/policy_document.rb:116-142`). Validation
checks the presence of `:session`, grant-key availability, and the special
no-session tiers, but never checks a closed set (`:201-255`). The evaluator
copies the list and `Engine#mint_grant` checks only membership in that offer
(`evaluator.rb:82-102`; `engine.rb:243-256`). The normative ADR defines only
`:once` and `:session` (`documentation/adr/approval-policy-redesign/03-redesign-
adr.md:375-376`).

I loaded a temporary policy advertising `[once, session, lifetime]` and resolved
the unsupported value:

```text
{:loaded=>true, :offered_scopes=>[:once, :session, :lifetime],
 :resolved_scope=>:lifetime, :grant_store_rows_after_lifetime=>0,
 :replay_decision=>:ask, :replay_rule=>"tier.local_execute",
 :control_scope=>:session, :control_store_rows=>1,
 :control_replay_decision=>:allow, :control_replay_rule=>"engine.grant_hit"}
```

The behavior is a genuine schema/contract defect: a durable decision row can
record an unsupported scope, and the returned `Grant` has no defined lifecycle.
The analyst's major impact claim is too strong on the current tree, however.
Only `:session` is inserted into or looked up from the grant store
(`engine.rb:96-99,282-296`); `:lifetime` produces no repeat allow. All in-tree
production resolution callers pass `:once` or `nil`
(`gems/tamoz-agent/lib/tamoz/agent/worker.rb:454,1136`,
`gems/tamoz-agent/lib/tamoz/agent/runtime/step_execution.rb:159-165`, and
`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:522-525`). No current caller treats
an arbitrary returned scope as a general authority token.

Threat-model assumptions: a trusted policy author can introduce a new scope
symbol, but no current in-tree caller interprets it as an auto-allow or a
durable capability. A future consumer that does so would change the impact and
must be assessed at that new seam.

Five whys, including the severity check:

1. YAML scope strings are symbolized without a supported-scope set.
2. Validation has special rules for `:session`, but no closed vocabulary.
3. The evaluator offers every resulting symbol.
4. The engine mints and journals any offered symbol, while stores implement only
   the `:session` lookup path.
5. The system accepts an inert, undefined grant value; that is schema drift and
   future-call-site risk, not a demonstrated current authority bypass.

The control is the normal `[once, session]` policy: a session resolution inserts
one row and the next decision returns `engine.grant_hit`. The unsupported value
does neither. F13-SEC-01 owns the distinct case where an actually reusable
`:session` grant reaches a tier that forbids it; SEC-02 should not inherit that
severity merely because both start in policy normalization.

The smallest fix remains load-time validation against `{once, session}` plus the
engine membership check as defense in depth. If a future consumer gives
unsupported scopes lifecycle semantics, the grade should be revisited from the
new call site with evidence.

## F13-REL-01 — resolution commits without a repairable session grant

**Challenge: reproduce. Severity: major, high confidence, open.**

`Engine#resolve` records the resolution before calling
`grant_store.insert` (`gems/tamoz-approval/lib/tamoz/approval/engine.rb:73-100`).
The SQLite decision update and grant insertion each use their own transaction
(`gems/tamoz-sqlite/lib/tamoz/sqlite/approval_decision_log.rb:63-87` and
`approval_grant_store.rb:18-45`; the adapter transaction boundary is in
`database_kernel.rb`). On replay, the engine returns the recorded grant at the
early branch and never repairs the missing row (`engine.rb:85-98`).

I wrapped the real SQLite grant store with a fail-once insert seam. The first
resolution committed to the SQLite decision row, then the grant insert failed;
after reopening the database, replay returned a grant object but still left no
lookup row:

```text
{:first_error=>"RuntimeError: simulated grant-store outage",
 :resolution_logged=>true, :logged_scope=>:session,
 :grant_rows_after_error=>0, :replay_scope=>:session,
 :grant_rows_after_replay=>0, :next_decision=>:ask,
 :next_rule=>"tier.local_execute", :insert_attempts=>1}
```

A healthy-store control inserts one row and a repeat decision returns
`:allow`/`engine.grant_hit`; the failure is therefore the transaction handoff,
not an expected no-grant behavior. The threat model is a transient SQLite/store
failure after resolution commit. No concurrency race or missing test is needed.

Five whys:

1. The engine's critical section spans calls but not one shared durable
   transaction.
2. The decision log commits the answer and grant projection first.
3. The separate grant transaction can fail after that commit.
4. Replay trusts the recorded resolution and returns before retrying insertion.
5. The journal says “approved” while the lookup path asks again forever until
   manual repair or a different request identity appears.

F07-REL-01 owns the request-inbox candidate starvation/claim threshold, and
F07-SEC-01 owns cross-thread effect-row authorization. F13-REL-01 is the
approval-specific decision-log/grant-store handoff; it should not be merged into
the generic SQLite request/effect findings. F22-REL-01 has already been merged
into F07-REL-01 and is unrelated to this grant row.

The repair recommendation is sound: make the replay branch idempotently ensure
the session row exists, or give the two SQLite-backed writes one transaction
boundary with a recovery-safe receipt.

## F13-REL-02 — mode rebind publishes memory before durable audit

**Challenge: reproduce. Severity: major, high confidence for the engine seam,
open.**

`Engine#rebind_session` installs the new document and updates `@session_revs`
under its mutex, then records the mode switch after unlocking
(`gems/tamoz-approval/lib/tamoz/approval/engine.rb:135-157`).
`record_switch` rescues only the conflict case
(`engine.rb:183-199`). In the worker, another `StandardError` is emitted and
returns `false` without rolling back the session (`gems/tamoz-agent/lib/tamoz/
agent/worker.rb:988-1033`). The acceptance bar requires the switch to be
durable (`documentation/adr/approval-policy-redesign/00-acceptance-bar.md:135-140`;
`03-redesign-adr.md:464-498`).

I used a decision log that raises once on `record_mode_switch`:

```text
{:from_rev=>"543a...", :rebind_error=>"RuntimeError: simulated mode-switch log outage",
 :in_memory_profile_after_failure=>"auto", :in_memory_rev_after_failure=>"78d4...",
 :mode_switch_row_after_failure=>nil, :retry_result=>"78d4...",
 :mode_switch_attempts=>1, :mode_switch_row_after_retry=>nil,
 :next_decision=>:allow}
{:control_switch_logged=>true, :control_rev=>"78d4...", :control_profile=>"auto"}
```

The second call is the key control of the failure path: because the in-memory
session already has the destination revision, `rebind_session` returns before
calling the log again. A fresh engine has no durable override and reconstructs
the old mode. The normal log control records the row and a new engine can
reconstruct `auto`.

Threat-model assumptions: an otherwise valid operator mode switch reaches the
engine, and the decision log has a transient non-conflict failure after the
engine changes its in-memory map. The worker's retry/recovery path then uses the
same engine or a fresh engine over the same durable store.

Five whys:

1. The implementation changes the live session map before the audit call.
2. The audit call is outside the mutex and is not part of a transaction with the
   map update.
3. A non-conflict log outage escapes to the worker rescue, which leaves the map
   changed.
4. Retry sees `prior == new_policy.policy_rev` and skips the audit call, while a
   fresh engine sees no mode-switch row.
5. One process can execute under a mode that another process cannot prove or
   reconstruct, violating the durable switch contract.

F22-SEC-01 is the session's missing profile-digest check; F21/F25 own profile
authority integrity across replay/restart. This finding is the ordering and
retry behavior of the approval mode-switch audit itself. F13 owns it, while
F07's durable transaction findings remain separate.

The smallest repair is to persist the switch before exposing the new in-memory
revision, or roll the map back and leave the inbox request retryable when the
audit write fails. The failure-injected regression should assert both the
request retry and the durable row.

## F13-SEC-03 — crash cleanup does not bound durable session grants

**Challenge: qualify reachability. Severity: major for the session-grant
lifecycle contract, medium confidence for in-tree product reachability, open.**

The durable engine can mint a `:session` grant with no expiry, and lookup matches
the stable `(key, scope, session_id, policy_rev)` tuple
(`gems/tamoz-approval/lib/tamoz/approval/engine.rb:160-179,282-296`; SQLite
`approval_grant_store.rb:18-55`). `WorkerRuntime#bind_approval_session` names a
session `profile:<id>` (`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:
1171-1176`), and `Worker#run` deletes grants only in its ensure block
(`gems/tamoz-agent/lib/tamoz/agent/worker.rb:106-112`). A process kill can skip
that ensure. Migration 17 has no worker epoch or run fence in the grant table
(`gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb:1085-1099`). The ADR says session
grants die with the session and records the accepted teardown/expiry contract
(`documentation/adr/approval-policy-redesign/03-redesign-adr.md:375-386`).

The analyst's exact reachability wording needs correction. The normal in-tree
worker approval path always resolves an approval as `:once`
(`worker.rb:454`); the one-shot step path also passes `:once`
(`gems/tamoz-agent/lib/tamoz/agent/runtime/step_execution.rb:151-165`). The
interactive CLI can choose `:session` only after the explicit remember prompt
(`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:519-525`), but that CLI constructs
an in-memory approval engine (`gems/tamoz-agent/lib/tamoz/agent.rb:61-79`), not
the worker's SQLite engine. Thus “the worker's normal resolution path mints a
session grant” is not reproduced and should be removed.

The lifecycle defect still reproduces through the public durable engine seam,
which supports session grants. I resolved a `run_check` approval under
`profile:default`, closed the SQLite adapter without `close_session` to model an
ungraceful crash, and reopened the same database and session key:

```text
{:session_key=>"profile:default", :first_grant_scope=>:session,
 :first_expires_at_ms=>nil, :grant_rows_before_crash=>1,
 :reopened_decision=>:allow, :reopened_rule=>"engine.grant_hit",
 :grant_rows_after_reopen=>1}
{:control_cleanup_decision=>:ask, :control_cleanup_rule=>"tier.local_execute",
 :control_grant_rows_after_reopen=>0}
```

The control calls `Engine#close_session` before reopening and gets the expected
ask. The threat model is therefore narrow and explicit: a legitimate caller
uses the durable engine's supported `:session` scope, the process dies after the
grant commit and before cleanup, and the same runtime directory, profile id,
and policy revision are reused. If the coordinator requires a currently shipped
worker path that selects `:session`, this should be demoted until such a caller
exists; the engine contract itself makes the stale grant behavior real.

Five whys:

1. Session grants are durable rows and are intended to die with a session.
2. Their identity uses a stable profile key and policy revision, with no worker
   epoch.
3. The engine accepts a nil expiry, and current durable session callers do not
   provide a deadline.
4. A kill skips the worker's cleanup ensure and the next process reuses the same
   tuple.
5. A previous human-approved session grant can silently allow a later process;
   the lifecycle guarantee is not enforced by durable identity.

F25-SEC-01 owns mutable trusted **agent** profile authority after worker restart;
F21 owns profile digest replay integrity. F13-SEC-03 owns the approval grant's
session lifetime. They are related restart hazards but not duplicate controls.
F05 owns scheduler occurrence retention/leases, not approval grants.

The smallest contract-complete repair is an epoch/run component in the durable
session id, or a bounded expiry tied to a real session budget plus startup
revocation. Cleanup failures should remain observable. The code and documentation
must first decide whether a worker restart is ever the same logical approval
session.

## F13-SCA-01 — append-only decisions have no retention seam

**Challenge: refute as a defect. Recommended: accepted info/design fact; close
the open defect lead.**

The observations are true: `DecisionLog` is append-only
(`gems/tamoz-approval/lib/tamoz/approval/decision_log.rb:5-11`), `Engine#decide`
and grant-hit logging append decisions (`engine.rb:43-53,315-334`), and the
SQLite migration creates the table and reuse index without purge methods
(`gems/tamoz-sqlite/lib/tamoz/sqlite/approval_decision_log.rb:31-52`; `migrator.rb:
1101-1137`). There is no measured load or storage incident in the F13 evidence.

The cited `04-review-simplicity.md:97-100` calls this a NIT and asks for one line
that either adds a purge story or explicitly accepts accumulation. The normative
redesign contains that acceptance: “The decision log is append-only and retained
with the database it lives in — accepted”
(`documentation/adr/approval-policy-redesign/03-redesign-adr.md:382-387`).
The security model likewise treats the durable decision log as the audit record
(`documentation/architecture/security-model.md:47`).

Threat-model assumptions: a long-lived, high-rate worker could grow its audit
table, but no F13 contract promises bounded storage, no measured threshold is
reported, and the owner explicitly accepted retention with the database.

Five whys, checking the alleged defect:

1. Approval decisions are retained for replay and audit.
2. The log is intentionally append-only and has no purge API.
3. The ADR explicitly chooses retention with the database.
4. No current contract gives F13 an operator-visible age or size bound.
5. Therefore this is an accepted resource/design choice, not evidence of a
   violated F13 behavior contract; a future retention requirement would be a
   new, measured scalability decision.

The control is the stated accepted contract itself: decisions remain available
for idempotent replay and audit, while reads are indexed by request identity.
F05-REL-04/05 concerns occurrence-history growth and a wedged schedule; F07's
storage findings concern request/effect rows. Neither changes the approval ADR's
explicit retention decision.

No code change is recommended for this challenge. If operators later need a
bounded audit store, record that as a new owner-approved retention requirement
with export/replay consequences rather than silently adding a purge to F13.

## Cross-finding ownership and non-duplication

The overlap review gives these ownership decisions:

- **F05:** F05-REL-05 remains the occurrence claim/lease wedge. F13-COR-01 is
  the approval profile field lost between schedule materialization and session
  binding; its fix can be sequenced with F05 but is not the same defect.
- **F07:** F07-SEC-01 remains foreign effect-row scope authorization and
  F07-REL-01 remains request-queue starvation. F13-REL-01 is the approval
  decision/grant transaction handoff. F22-REL-01 is already the F07 duplicate.
- **F09/F10:** their findings own MCP/websearch admission, egress, endpoint,
  and provider wiring. F13-SEC-01 is the policy document's no-session invariant
  and applies to any tier, regardless of MCP implementation.
- **F20/F23:** their systemic family is the unbound `human:` string in healing
  and improvement gates. F13 validates policy scopes and session grants; it does
  not create or consume those strings.
- **F21/F25:** F21 owns profile digest replay integrity; F25 owns worker restart
  loading the current trusted agent profile. F13-COR-02 owns approval overlay
  loss during active-policy reload, and F13-SEC-03 owns stale approval grants.
- **F22:** F22-SEC-01 is the session layer's missing profile digest comparison;
  F13-REL-02 is mode-switch audit ordering and retry idempotency. Different
  fields and failure outcomes. F22-REL-01 remains the F07 duplicate.
- **F24:** F24 owns CLI parser/help/rendering and confirms the interactive
  remember prompt. The schedule flag's execution consumer and approval policy
  are F13's boundary.

No F13 finding should be double-counted against those rows. The residual SEC-02
schema item must not absorb SEC-01's high-risk reusable-session consequence.

## Commands and results

Focused suites were run one file per command with `ruby -Itest`; no bundle
installation and no lint were used:

| Command | Result |
|---|---|
| `ruby -Itest test/approval_policy_document_test.rb` | 23 runs, 66 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/approval_engine_test.rb` | 26 runs, 95 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/approval_mode_switch_test.rb` | 11 runs, 30 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/sqlite_approval_stores_test.rb` | 10 runs, 45 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_approval_boot_test.rb` | 5 runs, 18 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/approval_resolve_test.rb` | 16 runs, 62 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/approval_reload_test.rb` | 8 runs, 15 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_schedule_test.rb` | 9 runs, 65 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_mode_switch_kill_matrix_test.rb` | 2 runs, 17 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_mode_switch_test.rb` | 4 runs, 45 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/approval_grant_key_test.rb` | 4 runs, 8 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/approval_values_test.rb` | 6 runs, 30 assertions, 0 failures, 0 errors, 0 skips |

The failure-injected and lifecycle probes are reproduced inline above. All
temporary databases and policy files were created under `/tmp` or Ruby temp
directories and removed by their temp-directory blocks.

## Deviations and forbidden-file proof

I did not run full CI, lint, load/soak testing, or a real provider. The schedule
probe stopped at the materialized request payload because the source boundary
already proves which session the worker builds; it did not claim provider
behavior. The SEC-03 probe used the durable engine's supported session scope and
also recorded the absence of a normal worker `:session` caller.

Before writing, `git diff --name-only` was empty and the pre-existing untracked
audit package was captured in `/tmp/f13-status-before.txt`. After writing, the
only newly introduced repository path is this challenge file; no production,
test, config, root audit, or existing analysis path was touched. The required
liveness log is `/tmp/tamoz-agents/challenge_f13_approval.log`, mode `0644`.
