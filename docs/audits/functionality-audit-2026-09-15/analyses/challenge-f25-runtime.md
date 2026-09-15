# Independent challenge: F25 `tamoz-agent` runtime

| Field | Value |
|---|---|
| Row / queue | F25 `tamoz-agent` / W2A (CLI and runtime) |
| Challenge branch / HEAD | `audit-15-09` / `0d19c8e0994ac4d62de6e0ee77131242a6142dfd` |
| Analyst material | `analyses/F25-agent-runtime.md` and `analyses/F25-agent-runtime.json` (analyst baseline `582ae55`) |
| Scope | F25-COR-01 and F25-SEC-02 only |
| Mode | Read-only challenge; no production, test, configuration, fixture, or audit-control edits; no commit |

## Boundary and method

I read `BAR.md`, `COVERAGE.md`, `FINDINGS.md`, both F25 analyst artifacts, and the F25 runtime path end to end. The source trace covered `Worker`, `WorkerRuntime`, session cancellation and status projection, profile validation and budget binding, the graph step limit, the Comms gateway/store, and the outbox sink. I ran focused worker, cancellation, profile, and budget controls, then ran a temporary real `RuntimeDirectory`/`WorkerRuntime`/`Worker` probe from `/tmp` with the repository's scripted model and deterministic looping workload. The probe tests durable plumbing and terminal projection; it is not evidence of model intelligence.

The analyst's two pending findings both reproduce on the current source. Their high confidence is justified by direct source paths plus a runtime result through the relevant F25 seams. Both remain major and open. Neither finding is raised to critical: the cancellation target race retains its honest `completed_before_effect` state, and the existing model-call and wall-clock ceilings still stop work. The defects concern misleading terminal projection and accepted safety configuration with no corresponding enforcement.

## Verdict summary

| Finding | Challenge result | Severity / confidence | Owning seam and disposition |
|---|---|---|---|
| F25-COR-01 | Confirmed. A cancellation redirect is settled and delivered as `request.completed`, with `task_state: "completed"`; the durable reason remains `cancelled_by_user`. The outbox answer is prefixed `Verified` while its body says verification was not satisfied. | Major / high / open | F25 `Worker#settle_view` and its completed delivery path. Keep in F25. |
| F25-SEC-02 | Confirmed. `cost_usd`, `input_tokens`, `output_tokens`, and `steps` are accepted, carried into the profile/session record, and returned as declared budgets, while the worker gate only measures `model_calls` and `wall_clock_seconds`. | Major / high / open | F25 `Worker#exhausted_budget` plus `WorkerRuntime#budget_usage`; profile validation is the smallest immediate refusal seam. Keep in F25 if linked to the broader budget question. |

## F25-COR-01 — cancelled turn projected as completed

### Source path and callers

The gateway's `/cancel` command selects the current admitted target and calls `CommsStore#request_cancellation`, queuing a redirect payload with `cancel: true` and `reason: "cancelled_by_user"` (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb:110-138`). The CLI session cancellation path uses the same payload (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:204-219`). The durable session binding turns that payload into `{next_node: 'terminal', terminal_reason: 'cancelled_by_user'}` (`gems/tamoz-agent-session/lib/tamoz/agent/session_bindings.rb:82-84`).

The session's `lifecycle_status` returns the graph snapshot status unless the snapshot is blocked (`gems/tamoz-agent-session/lib/tamoz/agent/session.rb:490-492`). Thus a cancellation terminal node can commit `snapshot_status: :completed` while carrying the separate terminal reason. `Worker#settle_view` dispatches only on `view.status` (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:677-688`). It sends this view to `settle_completed_view`, which writes the terminal delivery as `request.completed` and emits a completed status projection (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:717-727`). `SessionStatusProjection#task_state` is `view.status.to_s` (`gems/tamoz-agent-session/lib/tamoz/agent/session_status_projection.rb:76-78`), so the projection says `completed` even though it includes `terminal_reason: "cancelled_by_user"`.

The operator-facing sink maps `request.completed` to an `answer` and to the `Verified` verification class (`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:28-55,152-166`). The worker's completion text does recognize the unsatisfied terminal evidence, so the resulting text can contain `Verification was not satisfied.` (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:856-867`). That leaves two contradictory claims in one terminal delivery: the status and prefix say completed/Verified, while the body says verification was not satisfied.

