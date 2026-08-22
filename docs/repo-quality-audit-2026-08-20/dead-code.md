# Dead-code and unreachable-surface audit

Date: 2026-08-20  
Repository: `/Users/ghassan/my-projects/tamoz`  
Auditor focus: dead or unreachable files, constants, methods, routes, branches, configuration, dependencies, tests, fixtures, and generated/declarative artifacts.  
Audit mode: read-only. No production code or tests were changed.

## Executive summary

The current tree contains three confirmed dead or unreachable surfaces:

1. `bin/tamoz-stream-worker-learning` is a committed executable whose only
   behavior is an unconditional retirement abort. It has no in-repository caller,
   test, task, or documentation reference.
2. Several committed generated/declarative quality and evidence artifacts still
   name deleted files and a renamed test. The stale paths include 154
   `.rubocop_todo.yml` entries (21 unique missing paths), 12 stale paths in the
   baseline Reek ledger, and one missing test path in the requirements manifest
   and generated requirements audit. The repository's own baseline-drift checker
   fails on the current tree.
3. The JSON domain fixture `cold-chain.json` is discovered by the generic domain
   loader but cannot enter the benchmark-family registry: hyphenated data is
   converted to the invalid constant name `Cold-chainDomain`. This is an
   unreachable data-driven branch, not an unused fixture.

One additional documentation candidate is recorded separately: the active-looking
P15 owner-gate text and older stream-worker audit still describe the retired P14
engine. That is documentation drift unless those files are intentionally retained
as historical records.

No additional confirmed dead production methods/constants, uncalled gRPC routes,
unused runtime dependencies, generated protobuf files, or dead committed fixtures
were established after tracing all listed components and their dynamic entrypoints.

## Findings

### D1 — Retired worker-learning launcher remains executable surface

Severity: P2 (medium)  
Confidence: 1.00 (confirmed)

Evidence:

- `bin/tamoz-stream-worker-learning:1-4`
  is tracked and ends with:

  ```ruby
  abort "tamoz-stream-worker-learning was retired; use tamoz-stream-worker and tamoz-stream-subscriber"
  ```

- Before this report was written, a repository-wide search of the existing
  source/config/docs found only that self-reference. There is no Rake task, test,
  gemspec entry, README command, or deployment configuration that invokes it.
- The root source inventory explicitly includes every `bin/*` file in
  `Rakefile:6-13`, so the retired
  launcher remains part of source/quality inventory even though it is not a gem
  executable.
- The replacement worker has a real implementation and test surface. The gRPC
  server shape is exercised from
  `test/stream_worker_server_test.rb:3-14`.

Why it matters: operators and automation can still discover or invoke a command
that always exits. It increases the apparent supported surface, makes command
inventory and packaging checks noisier, and can hide the actual worker/subscriber
entrypoint during migration. This is not a useful compatibility boundary: the
file itself says the command was retired.

Recommendation: remove the retired launcher and any external deployment reference
in the normal implementation change. Do not replace it with a compatibility shim;
the repository owner directive explicitly rejects backwards-compatibility paths.
Update the command inventory and retain the retirement explanation in a historical
release note if operators need migration context.

### D2 — Generated quality and requirements inventories reference removed paths

Severity: P2 (medium)  
Confidence: 1.00 (confirmed)

The quality/evidence artifacts were not regenerated after two source changes:

- Commit `1636d3b` removed the P14 stream-engine files and tests, including
  `gems/tamoz-sqlite/lib/tamoz/sqlite/stream_store.rb`, the old stream value and
  connector files, and the old stream test files.
- Commit `ddba441` renamed
  `gems/tamoz-sqlite/lib/tamoz/sqlite/memory_repository.rb` to
  `memory_store.rb` and `test/memory_repository_test.rb` to
  `test/memory_store_test.rb`.
- The current source has the replacement files at
  `gems/tamoz-sqlite/lib/tamoz/sqlite/memory_store.rb:30`
  and `test/memory_store_test.rb:9`;
  the old paths do not exist.

Concrete stale references:

- `.rubocop_todo.yml` contains 3,116 path exclusions; 154 entries (21 unique
  paths) point to files that do not exist. The first cluster is visible at
  `.rubocop_todo.yml:110-118`,
  and later entries still include the deleted
  `test/memory_repository_test.rb` and old stream tests.
- The generated Reek ledger has 210 file keys, 12 of which are missing from the
  current tree, including the old SQLite memory/stream files and old stream
  engine files at
  `docs/code-quality-baseline.json:336-339`
  and `docs/code-quality-baseline.json:474-509`.
  The artifact declares generation by
  `script/regenerate_quality_baseline` at commit `41579c7` in
  `docs/code-quality-baseline.json:2-5`,
  while the current HEAD is `1a61066`.
