# Quality Program — Live State

**Charter:** [`QUALITY_PROGRAM.md`](QUALITY_PROGRAM.md)
**This file is the single resume point.** Every session starts here. Update it at the end of
every slice and whenever the phase table changes.

---

## Checkpoint

- **Date:** 2026-08-06
- **HEAD:** `d9d156b` (main, ahead of origin by 4) — "Slow tests behind an explicit task"
- **Tree:** clean (after slice 1 commit)
- **Branch:** main. Never push/tag/release/rewrite.

## Precondition verdict

| Item | Result | Evidence |
|---|---|---|
| Staged/dirty autonomy work present? | **No — already captured** | Tree was clean; `1b060f1` "A1: close the autonomy slices and leave the tree clean for refactoring" is HEAD~2 |
| Autonomy slice complete & consistent? | Yes | A1 closed; fast gate 49s; full gate preserved |
| `agenteval/` untouched? | Yes | gitignored; never staged |
| Quality work startable? | **Yes** | from `d9d156b` |

## Audit findings (session 2026-08-06)

1. **Enola snapshot was polluted by agent worktrees** — `.qwen/worktrees/agent-*`,
   `.claude/worktrees/agent-*` appeared in facts (42,241 facts). **Fixed:** repository-owned
   `mcp-arch.yaml` excludes `.qwen/**`, `.claude/**`, `.cursor/**`, `.worktrees/**`,
   `agenteval/**`, docs/data globs. Re-pinned snapshot: **5,378 facts, 43 insights,
   parse_errors 0, 281 files seen / 255 parsed**, no worktree leakage. Production Ruby:
   225 files, all parsed.
2. **Enola CLI binary:** `~/.local/bin/enola` (v0.2.7-51-g72cd079, matches MCP server).
   Not on PATH — call by full path or add `~/.local/bin` to PATH. Manual gate works:
   `enola baseline pin .`, `enola check --fail-on=cycles,layers --min-confidence=0.8 .`
   (`--target`/`--max-spillover` supported).
3. **Quality gems:** rubocop 1.87.0 + rubocop-performance 1.26.1 + simplecov 0.22.0 locked
   in a `development, :test` Gemfile group (slice 1). **reek and rubocop-minitest could not
   be installed** — rubygems.org unreachable (2026-08-06, repeated OpenTimeout). Re-add on
   the next network-available session: `gem "reek", "~> 6.4"` and
   `gem "rubocop-minitest", "~> 0.38"` in the dev group, then `bundle install`.
4. **RuboCop baseline (slice 1):** raw debt vs Q6 ceilings = **40,232 offenses** across 391
   files (39,779 convention / 453 warning / **0 errors**). Top: Style/StringLiterals 30,332,
   Layout/SpaceInsideHashLiteralBraces 3,704, Metrics/AbcSize 936, Metrics/MethodLength 927.
   **Gate: `rubocop` = 0 offenses** via committed `.rubocop_todo.yml` (3.7k lines,
   per-file excludes ONLY — verified: zero `Enabled: false`, zero directory/glob
   exclusions). Q6 ceilings live in `.rubocop.yml` and apply to all non-excluded files.
   `script/clean_rubocop_todo` post-processes auto-gen so a regeneration cannot
   reintroduce a prohibited glob. RuboCop 1.87 wants `plugins: [rubocop-performance]`
   (not `require:`).
5. **Dependency review regenerated:** runtime closure 22 (unchanged), development 21
   (rubocop/simplecov/rake/minitest etc. correctly in development). Gate
   `DependencyReviewTest` re-fails until the regenerated docs are committed — drift
   detection works.
6. **Rakefile (255 lines)** has `:test`, `:test_slow`, `:test_fast`, `:test_parallel`,
   `:autonomy`, `:autonomy_strict`, `:syntax`, `:design:validate`, `:fixtures:refresh`,
   `:ci` (= design:validate + syntax + test_fast), `:ci_full`, `:ci_fast`. No
   `quality:*` namespace yet (Q1).
7. **Ignored dirs** (already correct for Enola): `.enola/`, `.qwen/`, `.claude/`,
   `.cursor/`, `.worktrees/`, `/coverage/`, `agenteval/` all in `.gitignore`.
8. **docs/ convention:** `P##_*_PLAN.md` + machine-readable JSON results. Quality
   artifacts: `docs/code-quality-baseline.json` + `docs/CODE_QUALITY.md` (Q0-5).
