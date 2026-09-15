# F27 `tamoz-evals-runner` — the scorecard gates are genuinely hard, but the longitudinal scoreboard records a fired hard-zero without gating on it

Row / queue: F27 (gem row, W5) / `tamoz-evals-runner` — "Evaluation harnesses, scorecards,
treatments and benchmarks with explicit external inputs."
Baseline: branch `audit-15-09`, commit `582ae55`, 2026-09-15.
Analyst: F27 independent analyst (read-only lane). Budget ~55 min, hard cap 60.

## Scope and source map

Read end to end (the spine and the highest-risk leaves):

| File | Lines | Role |
|---|---:|---|
| `gems/tamoz-evals-runner/exe/tamoz-eval-runner` | 6 | executable; calls `Runner::CLI.run(ARGV)` |
| `gems/tamoz-evals-runner/tamoz-evals-runner.gemspec` | 40 | dependency contract (17 deps) |
| `lib/tamoz/evals/runner.rb` | 55 | the require spine and `PACKAGE_ROOT` |
| `lib/tamoz/evals/runner/cli.rb` | 136 | the two commands, exit-code taxonomy |
| `lib/tamoz/evals/runner/input_manifest.rb` | 204 | `runner-input-v1` schema, digest+root validation |
| `lib/tamoz/evals/runner/input_adapters.rb` | 137 | external factory/file loading |
| `lib/tamoz/evals/runner/scorecard_summary_consumer.rb` | 88 | the scheduled read-only consumer |
| `lib/tamoz/evals/runner/scorecard_result.rb` | 86 | summary shape + gate counting |
| `lib/tamoz/evals/harness/external_inputs.rb` | 84 | the manifest/root trust boundary |
| `lib/tamoz/evals/harness/agent_smoke_scorecard.rb` | 177 | the four hard gates and the decision |
| `lib/tamoz/evals/harness/agent_run_audit.rb` | 208 | every counter the scorecard reports |
| `lib/tamoz/evals/harness/subprocess_runner.rb` | 616 | bounded child execution |
| `lib/tamoz/evals/harness/heuristic_paired_evaluation.rb` | 160 | paired holdout evaluation |
| `lib/tamoz/evals/benchmark/report.rb` | 220 | the go rule's full conjunction |
| `lib/tamoz/evals/benchmark/scoreboard.rb` | 540 | the longitudinal scoreboard + regression gate |
| `lib/tamoz/evals/benchmark/readiness.rb` | 701 | publishability gate (artifact + trace verification) |
| `lib/tamoz/evals/benchmark/openclaw_mission_runner.rb` | 558 | mission status normalization |
| `lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb` | 1026 | hard-zero evidence + metric projections |
| `lib/tamoz/evals/benchmark/leak_scan.rb` | 35 | holdout truth-leak token scan |
| `lib/tamoz/evals/benchmark/comparison.rb` | 81 | seeded cluster bootstrap |
| `lib/tamoz/evals/benchmark/environment_loader.rb` | 71 | provider-credential env filtering |
| `lib/tamoz/evals/benchmark/cell_extractor.rb` | 408 | manifest→artifact evidence join (read head+path guards) |

Entry seam: `exe/tamoz-eval-runner` → `Runner::CLI#dispatch`
(`cli.rb:57-64`) → `InputManifest.from_path` → `run_gate` → `report.passed?`.
The gem ships **no** corpora, models, or fixtures; every input arrives through the
manifest and is required to live outside `PACKAGE_ROOT` and `Tamoz::Evals::DATA_ROOT`.

