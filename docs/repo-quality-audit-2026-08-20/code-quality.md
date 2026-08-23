# Tamoz repository quality audit — code quality

Date: 2026-08-20  
Scope: correctness signals, maintainability, Ruby quality, error handling,
testing, observability, reliability/security quality signals, and the declared
RuboCop/Reek/SimpleCov/Enola program.  This report does not audit duplication,
dead code, missing abstractions, package placement, or design-pattern usage as
primary topics; those are separate passes.

## Executive verdict

Tamoz has unusually explicit quality intent: gem boundaries are executable,
canonical wire formats have focused tests, the Enola CLI gate passes, syntax and
proto drift checks pass, and the public API/documentation/packaging/secret tests
are healthy in isolation. The repository is not currently operating those
quality controls as a single trustworthy gate, however.

The highest-priority problems are:

- GitHub CI runs `rake ci`, but `ci` and `ci_full` do not invoke the declared
  RuboCop, Reek, coverage, or baseline-drift gates. The current configured
  RuboCop run reports 10,011 offenses and the current Reek run reports 4,950
  smells, yet CI can pass those dimensions if behavior tests pass.
- The baseline is stale (`41579c7` versus current HEAD `1a61066`) and the
  baseline generator ignores RuboCop's exit status. In this audit, a cache
  permission failure produced a JSON report with zero files inspected; the
  drift checker consequently reported `rubocop ... actual 0`.
- The 2026-08-20 evals change made `tamoz-evals` require and depend on the
  runtime graph, while README, coding standard, and executable dependency tests
  require evals to remain outside that graph. `DependencyIsolationTest` fails
  two assertions for this reason.
- Coverage is below the Q5 target: 89.45% line and 69.22% branch in the
  committed baseline versus 90%/80%; subprocess and killed-child coverage
  collation is explicitly still deferred.

These are confirmed findings, not recommendations inferred from a few large
files. The large-file and complexity register below is mostly existing,
baselined debt and should be handled in the quality program's characterization-
then-extraction slices.

## Confirmed findings

### CQ-01 — Declared quality gates are not in CI or the aggregate gate

Severity: High  
Confidence: 1.0  
Status: Confirmed

Evidence:

- `Rakefile:258-337` defines `quality:rubocop`, `quality:rubocop_gate`,
  `quality:reek`, `quality:coverage`, `quality:architecture`, and
  `quality:baseline_drift`.
- `Rakefile:383-388` defines `quality` as only
  `['quality:architecture']` and defines `ci` as only design validation,
  syntax, `test_fast`, proto drift, and `quality:architecture`.
- `Rakefile:399-401` defines `ci_full` without RuboCop, Reek, coverage, or
  baseline drift.
- `.github/workflows/ci.yml:31` runs only `bundle exec rake ci`.
- The quality charter says these tasks should block in `rake ci`
  (`docs/QUALITY_PROGRAM.md:106-114`), and the state document claims the three
  fast ratchets are already included (`docs/QUALITY_PROGRAM_STATE.md:91-100`),
  which is contradicted by the executable Rakefile.
- `Rakefile:36-68` excludes 7 slow and 10 serial files from the fast path.
  `test/dependency_isolation_test.rb` is one of the serial files, so the
  boundary regression below is also absent from the GitHub command.

Why it matters: a green CI result does not mean the repository satisfies its
own Ruby quality, design-smell, coverage, or current-baseline policy. This is a
control failure, not merely a missing convenience task.

Recommendation: make one command authoritative and wire the same commands into
local CI and GitHub. At minimum, the fast path should run the no-new-offense
RuboCop gate, Reek ratchet, and Enola gate; the full path should additionally
run coverage and the complete baseline/evidence checks. Do not add exclusions to
make the current run green.

### CQ-02 — Quality baseline is stale and the current configured static gate is red

Severity: High  
Confidence: 1.0  
Status: Confirmed

Evidence:

- `docs/code-quality-baseline.json:3-5` records generator commit `41579c7`;
  current HEAD is `1a61066`.
- `docs/CODE_QUALITY.md:3-14` reports 40,169 raw RuboCop offenses and 3,681
  Reek smells for that older tree.
- The non-mutating `script/check_baseline_drift` probe failed with stale
  RuboCop/Reek totals and numerous files whose committed Reek count is lower
  than current.
- With the pinned Ruby 3.3.11 runtime and RuboCop cache disabled, the current
  configured run reported 10,011 offenses across 708 files and exited 1.
  Top cops were `Style/StringLiterals` (6,903),
  `Layout/SpaceInsideHashLiteralBraces` (916),
  `Minitest/EmptyLineBeforeAssertionMethods` (379), `Metrics/AbcSize` (240),
  and `Metrics/MethodLength` (178).