- `docs/CODE_QUALITY.md:3`
  and `docs/CODE_QUALITY.md:239-247`
  report the older generated commit, 398 files, 56,735 LOC, and the old coverage
  ledger. The current source inventory is different.
- The quality-program hotspot table still lists deleted files at
  `docs/QUALITY_PROGRAM_STATE.md:252-253`.
- The generated requirements manifest names the deleted test path at
  `docs/requirements-manifest.json:461`
  and `docs/requirements-manifest.json:5145`.
  A recursive check found 98 distinct test files named by the manifest, with one
  missing file: `test/memory_repository_test.rb`.
- The corresponding generated audit JSON and Markdown repeat the stale evidence,
  for example `docs/REQUIREMENTS_AUDIT.md:400`
  and `docs/REQUIREMENTS_AUDIT.md:426-431`.

The repository's own checks confirm the drift:

- `bundle exec ruby script/check_baseline_drift` exits 1. It reports committed
  RuboCop total `40169` versus actual `0`, Reek total `3681` versus actual `4950`,
  and many current files whose Reek counts are absent or lower in the committed
  baseline.
- The checker is intended to compare against the current tree, as stated in
  `script/check_baseline_drift:6-13`,
  and the Rake quality namespace exposes it at
  `Rakefile:334-337`.
- The requirements-manifest generator explicitly says a missing named test must
  abort generation at `script/generate_requirements_manifest:19-23`.
  Its committed output therefore contains evidence that the generator's own
  invariant would reject today.

Why it matters: stale exclusions can make quality debt appear covered when the
excluded file no longer exists, while newly added or renamed files are absent from
the committed baseline. The requirements audit can also present evidence for a
test that cannot run. This weakens the trustworthiness of generated quality and
release artifacts rather than merely adding harmless historical text.

Recommendation: in a normal code-maintenance change, regenerate the affected
artifacts from the current tree using their prescribed generators, rather than
hand-editing generated output:

1. Regenerate the quality baseline with
   `bundle exec ruby script/regenerate_quality_baseline` after the raw quality
   state is intentional.
2. Regenerate and clean the RuboCop TODO using the documented quality flow and
   `script/clean_rubocop_todo`; retain only current file paths.
3. Regenerate the requirements manifest and requirements audit after the
   `MemoryStore` rename.
4. Refresh the quality-program hotspot/resume table and make the quality gate
   fail early when a generated path or named test file is absent.

This is consistent with the repository's generated-artifact rule and avoids
reintroducing deleted compatibility paths.

### D3 — Hyphenated `cold-chain` fixture cannot reach benchmark-family execution

Severity: P2 (medium, test/evaluation surface)  
Confidence: 1.00 (confirmed)

Evidence:

- The generic loader promises to discover every domain JSON file through
  `test/support/domain_loader.rb:18-29`,
  including the `*.json` glob at lines 23-24.
- The fixture declares the domain identifier `cold-chain` at
  `test/fixtures/domains/cold-chain.json:2`.
- The benchmark-family builder turns the raw identifier into a Ruby constant by
  calling `Object.const_get("#{domain_name.capitalize}Domain")` at
  `test/support/benchmark_families.rb:20-25`.
  `"cold-chain".capitalize` produces `"Cold-chain"`, not a valid Ruby constant
  identifier such as `ColdChainDomain`.
- The same module eagerly builds all families from `DomainLoader.domains` at
  `test/support/benchmark_families.rb:72-76`.
- `rake test_fast` reproduced the non-sandbox error
  `NameError: wrong constant name Cold-chainDomain` in
  `test/support/benchmark_families.rb:24`, causing benchmark-control and
  benchmark-holdout cases to fail. The other test failures in that run were
  largely sandbox `EPERM` errors from tests that bind local servers; this
  `NameError` is independent of that environment limitation.

Why it matters: the fixture is not dead—its JSON is dynamically discovered—but
its benchmark family is unreachable. The repository's “new domain JSON is picked
up automatically” contract is false for hyphenated identifiers, and the cold-chain
benchmark cannot exercise its truth/gold rules or holdout generation.

Recommendation: fix the generic data-to-constant boundary, not by adding
`ColdChainDomain` as domain-specific Ruby knowledge. Either normalize identifiers
to Ruby constant form (`cold_chain` → `ColdChainDomain`) or remove the constant
lookup and pass the `DomainLoader` data object directly. Add a test that builds a
family for every result of `DomainLoader.domains`, including `cold-chain`. Keep all
domain content in JSON as required by `AGENTS.md`.

## Review candidate: stale stream/P15 documentation

Severity: P2 if `P15_OWNER_GATE.md` remains an active release gate; otherwise P3  
Confidence: 0.95