Supporting reads (contract, not this row's ownership): `documentation/guides/evaluation.md`,
`documentation/limitations.md:131-148`, `script/benchmark_openclaw_scoreboard` (72 lines),
`script/benchmark_holdout:126-138`, `test/support/agent_smoke_corpus.rb` (2719 lines — the
caller-owned corpus/external input this gem executes).

## Behavior path

1. **Manifest admission.** `InputManifest.from_path` (`input_manifest.rb:46-56`) parses JSON,
   requires the exact key set `manifest_version == 'runner-input-v1'`
   (`input_manifest.rb:126-134`), then for each of 13 external documents calls
   `validate_document!` (`input_manifest.rb:169-180`): the path must be **absolute**, must
   `File.file?`, must `realpath` **under** `external_root`, and must be under **none** of the
   package roots (`input_manifest.rb:76-91`), and its `sha256` must equal the manifest value
   (`input_manifest.rb:176-177`). `openclaw_fixture_factory` is a block, not a path, and is
   separately validated as callable (`input_manifest.rb:163-167`).
2. **Adapter load.** `CLI#dispatch` (`cli.rb:57-64`) loads scripted responses and, when no
   factory was injected, the scripted-model adapter through
   `InputAdapters.load_external_file!` (`input_adapters.rb:106-125`), which repeats the same
   realpath/outside-package-roots/digest triple before `load`ing Ruby source.
3. **Scorecard run.** `AgentSmokeScorecard#run` (`agent_smoke_scorecard.rb:32-45`) maps the
   corpus to executions, calls `AgentRunAudit#call` on each, and builds the report.
4. **Gate.** `build_report` (`agent_smoke_scorecard.rb:67-117`) emits four gates; `decision`
   is `pass` only when `gates.all? { status == 'pass' }` (`:115`).
5. **Exit.** `CLI#run_gate` (`cli.rb:106-116`) prints one JSON line and returns
   `SUCCESS`/`GATE_FAILURE`, so a failed gate is a non-zero exit.
6. **Benchmark path.** `OpenclawMissionRunner#normalize_result` → `outcome_status`
   (`openclaw_mission_runner.rb:345-359`) downgrades a `ready` mission to `failed` on any
   non-`passed` hard-zero; `Readiness.evaluate` (`readiness.rb:56-74`) turns that into
   `mission_hard_zero_not_passed:<id>` (`readiness.rb:424-428`) and `status: 'blocked'`;
   `Result#publishable?` (`readiness.rb:41-44`) requires `ready?`; `Report#verdict`
   (`report.rb:189-207`) returns `inconclusive` unless `@readiness.publishable?`.

## Lens: correctness

**Proven.** The scorecard's four hard gates are genuinely derivable and genuinely falsifiable:
`no_unsafe_or_bypassed_actions`, `no_false_positive_completions`, and `complete_case_evidence`
each read a real aggregate (`agent_smoke_scorecard.rb:74-76`) that `AgentRunAudit` computes
from observed events (`agent_run_audit.rb:15-16,42-73`) — not from a constant. The
`agent_scorecard_test.rb:387-408` test seeds a real violation (drops `plan_reviewed` events)
and asserts `refute unsafe.passed?` plus `"fail"` on the named gate, and separately seeds
`evidence_complete: false` and asserts the `complete_case_evidence` gate fails. This is the
direct answer to the "vacuous hard counter" question the row asks: it is **not** the
`autonomy_case.rb` shape — the gate can fail, and a test demonstrates it failing.

The benchmark go-rule is also a real conjunction (`report.rb:189-207`): inconclusive on empty
cells, on any stop-rule violation, on any `pilot` label, on `controls_passed` false, and on a
non-publishable readiness — before the effect test. `stop_rule_violations`
(`report.rb:174-187`) detects fabricated evidence references, premature decisions, and
unreported failed attempts from the cells themselves.

**Finding F27-COR-01** (major) is recorded below: the longitudinal scoreboard's regression
verdict ignores hard-zero status.

## Lens: security and authority

**Proven, strong.** This gem's trust boundary is the most carefully built surface I read.
Untrusted input cannot widen what a run may do or point the harness at repository content:

- Absolute + realpath + under-`external_root` + **outside**-package-roots
  (`input_manifest.rb:76-91`, `input_adapters.rb:111-125`) means a manifest cannot make the
  harness load a script, corpus, or fixture from inside the checkout — the exact
  "runner does not ship its own inputs" claim in the README.
- Every external document is `sha256`-pinned at admission (`input_manifest.rb:169-180`) and
  re-digested at load (`input_adapters.rb:119`).
- Mission artifact reads defend against path escape, symlinks, and out-of-root reads
  (`readiness.rb:484-501`: `safe_artifact_path?`, `File.symlink?` rejection, `realpath`
  containment), bind the artifact to protocol/provider/model/git/config
  (`readiness.rb:523-537`), re-derive the mission digest (`readiness.rb:546-555`), and
  secret-scan the document before use (`readiness.rb:505`).
- Child processes get a scrubbed environment: `unsetenv_others: true`, `close_others: true`,
  a new process group, and `File::NULL` on stdin (`subprocess_runner.rb:220-232`). The
  scheduled consumer narrows further to seven named env keys and a 1 MiB output cap
  (`scorecard_summary_consumer.rb:64-75`).
- Provider credentials are filtered to the selected provider's own variable names and never
  override an already-present value (`environment_loader.rb:28-35,63-67`).

**Not evidenced:** there is no negative test that a manifest pointing at a
digest-mismatched adapter file is rejected at the CLI seam (the logic is proven by reading
`input_manifest.rb:176-177`; I did not find a test exercising that rejection end to end
through `exe/tamoz-eval-runner`). What would prove it: a CLI-level test with a tampered
`scripted_model.adapter.sha256`.

## Lens: reliability and durability

**Proven.** `SubprocessRunner` bounds every dimension the lens asks about:
`timeout_ms` is clamped to `MAX_TIMEOUT_MS = 3_600_000` (`subprocess_runner.rb:18,148-153`);
`output_limit_bytes` is clamped to 16 MiB and the capture loop truncates while still
digesting the full stream so `truncated` is honest without unbounded memory
(`subprocess_runner.rb:239-258`); on timeout it escalates `TERM` then `SIGKILL` **to the
process group** and asserts the SIGKILL actually landed
(`subprocess_runner.rb:318-344`); the `ensure` at `:213-217` calls
`terminate_and_reap(pid) if pid && !reaped`, closes every pipe, and joins both reader
threads. No orphan-process path was found: a child is always either reaped by
`waitpid2` (`:279-287`) or killed-and-reaped in `ensure`.

**Proven, degraded.** `HARNESS`-level robustness is weaker in one place: `CliSubprocessHarness`
in the corpus (`test/support/agent_smoke_corpus.rb:815-817`) uses a `sleep 1.1` to sequence a
kill/resume. That is caller-owned code, outside this gem's row, but it is the one wall-clock
dependency in the scorecard path — noted as an info item, not a finding against this gem.

## Lens: observability and evidence

**Proven.** Every outcome is a named, machine-readable artifact. The scorecard prints exactly
one canonical JSON line carrying `content_digest` (`agent_smoke_scorecard.rb:39`), per-case
`status`/`terminal`/`terminal_reason`, the full counter set, and a `hard_gates` array with a
per-gate `pass`/`fail` — so a refusal is visible per gate, not just as a scalar.
`terminal_reason` prefers the repair-stop reason, then `check_passed`, then the terminal value
(`agent_run_audit.rb:133-139`). The consumer re-validates the shape and refuses with a named
reason rather than reporting success on missing fields (`scorecard_result.rb:13-22,54-61`).

The honesty of the report header is notable and correct: `network_enforcement: "not_claimed"`,
`live_network_validation: "deferred"`, `attribution_claim: "not_claimed"`
(`agent_smoke_scorecard.rb:97-111`) — this is a controller-scripted run and the artifact says
so, which matches `AGENTS.md`'s "fakes stay in tests" rule rather than violating it.

## Lens: scalability and resource bounds

**Proven** for the subprocess plane (see reliability above: timeout, 16 MiB output ceiling,
process-group kill, pipe/thread cleanup) and for the bootstrap
(`comparison.rb:22-57` fixes `resamples: 2000` and a seeded `Random.new(seed + resample)`, so
cost and output are both bounded and reproducible).

**Not evidenced:** process-wide bounds for the CLI as a whole. `CLI#run` runs the entire
corpus in-process (`agent_smoke_scorecard.rb:34-37`) with no case-count ceiling, no wall-clock
budget, and no memory cap; a caller-supplied corpus of N cases costs O(N) executions and holds
every case report in memory (`:38`, `build_aggregate` `:119-148`). What would prove a bound:
either a documented input-size contract on the corpus document, or a per-run case ceiling.
This is a bounded-debt observation, not a demonstrated failure — the corpus is caller-owned
and currently 20-ish cases.

## Lens: maintenance and architecture

**Proven, with carried-forward debt.** Ownership is clean and the vocabulary is consistent:
`InputManifest` owns admission, `ExternalInputs` owns the root/manifest read boundary,
`InputAdapters` owns external code loading, `Readiness` owns publishability, `Report` owns
scoring, `Scoreboard` owns the longitudinal record. Dependency direction is honest — the
gemspec declares 17 pinned `= version` dependencies and the gem requires its own files
explicitly (`runner.rb:5-47`).

Carried-forward prior findings, re-verified against current source (not re-litigated):

- **014 [major][PLACE] still open.** Raw SQL plus `runtime.adapter.__send__(:read, ...)` over
  `tamoz_effects`/`tamoz_effect_attempts` remains at
  `openclaw_durable_cli_adapter.rb:937,941-944,959,963-966`, and the 1026-line class still
  folds CLI orchestration + hard-zero policy + metric projection. Tracker row 014 = `todo`.
- **038 [major][SIZE] still open, [minor][DUP] confirmed fixed.** The minor fix is real:
  `readiness.rb:59-68` computes `artifact_reasons` **once** and derives
  `artifacts_verified` from that single pass. The 701-line class still mixes schema
  validation, filesystem/digest verification, and provider-trace verification under a
  `ClassLength` disable (`readiness.rb:13`). Tracker row 038 = `partial`.
- **040 [major][DEAD] hardened, [minor][DEAD] correctly rejected.** Dispatch fail-fast is
  present (per the recorded resolution); `append_checkpoint`'s defaults are real. Tracker
  row 040 = `partial`.
- **062 / 013 / 070** are size/duplication debt. 070's recorded seams (`EntryPolicy`,
  `Intervals`) are verifiably present (`scoreboard.rb:70,168,262,265`) and the four
  `self.class.send` bypasses are gone — confirmed at `scoreboard.rb:262-265`. Tracker row
  070 = `done`; I agree with that row on the seam evidence I read.
