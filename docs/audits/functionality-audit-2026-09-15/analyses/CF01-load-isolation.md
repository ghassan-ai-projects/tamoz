# CF01 load and dependency isolation — PASS

Row / queue / baseline (commit, date) / analyst / budget

- Row: **CF01** — load and dependency isolation.
- Queue: cross-gem flow inventory in `COVERAGE.md`.
- Baseline: branch `audit-15-09`, code commit `582ae55`, 2026-09-15.
- Analyst: coordinator direct read-only review after the standalone scanner pass.
- Budget: bounded review; no implementation or generated-artifact refresh.

## Scope and source map

| Source | Lines | Boundary role |
|---|---:|---|
| `gems/gemspec_helper.rb` | 61 | common package file/dependency construction |
| `gems/tamoz-core/lib/tamoz/core.rb` | 300+ | lowest runtime load boundary and Zeitwerk setup |
| `gems/tamoz-graph/lib/tamoz/graph.rb` | 29 | graph load boundary and eager loader |
| `gems/tamoz-agent/lib/tamoz/agent.rb` | 150+ | full runtime composition boundary |
| `gems/tamoz-evals/lib/tamoz/evals.rb` | 37 | verifier-only evaluation boundary |
| `test/dependency_isolation_test.rb` | 398 | subprocess load-graph and gemspec assertions |
| `test/dependency_review_test.rb` | 122 | declared dependency, licence, and provenance gate |
| `test/packaging_test.rb` | 1,100+ | package shape and isolated install paths |
| `test/public_api_test.rb` | 500+ | public entry inventory and reference manifest contract |

The entry seam is each gem's `lib/tamoz*.rb` umbrella. `TamozGemspec.build`
sets the release file list, `lib` require path, metadata, and declared runtime
dependencies (`gems/gemspec_helper.rb:9-58`). Core and graph use Zeitwerk with
an eager load rooted in their own library trees (`gems/tamoz-core/lib/tamoz/core.rb:54-62`,
`gems/tamoz-graph/lib/tamoz/graph.rb:14-21`). Higher layers compose by explicit
`require` edges, for example the agent runtime (`gems/tamoz-agent/lib/tamoz/agent.rb:3-26`).

## Behavior path

1. A gemspec calls `TamozGemspec.build` with a fixed package name, version, and
   dependency list. The helper resolves the package root from its own helper
   directory, includes only declared release patterns, and sets `require_paths`
   to `lib` (`gems/gemspec_helper.rb:9-41`).
2. Loading a lowest-level umbrella such as `tamoz/core` requires JSON, Zeitwerk,
   and its version, then sets up and eagerly loads only the core tree
   (`gems/tamoz-core/lib/tamoz/core.rb:3-5,54-62`).
3. A graph load adds only core, cancellation, concurrency, and the graph tree
   (`gems/tamoz-graph/lib/tamoz/graph.rb:3-7,14-21`). The graph path does not
   load the agent, SQLite, evaluation, model, HTTP, or socket layers.
4. Composition layers add their declared lower seams explicitly. The agent
   umbrella loads the runtime stack and deliberately does not require stream,
   SQLite, or evaluation at the top-level load boundary (`gems/tamoz-agent/lib/tamoz/agent.rb:3-26`; verified by
   `test/dependency_isolation_test.rb:121-139`).
5. The verifier remains independently installable: `tamoz/evals` requires core
   and its own verifier files, while the runner is a separate package
   (`gems/tamoz-evals/lib/tamoz/evals.rb:3-16`; `test/dependency_isolation_test.rb:141-152`).
6. A clean subprocess records `$LOADED_FEATURES`; the isolation suite checks the
   expected lower closure and refuses forbidden upward/sideways edges
   (`test/dependency_isolation_test.rb:352-378`).

## Lens: correctness

Reviewed. The common gemspec helper consistently sets the package root from the
fixed gem name and includes `lib/**/*.rb` plus each gem's explicitly supplied
runtime contracts (`gems/gemspec_helper.rb:9-41`). The load tests assert both
required entry files and the absence of forbidden features for core, graph,
tools, kernel, capabilities, cancellation, concurrency, agent, evals, MCP,
websearch, Comms, gateway, observability, and Telegram
(`test/dependency_isolation_test.rb:8-341`). The focused run passed **22 runs,
221 assertions, 0 failures, 0 errors, 0 skips**.

No current correctness defect was established. The scanner's broad signal count
is a routing input; the subprocess assertions trace actual load behavior.

## Lens: security and authority