### Reproduction and controls

The `/tmp` probe command was:

```text
/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby /tmp/tamoz-challenge/f25_probe.rb
```

The `cancelled-redirect` case used a real `WorkerRuntime` and `Worker` with a cancellation redirect. It returned:

```text
request.completed; status=completed; status_projection.task_state=completed;
terminal_reason=cancelled_by_user; view.status=completed; terminal.satisfied=false
```

The `cancelled-redirect-outbox` case used the configured `OutboxDeliverySink` and a `telegram-ops` channel. Its cancellation row was `kind: "answer"` with text beginning `Verified: result — Committed progress: no verified steps.` and continuing with `Verification was not satisfied.` The sink therefore confirms that the incorrect worker event is observable at the external delivery boundary, rather than being limited to an internal event stream.

There is a valid control on the separate target-request axis. `test/cancellation_visibility_test.rb` passed **11 runs / 106 assertions / 0 failures**, and `test/sqlite_comms_store_test.rb` is covered by the existing cancellation contract: when the target turn settles before cancellation is observed, the target remains `completed_before_effect`. The probe's target request status likewise reported `completed_before_effect`, with `task_state: "completed"` and `effect_state: "succeeded"`. That control prevents this challenge from claiming that a raced target completion is falsely reported as stopped. It does not correct the separate cancellation redirect's worker event and outbox classification.

The focused CLI cancellation control passed **1 run / 2 assertions / 0 failures** (`test/agent_cli_test.rb -n '/cancel_routes_to_terminal/'`). It checks the interactive terminal view and does not assert a worker event or outbox row. No existing test combines a worker cancellation redirect with terminal event, status projection, and sink delivery.

### Five whys

1. The cancellation redirect is delivered as completed because `Worker#settle_view` selects the completed branch from `view.status` and does not inspect `view.terminal.reason`.
2. The graph session records cancellation by moving to the terminal node, while `Session#lifecycle_status` preserves the normal completed snapshot status.
3. Worker settlement has a four-status dispatch, and cancellation reason handling was added to terminal detail, schedule status, and progress text without a corresponding event-disposition branch.
4. The Comms target timeline and the worker's cancellation redirect are separate projections, so the target's honest race classification does not drive the redirect's terminal event kind.
5. Tests cover Comms cancellation state and an interactive CLI view independently; no worker-to-outbox cancellation contract test makes the event kind, task state, and verification class agree.

### Smallest existing-seam recommendation

