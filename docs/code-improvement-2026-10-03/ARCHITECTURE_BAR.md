# Architecture and modularity — quality bar

**Task:** make every production class one responsibility and keep the gem graph acyclic ·
**Owner:** Ghassan · **Size:** L · **Set:** 2026-10-03 (before the change)
**Governing ADRs:** ADR-040 (monorepo of publishable gems), ADR-052 (a gem owns one dependency
boundary, reached only through its facade) · **Branch:** `code-improvement`
**Analysis:** [`MODULE_MAP.md`](MODULE_MAP.md) · **Companion bar:** [`CLEAN_CODE_BAR.md`](CLEAN_CODE_BAR.md)

## 0. Outcome and fence

**Outcome:** the gem and directory dependency graph has no cycle, and no production class or module
exceeds 250 lines — each large one is split into collaborators named for the business concept they
own, inside the gem that already owns it.

**Done when:** every row is PASS (or WAIVED by the owner), the review log has no open critical or
high finding, and the loop log's last iteration changed nothing.

**Not in scope:** new gems (ADR-052 admits a gem only for its own dependency boundary — none is
needed); cross-gem renames `MODULE_MAP.md` D1 and D2 (owner decisions); tests.

**Owner decisions needed:** D1 (group `tamoz-sqlite` by domain), D2 (sub-namespace per
`tamoz-agent-*` gem). Neither blocks this bar.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seam extended | Each split class keeps its public constant and public methods; extracted collaborators are new classes in the same gem and namespace. |
| 1.2 | What already does part of this | `test/dependency_isolation_test.rb`, `test/public_api_test.rb`, `rake quality:architecture`, `enola check` |
| 1.3 | Blast radius | `impact_analysis` on each class before its split; a split must not change the callers' code outside the gem |
| 1.4 | Baseline | enola baseline pinned 2026-10-03 at `c2887afa` (16,223 facts, 277 insights, 1 cycle) |

## A. Safety and boundaries

| # | Property | Check | Status |
|---|---|---|---|
| A1 | No behavior change | `rake ci` test steps pass; `git diff --stat -- test/` empty | OPEN |
| A2 | No gem reaches past another's facade; no new cross-gem dependency | `test/dependency_isolation_test.rb`, boundary tests, enola `diff_snapshot` (no added cross-gem edge) | OPEN |
| A3 | Public surface unchanged | `test/public_api_test.rb`; `docs/public-api.json` not in the diff | OPEN |

## B. Function — the structure delivers the outcome

| # | Property | Check | Status |
|---|---|---|---|
| B1 | No dependency cycle | enola `query_insights(explainer: "cycles")` → 0 | FAIL (1: `lib/tamoz` ↔ `lib/tamoz/core`, see note) |
| B2 | No production class over 250 lines, no module over 100 (the ceilings `.rubocop.yml` enforces) | `bundle exec rubocop -c docs/code-improvement-2026-10-03/metrics.rubocop.yml --ignore-disable-comments --only Metrics/ClassLength,Metrics/ModuleLength gems apps bin script` → 0 | FAIL |
| B3 | The debt list excuses no production file for B2 | `awk '/^Metrics\/(ClassLength\|ModuleLength):/,/^$/' .rubocop_todo.yml \| grep -E "'(gems\|apps\|bin\|script)"` → empty | FAIL |
| B4 | Each extracted class is one responsibility named for a business concept, not a technical bucket (`Helpers`, `Utils`, `Part2`) | reviewer subagent per round | OPEN |
| B5 | No layer violation; enola instability/distance not worse for any touched package | `enola check --fail-on=cycles,layers --min-confidence=0.8 .`; `package_metrics` vs baseline | OPEN |

## D. Gates

Same gates and known-red list as [`CLEAN_CODE_BAR.md`](CLEAN_CODE_BAR.md) §D.

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | A split follows a seam already in the class (a group of methods sharing state); no new abstraction layer, registry, or base class | review | OPEN |
| E2 | One class per file; path mirrors constant; Zeitwerk loads it (`rake syntax`, gem load tests) | `rake ci` | OPEN |
| E5 | No new gem; a changed graph node bumps its `version:` | diff | OPEN |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F2 | Gem READMEs still describe what each gem holds | review | OPEN |
| F3 | ADR-040/052 still true | `rake adr:validate adr:verify` | OPEN |

**B1 note.** Round 1 removed the redundant `core/capability.rb` namespace file, which shrank the
cycle from three directories to two. The two left are `lib/tamoz/core.rb` (the `Tamoz::Core` facade,
which Ruby places beside its directory) delegating to `lib/tamoz/core/jcs.rb`, and the error classes
in `lib/tamoz/core/` subclassing `Tamoz::Error`. Removing it means changing the public error ancestry
or renaming `Tamoz::Core` — owner decision D3. `rake quality:architecture` reports the smaller cycle
as "new" because its finding id changed; the same run lists the three-directory cycle as resolved.