Reviewed. Gem load boundaries do not grant capabilities. The core and graph
tests reject model, SQLite, agent, evaluation, HTTP, socket, and OpenSSL loads
where those packages are outside the seam (`test/dependency_isolation_test.rb:24-40,43-50`).
The Comms and Telegram tests keep the HTTP-carrying transport separate from the
agent and durable store (`test/dependency_isolation_test.rb:221-241,319-341`).
The dependency review rejects undeclared or non-permissive runtime licences and
checks that no production code installs or loads code dynamically
(`test/dependency_review_test.rb:32-54,103-120`).

No authority bypass was found at the package-load boundary. Runtime capability
decisions occur later in profile, capability, and approval seams; CF01 does not
re-grade those flows. An external package consumer or malicious gem server was
not modeled; proving that would require a clean registry install and signed
provenance verification outside this source audit.

## Lens: reliability and durability

Reviewed. `TamozGemspec.build` packages the runtime contract files named by each
gem and excludes development vectors by pattern (`gems/gemspec_helper.rb:24-34`).
The packaging gate builds every gem and verifies strict release shape and the
Ruby/Rubygems requirements (`test/packaging_test.rb:7-29`). The dependency review
regenerates from gemspecs and the lockfile, so a stale declaration is intended
to fail the gate (`test/dependency_review_test.rb:14-30,56-81`).

The full package-build/install suite was **not run** in this bounded review; its
coverage is present in the source but its current runtime result is not claimed.
No partial-load recovery or package-cache repair contract is declared. That is
an evidence gap for release operations, not a source-proven reliability defect.

## Lens: observability and evidence

Reviewed. The load-graph tests emit the exact feature set from a clean child
process and assert status before parsing JSON (`test/dependency_isolation_test.rb:352-378`).
The dependency-review gate compares generated output with the committed report
and checks every on-disk gemspec (`test/dependency_review_test.rb:14-30,73-81`).
This gives a reproducible evidence trail for the package boundary.

The evidence is limited to feature loading and gemspec metadata; it does not
prove a downstream application uses the same entry point after installation.
An install-and-execute result for every gem would prove that remaining claim;
the broad packaging test was not run here.

## Lens: scalability and resource bounds

`not evidenced` for production-scale package installation or cold-boot latency.
The source load path is finite and deterministic: core/graph eager-load their
own trees (`gems/tamoz-core/lib/tamoz/core.rb:54-62`,
`gems/tamoz-graph/lib/tamoz/graph.rb:14-21`), and the package file list is a
finite glob (`gems/gemspec_helper.rb:24-40`). A measured installation/boot
matrix across all 27 gems and multiple concurrent processes would prove actual
resource bounds; no such measurement is part of this read-only pass.

## Lens: maintenance and architecture

Reviewed. Dependency direction is explicit in the umbrella requires and the
gemspec lists. The isolation suite also checks that production gemspecs do not
depend on evaluation packages and that only the intended agent dependents may
depend on `tamoz-agent` (`test/dependency_isolation_test.rb:294-317`). Public
entry points are pinned in `docs/public-api.json` and exercised by
`test/public_api_test.rb`; the helper's metadata includes the MFA requirement
(`gems/gemspec_helper.rb:48-54`).

The main residual is test maintenance: the isolation assertions are hand-listed
per boundary, so a new gem requires a new test method. That is an explicit,
reviewable contract rather than a finding for this flow. No duplicate loader or
new abstraction was identified.

## Tests and contracts

- `ruby -Itest test/dependency_isolation_test.rb` → **22 runs / 221 assertions / 0 failures / 0 errors / 0 skips**.
- `test/dependency_review_test.rb` → not run in this bounded pass; source gate reviewed.
- `test/packaging_test.rb` → not run in this bounded pass; source gate reviewed.
- Public API load assertions → source reviewed; no separate run claimed.
- A clean external registry install and boot matrix → not found in this pass.

## Findings

No CF01 critical, major, minor, or info finding is proposed. Existing package
and public-API findings are outside this flow's ownership and remain indexed in
`FINDINGS.md` under their owning rows. In particular, A01's inert reference
manifest is not a package-load defect, and the F21/F25 authority findings are
runtime replay seams rather than dependency isolation.

## Blind spots

- Full package-build/install execution was not run; the source gate and focused
  subprocess load graph were reviewed.
- No registry/network provenance or signature verification was exercised.
- No external application was tested against the installed gem entry points.
- The cross-flow interaction after load (runtime wiring, store migrations, and
  provider calls) belongs to CF02–CF13 and remains outside this row.

## Verdict

**PASS** under `BAR.md`: the source trace and six lenses are complete for the
load/dependency boundary, the focused isolation contract passed, and no accepted
critical/major finding or three-minor threshold applies. This PASS does not close
the other cross-flow rows or the audit package as a whole.