- **Duplication check (AGENTS.md).** I found **no** new class in this gem duplicating a
  production capability. `LeakScan`, which looked dead on a first grep, is in fact consumed
  by `script/benchmark_holdout:130` — it is the shared implementation, correctly factored out
  rather than duplicated. `CellExtractor` is the single manifest→artifact join
  (`comparison_executor.rb:29`).

## Tests and contracts

All run with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`, one
file per command. No real LLM was called; no generator wrote into the repo.

| Command | Result |
|---|---|
| `ruby -Itest test/agent_scorecard_test.rb` | 6 runs / 215 assertions / **0 failures** / 0 errors / 0 skips (37.8 s) |
| `ruby -Itest test/benchmark_harness_test.rb` | 25 runs / 67 assertions / **0 failures** |
| `ruby -Itest test/benchmark_controls_test.rb` | 14 runs / 42 assertions / **0 failures** |
| `ruby -Itest test/benchmark_report_test.rb` | 9 runs / 65 assertions / **0 failures** |
| `ruby -Itest test/agent_change_evaluation_test.rb` | 2 runs / 30 assertions / **0 failures** |
| `ruby -Itest test/openclaw_durable_cli_adapter_test.rb` | 3 runs / 12 assertions / **0 failures** |
| `ruby -Itest test/openclaw_mission_runner_test.rb` | 9 runs / 39 assertions / **0 failures** |
| `ruby -Itest test/openclaw_benchmark_readiness_test.rb` | 10 runs / 41 assertions / **0 failures** |
| `ruby -Igems/tamoz-evals/test -Igems/tamoz-evals-runner/lib -Itest gems/tamoz-evals/test/scoreboard_test.rb` | 4 runs / 22 assertions / **0 failures** |
| `ruby -Itest test/autonomy_scorecard_test.rb` | 17 runs / 143 assertions / **3 FAILURES** / 0 errors |

`autonomy_scorecard_test.rb` is recorded as a **reproducible 3-failure result**, command and
counts above. All three are in the comms/chat path, not in this gem's code:
`test_case_11_chat_message_becomes_a_durable_turn_and_an_answer_returns:262`
("the terminal answer must be sent exactly once. Expected: 1 Actual: 0"),
`test_case_16_saturated_capacity_refuses_intake_but_reserves_the_answer:403`
("the refused sender should get a busy notice, not a turn"), and
`test_case_17_follow_up_messages_queue_and_carry_the_transcript:442`
("every message must get a terminal answer. Expected: 2 Actual: 0"). This file lives under
`test/`, and I did not edit it. I record the result because the row brief asked me to run it
and report exact pass counts; the owning code is the comms/turn-delivery surface, which is a
different row. It does **not** touch the evaluation hard gates.

`test/scoreboard*` — the only file matching that glob is the `tamoz-evals` one run above.
`test/benchmark_*_test.rb` were not all run (see Blind spots). `not run`: the remaining
`benchmark_*` files and `test/openclaw_*` beyond the two above, all skipped for the 60-minute
cap, not because of a known failure.

## Findings

### F27-COR-01 — the longitudinal scoreboard records a fired hard-zero but the regression verdict never reads it

- **Severity:** major
- **Confidence:** high
- **Status:** open
- **Lens:** correctness (with observability and evidence)
- **Source evidence:**
  - `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/scoreboard.rb:431` — `append` writes
    `'hard_zero_fired' => hard_zero_names(@manifest, @report)` into the entry.
  - `scoreboard.rb:154-163` — `hard_zero_names` collects every non-`passed` mission hard-zero
    plus `report['hard_zero_fired']`.
  - `scoreboard.rb:342-351` — `evaluate_regression` computes the verdict **only** from
    `regression_drops`, i.e. `current.axes[axis] < prior_interval.low` (`:353-366`).
  - `scoreboard.rb:331-340` — `regression_result` sets `status` from
    `regressions.empty? || acknowledged` alone.
  - `scoreboard.rb:386-398` — `append` calls `validate_run!` (run_kind + controls_passed +
    safe root, `:402-412`) and `validate_entries!` (schema only, `:81-105`), then writes.
    **No hard-zero branch exists anywhere in the class.**
  - `script/benchmark_openclaw_scoreboard:39-58` — the CLI validates `run_kind` and
    `controls_passed` from a caller-supplied manifest file and calls `Scoreboard.append`
    directly; it never calls `Readiness.evaluate` and never binds the manifest to an artifact
    digest.
- **Test/contract evidence:** `gems/tamoz-evals/test/scoreboard_test.rb:12-35` —
  `test_append_scales_axes_integers_inverts_cost_and_collects_hard_zeros` builds a report with
  two fired hard-zeros and asserts the append **succeeds** (`assert_predicate result,
  :appended?`, `:22`) and that the names are merely *collected* (`:30`). Run:
  `ruby -Igems/tamoz-evals/test -Igems/tamoz-evals-runner/lib -Itest
  gems/tamoz-evals/test/scoreboard_test.rb` → 4 runs / 22 assertions / 0 failures. The test
  pins the non-gating behavior as intended.
- **Contrast that proves this is not the general design:** the OpenClaw path *does* gate on
  it — `openclaw_mission_runner.rb:348-349` (`failed = hard_zero.value?('failed') … ; return
  'failed'`), `readiness.rb:424-428` (`mission_hard_zero_not_passed`),
  `readiness.rb:41-44` (`publishable?`), `report.rb:198` (verdict → `inconclusive`). The
  scoreboard is the one consumer of the same hard-zero vocabulary that does not enforce it.
- **Scanner signal:** grep for `hard_zero_fired` across `gems/` and `test/` returns five hits;
  every one is a write, a schema type-check, or a test assertion — **zero read into a
  decision**.
- **Independent judgment:** I confirmed the write path and disproved a possible defence. The
  defence would be "readiness already refused the run before the scoreboard saw it" — but the
  scoreboard CLI takes `--manifest PATH` and `--report PATH` as plain files and performs no
  readiness call (`script/benchmark_openclaw_scoreboard:34-58`). The gate exists upstream; the
  append path is a second, unguarded door to the same append-only record. What I did **not**
  prove is that this has already produced a misleading committed entry — I did not read
  `documentation/benchmark/scoreboard/INTELLIGENCE_SCOREBOARD.json`. The defect is that the
  record's acceptance rule permits it.
- **Root cause (five whys):**
  1. A run whose unauthorized-effect or false-success hard-zero fired still yields a `passed`
     regression verdict on the scoreboard.
  2. Because `regression_result` derives `status` solely from `regressions.empty? ||
     acknowledged` (`scoreboard.rb:332`) and `regressions` is derived solely from axis
     interval drops (`:353-366`).
  3. Because `hard_zero_fired` was modelled as a descriptive entry field
     (`scoreboard.rb:24,431`) rather than as an admission predicate alongside
     `run_kind`/`controls_passed`.
  4. Because the two gates that *were* modelled as admission predicates were the two that
     happen to be cheap to read off the manifest itself (`scoreboard.rb:402-407`), while
     hard-zero status required reaching into the mission records — and the append path was
     never wired to `Readiness`, the component that already computes it
     (`readiness.rb:424-428`).
  5. Because the same hard-zero vocabulary has **two independent evaluators** — `Readiness`
     (publishability) and `Scoreboard` (longitudinal acceptance) — with no shared contract
     naming which one owns the hard-zero verdict. There is no test that a fired hard-zero is
     rejected by the scoreboard, so the divergence was never surfaced. The missing contract
     is: *a hard-zero is an admission predicate on every evaluation artifact, not a field on
     one of them.*
- **Recommendation (smallest credible action at the existing owner seam):** in
  `Scoreboard#validate_run!` (`scoreboard.rb:402-412`), alongside the existing
  `run_kind`/`controls_passed` checks, raise `Scoreboard::Error` when
  `hard_zero_names(@manifest, @report)` is non-empty. `hard_zero_names` already exists
  (`:154-163`) and is already called one line later in `build_entry` (`:431`), so this is a
  guard at the seam that already owns admission — no new class, no new module. Add one
  negative test beside the existing positive one in `scoreboard_test.rb:12-35` asserting the
  append raises on a fired hard-zero.
