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

Fifteen scenarios, each a runtime database built through the real APIs (`DurableRecordBuilder`:
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
| `unknown_write_among_misses` (trap) | 8 routine reads fail `not_found`; 1 aerator write ends `unknown`, `transport_timeout` — the code appears only in the timeline | `transport_timeout` |
| `unknown_feeder_among_empty_searches` (trap) | 5 searches fail `no_results`; 1 feeder write ends `unknown`, `connection_reset` — timeline only | `connection_reset` |
| `approval_stall` | 2 approvals unanswered (judged 5 h later) | `approval.waiting` |
| `stuck_effect` | 1 shell effect running (judged 45 min later) | `effect.stuck` |
| `clean` | none | — |

## 2. Detector accuracy (C3, plumbing)

`ruby -Itest test/self_diagnosis_corpus_test.rb` — 16 runs (15 scenarios + the digest pin),
44 assertions, 0 failures. Each scenario must fire **exactly** its expected rules, and the marker must
be in the output of the probe that decides it (`diagnose`, or `timeline` for the two traps).

| | Result |
|---|---|
| Fault scenarios whose expected rules all fired | 14 / 14 (100%) |
| Rules fired that were not expected | 0 |
| Findings on the clean runtime | 0 |
| Marker present in its deciding probe's output (so a model *can* find it) | 14 / 14 |

**Expectation error caught by the first run, recorded rather than hidden.** Before any run, the
corpus expected `model.failure_rate` / `tool.failure_rate` to fire in four scenarios. They did not:
with the healthy noise, 4 failures out of 22 model calls is 18%, under the 25% threshold written in
`rules.yaml` before the run (and 12 of 24, 4 of 16 reads are at or under 50%). The detectors behaved
as their rules say; the expectation was wrong. The four expectations were corrected; the thresholds
were not touched. `effect.repeated_failure` named the cause in all four.

## 3. Value against the existing surface (C4, plumbing)

`script/self_investigation_eval value` builds each scenario into a real runtime directory
(`tamoz init`), then asks the existing operator surface and the new command whether they *name* the
root-cause marker. Raw output (clean tree, `e542237d`):
[`runs/value-2026-10-04-final.json`](runs/value-2026-10-04-final.json).

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
| unknown_write_among_misses (trap) | no | no | no — the code is only in `timeline` |
| unknown_feeder_among_empty_searches (trap) | no | no | no — the code is only in `timeline` |
| **Total** | **0 / 12** | **0 / 12** | **10 / 12** (the traps are found through `timeline`, §4) |

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
unchanged. A second review found a model-free "most frequent code" policy also scored 9/9, so the
grader now scores two deterministic baselines beside the model, and two trap scenarios hide the cause
from `diagnose` (`test_model_free_baselines_solve_an_ordinary_scenario_and_fail_the_trap`).

### Final-design run — [`runs/real-2026-10-04-run4-zai-final.json`](runs/real-2026-10-04-run4-zai-final.json) — C5

**Model:** `zai/glm-5.3-flash` (Z.ai coding-plan endpoint). **Code:** `e542237d` (the record says
`dirty: true` because EVAL.md and one test's file-read encoding were being edited during the run; no
file under `gems/` or `script/` differed). **Corpus:** `sha256:60437638…`, 11 real-model scenarios,
development set. Every investigation got the same question; the hypothesis field must be exactly the
root-cause code. Graded by `test/support/self_investigation_grader.rb`; next to the model, two
model-free baselines are scored by the same grader on the same `diagnose` output: **frequency** (the
most frequent known code) and **ranked** (the first known code in the top-ranked finding).

| Scenario | Model | Frequency baseline | Ranked baseline | Probe calls | Model calls | Seconds |
|---|---|---|---|---|---|---|
| provider_balance | success | success | success | 5 | 4 | 143 |
| rate_limited | success | success | success | 3 | 7 | 106 |
| mcp_transport | success | success | success | 3 | 4 | 86 |
| check_failing | success | success | success | 4 | 5 | 192 |
| tool_not_found | success | success | success | 4 | 5 | 185 |
| worker_claim_errors | success | success | success | 4 | 6 | 185 |
| auth_refused | success | success | success | 4 | 5 | 154 |
| websearch_egress | success | success | success | 3 | 4 | 71 |
| telemetry_loss | success | success | success | 5 | 5 | 150 |
| unknown_write_among_misses (trap) | **wrong cause** (`not_found`) | fail | fail | 3 | 5 | 257 |
| unknown_feeder_among_empty_searches (trap) | **success** (`connection_reset`) | fail | fail | 3 | 4 | 110 |

| Measure | Model | Baselines | Threshold (bar C5) |
|---|---|---|---|
| Correct, grounded in a cited probe result | **10 / 11** | 9 / 11 each | ≥ 6 / 8 |
| Fabricated codes or citations | **0** | — | 0 |
| Model calls | 54 (4.9 per investigation) | 0 | — |

What this does and does not show:

- **It finds its own failures, cites what it read, and invents nothing**: 10/11, no fabricated code
  or citation, every turn ended `reported`.
- **On the nine ordinary scenarios a model-free baseline does as well.** The diagnosis engine already
  ranks the cause first, which is the design: detection is deterministic, the model reads it,
  explains it and cites it. Those nine scenarios show faithful reporting, not independent reasoning.
- **The traps are where reasoning is needed.** The root cause (an `unknown` outcome on an external
  write) is absent from `diagnose` and visible only through `timeline` or `explain_turn`, and both
  baselines fail. The model solved one of the two here and the other in a separate earlier run
  ([`runs/real-2026-10-04-trap-zai.json`](runs/real-2026-10-04-trap-zai.json)): 2 of 3 trap attempts,
  too few to quote a rate. Where it failed, it fell for the frequent, harmless `not_found` reads.
- Development set, one model, one run per scenario. Not held out; not a benchmark.

Earlier run on the same final design but the previous corpus (9 scenarios, no traps):
[`runs/real-2026-10-04-run3-zai.json`](runs/real-2026-10-04-run3-zai.json) — 9/9, 0 fabricated.

### Run 1 — [`runs/real-2026-10-04-run1.json`](runs/real-2026-10-04-run1.json)

Design at the time: the reader still returned a bounded failure message, and the question did not
yet say "name exactly one code".

| Scenario | Outcome (old token-search grader; hedging applied by hand) | Probe calls | Model calls | Seconds |
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

Not a C5 measurement: the grader, question and reader have changed since, and the run kept too
little to regrade. Recorded so it is not dropped.

| Measure (historical) | Value |
|---|---|
| Correct under the old grader, hedging counted as failure | 7 / 9 |
| Correct under the old grader as it ran | 8 / 9 |
| Fabricated codes | 0 |
| Model calls | 78 (8.7 per investigation) |
| Spend | not measured (lesson recorded in `.agent/rules/evaluation.md`) |

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

**Final design:** [`runs/postmortem-provider-balance-zai.md`](runs/postmortem-provider-balance-zai.md)
is unedited output of `tamoz postmortem --analysis` embedding a real `tamoz investigate` turn
(`zai/glm-5.3-flash`, current reader: class and code only) on the `provider_balance` runtime. The
model set the hypothesis to `insufficient_balance`, cited the probes that showed it, set aside the
`not_found` read as non-actionable, and flagged on its own that the fixture's turn is recorded
`completed` with a timestamp earlier than its failed effects — a real artefact of how the corpus
builder writes effects after the turn, recorded in §6.

**Historical:** [`runs/postmortem-provider-balance.md`](runs/postmortem-provider-balance.md) is unedited output of
`tamoz postmortem --analysis` (final code) embedding the findings report of a real `tamoz
investigate` turn (DeepSeek v4.1 flash via OpenRouter, run before the reader stopped returning
failure messages) on the `provider_balance` runtime. The model named `insufficient_balance`, cited
the probe calls that showed it, and set aside the `not_found` red herring as unrelated. The
postmortem labels the analysis as not verified by the postmortem command itself.

## 6. What it cannot do yet

- **The model's added value over the deterministic ranking is small in this corpus**: model-free
  baselines match it on every ordinary scenario; it beats them only on the traps, 2 of 3 attempts.
- **Corpus realism:** the builder writes failed effects after their turn completed, so turns read
  `completed` with failures inside them (the model noticed). Real runtimes order these differently.
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

## 7. Final-design real-model postmortem, verbatim (C6)

Unedited copy of [`runs/postmortem-provider-balance-zai.md`](runs/postmortem-provider-balance-zai.md) (headings demoted to fit this page). The historical DeepSeek-era postmortem is kept in [`runs/postmortem-provider-balance.md`](runs/postmortem-provider-balance.md).

#### Postmortem: Model calls refused: provider balance

Window: 2026-10-03T19:35:55Z → 2026-10-04T19:35:55Z · generated 2026-10-04T19:35:55Z

Blameless; assembled read-only from the durable record. Proposed actions are never executed.

#### Impact

- Failed turns: 0
- Threads with failures: thread.noise.5
- Findings by severity: high 2

#### Analysis (the attached findings report; this command does not verify it)

**Summary:** Investigated the Tamoz runtime's durable record over the last 24 hours after a 4-hour lookback showed an empty recent window. All five effect failures in the record are concentrated in one turn (thread.noise.5) at ~1791125835196-1791125835202, about 4.6 hours before diagnosis: four model.generate.plan attempts failed with Tamoz::Agent::ModelCallError code insufficient_balance, and one tool.read_file attempt failed with ToolError code not_found. The runtime's own high-severity rules fired only on the balance failure.

**Hypothesis (high):** insufficient_balance

- The runtime's own rules fired twice with high severity on the same failure: rule effect.repeated_failure and rule model.call_failed, each count 4, category dependency_unavailable, detail Tamoz::Agent::ModelCallError/insufficient_balance. Both rules name a provider/account condition, not a Tamoz defect. [call_-7218248447135049513]
- Timeline inside thread.noise.5: three model.generate.plan successes and two tool.read_file successes at ~1791125835190-5195, then four consecutive model.generate.plan failures with code insufficient_balance at ~1791125835196-5200, all distinct effect keys, each a single attempt with duration 0 ms (refused immediately, no retries). The account crossed its balance threshold mid-burst: model calls worked until 5195 and every model call after 5196 failed. These are the last model calls in the record. [call_-7218248447135049512, call_-7218263805938099576]
- The only other error code in the window is ToolError/not_found: a single tool.read_file attempt at ~1791125835202 in the same thread, after the balance failures. It occurs once, fires no rule, and no other thread had any failure. It cannot explain four model calls failing with a balance code; it is best read as collateral of the planner losing the model (a path that was never produced) or an unrelated missing file. [call_-7218248447135049512, call_-7218263805938099576]
- Nothing else in the runtime is degraded: degraded=false, no worker-error occurrences, journal empty, and the sibling turns (thread.noise.0 through thread.noise.4) completed with all their effects succeeding. The failure is isolated to one thread at one instant, which matches a shared account hitting zero rather than a runtime fault. [call_-7218248447135049513, call_-7218263805938099575]
- A 240-minute lookback returned an empty timeline and empty summary even though rows exist; the 1440-minute lookback contains the incident. The burst is at 1791125835196 and diagnosis ran at 1791142396000, about 276 minutes earlier, so 'the last few hours' sits just outside the 4-hour window. [call_-7218296997445368582, call_-7218296997445368581, call_-7218248447135049512]
- Turn accounting is odd but secondary: thread.noise.5's request and final checkpoint are recorded completed at ~1791125835189, before the five failed effects at 5196-5202, and the turn outcome is 'completed' despite four failed planner effects. No attempt was retried, so there was no retry storm. [call_-7218263805938099576]

#### Timeline

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

#### Findings

##### [high] The same failure is repeating (4)

Rule `effect.repeated_failure` · category `dependency_unavailable` · finding `sha256:8146d08bf5ca58b809f31da9796f7777b9a554472a1db3f61b9eeabe710cd0f5`  
Seen 2026-10-04T14:57:15Z → 2026-10-04T14:57:15Z

**Action:** One error class and code keeps recurring; fix that cause once instead of retrying the calls.

- `effect_attempts` `sha256:6b5f1a06739e0756a0ca80311473543652496a3e37467a35725e2cae2b678fe6#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:47da65c43e58aef0b0f8e63b04b7e058125def876cdafa712a5b4160997bc741#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:f37cd3c8dfd3f6beb3395e3c04ca63604241e9dd9b5f39cad0e57ed201ed123b#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:26fd998ea674d71ec786f1b263a8466a84e9a659378223bb6b343cd512013d0a#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance

##### [high] A model call failed (4)

Rule `model.call_failed` · category `dependency_unavailable` · finding `sha256:99be8bdd0b0664008aac074cce4b4b917fdba03769ffca2e0a98c6b251b6434f`  
Seen 2026-10-04T14:57:15Z → 2026-10-04T14:57:15Z

**Action:** A failed model call can end or degrade the turn that made it; check the error code (a refused key, an empty account or a rate limit is a provider problem, not a Tamoz bug).

- `effect_attempts` `sha256:6b5f1a06739e0756a0ca80311473543652496a3e37467a35725e2cae2b678fe6#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:47da65c43e58aef0b0f8e63b04b7e058125def876cdafa712a5b4160997bc741#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:f37cd3c8dfd3f6beb3395e3c04ca63604241e9dd9b5f39cad0e57ed201ed123b#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:26fd998ea674d71ec786f1b263a8466a84e9a659378223bb6b343cd512013d0a#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance

#### Unknowns

None.

#### Proposed actions (not executed)

- One error class and code keeps recurring; fix that cause once instead of retrying the calls.
- A failed model call can end or degrade the turn that made it; check the error code (a refused key, an empty account or a rate limit is a provider problem, not a Tamoz bug).

## 8. Validation history

**Continuation (another agent, 2026-10-04).** At that point the corpus held 12 fault scenarios; its
value run is [`runs/value-2026-10-04-continuation.json`](runs/value-2026-10-04-continuation.json) and
its mutation record [`runs/mutations-2026-10-04.json`](runs/mutations-2026-10-04.json). It made no
paid call: OpenRouter had $0.45 left and refused calls
([`runs/provider-credit-2026-10-04.json`](runs/provider-credit-2026-10-04.json)).

**Round 3 (2026-10-04).** The funded provider is Z.ai's coding-plan endpoint
(`ZAI_API_BASE=https://api.z.ai/api/coding/paas/v4`; the default endpoint answers `1113 Insufficient
balance`, which Tamoz mislabels `model_rate_limited` — raised as a separate task). Safety mutations
were re-run in a scratch copy of `e542237d` with each mutation written down
([`runs/mutations-2026-10-04-round3.json`](runs/mutations-2026-10-04-round3.json)): every property's
test goes red under its mutation and green after restore. One honest exception: removing *either*
`readonly` or `PRAGMA query_only` alone is not caught, because the other guard still refuses the write;
removing both is (A1c).
