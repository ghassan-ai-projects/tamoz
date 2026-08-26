# Phase 2 evidence matrix

The implementation agent captures the baseline receipt before moving any
runner file, then reruns the same rows after correction. Hashes belong in the
machine-readable receipt; this table defines what must remain equal.

| Surface | Baseline and after check | Equality/acceptance rule |
|---|---|---|
| Case/evidence/result artifacts | existing base `suites/**/*.case.json`, schemas, baselines, and referenced bytes | byte-identical; verifier accepts the same paths |
| Verifier API | `Tamoz::Evals.verify` for pass, fail, invalid, infrastructure, and insufficient evidence | same decisions, digests, references, exception classes, and safe messages |
| Verifier CLI | `tamoz-eval --version`, `verify` for one/multiple artifacts, malformed usage | same stdout/stderr bytes and exit codes; same multi-artifact precedence |
| Runner scorecard/treatment | deterministic scorecard and CI treatment reports | same report identity, labels, aggregates, hard gates, and content digests |
| Benchmark adapters | fixture/pilot and real-provider readiness manifests | same `run_kind`, attribution labels, controls, and publication decisions; fixtures are injected externally and are not packaged |
| Scheduler consumer | read-only grant, default argv, valid summary, nonzero exit, malformed JSON, missing binary | same fail-closed result shape; only command path and namespace intentionally change |
| Base-only install | package file list and subprocess load graph | no runner/harness/benchmark constants or heavy dependencies; no repository paths |
| Runner-only install | package file list, explicit external fixture injection, subprocess load graph | only declared dependencies load; no fixture source/data enters the runner gem |

The report must distinguish byte equality, semantic equality, and intentional
surface changes. A focused test pass without a stored baseline receipt does not
satisfy the Phase 2 bar.

The receipt also requires these rows, which are not optional:

| Public API/require | base and runner entrypoints in isolated subprocesses | same verifier constants and ancestry; runner constants appear only after runner require; no heavy package loads in the base process |
| Runner CLI process | explicit manifest success plus omitted/malformed manifest | exact stdout/stderr and bounded exit classification; no benchmark side effect without a valid manifest |
Manifest failure cases are fixed before implementation:

| Input | Exit | Stdout | Stderr | Side effect |
|---|---:|---|---|---|
| missing manifest | 3 | empty | runner input manifest is required plus one LF | none |
| malformed JSON | 64 | empty | runner input manifest is invalid plus one LF | none |
| incomplete fields | 64 | empty | runner input manifest is incomplete plus one LF | none |
| repository-relative path | 64 | empty | runner input paths must be explicit and external plus one LF | none |
| missing OpenClaw factory loader/callable | 3 | empty | openclaw benchmark requires an external fixture factory plus one LF | none |
