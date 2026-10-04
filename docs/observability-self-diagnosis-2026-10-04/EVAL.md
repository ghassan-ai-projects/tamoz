# Self-diagnosis — evaluation

**Date:** 2026-10-04 · **Branch:** `observability-self-diagnosis` · **Thresholds:** fixed in
[`QUALITY_BAR.md`](QUALITY_BAR.md) §C before any run · **Corpus:**
`test/fixtures/self_diagnosis/scenarios.json`, digest pinned in `test/self_diagnosis_corpus_test.rb`.

Three different kinds of evidence, never mixed:

| Kind | What it proves | What it cannot prove |
|---|---|---|
| Deterministic tests (plumbing) | The reader, rules, detectors and commands do what they say, on records written through the real `tamoz-sqlite` APIs | That a model reasons well |
| Value comparison (plumbing) | What an operator learns from `diagnose` that the existing surface does not show | Anything about a model |
| Real-model runs (DeepSeek via OpenRouter) | That the agent finds the root cause of its own failures through `self-observe` probes and cites what it read | Generalisation: the corpus is a development set, not held out |

## 1. The corpus

Thirteen scenarios, each a runtime database built through the real APIs (`DurableRecordBuilder`:
graph turns through `durable_runner`, effects through `open_writer` → `effects.prepare/start/complete`,
approvals through the approval decision log, journal events through the real `Recorder::Journal`).
Every scenario sits inside the same healthy noise: 6 completed turns, 18 successful model calls,
12 successful tool reads and 6 answered approvals. Several carry a red herring (one unrelated
failure of another class). Journal drop counts are the one fixture written directly (the health
sidecar file the journal itself writes).

| Scenario | Injected fault | Root-cause marker (hidden from the model) |
|---|---|---|
| `provider_balance` | 4 model calls fail `ModelCallError/insufficient_balance`; 1 unrelated `not_found` | `insufficient_balance` |
| `rate_limited` | 8 model calls fail `rate_limited` | `rate_limited` |
| `mcp_transport` | 3 MCP queries fail and 1 write ends `unknown`, `transport_timeout` | `transport_timeout` |
| `check_failing` | 4 `check.test` runs fail `check_exit_nonzero` | `check_exit_nonzero` |
| `tool_not_found` | 12 reads refused `path_outside_workspace` | `path_outside_workspace` |
| `worker_claim_errors` | 5 journal `tamoz.worker.error` (`lease_lost`); 2 failed turns | `lease_lost` |
| `auth_refused` | 5 model calls fail `authentication_failed`; 1 unrelated `rate_limited` | `authentication_failed` |
| `websearch_egress` | 4 searches refused `destination_not_allowed` | `destination_not_allowed` |
| `telemetry_loss` | 240 journal drops (`queue_full`) | `queue_full` |
| `single_model_failure` | 1 model call fails `http_failure` (added after run 2, see §4) | `http_failure` |
| `approval_stall` | 2 approvals unanswered (judged 5 h later) | `approval.waiting` |
| `stuck_effect` | 1 shell effect running (judged 45 min later) | `effect.stuck` |
| `clean` | none | — |

## 2. Detector accuracy (C3, plumbing)

`ruby -Itest test/self_diagnosis_corpus_test.rb` — 14 runs (13 scenarios + the digest pin),
38 assertions, 0 failures. Each scenario must fire **exactly** its expected rules, and the diagnose
output must contain the marker.

| | Result |
|---|---|
| Fault scenarios whose expected rules all fired | 12 / 12 (100%) |
| Rules fired that were not expected | 0 |
| Findings on the clean runtime | 0 |
| Marker present in the `diagnose` output (so a model *can* find it) | 12 / 12 |

**Expectation error caught by the first run, recorded rather than hidden.** Before any run, the
corpus expected `model.failure_rate` / `tool.failure_rate` to fire in four scenarios. They did not:
with the healthy noise, 4 failures out of 22 model calls is 18%, under the 25% threshold written in
`rules.yaml` before the run (and 12 of 24, 4 of 16 reads are at or under 50%). The detectors behaved
as their rules say; the expectation was wrong. The four expectations were corrected; the thresholds
were not touched. `effect.repeated_failure` named the cause in all four.

## 3. Value against the existing surface (C4, plumbing)

