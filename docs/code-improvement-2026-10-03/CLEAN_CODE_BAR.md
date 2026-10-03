# Clean functions — quality bar

**Task:** refactor production Ruby so every function is short, does one thing, and reads top-down ·
**Owner:** Ghassan · **Size:** L · **Set:** 2026-10-03 (before the change)
**Governing rules:** `docs/CODING_STANDARD.md` §4 (methods ≤ 20 lines, cyclomatic/perceived ≤ 8),
`AGENTS.md` (simple over complicated; comments) · **Branch:** `code-improvement`
**Companion bar:** [`ARCHITECTURE_BAR.md`](ARCHITECTURE_BAR.md) · **Module analysis:** [`MODULE_MAP.md`](MODULE_MAP.md)

## 0. Outcome and fence

**Outcome:** every production method is at most 20 lines with cyclomatic and perceived complexity
at most 8, and no production file is excused from those cops in `.rubocop_todo.yml`.

Production Ruby is `gems/*/lib`, `gems/*.rb`, `apps/`, `bin/`, `script/`
(`docs/CODING_STANDARD.md` scope).

**The principles each refactored method is held to:**

1. The name states the intent.
2. It is short and does one thing.
3. It stays at one level of abstraction.
4. Public, top-level methods read like a small domain language.
5. Each method calls methods one level below it; the code steps down until what is left is small
   and concrete.
6. At most 20 lines (owner, 2026-10-03: keep the existing 20-line rule).

**Done when:** every row is PASS, the review log has no open critical or high finding, and the loop
log's last iteration changed nothing.

**Not in scope:** tests (owner, 2026-10-03: "no need to work on tests now") — test files are not
refactored; they run unchanged as the behavior proof. `Metrics/AbcSize` and
`Metrics/ParameterLists` are reported, not required. Cross-gem renames (see `MODULE_MAP.md` D1, D2).

**Owner decisions needed:** none for this bar.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seam extended | None — behavior-preserving extract-method refactors inside existing classes. |
| 1.2 | What already does this | RuboCop ceilings in `.rubocop.yml`; per-file debt in `.rubocop_todo.yml`. The bar adds no new tool: `metrics.rubocop.yml` here runs the same cops without the debt list. |
| 1.3 | Blast radius | Per method: private helpers only; public signatures unchanged (`test/public_api_test.rb`). |
| 1.4 | Baseline | enola baseline pinned 2026-10-03 at `c2887afa`. Known-red at HEAD listed under D. |

**Starting measure (HEAD `c2887afa`):** `Metrics/MethodLength` 306 · `CyclomaticComplexity` 176 ·
`PerceivedComplexity` 162 offenses in production Ruby (tracked only: `AbcSize` 360, `ParameterLists`
178).

## A. Safety — behavior preserved

| # | Property | Check | Status |
|---|---|---|---|
| A1 | No behavior change: every existing test passes unchanged | `rake ci` → `test_parallel … all passed`; test files untouched (`git diff --stat -- test/` empty) | OPEN |
| A2 | Durable bytes unchanged: checkpoints, journal keys, wire frames, prompt headers | pinned-digest tests inside `rake ci`; `rake ci_full` (both locales) after any round touching `tamoz-sqlite`, `tamoz-graph`, `tamoz-mcp`, or packaging | OPEN |
| A3 | No authority path is reordered: an extracted guard still runs before the effect it guards | reviewer reads each touched `enforce_*`/`verify_*`/effect method against HEAD | OPEN |
| A4 | Public surface unchanged | `test/public_api_test.rb` inside `rake ci`; `docs/public-api.json` not in the diff | OPEN |

## B. Function — the refactor delivers the outcome