- The current Reek run over `gems/`, `script/`, `bin/`, and `apps/` reported
  4,950 smells and exited 2 as expected for raw smell findings. Top types were
  `DuplicateMethodCall` (1,353), `TooManyStatements` (828), `FeatureEnvy`
  (409), `LongParameterList` (333), `UtilityFunction` (281), and
  `MissingSafeMethod` (272). Current top files included
  `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb` (124),
  `gems/tamoz-stream/lib/tamoz/stream/situation_request.rb` (120), and
  `gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb` (77).

Why it matters: the current tree has unratcheted quality debt, including debt
on recently added/extracted files. The old baseline cannot distinguish an
intentional refactoring delta from a regression.

Recommendation: decide the intended scope for the current refactoring series,
run the generator successfully on the pinned runtime, review every delta, and
commit the generated baseline with the corresponding slice. Keep raw debt,
ratchet state, and generated/evaluation corpus classifications separate.

### CQ-03 — Baseline generation can convert a RuboCop infrastructure failure into zero debt

Severity: High  
Confidence: 1.0  
Status: Confirmed by this audit

Evidence:

- `script/regenerate_quality_baseline:65-70` calls `Open3.capture3` for
  RuboCop but discards `err` and `status`, then parses the output file.
- The first RuboCop run in this environment failed before inspection with
  `Operation not permitted` while opening `/Users/ghassan/.cache/rubocop_cache`.
- After that failure, `tmp/rubocop-raw.json` contained
  `{"offense_count":0,"target_file_count":708,"inspected_file_count":0}`.
- The concurrent `rake quality:baseline_drift` probe consequently reported
  `rubocop.total: committed 40169 != actual 0`, rather than reporting the
  tool failure. The successful fallback required `--cache false`.

Why it matters: regenerating the committed baseline under a cache, plugin,
Ruby, or filesystem failure could record a false zero or stale report. A
quality ratchet must fail closed when the analyzer did not inspect files.

Recommendation: check the subprocess status and stderr, require a nonzero
`inspected_file_count`, and use a repository/temp cache location that CI owns.
Apply the same fail-closed rule to every analyzer whose exit status is
currently ignored. Do not rely on a stale output file.

### CQ-04 — `tamoz-evals` now violates its documented and tested package boundary

Severity: High  
Confidence: 1.0  
Status: Confirmed; introduced by commit `7cb3f9f7` on 2026-08-20

Evidence:

- `README.md:32-36` says `tamoz-evals` is stdlib-only and non-runtime.
- `docs/CODING_STANDARD.md:156-164` and `docs/QUALITY_PROGRAM.md:185-186`
  require evals to stay outside the production runtime graph.
- `gems/tamoz-evals/tamoz-evals.gemspec:16-20` now declares
  `tamoz-core`, `tamoz-agent`, `tamoz-sqlite`, and `tamoz-mcp` dependencies.
- `gems/tamoz-evals/lib/tamoz/evals.rb:7-11` now eagerly requires
  `tamoz/agent`, `tamoz/sqlite`, and `tamoz/mcp`.
- `test/dependency_isolation_test.rb:56-64` fails because requiring
  `tamoz/evals` loads the runtime graph.
- `test/dependency_isolation_test.rb:172-184` fails because the evals gemspec
  depends on `tamoz-agent`; the focused run produced exactly 2 failures in 12
  tests / 98 assertions.
- `gems/tamoz-evals/README.md:3-4` still describes the artifact verifier as
  stdlib-only, while `:16-19` describes agent-smoke as optional/lazy.

Why it matters: this is an executable architecture contract failure and makes
the supposedly lightweight verifier pull the model/runtime/storage graph into
processes that only need artifact validation. It also invalidates the package
dependency review's stated direction.

Recommendation: preserve the boundary by separating stdlib-only artifact
verification from the runtime-dependent harness, for example as a distinct
optional gem or an explicitly lazy profile with no eager runtime dependency.
If the intended contract has changed, update README, coding standard, Q7,
dependency tests, and packaging evidence in one reviewed cross-gem decision;
do not weaken the failing test in isolation.

### CQ-05 — Test teardown masks the original socket/setup failure

Severity: Medium  
Confidence: 1.0 for the teardown defect; environment-specific for the socket
failure  
Status: Confirmed

Evidence:

- `test/support/local_model_endpoint.rb:50` binds `TCPServer.new("127.0.0.1", 0)`.
  The sandbox rejects this with `Errno::EPERM`.