- **Disposition:** open. Needs an independent challenge. Note the deliberate counter-argument
  for the coordinator: `documentation/benchmark/openclaw-intelligence-study/02-mission-catalog-and-scoring.md:161-165`
  documents the regression gate as interval-only, so the *current* behavior matches its
  written contract; the finding is that the written contract is weaker than the hard-zero
  claim the suite makes elsewhere, and the two must be reconciled one way or the other.

### F27-OBS-01 — `verified_completion` on six scorecard cases is a harness-constructed process status, not a verification result

- **Severity:** info
- **Confidence:** high
- **Status:** open
- **Lens:** observability and evidence
- **Source evidence:** `AgentRunAudit` defines the counter as
  `execution.result&.satisfied == true` (`agent_run_audit.rb:19`) and aggregates it into
  `verified_completions` / `verified_completion_basis_points`
  (`agent_smoke_scorecard.rb:133-134`). For most cases `result` is the agent's own
  verify-stage output (`gems/tamoz-agent/lib/tamoz/agent/runtime.rb:616-623`, sourced from
  `Deliberation.parse_verification(raw)`). But for the six `requires_check: false` cases the
  harness constructs the value itself:
  `test/support/agent_smoke_corpus.rb:821` (`CliOutcome.new(satisfied: resume_status == 0)`),
  `:905` (`satisfied: status.zero?`), `:1282`, `:1712`, `:2372`, `:2488`.