9. **Lockfile portability (offline machine):** bundler 4.0.12 on this machine prunes the
   `ruby` platform from Gemfile.lock whenever it re-resolves (sqlite3's ruby variant is
   not installed locally) — HEAD's committed lock had already lost it, making
   `CIConfigurationTest#test_lockfile_has_a_portable_platform` red BEFORE this program.
   **Fixed by completing the CHECKSUMS section** from the local `.gem` cache
   (`~/.rbenv/versions/3.3.11/lib/ruby/gems/3.3.0/cache`, digest of the `.gem` file —
   validated against sqlite3's known checksum): with complete checksums, `bundle exec`
   no longer re-resolves and the portable lock survives. Do NOT use `bundle install
   --local` and commit its output; re-lock with network when available.

## Phase status

| Phase | Status | Acceptance (abridged) |
|---|---|---|
| Q0 Measure honestly | **IN PROGRESS** (rubocop + enola done; coverage + baseline docs pending) | `docs/code-quality-baseline.json` + `docs/CODE_QUALITY.md` committed; deterministic regeneration script; prod vs tests vs generated classified separately |
| Q1 Ratcheting gates | pending | `rake quality:*` + wiring into `ci`; ratchet policy; committed RuboCop TODO (no exclusions for CI) |
| Q2 Characterize hotspots | pending | characterization + failure-path tests per hotspot; mutation-proven |
| Q3 Extract by responsibility | pending | one responsibility per slice; target architectures in charter |
| Q4 Remove accidental complexity | pending | Data values, codec centralization, no banned abstractions |
| Q5 Coverage quality | pending | ≥90/80 overall, ≥95/90 critical paths, subprocess collation |
| Q6 Ruby quality targets | pending | method/class/ABC/cyclomatic/params/nesting limits |
| Q7 Architectural gates | pending | gem direction table, zero cycles/layer violations, hotspot −25% |
| Review protocol | pending | fresh-context critic per major extraction |

## Toolchain status

| Tool | Needed | Status |
|---|---|---|
| RuboCop + performance + minitest | gate at 0 | **done** — locked; `plugins:` form; Minitest cops active (raw debt 42,378, debted per-file) |
| Reek | design smells | **done (user-installed 6.5.0)** — `.reek.yml` isolates repo content; raw baseline 4,588 smells / 202 files (below); untuned by design until Q0-5 |
| SimpleCov | branch + subprocess collation | locked 0.22.0; **not yet wired** (Q0-4) |
| Enola CLI | manual baseline/check gate | **done** — `~/.local/bin/enola`; mcp-arch.yaml; baseline pinned |
| RubyCritic | optional aggregator | evaluate after core tools calibrated |

**Reek raw baseline (2026-08-06, reek 6.5.0, JSON run over gems/ script/ bin/ apps/,**
**no tuning):** 4,588 smells across 202 files. Top types: DuplicateMethodCall 1,302,
TooManyStatements 793, FeatureEnvy 394, LongParameterList 309, MissingSafeMethod 260,
IrresponsibleModule 242, UtilityFunction 214, DataClump 187, NilCheck 156,
ControlParameter 148. Top files (validate the Q2 hotspot list): agent_smoke_corpus.rb
248 (evals corpus — classify separately per Q0), cli.rb 217, checkpoint_store.rb 173,
toolbox.rb 140, compiled.rb 139, profile.rb 126, skills.rb 113, session_nodes.rb 113,
effect_journal.rb 73. Reek's ratchet is context-named (stricter than per-file
excludes): the Q0-5 baseline stores per-context counts.

## Gate policy (owner-confirmed 2026-08-06)

`rake ci` (fast gate, ~49s) + `rubocop` + `enola check` is the everyday gate for every
slice. `rake ci_full` under BOTH locales is ~145s per locale — run it **only when the
slice touches durability, MCP, packaging, or committed evidence artifacts** (the
Rakefile's own hint), never speculatively. Scorecards and the release benchmark run when
the slice touches agent/autonomy/worker or persistence/planning/effects respectively.

## Next actions (ordered)

1. **Q0-4:** Wire SimpleCov (branch coverage) into the test entrypoints (root `test/`,
   subprocess children) and produce line/branch numbers for prod and tests. Watch the
   subprocess load-path memory (children must carry every transitive tamoz gem on `-I`).
2. **Q0-5:** Write `script/regenerate_quality_baseline` — deterministic: RuboCop raw
   ledger (config without `inherit_from`), coverage numbers, Enola `log`/`show` facts +
   `check`, dependency-review + public-api + scorecard + benchmark results; generate +
   commit `docs/code-quality-baseline.json` and `docs/CODE_QUALITY.md`.
3. **Q1:** `quality:rubocop` (gate + TODO drift check), `quality:reek` (when reek lands),
   `quality:coverage`, `quality:architecture` (enola check), `quality`; wire blocking
   tasks into `ci`/`ci_full` without slowing the everyday gate.
4. **Q2:** first hotspot = CLI (`gems/tamoz-agent/lib/tamoz/agent/cli.rb`) — Enola impact
   analysis, callers, characterization + failure-path tests, mutation-proven.
5. Then Q3 slice 1, and so on. Update this table after every slice.
6. When network returns: install reek + rubocop-minitest, lock, and fold their gates in.

## Slice ledger

| # | Date | Hotspot | Responsibility | LOC b/a | Cov b/a | RuboCop/Reek | Enola delta | Behavior | Commit |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 2026-08-06 | — (Q0 tooling) | toolchain + honest baseline | — | — | gate 0/391; raw debt 40,232 | 42,241 → 5,378 facts (worktree pollution removed) | no production behavior change; dependency review runtime closure unchanged (22); full gate 130/24,970 both locales | 8ce5581 + 4f49a4f + dbf2848 |
| 2 | 2026-08-06 | — (Q0 tooling) | reek + rubocop-minitest + coding standard | — | — | rubocop gate 0/391 (raw 42,378); reek raw 4,588/202 | unchanged | no production behavior change | f1bcf8e (owner) + e5802f8 |

## Owner-decision queue

- (none — the reek / rubocop-minitest installation blocker was resolved by the owner
  installing both gems on 2026-08-06)