This is not executable dead code, but it can make retired code look live:

- `docs/P15_OWNER_GATE.md:34-55`
  asks for an owner decision about `Tamoz::Stream::ChannelDescriptor` and its
  queue/overflow declaration.
- `script/generate_requirements_manifest:67-69`
  says stream clauses 44-51 are retired and are no longer generated as manifest
  requirements.
- `gems/tamoz-stream/lib/tamoz/stream.rb:19-25`
  says the P14 channels/events/connector/admission/replay engine was retired.
- `docs/STREAM_WORKER_IMPLEMENTATION_AUDIT_2026-08-12.md:3-8`
  is explicitly an older audit, and its T8.3 conclusion at
  `docs/STREAM_WORKER_IMPLEMENTATION_AUDIT_2026-08-12.md:108`
  says the old engine files were still present. Commit `1636d3b` subsequently
  removed them.

Recommendation: close or revise the owner gate to refer to the current supervised
worker/reverse-channel surface, and mark the old P14 plan/audit as historical with
its as-of commit. Do not restore the retired classes solely to satisfy stale prose.

## Validated non-findings and false positives

These surfaces initially look unused under a filename-only search but have live
loaders or external entrypoints:

- `test/fixtures/domains/*.json`: `DomainLoader.domains` loads the entire glob.
  `aquaculture` and `climate` have support-module callers; `shipment` and
  `cold-chain` are data inputs discovered by the same loader. `cold-chain` is the
  D3 unreachable case rather than a dead file (and it currently prevents the
  eager benchmark-family registry from reaching later families).
- `gems/tamoz-stream/contracts/runtime-v1.proto` and the two generated protobuf
  files under `gems/tamoz-stream/lib/tamoz/stream/gen/` are loaded by the stream
  entrypoint and worker/server/evidence code. The graph contains three gRPC routes:
  `EpisodeWorker/Handshake`, `EpisodeWorker/Execute`, and `EvidenceTools/Call`.
  Their route definitions are at `runtime-v1.proto:16`, `:20`, and `:26`.
- `bin/tamoz-stream-worker` and `bin/tamoz-stream-subscriber` are operator-facing
  entrypoints. Lack of a local caller is expected and is not evidence of dead
  code; the worker has direct server tests and the subscriber's implementation is
  exercised through stream-learning tests.
- `docs/public-api.json` is consumed by `test/public_api_test.rb`, which resolves
  documented constants/methods dynamically. It is not an unused declaration.
- `tamoz-evals` suite/schema/baseline JSON is consumed by the eval harness and
  generator scripts. The gem's main file explicitly requires its harness modules;
  the suite files are data inputs, not orphan fixtures.
- Version files with no coverage in the older baseline are package identity
  constants, not dead code. The baseline itself is stale and should not be used as
  a liveness verdict.
- The local `coverage/` resultset was inspected but excluded from findings: the
  directory is ignored, and SQLite `*.sqlite3-shm`/`*.sqlite3-wal` sidecars are
  ignored at `.gitignore:79-81`.
  Their stale local contents are not committed repository artifacts.

No unused runtime dependency was confirmed. The gemspec closure, generated
dependency review, and Enola dependency facts showed declared runtime dependencies
with consuming `require`/use sites or transitive provenance. In particular,
`google-protobuf`/`grpc` are used by the generated stream surface, `sqlite3` by
`tamoz-sqlite`, and the MCP/LLM dependencies are loaded by their respective gem
entrypoints. A dependency may still warrant a separate size/licensing review, but
this pass did not find a dead dependency.

## Coverage checklist

The following checklist records the full in-scope inventory examined. “No other
confirmed dead candidate” means the component was traced and only the findings
listed above were retained.