- **Test/contract evidence:** `ruby -Itest test/agent_scorecard_test.rb` → 6 runs / 215
  assertions / 0 failures, including the positive assertions at
  `test/agent_scorecard_test.rb:185,218,236,276` that those same cases report
  `verified_completion == true`.
- **Independent judgment:** this is a **verified design fact, not a defect**, and I am
  deliberately not inflating it. The metric is not load-bearing on its own: `task_success`
  comes from the case oracle (`agent_run_audit.rb:18`) and the false-positive gate from
  `false_positive_completion?` (`:147-151`), which for these cases also requires the oracle.
  The oracles are independently proof-rich (`agent_smoke_corpus.rb:849-865` re-reads the
  workspace, history, and effect receipts). So the scorecard cannot pass on the strength of
  this counter. The honest caveat is one of naming: on those six cases
  `verified_completion` means "the harness observed a zero process exit under a rich oracle",
  and a reader who takes the field name at face value would over-read it. Recording it so the
  coordinator can decide whether a rename or a per-case provenance field is worth it — I
  recommend neither, since the report already carries `terminal`, `oracle`-derived
  `task_success`, and `check_passed` per case (`agent_smoke_scorecard.rb:55-63`).
- **Root cause (concise):** the subprocess-driven cases bypass the agent's in-process verify
  stage, so there is no `Result` to read; the harness substitutes the only signal available
  to it and reuses the same field name.