`script/self_investigation_eval value` builds each scenario into a real runtime directory
(`tamoz init`), then asks the existing operator surface and the new command whether they *name* the
root-cause marker. Raw output: [`runs/value-2026-10-04.json`](runs/value-2026-10-04.json).

| Scenario | `tamoz status --json` | `tamoz observe metrics` | `tamoz diagnose` |
|---|---|---|---|
| provider_balance | no | no | **yes** |
| rate_limited | no | no | **yes** |
| mcp_transport | no (lists the blocked effect key, not why) | no | **yes** |
| check_failing | no | no | **yes** |
| tool_not_found | no | no | **yes** |
| worker_claim_errors | no | no | **yes** |
| auth_refused | no | no | **yes** |
| websearch_egress | no | no | **yes** |
| telemetry_loss | no (shows a total drop count) | no | **yes** |
| single_model_failure | no | no | **yes** |
| **Total** | **0 / 10** | **0 / 10** | **10 / 10** |

`approval_stall` and `stuck_effect` need real elapsed time from the CLI (the command uses the wall
clock); they are covered by the injected-clock tests above. **Harness defect caught:** the first value
run reported `status` naming `rate_limited` — because the temp directory was named after the scenario
and `status` prints its path. The same name reached the model as the workspace root, which would have
leaked the answer in that scenario. Temp directories are now neutral; that run was discarded.

## 4. Real model: Tamoz investigating itself (C5)

`script/self_investigation_eval real` — for each scenario: `tamoz init`, build the records, declare
the `self-observe` server and three probes (`test/fixtures/self_diagnosis/probes.yaml`), then run the
real `tamoz investigate` with the same question for every scenario; the root cause is never in the
input. Historically graded by `test/support/self_investigation_grader.rb`, whose controls
(`test/self_investigation_grader_test.rb`) prove an oracle passes and a null, an ungrounded citer, a
fabricator, a wrong-cause answer and a hedger each fail. The grader reads probe results from the
investigation's session database and links findings to probes through Tamoz's rendered
`[from probe…]` lines, never through model text.

**Continuation review (2026-10-04):** the historical grader searched for code tokens in prose and
could accept an explicit denial of the true cause. Its original runs retained a hypothesis and output
tail, but discarded the complete report and served probe results. The historical success counts below
are therefore non-replayable results under the old grader, not final-design evidence.

The current eval is **exact-code selection**: the existing hypothesis field must equal the root-cause
code, with reasoning in the findings. Every rendered citation must refer to a successful served probe,
and a finding's cited result must contain the decisive marker. Controls reject explicit denial, a
fabricated citation hidden beside a valid one, and the earlier wrong-cause/ungrounded cases. Future
runs retain the full grading inputs, question, corpus/rules digests and implementation provenance.
The question changed, so the corpus digest was reviewed and repinned; historical run digests remain
unchanged. Final-design real-model C5 remains BLOCKED until a funded provider run completes.

**Model:** `deepseek/deepseek-v4.1-flash` via OpenRouter. **Set:** development, not held out.

### Run 1 — [`runs/real-2026-10-04-run1.json`](runs/real-2026-10-04-run1.json)

Design at the time: the reader still returned a bounded failure message, and the question did not
yet say "name exactly one code".

| Scenario | Outcome (corrected grader) | Probe calls | Model calls | Seconds |
|---|---|---|---|---|
| provider_balance | success | 10 | 7 | 75 |
| rate_limited | success | 11 | 17 | 534 |
| mcp_transport | success | 11 | 7 | 123 |
| check_failing | success | 10 | 8 | 123 |
| tool_not_found | success | 10 | 9 | 135 |
| worker_claim_errors | success | 9 | 7 | 92 |
| auth_refused | **hedged** — named `authentication_failed` and called the red-herring `rate_limited` a knock-on effect | 6 | 6 | 147 |
| websearch_egress | success | 10 | 6 | 110 |
| telemetry_loss | **no report** — exit 2 after 16 probe and 11 model calls; most likely the provider credit ran out (run 2 failed that way from its first call), not confirmed | 16 | 11 | 242 |

| Measure | Value | Threshold (bar C5) |
|---|---|---|
| Root cause correct, grounded in a cited probe result, one code named | **7 / 9** | ≥ 6 / 8 |
| Same, without the one-code rule (grader at run time) | 8 / 9 | — |
| Fabricated codes (named but never served by any probe) | **0** | 0 |
| Model calls | 78 (8.7 per investigation) | — |
| Spend | not measured (lesson recorded in `.agent/rules/evaluation.md`) | — |

