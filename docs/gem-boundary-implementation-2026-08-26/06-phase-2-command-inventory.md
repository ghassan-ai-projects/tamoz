# Phase 2 command inventory

Operational commands move to `tamoz-eval-runner`. Historical reports retain
their original command text as historical evidence.

## Active surfaces to migrate

| Path | Current surface | Phase 2 action |
|---|---|---|
| `README.md` | `tamoz-eval scorecard agent-smoke` | document `tamoz-eval-runner` and base verifier separately |
| `documentation/guides/evaluation.md` | scorecard/treatment examples | use runner executable |
| `script/release_rehearsal` | packaged scorecard invocation | install and invoke runner executable |
| `script/generate_release_evaluation_manifest` | scorecard subprocess | invoke runner executable |
| `test/packaging_test.rb` | installed eval executable proof | split base verify and runner scorecard proofs |
| `test/agent_scorecard_test.rb` and treatment tests | direct CLI calls | require runner and call `Tamoz::Evals::Runner::CLI` |
| `test/scheduler_consumer_test.rb` | scheduler consumer namespace | test runner-owned consumer and default argv |
| `test/public_api_test.rb`, `docs/public-api.json` | CLI/consumer inventory | remove old owner and add runner surfaces |

## Historical surfaces

`docs/reviews/**`, `docs/GAUNTLET_PROGRESS.md`, dated manual reports, and old
design plans retain historical command examples. Active operational sections
must receive the current command; archived evidence must not be rewritten to
pretend it used the new command.

## Negative proof

The runner phase adds a test that
`Tamoz::Evals::CLI.run(["scorecard", ...])` and
`Tamoz::Evals::CLI.run(["treatment", ...])` return usage error 64 without
loading `Tamoz::Evals::Runner`, while `Tamoz::Evals::Runner::CLI` handles those
commands only after `require "tamoz/evals/runner"`.

## Complete active inventory

The following active surfaces must be classified and migrated before the
implementation bar can pass:

- script/benchmark_run, script/benchmark_release, script/benchmark_holdout
- script/benchmark_comms_run, script/benchmark_openclaw_run
- script/benchmark_openclaw_cells, script/benchmark_openclaw_readiness
- script/benchmark_openclaw_regression, script/benchmark_openclaw_scoreboard
- script/run_m1_conformance, script/run_m2_conformance
- script/generate_m0_fixtures, script/generate_m1_fixtures,
  script/generate_m2_fixtures
- script/generate_agent_smoke_fixtures,
  script/generate_agent_memory_fixtures,
  script/generate_agent_memory_repository_fixtures
- script/generate_benchmark_protocol, script/autonomy_scorecard,
  script/release_rehearsal, script/generate_release_evaluation_manifest
- bin/tamoz-eval and every active README, guide, packaging, public API,
  scheduler, benchmark, OpenClaw, and release test that invokes these paths.

Benchmark and conformance commands use the runner with an explicit external
input manifest. Fixture generators remain repository-owned input providers;
their outputs are never packaged in the runner. Historical reports retain
their original command text but are labeled historical.
Additional active surfaces found by the follow-up repository search:

- script/generate_calibration_artifact: repository-owned artifact generator;
  keep external and classify its output as explicit runner input if consumed.
- script/generate_dependency_review: repository-owned dependency/release
  generator; update it for the new gem and include regenerated output in the
  phase evidence.
- script/generate_requirements_manifest: repository-owned requirements
  generator; update it for the new gem and include regenerated output.
- script/generate_legacy_session_fixture: repository-owned fixture generator;
  keep it outside both gems and pass generated paths explicitly.
- script/tamoz_sqlite_oracle: repository-owned oracle/probe; keep it external
  and classify any runner invocation explicitly.
- script/mcp_test_server: repository-owned deterministic MCP input provider;
  it is never copied into tamoz-evals-runner.
## Per-command input and load-path contract

