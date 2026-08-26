# Phase 2 plan: `tamoz-evals-runner`

## Decision to review

Use a two-package executable split:

- `tamoz-evals` keeps `Tamoz::Evals.verify`, the artifact/schema/digest/error
  library, `Tamoz::Evals::DATA_ROOT`, and a verifier-only `tamoz-eval`
  executable. `Tamoz::Evals::CLI` remains the verifier CLI and returns usage
  error 64 for `scorecard` or `treatment` rather than dispatching them.
- `tamoz-evals-runner` depends on `tamoz-evals`, owns the existing
  `Tamoz::Evals::Harness` and `Tamoz::Evals::Benchmark` namespaces, exposes
  `Tamoz::Evals::Runner::CLI` from `require "tamoz/evals/runner"`, and adds
  `tamoz-eval-runner` for `scorecard` and `treatment` commands.
- The scheduler's eval-specific `ScorecardSummaryConsumer` and its result
  value move to `Tamoz::Evals::Runner::ScorecardSummaryConsumer` and its
  private `ScorecardResult`. `tamoz-scheduler` remains a generic scheduling
  contract and no longer loads evals or spawns an eval subprocess. The only
  current caller is the eval harness/test surface; no production scheduler
  caller was found, so this is a deliberate public-surface relocation.

This keeps verifier installation light and avoids two installed gems shipping
the same executable name. It is an intentional command-surface change under
the repository's no-compatibility-shim convention.

## Source ownership

1. Freeze the base verifier surface and record current outputs, decisions, exit
   codes, artifact digests, and public constants before moving files.
2. Leave the base artifact data (`schemas/`, `suites/`, and `baselines/`) in
   `tamoz-evals`; the verifier must continue to read and validate those bytes.
   Add `Tamoz::Evals::DATA_ROOT` in the base entrypoint and resolve the
   runner's `AgentSmokeCorpus`, `AgentMemoryCorpus`, and
   `AgentMemoryRepositoryCorpus` roots through it. Move runtime code, not
   verifier input artifacts. Do not add fixture files, fixture data,
   deterministic MCP servers, scripted-provider fixtures, or OpenClaw fixture
   classes to either new gem. Keep existing fixture assets under their current
   repository test/support or script owners and inject them into tests and
   benchmark adapters through explicit factories/paths. Do not keep
   CASE_DEFINITIONS or any other embedded case data in runner code. Add a
   digest/identity parity test against the base JSON artifacts and load
   canonical case metadata from the base artifacts or the external input API.
3. Move `lib/tamoz/evals/harness/` and
   `lib/tamoz/evals/benchmark/` into `gems/tamoz-evals-runner` without changing
   their namespaces or behavior, except that fixture-only files such as
   `openclaw_comms_fixture.rb`, `openclaw_comms_runner.rb`, and the
   fixture-backed `ScenarioDriver` remain outside both new gem packages and
   are supplied through explicit external adapters. Move the runner CLI
   implementation into the child and make `tamoz/evals.rb` eager-load only
   base verifier files. The packaged `OpenclawMissionRunner` accepts only
   generic caller-owned adapters; no `require_relative` edge may point at a
   fixture. Any fixture coupling exposed by the move is a blocker to resolve
   by injection, not a reason to package the fixture.
4. Replace the base `Tamoz::Evals::CLI` with the verifier-only command surface
   needed by `tamoz-eval verify`; define `Tamoz::Evals::Runner::CLI` separately
   so loading the base gem cannot load runner classes. Preserve the numeric
   verifier decision mapping and error output bytes. Add a negative test for
   the removed base `scorecard`/`treatment` dispatch.
5. Move `tamoz-scheduler`'s `ScorecardSummaryConsumer` and private result
   implementation into `Tamoz::Evals::Runner`. Update the agent-smoke
   scheduler proof, scheduler tests, public API data, and default command to
   call `tamoz-eval-runner scorecard agent-smoke`. Update the runner-owned
   default and assert the command argv in an installed subprocess test.

## Dependency and load-path work

1. Add the child gem, version, README, LICENSE, gemspec, root Gemfile entry,
   lockfile entry, and explicit `require "tamoz/evals/runner"` entrypoint.
2. Set the base gem's runtime dependency closure to the verifier's real needs
   (currently `tamoz-core` for the shared error root) and remove runner-only
   dependencies from `tamoz-evals`.
3. Derive and declare the runner's direct closure from the moved source. The
   initial candidates are `tamoz-evals`, `tamoz-core`, `tamoz-agent`,
   `tamoz-agent-kernel`, `tamoz-agent-cli`, `tamoz-agent-capabilities`, `tamoz-agent-session`,
   `tamoz-agent-improvement`, `tamoz-sqlite`, `tamoz-mcp`,
   `tamoz-graph`, `tamoz-tools`,
   and `tamoz-comms`; confirm each against actual requires
   and remove any dependency not proven direct.

   `tamoz-telegram` is explicitly external fixture/operator closure only. Add
   a negative package and lockfile assertion that the runner gemspec and its
   direct dependency list do not contain tamoz-telegram.
4. Update root test/load helpers and every runner script to use explicit child
   load paths. The runner receives existing deterministic MCP and OpenClaw
   fixtures from outside the install root through explicit test/operator
   injection. `tamoz-eval-runner` accepts an explicit input-manifest path for
   fixture-backed commands and returns a bounded usage/infrastructure failure
   when it is absent; gem code has no repository fallback. No
   `Dir["../gems/*/lib"]` or ambient bundle is valid evidence.

## Verification and correction loop

1. Add a base-only hermetic test that installs just the base verifier closure,
   proves runner constants and heavy packages are absent, verifies a golden
   artifact, and checks the verifier's JSON/exit-code contract.