- `test/stream_episode_skills_memory_test.rb:151,303,326,405,436` use bare
  `endpoint.stop` in `ensure` blocks. If initialization raises, the local
  variable was never assigned, so teardown raises
  `NoMethodError: undefined method 'stop' for nil`.
- `rake ci` was unable to complete its parallel behavior phase in this
  environment: the original bind error was followed by repeated nil-stop
  errors. This is why the full CI result is an environment-blocked result,
  not evidence of product behavior failure.
- Other tests in the same file already use the safer `endpoint&.stop` form
  (`:122, :173, :197, :244, :282, :503`), so the inconsistency is local and
  actionable.

Why it matters: failed setup is reported as a secondary teardown error,
reducing diagnostic value and making CI failures harder to classify. The same
pattern can conceal real resource-leak/setup defects on machines where socket
binding is restricted or intermittently unavailable.

Recommendation: make teardown nil-safe consistently and add an explicit
unsupported-socket/environment path that preserves the original exception or
skips only tests requiring the local endpoint. Keep the real endpoint tests;
they are valuable boundary tests.

### CQ-06 — Coverage is below target and the critical subprocess paths are not measured

Severity: Medium  
Confidence: 1.0  
Status: Confirmed baseline gap

Evidence:

- `docs/code-quality-baseline.json:544-567` reports 89.45% line coverage
  (21,729/24,291) and 69.22% branch coverage (5,630/8,134), below the Q5
  targets of 90%/80% in `docs/QUALITY_PROGRAM.md:160-168`.
- The baseline lists 11 fully uncovered production files, all gem `version.rb`
  entrypoints. These are likely harmless declarative constants, but the Q5
  policy requires an explicit classification/reason for exceptions.
- `docs/QUALITY_PROGRAM_STATE.md:145` says subprocess result collation and
  `test_slow` measurement are deferred. Thus killed-child, CLI, crash/recovery,
  and evidence-path coverage is not represented by the main baseline.

Why it matters: branch coverage is about 10.8 percentage points below target,
and the most failure-sensitive durability/authority/effect paths are not yet
measured using the required subprocess collation. The headline line number is
therefore not a complete risk measure.

Recommendation: complete Q5 collation, classify the 11 version files in the
generated baseline, then prioritize branch coverage in authority, durability,
effect-journal, approval, reconciliation, MCP, and subprocess lifecycle code.
Keep mutation checks for digest, approval, effect identity, budget, and
transaction-boundary invariants.

### CQ-07 — The raw RuboCop baseline does not preserve the mandated production/test split

Severity: Medium  
Confidence: 1.0  
Status: Confirmed measurement-design gap

Evidence:

- The Q0 charter requires production and tests to be measured separately
  (`docs/QUALITY_PROGRAM.md:98-104`).
- `Rakefile:6-13` defines `RUBY_SOURCES` over both `gems/**/*.rb` and
  `test/**/*.rb`.
- `script/regenerate_quality_baseline:65-70` invokes RuboCop without explicit
  scope separation, so the raw RuboCop ledger includes test cops. The committed
  baseline contains 1,026 `Minitest/EmptyLineBeforeAssertionMethods` and 606
  `Minitest/MultipleAssertions` offenses alongside production metrics.
- Reek uses a different scope (`script/regenerate_quality_baseline:114-130`,
  `REPORT_DIRS = %w[gems script bin apps]`), so RuboCop and Reek totals are not
  directly comparable by scope.

Why it matters: a single raw debt number mixes maintainability of shipped code,
test style, evaluation harnesses, and scripts. It obscures whether a change
improved production quality or merely moved test/style debt.

Recommendation: keep separate generated ledgers for hand-maintained runtime
code, tests, evaluation harnesses, scripts, and generated/declarative files.
Retain a combined report only as a secondary summary.

## Complexity and maintainability register

The following are review candidates, not automatically incorrect code. They
are grounded in the current Enola graph and the repository's Q6 ceilings. The
existing quality program already treats these as staged debt; an extraction
must preserve transaction, wire, effect, authority, and ordering semantics.

