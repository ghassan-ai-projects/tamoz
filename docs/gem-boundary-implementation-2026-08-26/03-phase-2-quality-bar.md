# Phase 2 implementation bar: `tamoz-evals-runner`

This bar is frozen before implementation. The phase is complete only when all
items below are evidenced; a focused test pass is not sufficient by itself.

## Boundary and public surfaces

- [ ] `tamoz-evals` owns only artifact bytes, schemas, canonical JSON, case and
      evidence values, digest rules, verifier decisions, and the verifier
      entrypoint `Tamoz::Evals.verify`.
- [ ] `tamoz-evals-runner` owns the `Harness/` and `Benchmark/` runtime code,
      scorecard/treatment commands, subprocesses, and OpenClaw benchmark
      adapters, but no fixture source or fixture data.
      Existing `Tamoz::Evals::Harness` and `Tamoz::Evals::Benchmark` namespaces
      remain unchanged inside the runner package.
- [ ] The executable split is explicit: `tamoz-eval verify ARTIFACT...` stays
      in the base gem; `tamoz-eval-runner scorecard agent-smoke` and
      `tamoz-eval-runner treatment memory` belong to the runner. There is no
      compatibility alias for the old scorecard/treatment command path; the
      base command returns its documented usage error for those commands.
- [ ] The base Ruby entrypoint is `require "tamoz/evals"` with
      `Tamoz::Evals::CLI` limited to verifier commands. The runner entrypoint
      is `require "tamoz/evals/runner"` with
      `Tamoz::Evals::Runner::CLI` owning scorecard/treatment commands. The
      shared `Tamoz::Evals::ExecutionError` taxonomy remains defined by the
      base error file so runner failures retain their existing ancestry.
- [ ] The eval-specific scheduler consumer moves out of `tamoz-scheduler` to
      `Tamoz::Evals::Runner::ScorecardSummaryConsumer` (with its private
      `ScorecardResult`), loaded by the runner entrypoint. `tamoz-scheduler`
      remains loadable without the runner or evals gem and no longer requires
      `open3`, eval code, or the scheduler consumer.

## Dependency and installation truth

- [ ] The base gemspec has no runtime dependency on SQLite, MCP, agent,
      comms, Telegram, model SDKs, graph, scheduler, or runner-only packages.
      Its installed parent-only closure loads and verifies an artifact without
      loading any of those packages.
- [ ] The runner gem declares every direct Tamoz and external runtime import,
      including the direct CLI, comms/Telegram adapters, scheduler-consumer,
      tools, websearch, and provider-facing paths identified by the source
      closure. No declaration relies on the root bundle.
- [ ] Neither new gem contains a test fixture, deterministic MCP server,
      scripted-provider fixture, OpenClaw fixture source, fixture data, or
      fixture-only dependency. Fixtures are existing repository test assets
      supplied through explicit injection or paths outside the gem package.
- [ ] The runner has a concrete external-input API: corpus definitions,
      scripted-model responses, MCP server paths, OpenClaw fixture factories,
      and scenario tables enter through constructor inputs or an explicit CLI
      input manifest. Missing inputs fail closed; no repository-relative or
      built-in fixture fallback exists.
- [ ] The machine-readable direct-import manifest records each moved source
      file, its `require`/constant owner, dependency classification, and the
      final gemspec entry. `ruby_llm` is either proven transitive through the
      agent runtime or explicitly declared if the moved source loads it
      directly.
- [ ] Hermetic subprocesses for both packages clear `RUBYLIB`, `RUBYOPT`,
      `BUNDLE_GEMFILE`, and ambient repository gem paths, then load only their
      installed package closure.

## Behavioral and evidence invariants

- [ ] Artifact bytes, schemas, canonical digests, reference traversal,
      verifier decisions, JSON output, error mapping, and verifier exit codes
      are byte/decision identical before and after the split.
- [ ] Runner scorecard, treatment, benchmark, OpenClaw adapter, and scheduler
      consumer behavior is preserved by focused tests and installed-package
      subprocess tests with explicit external fixture injection.
- [ ] Fixture, deterministic, and real-provider evidence labels remain
      truthful; no fixture or deterministic provider is reported as real model
      evidence.
