# CF13 evaluation corpus, harness, scorecard, verification, and release evidence — IMPROVE

Row / queue / baseline
- Row: **CF13** — evaluation corpus, harness, scorecard, verification, and release evidence
- Queue: W5 (`COVERAGE.md`, evals / evals-runner)
- Baseline: branch `audit-15-09`, code commit `582ae5566de1ae073aea82b69bb2bbf444494d3b`, 2026-09-15
- Analyst: coordinator direct review; delegation was paused by the owner
- Budget: one bounded source, test, and cross-boundary probe pass

## Scope and source map

The flow was traced from caller-owned input admission through the harness, the
scorecard and benchmark gates, artifact verification, and the release rehearsal.
The component reports remain the authoritative detailed reviews; this report
records the boundary behavior and the coordinator's overlap decisions.

| Boundary | Source path read | Contract carried across |
|---|---|---|
| External input admission | `gems/tamoz-evals-runner/lib/tamoz/evals/runner/input_manifest.rb:46-180`, `input_adapters.rb:106-125` | exact `runner-input-v1` shape, absolute external paths, realpath containment, SHA-256 pins |
| Runner dispatch | `gems/tamoz-evals-runner/lib/tamoz/evals/runner/cli.rb:27-124`, `gems/tamoz-evals-runner/lib/tamoz/evals/runner.rb:3-47` | typed usage/evidence/infrastructure exits; external adapter invocation |
| Scorecard execution | `gems/tamoz-evals-runner/lib/tamoz/evals/harness/agent_smoke_scorecard.rb:32-148`, `agent_run_audit.rb:15-151` | per-case terminal/evidence/safety facts, four hard gates, canonical report digest |
| Child and benchmark execution | `gems/tamoz-evals-runner/lib/tamoz/evals/harness/subprocess_runner.rb:143-344`, `benchmark/report.rb:174-207`, `benchmark/readiness.rb:41-74,424-428` | timeout/process-group cleanup; publishability and hard-zero rules |
| Artifact verification | `gems/tamoz-evals/lib/tamoz/evals/verifier.rb:39-161`, `canonical_json.rb:26-97`, `cli.rb:31-74` | closed schema, digest, references, typed refusal and exit precedence |
| Release pin | `script/generate_release_evaluation_manifest:52-126` | fresh scorecard run compared with the committed external pin |
| Release rehearsal | `script/release_rehearsal:20-58,157-347`, `Rakefile:444-482` | clean clone, both locales, scorecard, packaged gems, durability, requirements evidence |
| Requirements evidence | `script/generate_requirements_audit:24-214`, `test/requirements_manifest_test.rb:180-192` | named-test exit mapping and committed audit artifact |
| Longitudinal benchmark record | `script/benchmark_openclaw_scoreboard:34-82`, `benchmark/scoreboard.rb:154-163,331-412,431` | real-provider manifest checks, interval regression record, hard-zero field |

## End-to-end behavior

1. A caller supplies a manifest whose 13 external documents and MCP server are
   outside the package roots and are SHA-256 pinned. `InputManifest` resolves
   every path before the runner constructs a corpus or loads Ruby source.
2. `Runner::CLI` reloads the pinned scripted responses and adapter, then invokes
   the selected scorecard or treatment factory. A factory may receive the
   validated manifest; it cannot silently replace the input contract.
3. `AgentSmokeScorecard` runs the caller-owned corpus, audits each execution,
   aggregates the observed counters, emits four hard gates, and computes a
   canonical content digest. The CLI returns success only when every gate is
   `pass`; invalid evidence and infrastructure failures have distinct exits.
4. The benchmark path applies the same external-input boundary. Child processes
   have bounded output and time, process-group termination, and reaping. OpenClaw
   readiness turns any non-passed mission hard-zero into a non-publishable result;
   the report therefore cannot call a hard-zero run ready.
5. `Tamoz::Evals::Verifier` independently validates evidence artifacts, recomputes
   their digest, checks referenced files and stable reads, and maps refusal to a
   typed CLI exit. This is a second consumer of the scorecard's evidence, not a
   trust in the runner's printed JSON.