At `Worker#settle_view`, inspect the committed terminal reason before taking the `:completed` branch. Route `cancelled_by_user` through the existing stopped terminal vocabulary (`request.stopped`, stopped text, and a non-completed task-state projection), reusing the reason mapping already present in `scheduled_terminal_status` (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:607-622`) and the existing `TerminalProgress::STOP_ACTIONS` entry (`gems/tamoz-agent/lib/tamoz/agent/terminal_progress.rb:16`). This makes the existing sink map the cancellation to `stopped` and `Not verified`. Add one focused worker-plus-outbox cancellation test that asserts the event kind, projection, and delivery row together. No new cancellation engine is needed.

### Disposition

**Confirmed, major / high / open.** The analyst finding is accurate. Major remains proportionate because a supervisor receives a false completed/Verified projection, while the durable terminal reason and unsatisfied evidence remain visible and no post-cancel effect or authority bypass was demonstrated. This is an F25 worker projection defect. It is adjacent to, and does not replace, the F07/Comms-store target cancellation race contract or the F24 CLI surface.

## F25-SEC-02 — four accepted profile budgets are inert

### Source path and callers

`Profile::BUDGET_KEYS` accepts six numeric keys: `cost_usd`, `input_tokens`, `output_tokens`, `wall_clock_seconds`, `steps`, and `model_calls` (`gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:77-83`). `DocumentValidator#budgets!` rejects unknown names and validates each accepted value as numeric, so all six names pass the same shape check (`gems/tamoz-agent-profile/lib/tamoz/agent/profile/document_validator.rb:92-96,236-239`). `WorkerRuntime#thread_budgets` resolves and returns the full profile budget hash (`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:391-396`), and `build_session` passes `profile_budgets` into the session (`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:1030-1057`). The session record explicitly describes these budgets as recorded profile context (`gems/tamoz-sqlite/lib/tamoz/sqlite/session_records.rb:63-66`).

The enforcement path has a narrower contract. `Worker#exhausted_budget` iterates the literal `%w[model_calls wall_clock_seconds]` (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:383-398`). `WorkerRuntime#budget_usage` returns only those two measurements: model calls from the effect census and wall-clock age from the occurrence (`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:398-405`). The graph's recursion limit is a process-wide `Tamoz.configuration.recursion_limit`, not the profile's `budgets.steps` (`gems/tamoz-graph/lib/tamoz/graph/limits.rb`; `gems/tamoz-core/lib/tamoz/configuration.rb:15`). The product limitation is stated in `documentation/limitations.md:219-225`, which says exactly two budgets are enforced and the other four are recorded and pinned only.

### Reproduction and controls

The same probe command was:

```text
/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby /tmp/tamoz-challenge/f25_probe.rb
```

The probe used one looping workload with the same scripted model for each profile. The stable results were:

| Declared profile budget | Worker stop | Durable exhaustion | Direct runtime evidence |
|---|---|---|---|
| `steps: 1` | None; request ended `request.failed` with `reason: no_check` | None | `thread_budgets` returned `steps: 1`; `budget_usage` returned only `model_calls: 6` and `wall_clock_seconds` |
| `cost_usd: 0.000001`, `input_tokens: 1`, `output_tokens: 1` | None; request ended `request.failed` with `reason: no_check` | None | `thread_budgets` returned all three keys; `budget_usage` returned only the two active keys |
| `model_calls: 2` | One `request.stopped` | One `model_calls` exhaustion row | Detail reported `model_calls 6 reached ... limit 2` |
| `wall_clock_seconds: 0.000001` | One `request.stopped` | One `wall_clock_seconds` exhaustion row | Detail reported a positive occurrence age above the tiny limit |

The control output proves that the gate itself works for the two active keys. The `steps` workload made six model calls and was not stopped at one declared step. The accounting keys had no usage source and did not stop the same workload. The focused `test/agent_budget_test.rb` passed **7 runs / 20 assertions / 0 failures** and covers the active model-call/wall-clock behavior. `test/agent_profile_test.rb` passed **44 runs / 130 assertions / 0 failures**, and `test/session_context_controls_test.rb` passed **10 runs / 91 assertions / 0 failures**; those controls do not assert enforcement for the four inert keys. No test under `test/` asserts `steps`, `cost_usd`, `input_tokens`, or `output_tokens` enforcement.

### Five whys

1. Four declared ceilings never stop a turn because `Worker#exhausted_budget` only checks two hardcoded names.
2. The worker runtime exposes only model-call and occurrence-age measurements, so the other keys have no evidence for a comparison.
3. The existing durable seams provide an effect census and occurrence start time, while provider token/cost usage and committed logical-step accounting are not connected to this gate.
4. The profile schema uses one accepted-key set for both active and forward-looking budgets, and the validator has no active/inert distinction or effective-budget report.
5. Documentation carries the distinction in prose, while a valid profile can still pin an inert numeric ceiling and the focused tests cover only the two active keys.

### Smallest existing-seam recommendation

The smallest immediately safe change is to make the profile contract truthful: until evidence ledgers exist, have `DocumentValidator#budgets!` reject `steps`, `cost_usd`, `input_tokens`, and `output_tokens` using its existing invalid/unknown-budget validation path, and expose only the two enforceable keys in the profile schema and fixtures. Add a validator test for each rejected key and retain the existing active-budget tests.

If the product requires the six-key vocabulary, extend the existing `budget_usage`/`exhausted_budget` seam with one durable evidence source per key before accepting it as a ceiling. `steps` would need committed checkpoint logical-step evidence; token and currency limits would need provider usage written to the durable model-call record. The gate must compare each declared key against its evidence and record a typed exhaustion. Pinned metadata by itself is not enforcement.

### Disposition

**Confirmed, major / high / open.** The behavior is a real contract and resource-boundary gap. `documentation/limitations.md` honestly discloses the current two-key boundary, which reduces deception and supports keeping the finding at major rather than critical. It does not make a valid `steps` or spend/token ceiling effective. F25 owns the decision gate; F07 effect-journal/provider seams may supply future evidence, while the global graph recursion limit is a separate process control. Keep this linked to any broader cross-flow budget finding rather than transferring ownership away from `Worker#exhausted_budget`.

## Ownership, duplicates, and out of scope

- F25-COR-01 belongs to the worker's terminal projection and delivery path. The Comms store owns the target request's requested/observed/raced cancellation facts; its `completed_before_effect` control remains valid and is not a duplicate of the worker event defect.
- F25-SEC-02 belongs to the F25 worker gate because that is where declared budgets are selected and stopped. A broader cross-flow budget finding can link to it; ownership does not move to the graph's global recursion limit or the SQLite census implementation.
- F25-SEC-01, the existing critical profile-authority finding, was not re-litigated. F25-OBS-01, F25-SCL-02, CF04-REL-01, and CF05-SEC-01 were outside this bounded challenge. No new finding is proposed.

## Commands, pass counts, and deviations

Focused tests were run one file per command with the pinned Ruby:

| Exact command | Result |
|---|---|
| `/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby -Itest test/cancellation_visibility_test.rb` | 11 runs / 106 assertions / 0 failures / 0 errors / 0 skips |
| `/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby -Itest test/agent_budget_test.rb` | 7 runs / 20 assertions / 0 failures / 0 errors / 0 skips |
| `/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby -Itest test/agent_worker_test.rb` | 25 runs / 122 assertions / 0 failures / 0 errors / 0 skips |
| `/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby -Itest test/agent_terminal_progress_test.rb` | 4 runs / 19 assertions / 0 failures / 0 errors / 0 skips |
| `/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby -Itest test/agent_cli_test.rb -n '/cancel_routes_to_terminal/'` | 1 run / 2 assertions / 0 failures / 0 errors / 0 skips |
| `/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby -Itest test/session_context_controls_test.rb` | 10 runs / 91 assertions / 0 failures / 0 errors / 0 skips |
| `/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby -Itest test/agent_profile_test.rb` | 44 runs / 130 assertions / 0 failures / 0 errors / 0 skips |
| `/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby /tmp/tamoz-challenge/f25_probe.rb` | JSON probe completed with the results recorded above; the required test helper emitted an unrelated 0-run Minitest trailer |

The seven focused test commands total **102 runs / 490 assertions / 0 failures / 0 errors / 0 skips**. The analyst's broader 13-file suite remains recorded in the F25 report. `rake ci` and `rake ci_full` were not run because the audit brief forbids full CI for this bounded challenge and the row budget excludes it. No sandbox restriction prevented a required read, focused test, or probe; no network or external model call was used. Probe code and temporary runtime directories stayed under `/tmp/tamoz-challenge`.

## Forbidden-path proof

Before this report was created, `git status --short --branch` showed branch `audit-15-09` with only the pre-existing untracked `docs/audits/functionality-audit-2026-09-15/analyses/challenge-f26-evidence.md`; the four audit-control files were hashed as follows:

```text
BAR.md        ac4442776b19c4d040256b593d57e0115c6301bd4c6d592a82e9fae1f2820f39
COVERAGE.md   bf14044f3bd636565758f7164e81aaf9522fa71ec8b7d1c0dff4e307ead865de
FINDINGS.md   f1a81c5837a2ba8ffb160c3c01d4f864686f4ce53462a5595de72d531af0198b
CHECKPOINT.md 07446cf899ea6552bd7d13f295079a16779bcf0da007e0fdcf2e6afefac0911e
```

The exact post-write verification commands were:

```text
git status --short --branch --untracked-files=all
git diff --name-only
shasum -a 256 docs/audits/functionality-audit-2026-09-15/BAR.md docs/audits/functionality-audit-2026-09-15/COVERAGE.md docs/audits/functionality-audit-2026-09-15/FINDINGS.md docs/audits/functionality-audit-2026-09-15/CHECKPOINT.md
stat -f '%Sp %Mp%Lp %N' docs/audits/functionality-audit-2026-09-15/analyses/challenge-f25-runtime.md
```

Verification showed exactly these two untracked reports: this F25 report and the pre-existing F26 report; `git diff --name-only` was empty. The four post-write hashes were identical to the pre-write hashes above, and `stat` reported `-rw-r--r-- 0644` for this file. The pre-existing F26 report remains untouched. No production code, test, configuration, fixture, `FINDINGS.md`, `COVERAGE.md`, `CHECKPOINT.md`, or `BAR.md` file was edited, and no commit was made.