- **Recommendation:** none required. If the field name is judged misleading, the smallest
  action is a per-case provenance key beside `verified_completion` in
  `build_case_report` (`agent_smoke_scorecard.rb:49-65`) — not a new class.
- **Disposition:** accept as `info`; no fix required.

### F27-SEC-01 — no end-to-end negative test for manifest digest rejection at the CLI seam

- **Severity:** minor
- **Confidence:** medium
- **Status:** open
- **Lens:** security and authority (test-coverage gap)
- **Source evidence:** the rejection logic is present and correct —
  `input_manifest.rb:169-180` (`raise Invalid, "#{label} digest does not match its manifest"
  unless expected == actual`) and `input_adapters.rb:119` (same check again at load time).
- **Test/contract evidence:** `not found` — I found no test that drives
  `exe/tamoz-eval-runner` with a manifest whose `scripted_model.adapter.sha256` (or any other
  pinned digest) has been tampered with, and asserts the `USAGE_ERROR` exit. What I read is
  unit-level logic only.
- **Independent judgment:** the guard is real and read directly, so this is a coverage gap,
  not a suspected hole. `medium` confidence because I did not exhaustively search the test
  tree for such a case; I searched only the files in this row's test surface.
- **Root cause (concise):** the manifest's digest check was tested at the unit level, where
  the boundary is easy to construct, and the CLI-level path was covered for shape errors
  rather than for tamper.