| # | Property | Check | Status |
|---|---|---|---|
| B1 | No production method over 20 lines, counting methods hidden behind an inline `rubocop:disable` | `bundle exec rubocop -c docs/code-improvement-2026-10-03/metrics.rubocop.yml --ignore-disable-comments --only Metrics/MethodLength gems apps bin script` → 0 offenses | FAIL |
| B2 | No production method over cyclomatic/perceived 8 | same command, `--only Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity` → 0 | FAIL |
| B3 | The debt list excuses no production file for these cops | `awk '/^Metrics\/(MethodLength\|CyclomaticComplexity\|PerceivedComplexity):/,/^$/' .rubocop_todo.yml \| grep -E "'(gems\|apps\|bin\|script)"` → empty | FAIL |
| B4 | Principles 1–5 hold in every refactored method: intent names, one level of abstraction, top-level reads as domain language, step-down order | reviewer subagent per round; findings in the review log | OPEN |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Everyday gate | `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bundle exec rake ci` — all steps except the known-red one | OPEN |
| D2 | `rake ci_full`, both locales, after durability/MCP rounds | output | OPEN |
| D3 | RuboCop: no new offense of any cop in a touched file | `bundle exec rubocop <files>` vs `git show HEAD:<file>` | OPEN |
| D4 | enola: no new cycle, layer violation, or cross-gem coupling | `diff_snapshot` vs the pinned baseline; `rake quality:architecture` | OPEN |

**Known-red at HEAD `c2887afa`** (each reproduced at the base in the detached worktree):
- `rake test_slow`: `test/sqlite_scenario_driver_test.rb` — `request.redirect_ready: SQLite failure SQLite3::SQLException`, same error at the base.
- `rake test` under `LANG=C`: `test/agenteval_skills_optimizer_test.rb` cannot load (`invalid byte sequence in US-ASCII` at line 11); a test-file encoding issue, unchanged by this work.
- `stream:proto:check` — `grpc_tools_ruby_protoc` ships an x86_64 `protoc`; this arm64 machine has
  no Rosetta (`Errno::EBADARCH`). Environment, not code; every other `rake ci` step passed.
- `bundle exec rubocop` (whole repo) — 4,809 offenses in 156 files at HEAD (files never added to the
  debt list). This bar only requires no new offense in touched files and the B rows.

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Extracted methods are private, named for intent; no new class created just to hold a split | review | OPEN |
| E2 | No shim, alias, or compatibility wrapper | diff review | OPEN |
| E3 | No new comments (owner, 2026-10-03: "try not to write comments"); the only addition allowed is the one-line class doc `Style/Documentation` forces on a new class. A "why" comment on a line that moves is replaced by a name that carries it (`require_run_identity!`, `count_keeping_highest`), not dropped silently | review | OPEN |
| E4 | No scratch files; modes unchanged | `git status`, `git ls-files -s` | OPEN |
| E6 | No domain literal added to Ruby | review | OPEN |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | The report says these are refactors proven by the existing suite; no real-model run is claimed | report review | OPEN |
| F3 | No ADR changes: the 20-line rule already lives in `CODING_STANDARD.md`; no decided rule moves | `rake adr:validate adr:verify` | OPEN |
| F4 | Lessons recorded in `.agent/rules/` in the round that taught them | review | OPEN |

## Review log