| Surface | Owner after split | Input contract | Load-path contract |
|---|---|---|---|
| script/benchmark_openclaw_run | runner + caller-owned scenario adapter | runner-input-v1 manifest; scenario definition loader is manifest-selected | installed runner closure plus declared external root |
| script/benchmark_comms_run | repository benchmark wrapper + runner oracles | runner-input-v1 manifest plus external fixture and comms-runner loader | installed runner closure plus declared external root; fixture scenario driver stays outside the gem |
| script/benchmark_run | runner | runner-input-v1 manifest; no implicit MCP server | installed runner closure plus declared external root |
| script/benchmark_holdout | runner | digest-pinned external holdout manifest | installed runner closure plus declared external root |
| script/benchmark_openclaw_readiness | runner | runner-input-v1 manifest; preserves run-kind labels | installed runner closure plus declared external root |
| script/benchmark_openclaw_regression | runner | runner-input-v1 manifest and external protocol/catalog | installed runner closure plus declared external root |
| script/generate_dependency_review | repository generator | none; records the new gem closure | explicit repository paths only |
| script/generate_requirements_manifest | repository generator | none; records the new gem surfaces | explicit repository paths only |
| script/tamoz_sqlite_oracle | repository oracle | external scenario/graph inputs | explicit repository paths; never packaged |
| script/mcp_test_server | external deterministic input provider | caller passes executable path into manifest | outside both gem roots |

Every command in this table is exercised once in the baseline inventory and
once after the move, or is explicitly classified as a generator/provider
whose output is consumed through the manifest.
## Required row-by-row classification

| Surface | Owner | Input or manifest | Migration and load-path rule |
|---|---|---|---|
| script/benchmark_openclaw_cells | runner | runner-input-v1 plus external protocol/catalog | runner executable/library; installed closure only |
| script/benchmark_openclaw_scoreboard | runner | runner-input-v1 plus external scorecard inputs | runner executable; installed closure only |
| script/run_m1_conformance | runner/orchestrator | explicit external fixture manifest | runner command with external provider paths |
| script/run_m2_conformance | runner/orchestrator | explicit external fixture manifest | runner command with external provider paths |
| script/generate_m0_fixtures | repository input provider | generated external files | remains outside both gems |
| script/generate_m1_fixtures | repository input provider | generated external files | remains outside both gems |
| script/generate_m2_fixtures | repository input provider | generated external files | remains outside both gems |
| script/generate_agent_smoke_fixtures | repository input provider | generated external files | remains outside both gems; manifest path is explicit |
| script/generate_agent_memory_fixtures | repository input provider | generated external files | remains outside both gems; manifest path is explicit |
| script/generate_agent_memory_repository_fixtures | repository input provider | generated external files | remains outside both gems; manifest path is explicit |
| script/release_rehearsal | repository release orchestrator | runner-input-v1 | installs and invokes the runner executable |
| script/generate_release_evaluation_manifest | repository release generator | runner-input-v1 | invokes runner executable; no ambient bundle |
| bin/tamoz-eval | base verifier wrapper | verifier artifact paths only | base closure only; no all-gems glob |
| test/packaging_test.rb | package proof | external inputs supplied by test | split base verifier and runner package subprocesses |
| test/scheduler_consumer_test.rb | runner package proof | explicit fake command only | tests runner-owned consumer and new argv |
| active benchmark, OpenClaw, release, and public API tests | owning package | explicit external fixture paths/factories | no fixture copied into package |
| script/benchmark_release | runner | runner-input-v1 manifest and external release inputs | runner executable; installed closure only |
| script/generate_benchmark_protocol | repository protocol generator | none; emits external digest-pinned protocol | repository path only; output is an explicit runner input |
| script/autonomy_scorecard | repository orchestrator | explicit runner-input-v1 manifest if it invokes evals | classify as runner wrapper or external orchestrator; no ambient bundle |
| script/generate_calibration_artifact | repository artifact generator | none; generated artifact remains external | repository path only; no fixture packaging |
| script/generate_legacy_session_fixture | repository fixture generator | generated external fixture | remains outside both gems; manifest path is explicit |