- **Recommendation:** one test in the existing runner-input test file that flips one byte of
  a pinned external document and asserts the CLI refuses with the usage exit code. No source
  change.
- **Disposition:** open, low priority; may be closed as duplicate if another row already
  owns runner-input tamper coverage.

### F27-SCAL-01 — the CLI has no whole-run case-count or wall-clock bound

- **Severity:** minor
- **Confidence:** medium
- **Status:** open
- **Lens:** scalability and resource bounds
- **Source evidence:** `AgentSmokeScorecard#run` maps over every corpus case in process and
  materializes all case reports before aggregating (`agent_smoke_scorecard.rb:34-38`,
  `build_aggregate` `:119-148`). `InputManifest` validates the corpus *descriptor* but not a
  case count. The per-child bounds exist (`subprocess_runner.rb:148-153`), but they are
  per-child, not per-run.
- **Test/contract evidence:** `not run` — I did not construct a large-corpus probe; doing so
  would need a generator, which this brief forbids.
- **Independent judgment:** this is bounded debt, not a demonstrated failure. The corpus is
  caller-owned and small; the risk is a hostile or careless manifest, and a hostile manifest
  already has to pass digest pinning and live outside the package roots
  (`input_manifest.rb:76-91`), so the practical exposure is a careless caller, not an
  attacker. I am recording it because the row explicitly asks for resource-bound evidence and
  the honest answer is "bounded per child, unbounded per run."
- **Root cause (concise):** input-size limits were designed for the child-process plane
  (where a runaway is real) and not for the in-process corpus plane (where the corpus is
  trusted-by-construction as caller-owned).
- **Recommendation:** none at present — documenting the expected corpus size in the runner
  README would close the observability half. A hard ceiling would be speculative machinery
  for a case that has not occurred, which `AGENTS.md` tells us not to build.
- **Disposition:** accept as recorded debt; recommend the coordinator either downgrade to
  `info` or leave open for the owner's call.

## Blind spots

Files in this gem I did **not** read (44 files / ~12 059 lines; I read the spine and the
highest-risk leaves listed in Scope, roughly 7 900 lines touched or skimmed):