6. `generate_release_evaluation_manifest` runs the scorecard again and compares
   corpus, decision, counters, and case digests with the committed pin. It writes
   only when `--accept` is explicitly supplied.
7. `release_rehearsal` performs those steps in a clean clone, runs the gate under
   two locales, exercises packaging and durability suites, and records a
   requirements audit. Its source calls `rake ci`, whose own composition and the
   unbounded shell-outs are owned by R01/S01.

## Six-lens assessment

### Correctness

The normal path has two independent decision layers: scorecard hard gates and
artifact verification. The four scorecard gates read observed execution facts,
and the benchmark report requires the conjunction of non-empty cells, controls,
readiness, and no stop-rule violation. The direct scorecard suite demonstrates
that safety and evidence gates can fail; this is not a constant-counter gate.

The one scoreboard discrepancy, `F27-COR-01`, is not a new CF13 defect. The
challenger verified that the written benchmark contract assigns hard-zero
blocking to readiness/publication while the scoreboard records interval trends.
`FINDINGS.md` therefore demotes it to a minor documentation/ownership question.

### Security and authority

The manifest boundary is strong: absolute external paths, realpath containment,
package-root exclusion, and digest checks occur before code loading. Child env
scrubbing and provider-key filtering keep the benchmark process from inheriting
ambient authority. The verifier rejects path traversal, symlink escape, duplicate
keys, bad digests, unstable reads, and unsupported schema keys.

The remaining security evidence gap is `F27-SEC-01`: no end-to-end CLI test
tampering a manifest-pinned adapter. The source guard is present and the direct
`RunnerInputManifestTest` covers the constructor, but the CLI seam is not tested.
This remains owned by F27 and is not counted again here.

### Reliability and durability

`SubprocessRunner` supplies the bounded child seam: timeout is clamped, output is
limited while the full stream is digested, TERM then KILL targets the process
group, and the `ensure` path closes pipes and reaps children. The release pin
reruns the harness, so a changed corpus cannot be accepted as a byte-only update.
The verifier's stable-file read also checks metadata before and after the read.

Two cross-boundary reliability gaps remain open under their owning rows. A
zero-byte evidence file escapes the verifier's typed error tree (`F26-ERR-01`),
and release rehearsal runs the weaker `rake ci` path rather than the declared
full gate (`R01-GATE-02`). Both are reproduced in the component/challenge files;
CF13 does not create a second finding for either.

### Observability and evidence

The scorecard report records per-case terminal state, reasons, safety violations,
all counters, four named gates, and a content digest. The release-evaluation pin
records the decision and the counters that a release relies on. The verifier
does not trust those fields until the artifact schema and digest pass.

The committed requirements audit is the weak evidence boundary. The generator
maps a zero-run filter to `not-run`, but the committed audit still contains a
phantom supporting test and stale pass rows because its guard compares only
requirement IDs and the absence of `unverified`. This is `F26-EVD-01`, challenged
and accepted as a major owned jointly by S01/R01. The potential zero-assertion
pass is `F26-EVD-02`, a minor generator contract gap with no current occupant.

### Scalability and resource bounds

Per-child execution is bounded, and the scorecard's bootstrap resampling and
artifact/reference byte budgets are bounded. The whole scorecard still has no
case-count, wall-clock, or process-wide memory ceiling (`F27-SCAL-01`), and the
requirements generator launches one subprocess per named case. Those are
caller-owned corpus and support-script decisions already recorded as F27/S01
findings; no distinct cross-flow failure was observed.

### Maintenance and architecture

Ownership is clear and the dependency direction is one-way: runner inputs and
harnesses call into the verifier, never the reverse; release scripts compose
both through command boundaries. The release pin and benchmark protocol use
explicit regeneration/compare patterns, while the requirements audit and Rake
gate rely on weaker freshness/composition contracts. `S01-BEN-01`, `R01-GATE-01`,
and `R01-GATE-02` remain the material composition findings. `F27-COR-01` is
already demoted to a minor documentation decision and is not duplicated here.