| Area | Evidence | Assessment and safe next step |
| --- | --- | --- |
| Agent deliberation | `gems/tamoz-agent/lib/tamoz/agent/deliberation.rb:186`, `structural_issues`, cyclomatic 21; 16 reverse callers in Enola | High-risk validation seam. Characterize validation/error identity, then extract pure issue validators; keep prompt/canonicalization contracts unchanged. |
| Session records | `gems/tamoz-agent/lib/tamoz/agent/session_records.rb:275`, `load!`, cyclomatic 20 | Durable record decoding is branch-heavy. Add malformed/version/error-path tests before separating codecs from policy. |
| Core JCS | `gems/tamoz-core/lib/tamoz/core/jcs.rb:112`, `JCS.emit`, cyclomatic 16; 50 callers of the digest family | Canonicalization is a shared primitive, not a god class by itself. Extract only with byte/vector tests and no API/digest drift. |
| SQLite scheduling | `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:271`, `claim_one_schedule`, cyclomatic 18 | Critical transaction/policy seam. Separate pure grant/occurrence decisions only if the transaction kernel remains explicit. |
| Stream request boundary | `gems/tamoz-stream/lib/tamoz/stream/situation_request.rb:202`, `EpisodeRequestEnvelope#validate!`, cyclomatic 16; Reek 120 current smells | Validate shape, authority, and request semantics in named steps; retain fail-closed ordering. |
| MCP invocation | `gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb:84-694`, 694 physical lines, Reek 77, fan-out 46 | Multiple validation, connection, retry, classification, and rendering concerns. Characterize effect identity and error taxonomy before a responsibility extraction. |
| Evals verifier | `gems/tamoz-evals/lib/tamoz/evals/verifier.rb:264,325,388,473`, complexity 16–21 | Important evidence correctness, but package-boundary decision must land first; classify harness separately from runtime. |
| SQLite/evals scripts | `script/tamoz_sqlite_oracle:319`, complexity 24; `gems/tamoz-evals/.../agent_smoke_corpus.rb:1998`, complexity 15 and 3,076 lines | These are oracle/corpus harnesses, not ordinary runtime classes. Keep them out of runtime hotspot targets; split only where a test/evidence responsibility is isolated. |

Current physical-size hotspots from the complete inventory include
`gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb` (1,303 lines),
`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb` (857),
`gems/tamoz-stream/lib/tamoz/stream/situation_request.rb` (857),
`gems/tamoz-graph/lib/tamoz/graph/checkpoint_codec.rb` (712),
`gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb` (694), and
`gems/tamoz-core/lib/tamoz/circuit/record.rb` (639). Size alone is not a defect;
the existing charter's recorded atomic-transaction/cohesion exceptions should
be respected.

## Positive signals and false positives

- The configured Enola CLI gate passed:
  `enola check --fail-on=cycles,layers --min-confidence=0.8 .` returned PASS.
  Its current receipt recorded 537 files seen, 495 parsed, 0 parse errors, and
  599 skipped by configured globs. The current graph had 9,659 facts and 52
  heuristic insights; the committed baseline's 6,830 facts / 45 insights is
  stale.
- `rake syntax` passed and `rake stream:proto:check` passed.
- Focused checks passed: `public_api_test` (3/792 assertions),
  `documentation_surface_test` (9/87), `documentation_tree_test` (7/1,068),
  `ci_configuration_test` (2/15), `packaging_test` (9/280), and
  `secret_sweep_test` (12/26).
- Enola's cycle explainer reported a 28-module cluster at confidence 0.40 and
  explicitly says it is not a load-order verdict. The high-confidence CLI gate
  found no actionable cycle/layer violation.
- Enola's `Tamoz::Core` fan-in of 150, `Tamoz::Core.digest` fan-in of 50, and
  `Tamoz::Core::JCS` fan-in are expected candidates for shared canonical
  primitives. The Q7 charter explicitly says not to lower fan-in on codecs
  merely for aesthetics.
- The `gems/tamoz-stream/contracts` 35/35 exported-surface result is a review
  signal, not proof of overexposure: wire contract symbols may deliberately be
  public and are protected by protocol tests.
- All fully uncovered baseline files are version constants. They should be
  classified explicitly, but adding trivial tests solely to raise a percentage
  is lower value than closing branch coverage on behavioral paths.
- RuboCop's raw `Style/StringLiterals`, layout, and Minitest counts are largely
  baselined mechanical debt. They should not be presented as correctness bugs;
  the current unratcheted files and metric offenses are the actionable signal.

## Coverage checklist

The inventory below accounts for every tracked component under the requested
paths. File/line totals are physical totals over tracked component files,
including gemspecs, READMEs, and scripts where present; they are not the
production-only SimpleCov denominator.