- `harness/sqlite_selector_control.rb` (644), `sqlite_convergence_probe.rb` (574),
  `sqlite_trace_recorder.rb` (536), `sqlite_scenario_registry.rb` (368),
  `memory_repository_adapter.rb` (363), `memory_treatment_profile.rb` (334),
  `sqlite_selector_control_intervention.rb` (245), `memory_cell.rb` (212),
  `sqlite_selector_control_stopper.rb` (211), `sqlite_trace_manifest_verifier.rb` (204),
  `memory_store.rb` (185), `heuristic_corpus.rb` (131), `sqlite_scenario_driver.rb` (139),
  `sqlite_trace_selector_deriver.rb` (120), `memory_retrieval.rb` (54),
  `memory_envelope.rb` (80), `memory_holdout.rb` (60), `sqlite_scenario_fault_gate.rb` (58).
  **Why it matters:** the SQLite scenario/selector-control/trace-verification plane is a
  distinct trust surface (it drives real durable storage in subprocesses) and its
  manifest-verification path (`sqlite_trace_manifest_verifier.rb`) is the kind of place a
  digest handoff could be vacuous. I verified only its dispatch fail-fast status through
  prior finding 040's resolution, not its runtime behavior.
- `benchmark/metrics.rb` (244), `baselines.rb` (133), `comparison_executor.rb` (85),
  `openclaw_publisher.rb` (54), `openclaw_comms_oracles.rb` (769). **Why it matters:**
  `metrics.rb` implements every score the report publishes; I read `Report` and `Comparison`
  but not the metric bodies, so a scoring formula defect would be invisible to this report.
- `openclaw_durable_cli_adapter.rb` beyond lines ~155-200 and ~440-530 (the hard-zero and
  `result_for` regions). **Why it matters:** the ~20 catalog metric projections and the
  subprocess crash-injection half are unread.
- `readiness.rb` beyond lines 36-100 and 400-560; the provider-trace/receipt cryptographic
  verification half (~560-697) is unread. **Why it matters:** that is the cryptographic
  provenance check the readiness gate depends on, and it is exactly where prior finding 038's
  major sits.
- `cell_extractor.rb` beyond the first 80 lines. **Why it matters:** the cell-scoring
  projection from artifact → cell is unverified; a wrong projection would move every
  benchmark number.

Behavioral gaps: I did not run the SQLite scenario suites, the memory treatment suites, the
remaining `benchmark_*` suites, or `test/openclaw_benchmark_environment_loader_test.rb` /
`openclaw_benchmark_readiness_cli_test.rb` / `openclaw_scenario_corpus_test.rb` — the 60-minute
cap. I did not read the committed
`documentation/benchmark/scoreboard/INTELLIGENCE_SCOREBOARD.json`, so I cannot say whether
F27-COR-01 has already produced a misleading recorded entry. I did not execute
`exe/tamoz-eval-runner` end to end (it needs a caller-owned manifest I would have had to
author, and authoring one would write into the repo). E03 (the executable row) is another
analyst's; I read `exe/tamoz-eval-runner` and `runner/cli.rb` only for this gem's contract and
claim nothing about E03.

## Verdict

**IMPROVE** — 0 critical, 1 major, 2 minor, 1 info.

Per BAR.md: one accepted major finding meets the `IMPROVE` threshold. All six lenses were
reviewed; the correctness, security, reliability, observability, and maintenance lenses carry
concrete `file:line` evidence, and the scalability lens records what is bounded and what is
not. The core question the row poses resolves **cleanly in the scorecard's favor**: the four
agent-smoke hard gates are genuinely hard and demonstrably falsifiable
(`agent_scorecard_test.rb:387-408`), the benchmark go-rule is a real conjunction that a
non-publishable readiness or any stop-rule violation reduces to `inconclusive`
(`report.rb:189-207`), and the OpenClaw hard-zero chain does downgrade a mission to `failed`
and refuse publication (`openclaw_mission_runner.rb:348-349` → `readiness.rb:424-428` →
`readiness.rb:41-44` → `report.rb:198`). The one place the hard-zero vocabulary is collected
but not enforced is the longitudinal scoreboard (`scoreboard.rb:342-366`, `:402-412`), which
is F27-COR-01. The external-input boundary is the strongest surface I reviewed in this row and
no hostile-manifest widening path was found.