In every successful run the model named the error class and code and, where there was one, set the
red herring aside in its findings. The first real run before these (on `provider_balance`) found the
`self-observe` server failing every call with `-32603`; the model refused to invent a cause and said
the probe server was broken. That was a real Tamoz bug (`tamoz-sqlite` was not loaded in a fresh
process); it is fixed and now covered by a subprocess test.

### Run 2 — [`runs/real-2026-10-04-run2.json`](runs/real-2026-10-04-run2.json) — BLOCKED

The final design (class and code only, "name exactly one code" in the question, hedging graded as a
failure) could not be measured: every turn ended `model_out_of_credit` on its first call, with $0.45
left on the OpenRouter key, and the direct DeepSeek account has no balance. Spend: $0.00. **Owner
action:** top up a provider and run `ruby script/self_investigation_eval real`.

Run 2 still taught something. The harness ran `tamoz diagnose` on each failed investigation's own
session, and it reported **nothing**: one failed model call (`ModelCallError/http_failure`) sat
under every count threshold, though one is enough to end a turn. The `model.call_failed` rule and the
`single_model_failure` scenario were added in response; the corpus now covers that case.

## 5. Real postmortem with a real-model analysis (C6)

[`runs/postmortem-provider-balance.md`](runs/postmortem-provider-balance.md) is unedited output of
`tamoz postmortem --analysis` (final code) embedding the findings report of a real `tamoz
investigate` turn (DeepSeek v4.1 flash via OpenRouter, run before the reader stopped returning
failure messages) on the `provider_balance` runtime. The model named `insufficient_balance`, cited
the probe calls that showed it, and set aside the `not_found` red herring as unrelated. The
postmortem labels the analysis as not verified by the postmortem command itself.

## 6. What it cannot do yet

- **Failure messages are not shown**, only class and code: the model and the operator see
  `ModelCallError/http_failure`, not "402 out of credit". This is the price of keeping content out.
- **Grounding is checked per probe, not per call.** A finding counts as grounded when a probe it
  cites returned the marker in any of its calls this turn.
- **Bugs inside Tamoz's own code are seen only as their symptoms.** Diagnosis reads the durable
  record: it sees that a turn failed or an effect raised `X/code`, not which line of Ruby is wrong.
  A graph-level failure records only `graph_status: failed` (no class), so it groups as
  `unclassified`.
- **No cost or token view.** Usage lives only in the lossy journal (deferred: durable usage).
- **Approvals in a shared worker database link to a turn by time**, so concurrent turns of one
  profile can be confused (deferred: F4 in `FUTURE_PLAN.md`).
- **`tamoz trace` is still journal-only**; the timeline is the durable view.
- **Age rules need elapsed time**: a fault that is minutes old is not yet "stuck".
- **The model can reach a wrong conclusion from real evidence.** Citations prove the evidence was
  read, not that the inference is right.
- **No regulatory evidence yet**: no tamper-evident seal, retention or reporting clock
  (`FUTURE_PLAN.md`).

## 7. Historical real-model postmortem, verbatim (C6)

This is the existing recorded artifact, not a new final-design real-model run.