| Component | Files | Lines | Largest/current focus |
| --- | ---: | ---: | --- |
| `gems/tamoz-agent` | 132 | 25,691 | `agent/cli.rb` 857; session/profile/worker/effects |
| `gems/tamoz-comms` | 25 | 2,416 | `comms/decision_record.rb` 317; values/admission/transport |
| `gems/tamoz-core` | 33 | 4,684 | `circuit/record.rb` 639; codecs, errors, pool, instrumentation |
| `gems/tamoz-evals` | 103 | 14,312 | `harness/agent_smoke_corpus.rb` 3,076; verifier/evidence harness |
| `gems/tamoz-graph` | 51 | 5,585 | `graph/checkpoint_codec.rb` 712; compiled/execution/checkpoints |
| `gems/tamoz-mcp` | 20 | 3,471 | `mcp/invocation.rb` 694; supervisor/websearch/catalog |
| `gems/tamoz-observability` | 21 | 1,938 | `observability/recorders.rb` 402; policy/metrics/signals |
| `gems/tamoz-otel` | 8 | 460 | HTTP/async exporters and egress policy |
| `gems/tamoz-scheduler` | 11 | 995 | `scheduler/schedule.rb` 433; grants/occurrences/store contract |
| `gems/tamoz-sqlite` | 70 | 13,391 | `sqlite/migrator.rb` 1,303; stores, effects, leases, transactions |
| `gems/tamoz-stream` | 34 | 5,209 | `stream/situation_request.rb` 857; worker/episode/contracts |
| `gems/tamoz-telegram` | 8 | 431 | transport/client/normalizer |
| `gems/tamoz-tools` | 27 | 3,084 | `tools/skills/compiler.rb` 317; toolbox/path/check/skills |
| `gems/gemspec_helper.rb` | 1 | 57 | shared gemspec construction |
| `apps/tamoz-agent` | 2 | 27 | app metadata/README |
| `bin/` | 4 | 252 | eval and stream entrypoints |
| `script/` | 32 | 9,476 | quality, conformance, release, oracle, fixture scripts |
| `test/` | 218 | 60,834 | Minitest unit, integration, subprocess, crash, packaging, fixtures |

In addition, I inspected the relevant configuration and quality artifacts:
`AGENTS.md`, `README.md`, `Gemfile`, `Gemfile.lock`, `Rakefile`,
`.rubocop.yml`, `.rubocop_todo.yml`, `.reek.yml`, `mcp-arch.yaml`,
`.github/workflows/ci.yml`, `docs/CODING_STANDARD.md`,
`docs/QUALITY_PROGRAM.md`, `docs/QUALITY_PROGRAM_STATE.md`,
`docs/CODE_QUALITY.md`, and `docs/code-quality-baseline.json`. The stream proto,
JSON schemas, contract files, eval suites, and generated gRPC Ruby files were
included in the inventory and covered by the proto, schema, packaging, and
documentation checks; they were not treated as ordinary hand-maintained Ruby.

## Tooling and environment blind spots

- The default shell selected system Ruby 2.6, which cannot satisfy the locked
  Bundler 4.0.12 or Ruby >=3.3 requirement. All Ruby evidence above uses the
  pinned `/Users/ghassan/.rbenv/versions/3.3.11/bin` toolchain.
- The sandbox prohibits loopback server binding. The socket-related CI failure
  is therefore not a product verdict. It did expose the real nil teardown issue
  described in CQ-05.
- The first RuboCop run hit a non-writable user cache. The report generator's
  fail-open handling of that failure is CQ-03; subsequent static evidence used
  `--cache false`.
- The MCP Enola snapshot path does not reproduce the CLI's configured baseline
  exactly. The configured CLI check is authoritative for the gate; MCP results
  were used for symbol/caller exploration and heuristic hotspot evidence only.
- SimpleCov's committed run does not yet collate all child-process/kill-path
  resultsets. Coverage percentages must not be described as complete evidence
  for crash/recovery behavior.
- No production or test code was changed. The only intended audit artifact is
  this report; pre-existing untracked study/review files were preserved.

## Prioritized action order

1. Repair the `tamoz-evals` boundary or make the contract change explicit across
   gemspec, eager requires, README, charter, dependency tests, and packaging.
2. Wire the declared static and coverage gates into the actual CI command, then
   make analyzer failures fail closed.
3. Regenerate and review the baseline from a successful pinned-runtime run;
   separate runtime, tests, eval harnesses, scripts, and generated data.
4. Fix endpoint setup/teardown diagnostics and make socket-dependent tests
   preserve the original setup failure.
5. Close Q5 coverage and subprocess collation before claiming production-grade
   coverage.
6. Refactor the complexity register in behavior-preserving slices, starting
   with deliberation/session validation and scheduling/MCP boundaries; keep JCS,
   SQLite atomic transactions, eval corpora, and oracles under their documented
   cohesion rules.