2. Add a runner-only hermetic test that installs the child closure, supplies
   existing inputs from outside the install root through `Runner::InputManifest`,
   runs `scorecard`, `treatment`, and representative benchmark subprocesses,
   and checks the runner's direct dependency closure. A second invocation omits
   the manifest and proves the command fails closed. The built runner gem's
   file list and source scan must prove that no fixture source or fixture data
   entered the package.
3. Keep existing verifier and runner tests paired with the package that owns
   their implementation. Add explicit before/after byte and decision fixtures
   for all verifier artifact types and the release-gate exit precedence.
4. Run targeted lint and tests, regenerate package/API/requirements/dependency
   artifacts, refresh Enola, then send the implementation through the five
   final review lanes from `03-phase-2-quality-bar.md`.
5. Apply reviewer corrections, rerun the complete phase bar, commit the phase,
   and only then consider the next audit candidate.

## Known risks to challenge in plan review

- The public `Tamoz::Evals::CLI` and `Tamoz::Scheduler::ScorecardSummaryConsumer`
  surfaces need a deliberate migration, not a file move.
- The base gem's `Tamoz::Error` ancestry makes `tamoz-core` a likely real base
  dependency; do not claim a fully stdlib-only verifier without checking it.
- Some runner files require agent constants only inside subprocesses while
  others use them at load time. The installed tests must prove both paths.
- Historical review documents contain old `tamoz-eval scorecard` examples;
  update active docs and label historical evidence rather than rewriting
  archived reports without a reason.

## Input manifest contract

This section supersedes any earlier wording that left fixture data or fixture
providers inside moved runner classes.

Tamoz::Evals::Runner::InputManifest is the named boundary for every
fixture-backed or scripted input. It accepts only explicit values:

- corpus_definitions: canonical case metadata or a path to an existing
  externally-owned case-definition document;
- scripted_model: a response map/factory or path to an externally-owned
  scripted-provider document;
- mcp_server: an executable path plus its argument vector, supplied by the
  caller;
- openclaw_fixture_factory: a callable supplied by the caller, never a class
  loaded from the runner package;
- scenario_definitions: scenario tables, graphs, and limits supplied by the
  caller;
- external_root: a required external root used to validate that supplied
  paths are outside the installed runner package.

Library constructors accept this object directly. The runner executable
accepts a manifest path for serializable fields; the caller-side adapter
registers the OpenClaw factory. A missing, malformed, repository-relative, or
incomplete manifest returns a bounded usage/infrastructure error and performs
no benchmark run. There is no default fixture, repository-root discovery,
ambient load path, or implicit MCP server. Existing test/support and script
assets remain the providers of the inputs and are loaded from outside both
gem packages.

The following sources remain repository-owned external inputs and must not be
copied into either package: openclaw_comms_fixture, script/mcp_test_server,
scripted provider responses, scenario tables, memory seeds, fixture graphs,
and fixture limits. OpenclawCommsRunner, OpenclawMissionRunner,
ScenarioDriver, AgentSmokeCorpus, AgentMemoryCorpus,
AgentMemoryRepositoryCorpus, SqliteScenarioDriver, and
SqliteConvergenceProbe must receive those values through the manifest or
constructor. No require-relative edge may point at a fixture.

The active command inventory is complete only after classifying benchmark
runners, conformance commands, fixture generators, release scripts, the root
wrapper, and every caller found by repository-wide search for tamoz-eval,
Tamoz::Evals::CLI, ScorecardSummaryConsumer, benchmark script names, and
fixture generator names.
The executable-side factory protocol is explicit: a serialized manifest may
contain an absolute factory-loader path outside the installed runner root.
The loader must define the caller-owned
Tamoz::Evals::Runner::InputAdapters.openclaw_fixture_factory callable. The
runner validates the real path, loads only that explicit file, and rejects a
missing loader or missing callable with exit 3, empty stdout, the exact
infrastructure message, and no benchmark side effect. Missing, malformed,
incomplete, or repository-relative manifest fields use exit 64, empty stdout,
the exact usage message, and no benchmark side effect. Library callers may
provide the callable directly in InputManifest; no gem source may define or
load the fixture class.

The exact failure cases and messages are recorded in
09-phase-2-baseline-schema.json and must be tested byte-for-byte, including
the single trailing newline emitted on stderr.
## Input manifest and installation mapping

The versioned manifest schema is
docs/gem-boundary-implementation-2026-08-26/10-phase-2-input-manifest-schema.json.
Its class-field map is normative. Each corpus, scenario, protocol, catalog,
scripted response, MCP executable, and OpenClaw factory loader is an explicit
hashed external input. The implementation must validate the schema before
constructing any runner object.

The OpenClaw executable path is operationally supported by a caller-owned
adapter file, loaded only from the manifest's absolute external path. The
adapter registers InputAdapters.openclaw_fixture_factory. For
`benchmark_comms_run`, it also registers the caller-owned comms scenario
runner; that fixture-backed class is never shipped in the runner gem. A JSON manifest
never serializes a Ruby callable; it serializes the loader path and hashes.

For hermetic subprocesses, the installed-closure parameter is the only source
of load paths. The runner constructs paths from installed gem specifications
or an explicit installed closure; it does not use REPO_ROOT, repository gem
globs, ambient BUNDLE_GEMFILE, RUBYLIB, RUBYOPT, or loaded $LOAD_PATH paths.
The subprocess receipt records every loaded library path and asserts that code
paths belong to the installed base/runner closure while input paths belong to
the declared external root.

The scheduler relocation is part of the import contract: the moved harness
references Tamoz::Evals::Runner::ScorecardSummaryConsumer, the runner owns
ScorecardResult, and tamoz-scheduler contains no Open3, eval consumer, or
ScorecardResult source after the move. Generic scheduler contracts remain
available without loading the runner.