- [ ] `Tamoz::Evals::DATA_ROOT` is the explicit base-package resource seam for
      runner corpus discovery. Existing verifier input artifacts remain
      base-owned; no new fixture data is introduced; and a parity test proves
      the existing `CASE_DEFINITIONS`/JSON identities do not drift.
- [ ] Canonical verifier artifacts already owned by `tamoz-evals` remain
      package data; they are not duplicated as runner fixture tables. Runner
      source contains no embedded memory seeds, scenario fixture graphs,
      fixture bytes, deterministic server implementation, or fixture-backed
      scenario driver. External benchmark adapters supply those inputs.
- [ ] Existing subprocess isolation, explicit load paths, credential
      precedence, model/provider error reporting, and scheduler read-only grant
      semantics remain intact.

## Surface, quality, and review gates

- [ ] Gem packages, lockfile, root load paths, executable wrappers, public API
      inventory, architecture/inventory docs, requirements inputs, and
      dependency review all agree on the new gem count and command ownership.
- [ ] Base verifier tests, runner tests, packaging/isolation tests, and
      relevant CLI/script tests pass. Targeted RuboCop passes; Reek is reported
      honestly against the repository's current unbaselined state; Enola
      reports no unintended structural regression; generated artifacts are
      regenerated and checked.
- [ ] Five independent read-only review lanes report PASS or their findings
      are fixed: verifier/API, dependency/package isolation, CLI/subprocess,
      evidence/durability, and documentation/release surfaces.
- [ ] No P0/P1 regression remains. Any pre-existing baseline debt is named in
      the correction record and is not silently folded into this extraction.

## Stop rules

Stop and record a blocker if preserving the verifier or runner contract needs a
new public namespace/command decision, a compatibility shim, a schema/digest
change, an unowned direct dependency, or a weakening of subprocess isolation.

## Corrections required before implementation

- [ ] The machine-readable direct-import manifest at
      docs/gem-boundary-implementation-2026-08-26/09-phase-2-direct-import-manifest.json
      records every planned moved source file, its require list, constant
      owner, dependency classification, and final gemspec owner before the
      writer starts. The post-move manifest is regenerated from source and
      must not lose an entry.
- [ ] The baseline receipt at
      docs/gem-boundary-implementation-2026-08-26/09-phase-2-baseline.json
      records source revision, gemspec/lockfile digests, artifact byte
      digests, verifier decisions and exception classes, CLI stdout/stderr
      bytes and exit codes, public require/constant inventory, runner report
      identities, and scheduler-consumer results. The after receipt uses the
      same schema and labels intentional command/namespace changes; a
      hand-written or partial receipt does not satisfy this gate.
- [ ] The external input API is concrete and named:
      Tamoz::Evals::Runner::InputManifest carries corpus definitions,
      scripted-model responses, MCP server paths, OpenClaw fixture factories,
      and scenario tables. Missing, malformed, incomplete, or
      repository-relative input fails closed.
- [ ] Neither package contains embedded CASE_DEFINITIONS, memory seed hashes,
      scenario fixture tables, fixture bytes, scripted model responses, a
      deterministic MCP server, or an OpenClaw fixture class. The canonical
      verifier schemas, suites, and baselines already owned by tamoz-evals are
      package artifacts, not newly introduced fixtures.

The baseline receipt must validate against
docs/gem-boundary-implementation-2026-08-26/09-phase-2-baseline-schema.json.
The schema defines normalized command argv, base64 stdout and stderr bytes,
numeric exit, decision and exception fields, artifact digests, public
require/constant inventories, base-versus-runner load graphs, and an
intentional-change list. The receipt is captured before the first move and
validated again after the final correction.

## Handoff state — 2026-08-26

The Phase 2 implementation is ready to commit. Focused verifier, runner,
manifest, scheduler-consumer, benchmark, packaging, public-API, documentation,
protocol, and dependency checks pass. Both receipts validate against the frozen
schema, and the package scan finds no fixture source or data in either gem.
The completed five-lens review cycle's actionable findings were corrected. A
replacement review cycle was stopped at the owner's request before reports
were returned.

The full `rake ci` run remains environment-bound: socket-binding tests fail in
the sandbox, and the repository's measured release audit still reports its
existing disclosure/evidence gaps. Those are recorded as baseline limitations;
they are not presented as a clean full-suite result for this extraction.