## Tests and direct checks

Focused commands were run one file per command from the repository root:

| Command | Result |
|---|---|
| `ruby -Itest test/evals_verifier_test.rb` | 23 runs, 294 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/requirements_manifest_test.rb` | 11 runs, 3018 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/release_evaluation_manifest_test.rb` | 9 runs, 149 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/release_rehearsal_evidence_test.rb` | 9 runs, 44 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/runner_input_manifest_test.rb` | 7 runs, 13 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/ci_configuration_test.rb` | 2 runs, 15 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/documentation_surface_test.rb` | 9 runs, 87 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_scorecard_test.rb` | 6 runs, 215 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest gems/tamoz-evals/test/scoreboard_test.rb` | 4 runs, 22 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/benchmark_controls_test.rb` | 14 runs, 29 assertions, 0 failures, 5 `Errno::EPERM` errors while loopback fixtures attempted `bind(2)`; environment-known red |

The direct tests confirm the manifest constructor, scorecard, verifier, pin,
rehearsal evidence shape, and scoreboard behavior. No real provider, network
service, full `rake ci`, full `rake ci_full`, or release rehearsal was run. The
loopback errors are sandbox restrictions, not product verdicts.

## Findings and overlap decisions

CF13 adds **no new machine-counted finding**. The following boundary findings are
accepted under their existing owners:

| Existing finding | CF13 treatment |
|---|---|
| `F26-EVD-01` | Carry as the stale requirements-audit artifact and freshness contract; S01/R01 own the generator/release composition. |
| `F26-ERR-01` | Carry as the verifier zero-byte fail-closed defect; F26 owns `read_stable_file`. |
| `F26-EVD-02` | Carry as the unoccupied zero-assertion evidence gap; F26/S01 own the generator contract. |
| `F27-COR-01` | Carry only as the challenged minor documentation/ownership question; no scoreboard gate change is inferred. |
| `F27-SEC-01`, `F27-SCAL-01` | Carry CLI tamper-test and whole-run bound gaps without a second count. |
| `S01-BEN-01` | Carry unbounded release/evidence subprocess sites; S01 owns the support seam. |
| `R01-GATE-01`, `R01-GATE-02`, `R01-GATE-04` | Carry gate composition and release-rehearsal mismatch; R01-GATE-04 is already merged into R01-GATE-01 in the coordinator index. |
| `E02`/`E03` entry-point items | Carry executable presentation and help-path observations to the app/entry-point rows; no CF13 duplicate. |

The direct trace found no additional reachability, authority, or durability
failure separable from these owners. The CF13 machine count is therefore
`critical=0`, `major=0`, `minor=0`, `info=0`; carried findings keep the flow
`IMPROVE`.

## Blind spots

- No caller-owned `runner-input-v1` manifest was executed through a successful
  real scorecard or release rehearsal; external corpora and providers are
  intentionally outside the repository.
- The full requirements audit was not regenerated because this is a read-only
  audit and regeneration writes committed artifacts. The stale-artifact finding
  remains open rather than being resolved by this report.
- `test/benchmark_controls_test.rb` could not bind loopback sockets in this
  environment; its five errors are recorded above and in the component report.
- No real OTLP/network endpoint or provider was contacted, and no full gate was
  run. Benchmark metrics and mission internals remain owned by F27.
- The support-script/Rakefile composition was read from source and challenge
  reports; CF13 does not claim a fresh runtime measurement of CI wall-clock or
  subprocess hangs.

## Verdict

**IMPROVE.** The end-to-end source trace and all six lenses are complete. CF13
adds no new machine-counted finding because every observed weakness maps to an
existing F26/F27/S01/R01/E02/E03 owner. The open carried majors include stale
release evidence, the zero-byte verifier crash, unbounded support subprocesses,
and incomplete gate composition, so the flow cannot be called PASS.