| Round | Findings (C / H / M / L) | Resolution | Commit |
|---|---|---|---|
| 1 | 0 / 0 / 2 / 7 — no behavior change found (22 error-path probes byte-identical) | M1 dropped "why" comments → carried by names (`require_run_identity!`, `count_keeping_highest`), owner's no-comment rule; M2 new circuit modules made `private_constant`; L: success reset moved into `OwnerTally.record_success`, window/rate split back to plain `when`s, schema methods renamed (`validate_state_fields!`, `validate_lifecycle_fields!`), `Context#assign_annotations` takes keywords, `corrupt!` deduplicated into `Circuit.corrupt_record!`, `Record.repaired` evaluation order restored. Removed unused internals: `Record.corrupt!`, `Record::KEYS` (not public API, no callers). | round 1 |
| 2 | 0 / 0 / 1 / 8 — no behavior change; ThreadRun keys, `on_stuck` timing, drain/deadline loop and close/join order confirmed equal | M: the deleted unreachable branch in `validate_tool_tiers!` was the only written statement of a rule nobody enforces — a tool entry on a no-session tier may declare `:session` scopes. Pre-existing gap; not fixed silently (it changes policy validation): flagged as a separate task with a failing test first, and listed for the owner. L: `REFUSED_IPV4` made private; Telegram `build_http` order restored; stale "metric smells" class comments trimmed; `Toolbox` read tools named once (`READ_TOOLS`) with an explicit `glob` arm; `ThreadRun` takes `ThreadLimits` instead of the pool; `HOST_LIMITS` inner hashes frozen. Accepted: OTel exporter now checks the timeout before building the request (differs only for a CR/LF credential header, which `open` already refuses). | round 2 |

| 3 | 0 / 0 / 2 / 0 — independent continuation review | Restored ID-before-task-text validation in `TurnContext.task`; made `JsonValues`, `ModelDocument`, and `ReconsiderationPayload` private constants. Existing focused suites passed; whole-project rows remain open or failing until final integration. | pending |

## Loop log

| Round | Date | What changed | B1 / B2 (MethodLength / Cyclo / Perceived) | Next |
|---|---|---|---|---|
| 0 | 2026-10-03 | Bars set, baseline pinned | 306 / 176 / 162; corrected in round 1 to 404 / 216 / 203 once the 107 inline `rubocop:disable Metrics/…` comments are ignored (`--ignore-disable-comments`) | smallest gems first |
| 1 | 2026-10-03 | `tamoz-core` clean: descriptor, JCS, state codec, circuit record/registry, context, immutable, instrumentation, stream part, store entry. Byte-identical to base on randomized differential runs (JCS 30k values, StateCodec 3k round-trips, circuits 19k transitions) | 290 / 155 / 147 | `tamoz-concurrency`, `tamoz-cancellation` |
| 2 | 2026-10-03 | `tamoz-concurrency` (`Pool` split into `Base`/`Inline`/`Threads`/`ThreadRun`/`ThreadLimits`), `tamoz-cancellation`, `tamoz-otel`, `tamoz-telegram`, `tamoz-tools`, `tamoz-comms` admission, `tamoz-approval` (`PolicyValidator`, `TargetPath`; one unreachable branch in `validate_tool_tiers!` removed), `tamoz-observability` (catalog split into signal families; registry identical to base), `tamoz-mcp-websearch` (IPv4 refusal as a CIDR table, identical to base on every /16), `tamoz-agent-capabilities`. Three stale inline `rubocop:disable Metrics/…` comments removed | 374 / 181 / 176 (with inline disables counted) | comms-gateway as collaborators; scheduler; profile; core modules over 100 |
| 3 | 2026-10-03 | `tamoz-scheduler` (`Schedule` → value + `FireCalendar` + `OccurrencePolicy` + `ScheduleValidator`; `Occurrence` compacted), remaining `tamoz-core` (`Capability::DescriptorRules`, `Capability::Source`, circuit `Registry::Condition`/`Scope` split, `JCS::Writer`/`NumberFormat`/`Scanner`, `Core::JsonValues`/`ModelDocument`/`ReconsiderationPayload`, `TurnContext` reusing `SafeText`), `tamoz-tools` (`InventoryProjection`, staging reaper), `tamoz-agent-profile` (`PinnedAuthority`, `DocumentLoader`, 24 uncalled one-line delegators removed, `consume_if_candidate!` split with find/guard/mark kept in one locked step), the bundled evidence-audit verifier script. Differential runs identical to base: descriptor (19 cases), inventory (1,536 gate combinations), JCS, circuits | 371 / 174 / 169 | `tamoz-comms`, then `tamoz-comms-gateway` as collaborators |
