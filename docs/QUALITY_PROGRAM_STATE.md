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
10. **Coverage baseline (Q0-4):** SimpleCov 0.22.0 wired in `test/support/simplecov_setup.rb`,
    loaded first in test_helper when `RUN_COVERAGE=1` (branch coverage, production-only
    via track_files gems/*/lib). `RUN_COVERAGE=1 rake test` (1,150 runs / 13,786
    assertions, 0 failures): **line 87.73% (17,897/20,399), branch 68.60% (5,198/7,577)**.
    This is the fast serial subset only — subprocess children and test_slow are not yet
    measured (Q5 collation), so the real full-suite number is higher. Targets: ≥90/80
    overall, ≥95/90 on security/authority/durability paths (Q5).
11. **Baseline artifacts (Q0-5):** `script/regenerate_quality_baseline` (deterministic,
    no timestamps) + committed `docs/code-quality-baseline.json` + `docs/CODE_QUALITY.md`.
    Key numbers (2026-08-06, git b6f611e dirty): LOC 49,968 code lines / 249 files;
    RuboCop raw debt 42,378 / 393 files (convention 41,894 + warning 484; top:
    Style/StringLiterals 30,336); Reek 4,588; Enola 5,387 facts / 43 insights, check
    PASS; coverage 87.73/68.60; tests 1,150/13,786. Branch totals are computed
    directly from the SimpleCov resultset (can differ by 1 branch from SimpleCov's
    printed summary — definitional edge, documented in the script).
12. **Q1 ratcheting gates (2026-08-06):** `rake quality:*` namespace in the Rakefile —
    `quality:rubocop` (gate + TODO-drift probe that restores the committed TODO even on
    failure), `quality:rubocop_gate` (fast), `quality:reek` (per-file drift vs the
    committed baseline — **it caught the new shared module's 8 smells on first run**,
    fixed to zero), `quality:coverage` (RUN_COVERAGE run, no-decrease), 
    `quality:architecture` (enola check), `quality` aggregate. `rake ci` now includes
    the three fast gates (rubocop_gate + reek + architecture) — one command, one gate
    (CODING_STANDARD §1). Coverage is made deterministic by pinning `MT_SEED=1` in both
    the generator and the gate (seed variance of ±0.01pp would false-fail the ratchet).
    Shared coverage math lives in `script/quality/coverage_totals.rb` (2 consumers).
    Baseline regenerated: **raw RuboCop debt net-zero** (42,378 → 42,378: the Rakefile
    block's +1 BlockLength / +3 StringLiterals offset by the generator refactor);
    LOC 49,992 / 250 files (new module). Known limitation (documented, inherent to the
    per-file TODO model): a new offense in an already-excluded (cop, file) pair is not
    caught by the drift probe — reek's context ratchet partially covers it, and Q2+
    slices remove the underlying debt.
13. **Q2 CLI characterization (2026-08-06):** `cli.rb` (1,610 lines, 217 reek smells,
    81% line coverage before). Callers: `gems/tamoz-agent/exe/tamoz` (production
    entrypoint), the evals smoke corpus (prepends a module to the CLI), loaded by
    `tamoz/agent.rb`. Authority seam (`resolve_session_authority`/`pinned_authority`)
    already covered by `test/agent_cli_profile_test.rb` (10 tests). Gaps found and
    filled in `test/agent_cli_test.rb` (+9 tests, 30 runs / 216 assertions):
    error-taxonomy rescue chain (ToolError / CheckpointConflictError / ApprovalDenied →
    exit 1 + "tamoz: " message; a generic RuntimeError must NOT be swallowed — it
    propagates), the three `--check` parse validations (empty name / empty command /
    duplicate → USAGE_ERROR), and the interactive answer vocabulary (`map_answer`:
    approve_tool + resolve_effect words — pinned via send as a documented contract
    characterization). **Mutation-proven:** dropping the "approve" word from
    `map_answer` made the vocabulary test fail (restored after). MCP Enola store
    divergence noted: `generate_snapshot` via MCP produces a 42k-fact polluted store
    (does not apply mcp-arch.yaml) while the CLI store is the clean 5,387-fact graph —
    the CLI store is authoritative for gates; the MCP-side divergence is a tooling
    wrinkle for a later slice.

## Phase status

| Phase | Status | Acceptance (abridged) |
|---|---|---|
| Q0 Measure honestly | **COMPLETE** (2026-08-06) | `docs/code-quality-baseline.json` + `docs/CODE_QUALITY.md` committed; deterministic regeneration script; prod vs tests vs generated classified separately |
| Q1 Ratcheting gates | **COMPLETE** (2026-08-06) | `rake quality:*` + `quality` aggregate; ci includes the fast ratchets (rubocop gate, reek drift, enola); ratchet verified live (reek caught 8 new smells); net-zero RuboCop debt added |
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
| Reek | design smells | **done (user-installed 6.5.0)** — `.reek.yml` isolates repo content; raw baseline 4,588 smells / 202 files (below); untuned by design until Q0-5; `IrresponsibleModule` explicitly pinned ON (default) per `docs/CODING_STANDARD.md` §11 (public API docs required) |
| SimpleCov | branch + subprocess collation | **wired (Q0-4)** — RUN_COVERAGE-gated (everyday gate stays fast); branch coverage on; main-process baseline line 87.73% / branch 68.59% (1,150 runs, `rake test`); subprocess collation + test_slow measurement deferred to Q5 |
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

**Code review after every change (owner, 2026-08-06, part of the loop):** before a
slice is committed, its diff is code-reviewed against `docs/CODING_STANDARD.md` §12 and
the charter's review protocol (correctness, security, quality, performance; transaction/
durability/authority deltas; abstraction leakage; API growth). Every critical and high
finding is fixed before the commit. Major hotspot extractions additionally get a
fresh-context critic.

## Next actions (ordered)

1. **Q3 CLI slice 1:** extract one cohesive responsibility from the CLI with
   characterization tests in place — start with the error-taxonomy/exit-code policy or
   the parser (argv → typed command); run Enola impact analysis + the 17-step loop;
   commit the extraction alone. Then continue per-hotspot: characterize next hotspot
   (session_nodes 113, profile 126, toolbox 140, checkpoint_store 173, compiled 139)
   before extracting from it.
2. **Q3+:** one responsibility per slice along the charter target architectures.
3. **Q5:** SimpleCov subprocess result collation (children: unique command_name per
   process, merged at the end; killed processes documented as blind seams with a
   non-killed control path), test_slow measurement, then the coverage targets.
4. When network returns: re-lock the bundle cleanly (`bundle lock --add-platform ruby`).
   Update this table after every slice.

## Slice ledger

| # | Date | Hotspot | Responsibility | LOC b/a | Cov b/a | RuboCop/Reek | Enola delta | Behavior | Commit |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 2026-08-06 | — (Q0 tooling) | toolchain + honest baseline | — | — | gate 0/391; raw debt 40,232 | 42,241 → 5,378 facts (worktree pollution removed) | no production behavior change; dependency review runtime closure unchanged (22); full gate 130/24,970 both locales | 8ce5581 + 4f49a4f + dbf2848 |
| 2 | 2026-08-06 | — (Q0 tooling) | reek + rubocop-minitest + coding standard | — | — | rubocop gate 0/391 (raw 42,378); reek raw 4,588/202 | unchanged | no production behavior change | f1bcf8e (owner) + e5802f8 |
| 3 | 2026-08-06 | — (Q0-4) | SimpleCov coverage wiring | — | line 87.73 / branch 68.59 (before) | rubocop gate 0 | unchanged | no production behavior change; 1,150 runs 0 failures | b6f611e |
| 4 | 2026-08-06 | — (Q0-5) | deterministic baseline script + artifacts | — | line 87.73 / branch 68.60 | rubocop gate 0; raw 42,378; reek 4,588 | 5,387 facts / PASS | no production behavior change | 1ce3e68 |
| 5 | 2026-08-06 | — (Q1) | quality:* rake gates + ci wiring | — | 87.73 / 68.60 (deterministic) | gate 0; raw 42,378 (net zero); reek 4,588 | unchanged (re-pin after commit) | no production behavior change; ci = one gate, one command | d499f53 |
| 6 | 2026-08-06 | CLI (Q2) | characterization tests (error taxonomy, --check validation, answer vocabulary) | — | 81% line before (674/832) | gate 0 | unchanged | no production behavior change; +9 tests (30 runs/216 assertions), mutation-proven | dea4396 |
| 7 | 2026-08-06 | CLI (Q3 slice 1) | error-taxonomy/exit-code policy (run() rescue chain → handle_usage_error / handle_fatal_error) | cli.rb 1,610 → 1,620 | 81% (unchanged) | reek 4,588 → 4,587 (one DuplicateMethodCall removed); gate 0 | PASS (no regression) | behavior byte-identical — Q2 taxonomy tests pass unchanged (4/10 + 30/216); exit codes + "tamoz: " messages pinned | pending |

## Owner-decision queue

- (none — the reek / rubocop-minitest installation blocker was resolved by the owner
  installing both gems on 2026-08-06)