## Placement log

Every file a round touches gets a verdict: right gem, move, or new gem (ADR-052 admits a new gem
only for its own dependency boundary).

| Round | Code | Verdict | Why |
|---|---|---|---|
| 1 | `Tamoz::Core::Capability::*` | stays in `tamoz-core` | The capability contract is shared by `tamoz-tools`, `tamoz-mcp` and `tamoz-agent-capabilities`; homing it in the capabilities gem would make `tamoz-tools` depend on a gem that depends on it. |
| 1 | `Tamoz::Circuit::*` (record, registry, evidence, new `RecordSchema`, `OwnerSchema`, `OwnerTally`) | stays in `tamoz-core` | A domain engine used by `tamoz-mcp`, `tamoz-mcp-websearch`, `tamoz-agent-healing` and `tamoz-sqlite`; it has no third-party dependency, so a gem of its own would be a boundary with nothing behind it. Candidate for its own gem only if it ever gains one. |
| 1 | `Tamoz::StateCodec` (+ new `Encoder`, `WireReader`, `ItemBudget`) | stays in `tamoz-core` | The durable value codec under both `tamoz-graph` checkpoints and `tamoz-sqlite`. |
| 1 | `JCS`, `Immutable`, `Context`, `Error`, `StoreEntry`, `StreamPart`, `Instrumentation` | stay in `tamoz-core` | Kernel values every gem uses. |
| 2 | `Tamoz::Pool` (+ `ThreadRun`, `ThreadLimits`) | stays in `tamoz-concurrency` | Thread machinery is that gem's whole job. |
| 2 | `CancellationToken` | stays in `tamoz-cancellation` | |
| 2 | OTel `HTTPExporter`, `EgressPolicy` | stay in `tamoz-otel` | The gem owns the OTLP egress boundary. |
| 2 | `Telegram::Client` | stays in `tamoz-telegram` | One transport, one gem (ADR-041). |
| 2 | `Tools::Toolbox` | stays in `tamoz-tools` | |
| 2 | `Comms::Admission` | stays in `tamoz-comms` | Pure channel policy, no transport. |
| 2 | `Approval::PolicyValidator`, `TargetPath` (new) | `tamoz-approval` | Both are approval rules; private constants. |
| 2 | Observability `Catalog` + `ModelSignals`/`WorkerSignals`/`CommsSignals`/`Measurements` | stay in `tamoz-observability` | The closed signal catalog is that gem's contract (ADR-044). |
| 2 | Websearch `EgressClient`, `EgressPolicy` | stay in `tamoz-mcp-websearch` | The gem owns the websearch egress boundary. |
| 2 | `Agent::CapabilityBinding` | stays in `tamoz-agent-capabilities` | |
| 2 | `Comms::Gateway` and its 10 mixins | right gem (`tamoz-comms-gateway`, a separate process per ADR-042); wrong shape | One 1,500-line class assembled from mixins. Next round turns the mixins into collaborator objects. |

**B5 note (round 1).** Splitting `StateCodec` into `lib/tamoz/state_codec/` moved `lib/tamoz` from
instability 0.053 to 0.073 (distance improved, 0.932 → 0.911): a facade that delegates to its own
sub-directory always gains that edge. `lib/tamoz/core` improved on both. `enola check` reports no layer
violation.

## Review log

| Round | Findings (C / H / M / L) | Resolution | Commit |
|---|---|---|---|
| 1 | see `CLEAN_CODE_BAR.md` review log (one review covered both bars) | as there | round 1 |

## Loop log

| Round | Date | What changed | B1 cycles / B2 classes > 250 | Next |
|---|---|---|---|---|
| 0 | 2026-10-03 | Bar set, baseline pinned | 1 / 50 (corrected to 50 classes + 53 modules: module ceiling fixed to 100, the real `.rubocop.yml` value, and inline disables counted) | core cycle, then the largest classes |
| 1 | 2026-10-03 | `tamoz-core`: cycle shrunk; `Circuit::Record` (508) and `StateCodec` (374) split into named collaborators | 1 (smaller) / 36 + 38 | `tamoz-concurrency`, `tamoz-cancellation`, then by gem |
| 2 | 2026-10-03 | `Pool`, `Approval::PolicyDocument` (294), `Approval::Engine` (258), observability `Catalog` (171-line module) split | 1 / 46 + 51 | comms-gateway, scheduler, profile, core modules |