```markdown
# Postmortem: Model calls refused: provider balance

Window: 2026-10-03T15:27:20Z → 2026-10-04T15:27:20Z · generated 2026-10-04T15:27:20Z

Blameless; assembled read-only from the durable record. Proposed actions are never executed.

## Impact

- Failed turns: 0
- Threads with failures: thread.noise.5
- Findings by severity: high 2

## Analysis (the attached findings report; this command does not verify it)

**Summary:** The runtime's own record over the last 24h shows 6 turns requested and completed, 35 effect attempts (30 succeeded, 5 failed). Four of the five failures are the same model call failing repeatedly in thread.noise.5, and the self-diagnosis rule effect.repeated_failure fired at high severity on exactly that group. The workspace is empty, so the record is the only evidence.

**Hypothesis (high):** The root cause is the model provider rejecting calls for non-payment: every failing model.generate.plan attempt carries error class Tamoz::Agent::ModelCallError with code insufficient_balance and reason "402 Payment Required: the account balance is empty". The exact error code identifying the root cause is insufficient_balance (class Tamoz::Agent::ModelCallError, rule effect.repeated_failure). The single tool.read_file failure (code not_found, "notes.md does not exist") is a separate, unrelated one-off and not the cause.

- Four model.generate.plan effect attempts failed in thread.noise.5 with the identical failure: class Tamoz::Agent::ModelCallError, code insufficient_balance, reason '402 Payment Required: the account balance is empty'. [call-af411c37-bf7d-4f98-b04d-8ab726f85bd8, call-a3c7e1f9-deda-42c4-adc7-5c26922e0a71, call-169bc01d-3bfa-4db1-949b-3109a8236ae1]
- The self-diagnosis rule effect.repeated_failure fired at severity high, category dependency_unavailable, count 4, first_seen 1791125835197 and last_seen 1791125835201, with detail failure 'Tamoz::Agent::ModelCallError/insufficient_balance'. [call-a3c7e1f9-deda-42c4-adc7-5c26922e0a71, call-4aeb3d16-5558-40ff-aee8-588aaca5d5bf]
- The failures are confined to thread.noise.5; threads noise.0 through noise.4 each requested and completed a turn without a model failure, and the runtime reports 6/6 requests completed with no degraded sources. [call-af411c37-bf7d-4f98-b04d-8ab726f85bd8, call-a3c7e1f9-deda-42c4-adc7-5c26922e0a71]
- A fifth, distinct failure occurred in the same thread: tool.read_file failed with class Tamoz::Agent::ToolError, code not_found, reason 'notes.md does not exist' — a one-off missing-file error, not part of the repeated group. [call-af411c37-bf7d-4f98-b04d-8ab726f85bd8, call-169bc01d-3bfa-4db1-949b-3109a8236ae1]
- The failing model calls are idempotent effects that each failed on attempt 1 with duration 0-1 ms, consistent with an immediate provider-side rejection rather than a timeout or retry exhaustion. [call-169bc01d-3bfa-4db1-949b-3109a8236ae1, call-a3c7e1f9-deda-42c4-adc7-5c26922e0a71]

## Timeline

- 2026-10-04T14:57:15Z `durable` turn requested (`thread.noise.0#request.d53a9484`)
- 2026-10-04T14:57:15Z `durable` turn completed (`thread.noise.0#request.d53a9484`)
- 2026-10-04T14:57:15Z `durable` turn requested (`thread.noise.1#request.9c624565`)
- 2026-10-04T14:57:15Z `durable` write_file ask (`decision.a8dcfc32`)
- 2026-10-04T14:57:15Z `durable` write_file approve (`decision.a8dcfc32`)
- 2026-10-04T14:57:15Z `durable` turn completed (`thread.noise.1#request.9c624565`)
- 2026-10-04T14:57:15Z `durable` turn requested (`thread.noise.2#request.d9b27000`)
- 2026-10-04T14:57:15Z `durable` write_file ask (`decision.0b288cd9`)
- 2026-10-04T14:57:15Z `durable` write_file approve (`decision.0b288cd9`)
- 2026-10-04T14:57:15Z `durable` turn completed (`thread.noise.2#request.d9b27000`)
- 2026-10-04T14:57:15Z `durable` turn requested (`thread.noise.3#request.14aeea98`)
- 2026-10-04T14:57:15Z `durable` write_file ask (`decision.8210bf4f`)
- 2026-10-04T14:57:15Z `durable` write_file approve (`decision.8210bf4f`)
- 2026-10-04T14:57:15Z `durable` turn completed (`thread.noise.3#request.14aeea98`)
- 2026-10-04T14:57:15Z `durable` turn requested (`thread.noise.4#request.8d415fce`)
- 2026-10-04T14:57:15Z `durable` write_file ask (`decision.a350b479`)
- 2026-10-04T14:57:15Z `durable` write_file approve (`decision.a350b479`)
- 2026-10-04T14:57:15Z `durable` turn completed (`thread.noise.4#request.8d415fce`)
- 2026-10-04T14:57:15Z `durable` write_file ask (`decision.aa225c6a`)
- 2026-10-04T14:57:15Z `durable` turn requested (`thread.noise.5#request.f8caebaf`)
- 2026-10-04T14:57:15Z `durable` write_file approve (`decision.aa225c6a`)
- 2026-10-04T14:57:15Z `durable` turn completed (`thread.noise.5#request.f8caebaf`)
- 2026-10-04T14:57:15Z `durable` write_file ask (`decision.165f90f2`)
- 2026-10-04T14:57:15Z `durable` write_file approve (`decision.165f90f2`)
- 2026-10-04T14:57:15Z `durable` model.generate.plan failed — Tamoz::Agent::ModelCallError/insufficient_balance (`sha256:26fd998ea674d71ec786f1b263a8466a84e9a659378223bb6b343cd512013d0a#1`)
- 2026-10-04T14:57:15Z `durable` model.generate.plan failed — Tamoz::Agent::ModelCallError/insufficient_balance (`sha256:f37cd3c8dfd3f6beb3395e3c04ca63604241e9dd9b5f39cad0e57ed201ed123b#1`)
- 2026-10-04T14:57:15Z `durable` model.generate.plan failed — Tamoz::Agent::ModelCallError/insufficient_balance (`sha256:47da65c43e58aef0b0f8e63b04b7e058125def876cdafa712a5b4160997bc741#1`)
- 2026-10-04T14:57:15Z `durable` model.generate.plan failed — Tamoz::Agent::ModelCallError/insufficient_balance (`sha256:6b5f1a06739e0756a0ca80311473543652496a3e37467a35725e2cae2b678fe6#1`)
- 2026-10-04T14:57:15Z `durable` tool.read_file failed — Tamoz::Agent::ToolError/not_found (`sha256:c5cda6aa674d4de60c4f8e317932dab581e66fa93fc4e602b4a9fa238aff4332#1`)