| Component | Inventory examined | Result |
|---|---:|---|
| `tamoz-agent` | 128 Ruby library files, executable, memory/healing/profile/worker-runtime subtrees | No other confirmed dead candidate; public and dynamic seams traced |
| `tamoz-comms` | 22 Ruby library files and communication contracts/stores | No other confirmed dead candidate |
| `tamoz-core` | 30 Ruby library files, immutable/core/circuit primitives | Shared by downstream gems; no dead candidate confirmed |
| `tamoz-evals` | 44 Ruby files, 55 JSON files, executable, benchmark/suite/schema/harness data | Dynamic suite inputs traced; no dead artifact beyond D2 |
| `tamoz-graph` | 48 Ruby library files, graph runtime/checkpoint/reducer paths | Reverse dependencies and callers traced; no dead candidate confirmed |
| `tamoz-mcp` | 17 Ruby library files, HTTP/websearch/circuit/config paths | Entrypoint and dynamic configuration paths traced |
| `tamoz-observability` | 18 Ruby library files | Exported recorders/metrics/signals have tests or downstream use |
| `tamoz-otel` | 5 Ruby library files | Exported exporter/policy paths have tests; no dead candidate confirmed |
| `tamoz-scheduler` | 8 Ruby library files | Consumer/store/schedule paths and tests traced |
| `tamoz-sqlite` | 67 Ruby library files, migration/store/adapter paths | Current `MemoryStore` traced; old store paths retained only as D2 artifact references |
| `tamoz-stream` | 25 Ruby library files, 2 generated protobuf Ruby files, proto contract | Current worker/reverse-channel paths traced; retired engine removed |
| `tamoz-telegram` | 5 Ruby library files and transport tests | External transport entrypoint; no dead candidate confirmed |
| `tamoz-tools` | 24 Ruby library files, skills/toolbox/dispatcher paths | Dynamic capability paths traced; no dead candidate confirmed |
| `apps/tamoz-agent` | 1 app manifest/README, 0 Ruby files | Deployment metadata reviewed; no dead Ruby surface |
| Root `bin/` | 4 entrypoints | D1 is the only dead entrypoint; 3 others retained as external/operator surfaces |
| `script/` | 32 scripts, including generators, conformance, release, quality, and adapters | Script callers/docs/Rake references traced; no other dead script confirmed |
| `test/` | 200 `*_test.rb` files | Test files are registered by Rake and/or direct support; D3 is a live-but-unreachable fixture path |
| `test/support/` | 10 support modules | Dynamic loaders and composition helpers traced; `benchmark_families.rb` is D3 |
| `test/fixtures/` | 6 tracked fixture files, including 4 domain JSON files | Dynamic domain loader verified; ignored SQLite sidecars excluded |
| Root/build/config | `Gemfile`, `Gemfile.lock`, all gemspecs, `Rakefile`, `.ruby-version`, `.gitignore`, RuboCop/Reek/Enola config | Dependency and source inventories reviewed; D2 quality artifacts stale |
| Relevant docs/generated artifacts | quality baseline/TODO/state, dependency review, public API, requirements manifests/audit, stream/P14/P15 docs | D2 and review candidate above; remaining generated surfaces have consumers |

Inventory totals: 13 gems; 441 Ruby library files under `gems/*/lib`; 1 app
directory; 4 root bin files; 32 scripts; 200 test files; 10 test-support files;
6 tracked test-fixture files; 55 eval-gem JSON data files; 3 extracted gRPC
routes. Enola saw 537 files, parsed 495, skipped 599 files/9 directory trees by
configured ignore rules, and reported 0 parse errors.

## Method and blind spots

Methods used:

- `rg`/`rg --files`, `git ls-files`, `git log`, and commit diffs to inventory every
  gem/app/bin/script/test/config surface and confirm deletions/renames.
- Direct source and caller tracing for `require_relative`, `Dir.glob`,
  `const_get`, `public_send`, generated-data loaders, test registration, gemspecs,
  Rake tasks, and standalone operator entrypoints.
- Enola snapshot and graph exploration at snapshot ID
  `sha256:5c7d6d74cbe04a9d86ce5c8396157538c253a8b375970f49fdfb2c808aa97b36`.
  Enola version `0.2.7-51-g72cd079` parsed Ruby and gRPC with 0 parse errors. Its
  single-repository `unused-routes` explainer did not run because that explainer
  requires an append-mode backend-plus-client snapshot, so no “unused route”
  conclusion was inferred from its absence. The three route facts were inspected
  manually.
- `bundle exec reek --format json gems apps bin script` and targeted RuboCop
  searches were used as supporting signals. Reek did not produce an explicit
  unused/dead-method finding. RuboCop's current unused-argument/assignment
  warnings were treated as review signals only; many are protocol/interface
  parameters and do not establish unreachable code.
- `bundle exec rake syntax` passed.
- `bundle exec rake test_fast` was attempted. It could not be treated as a full
  liveness gate because the sandbox denied local server binds and macOS sandbox
  setup (`EPERM`), and the run also surfaced unrelated existing failures. The
  independent `Cold-chainDomain` `NameError` was retained as D3 because it is a
  deterministic code/data reachability failure.

Static Ruby analysis cannot prove all external consumers of public gem APIs or
operator commands. Reflection, `const_get`, `public_send`, dynamic loading,
durable replay entrypoints, and data-driven registries were therefore checked
manually. A method with no local caller is not classified as dead when it is
exported, a protocol implementation, a durable callback, a generated surface, or
an operator entrypoint. Conversely, an unconditional abort or a generated path
that names a file absent from the current tree is classified as dead/stale only
when the source and generator contract provide direct confirmation.