## Findings

### [high] The same failure is repeating (4)

Rule `effect.repeated_failure` · category `dependency_unavailable` · finding `sha256:8146d08bf5ca58b809f31da9796f7777b9a554472a1db3f61b9eeabe710cd0f5`  
Seen 2026-10-04T14:57:15Z → 2026-10-04T14:57:15Z

**Action:** One error class and code keeps recurring; fix that cause once instead of retrying the calls.

- `effect_attempts` `sha256:6b5f1a06739e0756a0ca80311473543652496a3e37467a35725e2cae2b678fe6#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:47da65c43e58aef0b0f8e63b04b7e058125def876cdafa712a5b4160997bc741#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:f37cd3c8dfd3f6beb3395e3c04ca63604241e9dd9b5f39cad0e57ed201ed123b#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:26fd998ea674d71ec786f1b263a8466a84e9a659378223bb6b343cd512013d0a#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance

### [high] A model call failed (4)

Rule `model.call_failed` · category `dependency_unavailable` · finding `sha256:99be8bdd0b0664008aac074cce4b4b917fdba03769ffca2e0a98c6b251b6434f`  
Seen 2026-10-04T14:57:15Z → 2026-10-04T14:57:15Z

**Action:** One failed model call ends the turn that made it; check the error code (a refused key, an empty account or a rate limit is a provider problem, not a Tamoz bug).

- `effect_attempts` `sha256:6b5f1a06739e0756a0ca80311473543652496a3e37467a35725e2cae2b678fe6#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:47da65c43e58aef0b0f8e63b04b7e058125def876cdafa712a5b4160997bc741#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:f37cd3c8dfd3f6beb3395e3c04ca63604241e9dd9b5f39cad0e57ed201ed123b#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:26fd998ea674d71ec786f1b263a8466a84e9a659378223bb6b343cd512013d0a#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance

## Unknowns

None.

## Proposed actions (not executed)

- One error class and code keeps recurring; fix that cause once instead of retrying the calls.
- One failed model call ends the turn that made it; check the error code (a refused key, an empty account or a rate limit is a provider problem, not a Tamoz bug).
```

## 8. Continuation validation (2026-10-04)

The corpus still detects all 12 fault scenarios with no extra rule and no clean-runtime finding
(14 tests, 38 assertions). The current value comparison is retained separately in
[`runs/value-2026-10-04-continuation.json`](runs/value-2026-10-04-continuation.json); all ten measured
fault markers are named by diagnosis and by neither existing command.

Nine guard mutations in an isolated copy each produced a failing regression test; the working
worktree was never mutated during full-suite validation. Evidence:
[`runs/mutations-2026-10-04.json`](runs/mutations-2026-10-04.json).

The provider credit was checked live without making a model call:
[`runs/provider-credit-2026-10-04.json`](runs/provider-credit-2026-10-04.json). OpenRouter has
$0.451297018 remaining; its prior run was refused at this balance. No further paid calls were
attempted. C5 remains BLOCKED, and this continuation claims no new real-model result.
