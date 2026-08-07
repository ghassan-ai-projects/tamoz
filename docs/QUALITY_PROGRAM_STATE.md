# Quality Program — Live State

**Charter:** [`QUALITY_PROGRAM.md`](QUALITY_PROGRAM.md)
**This file is the single resume point.** Every session starts here. Update it at the end of
every slice and whenever the phase table changes.

---

## Checkpoint

- **Date:** 2026-08-07
- **HEAD:** `25011d3` (main) — "Q3 tier-3 slice 2: extract Skills::Catalog"
- **Tree:** clean
- **Branch:** main. Never push/tag/release/rewrite. (origin was externally updated to `a126fda` — local commits stay local.)
- **Quality commits so far:** 26, counted as `git rev-list --count 8ce5581..HEAD` + 1
  (`8ce5581` Q0 toolchain → HEAD). Recount with that command rather than
  incrementing by hand — an earlier entry had drifted one ahead of the tree, and
  the end-of-range SHA had gone stale behind it. Do not hand-edit the number.

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
| Q2 Characterize hotspots | **CLI COMPLETE** (dea4396); remaining: session_nodes, profile, toolbox, checkpoint_store, compiled | characterization + failure-path tests per hotspot; mutation-proven |
| Q3 Extract by responsibility | **IN PROGRESS** — CLI slice 1 done (d10e945); next: approval adapter, then parser/commands/factory/renderer | one responsibility per slice; target architectures in charter |
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

**GIANTS-FIRST (owner 2026-08-06):** slice selection targets the largest production
files first (measured 2026-08-06): checkpoint_store.rb (2,070 → 1,760 — SAFE
EXTRACTIONS COMPLETE: CheckpointWire validators/decoders/materialize/merge +
CheckpointWriter facade; the remaining ~1,700 lines are the atomic transaction core —
claim/recover/append/transition — which stays together BY DESIGN: splitting atomic
transactions is forbidden (charter), so the store's core is a recorded exception with
its own characterization tests). Next queue: profile.rb 1,547 (126 smells, authority-
critical) > cli.rb 1,481 (mid-flight) > session_nodes.rb 1,450 (113) > toolbox.rb 1,213
(140) > compiled.rb 1,152 (139) > skills.rb 1,063 > effect_journal.rb 950.
(agent_smoke_corpus.rb 3,287 is the evals corpus driver — classified separately.)

**EASY-FIRST (owner 2026-08-07, replaces giants-first):** slice selection is now
ordered by EXTRACTION COST, not by file size. The survey
(`script/survey_extractions.rb`, re-runnable) scored the largest 50 production files
for nested class/module definitions — the signal that has predicted a cheap slice every
time so far (the profile.rb registries, CheckpointWire, CheckpointWriter). False
positives were filtered by hand: `migrator.rb`'s "TEXT class" is a SQL heredoc column,
and several hits were a file's own namespace rather than a nested extra.

**Tier 1 — trivial moves.** One small self-contained nested definition; move verbatim,
qualify any outer constants, match visibility, done.

1. ~~`tamoz-mcp/lib/tamoz/mcp/catalog.rb` — `CanonicalJSON`~~ **DONE (slice 31)**, 291 → 243.
2. ~~`tamoz-graph/lib/tamoz/graph/memory_checkpointer.rb` — `Writer`~~ **DONE (slice 32)**, 318 → 250.
3. ~~`tamoz-agent/lib/tamoz/agent/healing/classification.rb` — `Matrix` + `LegacyTextAdapter`~~ **DONE (slice 33)**, 395 → 259.

**TIER 1 COMPLETE (slices 31-33):** four new files; catalog.rb −48, memory_checkpointer.rb −68, classification.rb −136; reek 4,376 → 4,355.

**Tier 2 — one substantial nested class.**

4. ~~`tamoz-agent/lib/tamoz/agent/memory/behavior_transition.rb` — `TransitionRegistry`~~ **DONE (slice 34)**, 487 → 172. It was a SIBLING, not nested.
5. ~~`tamoz-sqlite/lib/tamoz/sqlite/boundary_source_audit.rb` — `Auditor`~~ **SKIPPED (2026-08-07), deliberately.** The check the queue asked for came back negative: this file is ONE cohesive private unit, not a module/class pair worth separating. `BoundarySourceAudit` is itself `private_constant` on `SQLite`; its only public method is a three-line `audit!` delegating to `Auditor.new(...).audit!`; and all eleven constants (DYNAMIC_EXECUTION, FILE_MUTATIONS, STATEMENT_ACCESS, TRANSACTION_METHODS, MethodDefinition, Call, …) are `private_constant` AND used only by `Auditor`. Extracting it would move everything except those three lines into a sibling file and drag every constant along — file-count cosmetics, not a responsibility split. Left as is.

**Tier 3 — the big structural win: `tools/skills.rb` (1,063).** SEVENTY PERCENT of it is
five nested classes, and this is the highest value-per-risk in the repo. One slice each,
largest last so the pattern is proven on the small ones first:
~~`Snapshot` (~43)~~ **DONE (35)** → ~~`Catalog` (~110)~~ **DONE (36)** → `Walk` (~142) →
`Frontmatter` (~179) → `Compiler` (~264). skills.rb 1,063 → **905** so far; expect ≈ 325
when done. Parent reek debt 111 → **93**, concentrated in the three remaining classes.
`Walk` is the filesystem traversal (lstat + Dir.children only, never Find.find, no
symlink following) — agent_skills_adversarial_test is the suite that matters for it.
**`Skills::Compiler` and `Skills::Catalog` are PUBLIC API pinned in
`docs/public-api.json`** — moving them to `skills/<name>.rb` preserves the constant path
exactly, so `public_api_test` stays green; verify it does rather than assuming.

**Tier 4 — hard, no nested structure; every extraction is a design decision** like the
profile.rb validators were. Only after Tiers 1-3:
`session_nodes.rb` 1,450, `toolbox.rb` 1,213, `compiled.rb` 1,152, `effect_journal.rb`
950, and the rest of `cli.rb` (session factory, stream rendering).
`checkpoint_store.rb` 1,759 stays together BY DESIGN (charter: atomic transactions).

**EXTRACTION-FIRST (owner 2026-08-07):** the priority is breaking large files into
small ones and large methods into small ones. Q3 extraction is the DEFAULT slice type
from here. Characterization is still the precondition for touching a seam (charter:
behavior before structure) but is no longer its own slice — write only the
characterization the seam being extracted in that same slice actually needs, and only
where the suite does not already cover it. Two axes count as progress, and a slice may
target either: file size (extract a responsibility into its own file) and method size
(a method over the Q6 20-line ceiling split into named steps). Do not re-run a
standalone characterization pass on a file already covered at its extraction seam.

1. ~~**Q3 profile.rb slice 1 — lift the two registries out of the file.**~~ **DONE (slice
   18).** profile.rb 1,547 → 1,232; five files under `profile/`; both registries now
   split storage/locking from document validation. Next up is item 2.

   Original plan, kept for the record:
   `AdoptionRegistry` (1,224–1,285), `Transition` (1,293–1,319), and
   `TransitionRegistry` (1,334–1,544) are ~320 lines of nested classes at the bottom of
   `profile.rb` (1,547 lines) with no dependency on the loader above them. Move them to
   `profile/adoption_registry.rb`, `profile/transition.rb`,
   `profile/transition_registry.rb` (Zeitwerk maps the paths; keep the constant paths
   so no caller changes). Both are now characterized — adoption by slice 17, transitions
   by agent_profile_transition_test + agent_profile_machinery_test — so this is a move,
   not a rewrite. Expect profile.rb ≈ 1,230 lines after.
2. **Q3 profile.rb slices 2+ — the loader**, along the charter's target architecture:
   schema/constants, safe document loader, structural validator, semantic validator,
   canonicalizer/digester, authority projection.
   - ~~`validate_egress!`~~ **DONE (slice 19)** → `Profile::EgressValidator`.
   - ~~`scan_yaml!`~~ **DONE (slice 20)** → `Profile::YamlScanner`, a real
     Psych::Handler subclass with a `Frame` Struct.
   - **NEXT: the remaining `validate_*!` family** (~13 methods: validate_schema!,
     validate_strings!, validate_profile_fields!, validate_root!, validate_roots!,
     validate_model_roles!, validate_credential_ref!, validate_budgets!,
     validate_checks!, validate_argv0!, validate_tools!, validate_unattended!,
     validate_policy!). Likely `Profile::SchemaValidator` holding (hash, path); split
     structural vs semantic only if that turns out to be the honest seam rather than a
     name imposed on one pass. Already characterized by agent_profile_schema_seams_test
     (13 branches) + agent_profile_test.
   - Then the canonicalizer/digester (`canonical_digest`, `deep_freeze`, `build_fields`).
3. Then session_nodes.rb 1,450, toolbox.rb 1,213, compiled.rb 1,152, skills.rb 1,063,
   effect_journal.rb 950 — extract-first, characterizing only the seam being moved.
4. CLI completion (session factory, renderer, command objects, validate_thread_id!
   bang cleanup) interleaved when no larger file is waiting.

## Slice ledger

| # | Date | Hotspot | Responsibility | LOC b/a | Cov b/a | RuboCop/Reek | Enola delta | Behavior | Commit |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 2026-08-06 | — (Q0 tooling) | toolchain + honest baseline | — | — | gate 0/391; raw debt 40,232 | 42,241 → 5,378 facts (worktree pollution removed) | no production behavior change; dependency review runtime closure unchanged (22); full gate 130/24,970 both locales | 8ce5581 + 4f49a4f + dbf2848 |
| 2 | 2026-08-06 | — (Q0 tooling) | reek + rubocop-minitest + coding standard | — | — | rubocop gate 0/391 (raw 42,378); reek raw 4,588/202 | unchanged | no production behavior change | f1bcf8e (owner) + e5802f8 |
| 3 | 2026-08-06 | — (Q0-4) | SimpleCov coverage wiring | — | line 87.73 / branch 68.59 (before) | rubocop gate 0 | unchanged | no production behavior change; 1,150 runs 0 failures | b6f611e |
| 4 | 2026-08-06 | — (Q0-5) | deterministic baseline script + artifacts | — | line 87.73 / branch 68.60 | rubocop gate 0; raw 42,378; reek 4,588 | 5,387 facts / PASS | no production behavior change | 1ce3e68 |
| 5 | 2026-08-06 | — (Q1) | quality:* rake gates + ci wiring | — | 87.73 / 68.60 (deterministic) | gate 0; raw 42,378 (net zero); reek 4,588 | unchanged (re-pin after commit) | no production behavior change; ci = one gate, one command | d499f53 |
| 6 | 2026-08-06 | CLI (Q2) | characterization tests (error taxonomy, --check validation, answer vocabulary) | — | 81% line before (674/832) | gate 0 | unchanged | no production behavior change; +9 tests (30 runs/216 assertions), mutation-proven | dea4396 |
| 7 | 2026-08-06 | CLI (Q3 slice 1) | error-taxonomy/exit-code policy (run() rescue chain → handle_usage_error / handle_fatal_error) | cli.rb 1,610 → 1,620 | 81% (unchanged) | reek 4,588 → 4,587 (one DuplicateMethodCall removed); gate 0 | PASS (no regression) | behavior byte-identical — Q2 taxonomy tests pass unchanged (4/10 + 30/216); exit codes + "tamoz: " messages pinned | d10e945 |
| 8 | 2026-08-06 | CLI (Q3 slice 2) | interactive approval adapter (PromptAdapter: approve_tool/clarify/interrupt prompt loops) | cli.rb 1,620 → 1,577 + cli_prompt_adapter.rb 80 | 81% (unchanged) | reek 4,587 → 4,577 (−10: baselined prompt-method smells left cli.rb; new file 0 smells with site-level disables for the EOF-abort loop contract) | PASS | prompt text byte-identical (resume/interrupt tests + 30/216 unchanged); answer POLICY (answer_for/map_answer/approve-all) stays on the CLI; no public API change | a126fda |
| 9 | 2026-08-06 | CLI (Q3 slice 3) | argument parser (ArgumentParser: OptionParser grammar, defaults, --check validation, --version/--help) | cli.rb 1,578 → 1,503 + cli_argument_parser.rb 113 | 81% (unchanged) | reek 4,577 → 4,571 (parse's baselined smells left cli.rb; new file 0 smells — declarative-registry disables per CODING_STANDARD §6) | PASS | behavior byte-identical (critic: 8/8 probes SAME, 31/227 tests); fresh-context critic verdict **PASS-WITH-GAPS**, both LOW findings fixed (help-text regression test added; SUBCOMMANDS passed explicitly to the parser) | 8ba3616 |
| 10 | 2026-08-06 | CLI (Q3 slice 4) | option policy (OptionPolicy: profile/check capability-surface validation, renamed without ! per CODING_STANDARD §3) | cli.rb 1,503 → 1,481 + cli_option_policy.rb 43 | 81% (unchanged) | reek 4,571 → 4,567 (validators' baselined smells left cli.rb; policy clean via documented :reek:FeatureEnvy suppressions — stateless hash-validator, rationale in-file) | PASS | messages byte-identical (critic verified all three + exception class + truth tables); 5 call sites consistent; fresh-context critic verdict **PASS** (2 MINOR fixed/noted); later slice: drop validate_thread_id! bang for consistency | 98c17ac |
| 11 | 2026-08-06 | checkpoint_store (Q2, giant #1) | characterization tests — validation seams of history/open_writer (before_sequence, limit, ttl) | — (tests only) | 90.5% line before (503/556) | gate 0; reek 4,567 unchanged | PASS | +7 tests (12 assertions): bad before_sequence/limit/ttl → ConfigurationError; ttl boundary (0.1/lease_ttl) accepted; **mutation-proven** (removing the before_sequence validation failed 2 tests); uncovered branches mapped to methods (the remaining gaps are corruption/conflict raise-branches for the extraction slices) | 8d3611a |
| 12 | 2026-08-06 | checkpoint_store (Q3 slice 1, giant #1) | wire-value validation layer (CheckpointWire: enum_text/persisted_enum_symbol/request_status/canonical_state_value; bangs dropped per §3) | checkpoint_store.rb 2,070 → 2,034 + checkpoint_wire.rb 54 | 90.5% (unchanged) | reek 4,567 → 4,562 (validators' baselined smells left the store; wire file clean — one load-bearing :reek:FeatureEnvy on persisted_enum_symbol) | PASS | behavior byte-identical (critic verified messages/exceptions/raise conditions; atomic transaction methods untouched); canonicality-audit map re-pointed (checkpoint_store 2→1, wire +1); **ci_full both locales** 130/24,970; critic verdict PASS-WITH-GAPS (3 MINOR, all fixed) | a772603 |
| 13 | 2026-08-06 | checkpoint_store (Q3 slice 2, giant #1) | row decoders (materialize_request + decode_checkpoint_row moved into CheckpointWire; REQUEST_OPERATIONS/DELIVERY_MODES constants moved with them) | checkpoint_store.rb 2,034 → 1,925 + wire 54 → 169 | 90.5% (unchanged) | reek 4,562 → 4,554 (decoders' baselined smells left the store; wire 0 smells, disables load-bearing) | PASS | behavior byte-identical (critic: fetch indices/digest domains/messages/field mapping verified; atomic transaction methods + materialize zero hunks); canonicality map (store → 0, wire → 2); **ci_full both locales** 130/24,970; critic verdict **PASS** (1 LOW defensive reek token removed) | 320658d |
| 14 | 2026-08-06 | checkpoint_store (Q3 slice 3, giant #1) | active-checkpoint mapper (materialize + merge_pending into CheckpointWire; store keeps the pending-outcomes wrapper; decode core consolidated into verified_attributes/checkpoint helpers; fail-closed nil-pending precondition) | checkpoint_store.rb 1,925 → 1,886 + wire 169 → 215 | 90.5% (unchanged) | reek 4,554 → 4,548 (merge+materialize baselined smells left the store; wire smell-free with documented disables) | PASS | behavior equivalent (critic verified fetch indices/messages/merge semantics + NO query-count change; atomic tx methods + pending_outcomes + verify_existing_writes zero hunks); wire-layer COMPLETE (validators + request/checkpoint decoders + materialize + merge); critic verdict **PASS** (1 MED duplication consolidated + 2 LOW fixed: dead reek token, nil-pending hardening); **ci_full both locales** on the final state 130/24,970 | 98606fb |
| 15 | 2026-08-06 | checkpoint_store (Q3 slice 4, giant #1) | fenced writer facade (nested Writer → Tamoz::SQLite::CheckpointWriter, 16 guarded delegations) | checkpoint_store.rb 1,886 → 1,760 + checkpoint_writer.rb 150 | 90.5% (unchanged) | reek 4,548 → 4,536 (nested class's baselined smells left the store; writer smell-free — disables exactly cover TooManyMethods/MissingSafeMethod/2×ManualDispatch/2×FeatureEnvy/2×LongParameterList, critic strip-verified) | PASS | method-for-method identical (critic: 16 delegations + lease usage verified; structural fixes lease/adapter locals behavior-neutral; callers duck-typed unaffected; lease-arg store methods zero hunks); **ci_full both locales** 130/24,970; critic verdict **PASS** (0 fixes; Q4 note: merge accepts_effects?/accepts_store? duplication) | fc919b3 |
| 16 | 2026-08-06 | profile.rb (Q2, giant #2) | characterization tests — schema-validation seams (YAML safety, profile/roots/model_roles/credential_ref/checks validation) | — (tests only) | 90.9% line before (672/739) | gate 0; reek 4,536 unchanged | PASS | +11 tests (33 assertions): YAML merge keys + nesting limit → ValidationError; profile_id pattern + legacy-reserved; unknown profile/roots fields; invalid model role name; unknown provider; credential_ref kind; invalid check name; check argv non-string; **mutation-proven** (removing the merge-key rejection failed the test); 13 previously-untested validation branches now pinned | 8ca17c2 |
| 17 | 2026-08-07 | profile.rb (Q2, giant #2) | characterization tests — adoption-registry authority seams (codec fail-closed, unreadable bytes, owner-only storage, activate's write contract) | — (tests only) | 87.95 line / 68.92 branch (whole suite, measured BEFORE this slice — it is the tree at 8ca17c2, and supersedes the Q0-4 87.73/68.60 figure taken before slice 16; this slice only adds tests, so production coverage can rise but not fall. Re-measure belongs to the next slice) | gate 0; reek drift matches baseline | PASS (new edges are the test file's own) | +15 tests (42 assertions): no test in the suite had asserted either adoption-registry error message — the transition registry beside it had exactly these. Foreign schema_version / non-digest token / short digest / non-mapping document / non-mapping `activated` / non-array list / non-string id → "invalid"; unparseable YAML + alias expansion → "unreadable"; group-readable refused on read AND before `activate` writes; activate 0600-in-0700, idempotent, appends per digest. **Mutation-proven** (drop DIGEST_PATTERN → 2 fail; drop schema_version equality → 1 fail) | cc1b9d3 |
| 18 | 2026-08-07 | profile.rb (Q3 slice 1, giant #2) | the two operator-side registries lifted out, and storage/locking split from document validation | profile.rb 1,547 → 1,232; + adoption_document 47, adoption_registry 79, transition 45, transition_document 76, transition_registry 253 | not re-measured this slice (no test added; production lines moved, not removed) | rubocop raw 42,338 → 42,269; **reek 4,536 → 4,494**; new files 51 → **0** smells | **PASS** — no structural regression, zero layer violations; advisory coupled-cluster finding moved 20 → 21 modules (the file count of this split, not new coupling) | behavior-identical: every moved string literal diffed against HEAD (only the rubocop-required rescue rename + the field_rules table differ) and the four AdoptionError messages verified byte-identical at runtime; two redundant branches removed (`document` already returns empty when absent; `activate`'s pre-verify subsumed by `document`'s). **ci_full BOTH locales 130/24,970**. Owner option 2 applied — predicates got a home (AdoptionDocument/TransitionDocument, mirroring CheckpointWire) instead of a suppression; `consume_if_candidate!` kept whole with an inline disable naming the exception | f5def65 |
| 19 | 2026-08-07 | profile.rb (Q3 slice 2, giant #2) | the egress declaration validator (P17 §4) — `validate_egress!` + `validate_egress_host!` + `validate_egress_integer!` → `Profile::EgressValidator` | profile.rb 1,232 → 1,106; + egress_validator 228. **`validate_egress!` 91 lines → a 3-line delegation; zero Metrics/MethodLength offenses in the new file** (every step ≤ 20) | not re-measured (no test added; lines moved) | rubocop raw 42,269 → 42,227; reek 4,494 → 4,490; new file **0** smells | **PASS** — no structural regression, zero layer violations | behavior-identical: literals diffed against HEAD (differences are `path`→`@path`, the two booleans routed through one field-parameterised message, and `minimum/maximum`→`bounds.min/max`) and **all 20 egress error messages verified byte-identical at runtime**, plus valid-doc-returns-mapping and absent-returns-nil. Stateful validator holds (egress, path) so steps read as questions instead of threading two args; bounds travel as a Range so they cannot be passed in the wrong order. **ci_full BOTH locales 130/24,970** | d3c4fad |
| 20 | 2026-08-07 | profile.rb (Q3 slice 3, giant #2) | the pre-parse YAML safety scan (P8-E) → `Profile::YamlScanner`, a real Psych::Handler subclass | profile.rb 1,106 → 1,006; + yaml_scanner 167. **`scan_yaml!` 100 lines → gone**; zero Metrics/MethodLength, AbcSize or Cyclomatic offenses in the new file | not re-measured (no test added; lines moved) | rubocop raw 42,227 → 42,214; reek 4,490 → 4,480; new file **0** smells | **PASS** — no structural regression, zero layer violations | behavior-identical: literals diffed against HEAD (`path`→`@path`, `max_aliases`→`MAX_ALIASES`, `error`→`e`) and **all 8 YAML refusals verified byte-identical at runtime** (foreign tag, two documents, merge key, duplicate key, alias-in-key-position, complex key, alias limit, nesting limit) plus syntax-error wrapping and a clean scan of a valid profile. The old shape was an anonymous `Class.new(Psych::Handler)` over five lambdas closing on mutable locals; state now lives in ivars so each refusal is a named method, and the `[kind, keys, expecting]` array with magic indexes became a `Frame` Struct with `key_slot?`/`advance!`/`seen?`/`record!`. **ci_full BOTH locales 130/24,970** | b51fab8 |
| 21 | 2026-08-07 | profile.rb (Q3 slice 4, giant #2) | the configured-check specification validator (the profile's EXECUTION surface) → `Profile::CheckSpecValidator` | profile.rb 1,006 → 920; + check_spec_validator 169. `validate_checks!` 42 lines + `validate_argv0!` 36 + `separator?` → one object per check, every method ≤ 20 | not re-measured (no test added; lines moved) | rubocop raw 42,214 → 42,190; reek 4,480 → 4,473; new file **0** smells | **PASS** — no structural regression, zero layer violations | **all 15 check-spec messages verified byte-identical at runtime** (checks-not-mapping, bad name, check-not-mapping, unknown field, argv shape, NUL, control char, 4096 bytes, shell metacharacters, leading dash, directory, workspace-relative, dot program, shell wrapper, safety) plus valid-returns-mapping and absent-accepted. NOTE: the literal diff alone could NOT prove this slice — message construction moved into `problem`/`program_problem` helpers so the prefix cannot drift — so the runtime harness is the real evidence (kept at scratchpad/check_spec_messages.rb). One dead branch found and left alone: `argv[0] must be a program name` is unreachable through `call` because the argv shape check already requires all-strings; it stays as a defensive guard on the private method. **ci_full BOTH locales 130/24,970** | 5af810e |
| 22 | 2026-08-07 | profile.rb (Q3 slice 5, giant #2) | the tools/unattended/policy authority triad → `Profile::AuthorityValidator` | profile.rb 920 → 836; + authority_validator 187 | not re-measured (no test added; lines moved) | rubocop raw 42,190 → 42,146; reek 4,473 → 4,464; new file **0** smells | **PASS** — no structural regression, zero layer violations | **all 17 authority messages verified byte-identical at runtime**, plus tools! returning the normalized mapping, approval_required defaulting to [], absent unattended returning nil, and the optional unattended digest. **Kept THREE entry points rather than one `call`**: the loader runs `unattended!` early in validate_schema! against the RAW document while `tools!`/`policy!` run later and policy consumes tools' return — collapsing them would have changed which error an operator sees first. Two rubocop rewrites applied deliberately rather than by blanket `-A` (`all?(String)`, `intersect?`), both semantically identical for string arrays. **ci_full BOTH locales 130/24,970** | 8151cc7 |
| 23 | 2026-08-07 | profile.rb (Q3 slice 6, giant #2) | the declared sections' shape rules (profile fields, root, roots, model roles, credential refs, budgets) → `Profile::DocumentValidator` | profile.rb 836 → 737; + document_validator 220 | not re-measured (no test added; lines moved) | rubocop raw 42,146 → 42,103; reek 4,464 → 4,455; new file **0** smells | **PASS** — no structural regression, zero layer violations | **all 22 document messages verified byte-identical at runtime** plus valid-fields / absent-model_roles / absent-budgets accepted. Holds only `@path` (the one thing every refusal shares; the data is handed in already-fetched). `root!` split into spelling vs target, which named a real distinction and removed the complexity offense rather than suppressing it. **ci_full BOTH locales 130/24,970** | f91969c |
| 24 | 2026-08-07 | profile.rb (Q3 slice 7, giant #2) | the value-level content scan (denied keys, interpolation, secret material, entropy) → `Profile::ContentScanner` | profile.rb 737 → 716; + content_scanner 88 | not re-measured (no test added; lines moved) | rubocop raw 42,103 → 42,099; reek 4,455 → 4,451; new file **0** smells | **PASS** — no structural regression, zero layer violations | **all 9 content messages verified byte-identical at runtime**, plus the walk reaching nested mappings and arrays, the key path appearing in the interpolation message, arrays NOT extending the key path, every ENTROPY_EXEMPT_KEY accepted, a pure-hex digest accepted, an explicit key_path honoured, and a clean document passing. The companion pass to YamlScanner and deliberately separate: YamlScanner refuses CONSTRUCTS on the event stream before load, ContentScanner refuses CONTENT in the parsed structure. **ci_full BOTH locales 130/24,970** | e295bbd |
| 25 | 2026-08-07 | profile.rb (Q3 slice 8, giant #2) | the safe file-access layer (open_verified, verify_permissions!, verify_handle!, verify_parents!, read_bytes) → `Profile::SecureFile` | profile.rb 716 → 644; + secure_file 159 | not re-measured (no test added; lines moved) | rubocop raw 42,099 → 42,085; reek 4,451 → 4,444; new file **0** smells | **PASS** — no structural regression, zero layer violations | **all 8 secure-file messages verified byte-identical at runtime** (symlink, missing, directory, mode≠0600, oversized, non-UTF-8, world-writable parent, world-readable parent) plus the happy paths: good file verifies, handle yielded, UTF-8 text returned, `permissions: false` skipping the checks, and the descriptor closed after the block. Two genuine improvements beyond the move: `File.open` now uses the BLOCK form (same close-on-exception semantics as the manual begin/ensure, one less way to leak a descriptor), and the mode bit tests became `nobits?`/`anybits?`. NOTE: `permissions:` is a BooleanParameter that CODING_STANDARD §4 forbids; it is documented and left because its value is computed at the call site (`permissions: !suggestion`) so splitting the method would only push the conditional up — a named policy is the honest fix and is a **Q4 candidate**, not a move. **ci_full BOTH locales 130/24,970** | 4907504 |
| 26 | 2026-08-07 | profile.rb (Q3 slice 9, giant #2) | the immutable profile VALUE and its construction (`Fields` + `build_fields` → `Fields.build`) → `Profile::Fields` | profile.rb 644 → 592; + fields 103 | not re-measured (no test added; lines moved) | rubocop raw 42,085 → 42,058; reek 4,444 → 4,439; new file **0** smells | **PASS** — no structural regression, zero layer violations | **DURABLE CONTRACT PINNED BY BYTES**: the canonical digest for a fixed document is `sha256:909ef526e74ced422ce58608a81731351078e45b2a87497e58a1a0e52344a8d8` BEFORE and AFTER the extraction (harness run against a stashed HEAD, then against the working tree), plus digest stability, key-order insensitivity, content sensitivity, adoption-not-in-digest, and 22 Fields behaviours (realpath'd root, checks reduced to argv+safety, deep freeze, absent egress/unattended → nil, forbidden-wins in unattended_preauthorized, pinned honoured). `canonical_digest`/`deep_freeze` stay on Profile — they are general helpers and `Fields#initialize` calls `Profile.deep_freeze`. `pinned:`/`suggestion:` booleans documented as a **Q4 candidate** (a named provenance is the honest fix). **ci_full BOTH locales 130/24,970** | 53c9cc8 |
| 27 | 2026-08-07 | profile.rb (Q3 slice 10, giant #2) | the operator config tree and profile-path resolution → `Profile::Locations` | profile.rb 592 → 575; + locations 116 | not re-measured (no test added; lines moved) | rubocop raw 42,058 → 42,047; reek 4,439 → 4,437; new file **0** smells | **PASS** — no structural regression, zero layer violations | **all 17 location behaviours verified identical against a stashed HEAD**: the config tree (override honoured and expanded, profiles/adoption/transitions paths, EMPTY override falling through to the platform default, XDG honoured off darwin), the full precedence chain (explicit flag > TAMOZ_PROFILE > profile_id arg > TAMOZ_PROFILE_ID > nil), and resolve_explicit's three branches — including the security-relevant one, that a bare id NEVER resolves to a file in the working directory. Holds `env` because every answer is a function of it. `RUBY_PLATFORM.match?(/darwin/)` → `include?('darwin')` per Performance/StringInclude, equivalent for a literal. **ci_full BOTH locales 130/24,970** | 9078677 |
| 28 | 2026-08-07 | cli.rb (Q3 slice 5) | the `tamoz profile` subcommand → `Agent::CLIProfileCommands` | cli.rb 1,480 → 1,253; + cli_profile_commands 340. profile_activate 53 lines → 5 named steps, profile_import 42 → 3, plus the list and render splits; every method now inside the Q6 ceilings | not re-measured (no test added; lines moved) | rubocop raw 42,047 → 41,988; reek 4,437 → 4,410; new file **0** smells and ABSENT from the baseline | **PASS** — no structural regression, zero layer violations | **ci_full BOTH locales 130/24,970**. TWO MISTAKES CAUGHT, both invisible to the gates: (1) module methods are PUBLIC by default, so extracting ten private CLI methods widened the surface by ten verbs — compared against HEAD method-by-method and made the whole module private, 10/10 matching HEAD, `dispatch_subcommand` reaches `cmd_profile` by implicit receiver; (2) the quality baseline was regenerated while reek smells remained, silently ABSORBING 16 of them while the gate stayed green — the ratchet's failure mode, caught by grepping the new file's entry, then driven 16→6→4→1→absent | b3113d5 |
| 29 | 2026-08-07 | cli.rb (Q3 slice 6) | the session AUTHORITY resolver → `Agent::CLIAuthority` | cli.rb 1,253 → 1,105; + cli_authority 195 | not re-measured (no test added; lines moved) | rubocop raw 41,988 → 41,979; reek 4,410 → 4,396; new file **0** smells and ABSENT from the baseline | **PASS** — no structural regression, zero layer violations | **ci_full BOTH locales 130/24,970**. Visibility 7/7 private, matching HEAD. Puts the security asymmetry in one place: a NEW session takes authority from the loaded profile, an EXISTING one replays what its own checkpoint pinned, so editing a profile file cannot widen a session in flight. `resolve_session_authority` deliberately KEPT WHOLE with an inline disable — every split point needed the same six values as loose parameters, the failure mode documented on `consume_if_candidate!` in slice 18; the 7 repeated `profile.canonical_digest` reads were hoisted to one local instead, removing the duplication without loosening anything. Baseline regenerated LAST per the slice-28 rule, new file verified absent | 98e58ce |
| 30 | 2026-08-07 | cli.rb (Q3 slice 7) | session rendering + exit codes → `Agent::CLIRendering` | cli.rb 1,105 → 989; + cli_rendering 197 | not re-measured (no test added; lines moved) | rubocop raw 41,979 → 41,926; reek 4,396 → 4,376; new file **0** smells | **PASS** | **ci_full BOTH locales 130/24,970**. Visibility 7/7 private. **A module does not share the class's lexical scope** — the bare `EXIT_PAUSED`/`EXIT_SIGINT`/`EXIT_SIGTERM`/`THREAD_ID_PATTERN` that resolved inside `class CLI` raised NameError from the module. Thirteen tests caught it; rubocop and reek could not. Now `CLI::EXIT_PAUSED` etc. `render_final_view` and `render_show_human` split with refusal order preserved; `exit_for_view`'s duplicate branches merged (:paused/:blocked share a code, :failed was already `else`) | 51d1652 |
| 31 | 2026-08-07 | mcp/catalog.rb (Tier 1.1) | the deterministic JSON canonicalizer → `Tamoz::Mcp::CanonicalJSON` | catalog.rb 291 → 243; + canonical_json 59 | not re-measured (no test added; lines moved) | rubocop raw 41,926 → 41,923; reek 4,376 → 4,374; new file **0** smells | **PASS** | **ci_full BOTH locales 130/24,970**. FIRST slice of the easy-first queue and it validated the ordering — a fraction of the effort of a profile.rb design slice for a comparable reduction. **FINDING: CanonicalJSON never belonged to Catalog.** It is written inside `Catalog = Data.define(...) do ... end`, but constants assigned in a BLOCK belong to the enclosing lexical scope, so its name has always been `Tamoz::Mcp::CanonicalJSON` — which is why invocation.rb references it bare. Verified before moving (`Catalog.const_get(:CanonicalJSON, false)` raises NameError). CLIENT_INFO, DIGEST_DOMAIN, ENTRY_DIGEST_DOMAIN, TOOL_NAME_PATTERN and Entry sit in the same position and were left alone. normalize_object feeds a digest, so rubocop's each_with_object→to_h rewrite was checked BY BYTES: same SHA-256 `5205938d936e8c8e47978b4334dfde45b1cab4b05f80bbfe0379e3b18b6290a5` | c709ed0 |
| 32 | 2026-08-07 | graph/memory_checkpointer.rb (Tier 1.2) | the fenced write side → `MemoryCheckpointer::Writer` | memory_checkpointer.rb 318 → 250; + writer 96 | not re-measured (no test added; lines moved) | rubocop raw 41,923 → 41,918; reek 4,374 → 4,368; new file **0** smells (the parent's 27 are pre-existing debt) | **PASS** | **ci_full BOTH locales 130/24,970**. `private_constant :Writer` verified still raising NameError from outside after the move. **One rubocop finding deliberately NOT applied**: Naming/PredicateMethod wanted `def check! = true` renamed, but check! is a COMMAND in a duck-typed interface implemented by MemoryCheckpointer::Writer, SQLite::CheckpointWriter and Tamoz::Context, called as `context.check!`/`writer.check!` on adjacent lines in executor.rb — renaming would break three implementations to satisfy a naming cop. Inline disable with that reasoning at the site | 061d720 |
| 33 | 2026-08-07 | healing/classification.rb (Tier 1.3) | the proof matrix and the text-proposal adapter → `Classification::Matrix` + `Classification::LegacyTextAdapter` | classification.rb 395 → 259; + matrix 96, legacy_text_adapter 88 | not re-measured | rubocop raw 41,918 → 41,871; reek 4,368 → **4,355** (biggest single-slice drop of the easy tier); both new files **0** smells | **PASS** | **ci_full BOTH locales 130/24,970**. Constant paths verified unchanged at runtime (healing_matrix_test calls `Classification::Matrix.run` directly). **A genuine SPLIT, not a pure move** — the nested definitions carried three methods over the Q6 ceilings: `Matrix.run` (35 lines, ABC 42) → empty_tally/tally!/report + a shared `rate`; `abstention_quality` (ABC 27) → sum_field + quality with the original fetch ORDER preserved (fetch can raise, and order decides which missing key reports first); `LegacyTextAdapter#initialize` (26 lines) → validate_precision!/validate_patterns!. The (per_category, rule) DataClump was documented rather than designed away: the pair lives for exactly one `run` | 4d9c98d |
| 34 | 2026-08-07 | memory/behavior_transition.rb (Tier 2.4) | the behaviour transition registry → `Memory::TransitionRegistry` | behavior_transition.rb 487 → 172; + transition_registry 376 | not re-measured | rubocop raw 41,871 → 41,837; reek 4,355 → **4,332**; new file **0** smells and the parent fell **25 → 2** | **PASS** | **ci_full BOTH locales 130/24,970**. The survey called it a nested class; it is a SIBLING of BehaviorTransition — verified at runtime — so the file held two independent things. `record` got validate_kind!/validate_snapshot! extracted (ABC 31 → 23, 56 → 46 lines), both firing before any control state is read so a rejected snapshot never reserves a version; the remainder kept whole under §4 (one ordered transaction threading the same five values). **SURFACED A REAL FINDING** — see the owner-decision queue | 03c841c |
| 35 | 2026-08-07 | tools/skills.rb (Tier 3.1) | snapshot assembly + catalog digest → `Skills::Snapshot` | skills.rb 1,063 → 1,018; + skills/snapshot 62 | not re-measured | rubocop raw 41,837 → 41,832; reek 4,332 → 4,330; new file **0** smells (parent still carries **111**) | **PASS** | **ci_full BOTH locales 130/24,970**. First of five, smallest first so the pattern is proven before Compiler. Constant path unchanged and **public_api_test green (633 assertions)** — Skills::Compiler and Skills::Catalog are pinned in docs/public-api.json, so the paths under skills/ matter. **Empty-snapshot catalog digest byte-identical against a stashed HEAD**: `sha256:182a16f232863f7bd66e70dabb20b53bc2562762113c4acd35f78016bb6e5f3c` — that digest is what a session pins. The two 5-parameter signatures documented rather than bundled: they are the five parts a snapshot IS, and the digest is computed over exactly those five | 0e3b25c |
| 36 | 2026-08-07 | tools/skills.rb (Tier 3.2) | stage-1 progressive disclosure → `Skills::Catalog` | skills.rb 1,018 → 905; + skills/catalog 133 | not re-measured | rubocop raw 41,832 → 41,819; reek 4,330 → **4,312** (−18, against −2 for Snapshot); new file **0** smells and the parent fell **111 → 93** | **PASS** | **ci_full BOTH locales 130/24,970**. Public API: constant path unchanged, public_api_test green (633 assertions), catalog digest still `sha256:182a16f2…`, 37 adversarial tests green (catalog rendering is where a hostile skill would smuggle text). **`resolve`'s duplicated raise removed by reasoning, not by a helper**: a source-qualified id either matches exactly or has NO candidates, because only a bare name can be ambiguous — so the qualified case falls through to `when 0` and one shared message remains, with the many-candidates branch becoming `resolve_ambiguous`. `render` gained `within_budget`, whose contract is that the rendered catalog is always a PREFIX of what exists: never reordered, never a partial line | 25011d3 |

## Standing rules learned in flight (2026-08-07)

- **Regenerate the quality baseline LAST**, after reek is already 0 on the new file,
  then VERIFY the new file is absent from the **`reek.by_file`** ledger specifically —
  NOT by grepping the whole JSON. Every file legitimately appears in `loc.by_directory`,
  and a raw `grep <file> docs/code-quality-baseline.json` hit there reads as smells and
  costs a false alarm (slice 30: a "38" that was 38 lines of code).
  Regenerating while smells remain absorbs them into the baseline and the gate still
  passes — the ratchet cannot distinguish "no new smells" from "new smells baselined".
  This cost 16 absorbed smells in slice 28 before it was noticed.
- **Prefer removing a duplicate by understanding it to extracting a helper for
  it.** Slice 36's two identical raises vanished once it was clear a
  source-qualified id cannot be ambiguous, so the qualified case is simply "zero
  candidates". A helper called twice would have preserved the redundancy behind a
  name; the reasoning removed the branch and got written down instead.
- **Answering "no, this is not worth splitting" is a legitimate slice outcome.**
  Tier 2.5 asked the question before acting and the honest answer was no:
  boundary_source_audit.rb is one private unit (the module is `private_constant`, its
  only public method is a 3-line delegation, and all eleven constants are private and
  read only by `Auditor`). Splitting would have produced a 550-line file and a
  60-line stub holding one method — good line counts, bad everything else.
- **Use a quoted heredoc for commit messages, never `-m` with backticks.** The shell
  ate a word from slice 34's state commit, and the charter forbids amending.
- **Never let an autocorrect disguise a finding.** If a cop's fix would hide a
  possible bug — renaming an unused parameter, deleting a dead branch — run
  rubocop with `--except <Cop>` and document at the site instead (slice 34).
- **An extraction SURFACES the parent's baselined debt, and that is the point.**
  Read what appears with fresh eyes rather than reflexively silencing it: twice
  now it has been a real finding (slice 23's unreachable guard, slice 34's CAS).
- **A "nested" class may be a SIBLING.** Verify the constant's real parent at
  runtime before deciding what the file contains (slice 34).
- **A nested definition that carries oversized methods is a SPLIT, not a move.**
  "Nested class" predicts a CHEAP slice, not a free one. Tier 1.1 and 1.2 lifted out
  verbatim; 1.3 carried three methods over the Q6 ceilings. Budget the same for
  skills.rb's Compiler (264 lines).
- **Do not rename a method to satisfy a naming cop without checking for a duck
  type.** Grep for other implementations and call sites first; when several classes
  share the name, an inline disable naming the interface is the right answer
  (slice 32: `check!` across Writer, CheckpointWriter and Context).
- **Preserve `private_constant` across a move** and verify it still raises from
  outside afterwards; put the require above the class body so the constant exists
  by the time the `private_constant` line runs.
- **Move scripts half-apply in three distinct ways**: a stale boundary assertion,
  wiring added before the extraction succeeded, and writing into a directory that
  does not exist yet. `mkdir -p` first, assert boundaries, and on any failure
  `git checkout` the touched files and redo rather than patching forward.
- **Check where a nested constant actually LIVES before moving it.** Constants
  assigned inside a `do...end` block belong to the ENCLOSING lexical scope, not the
  class the block builds, so a definition that reads as `Outer::Inner` may really be
  `Enclosing::Inner`. Verify with `Klass.const_get(:Name, false)` and `Name.name` at
  runtime before choosing the target file (slice 31).
- **Module methods are public by default.** When extracting private methods into a
  module, compare visibility against HEAD with `public_method_defined?` /
  `private_method_defined?` and match it exactly, or the move widens the class's API.
- **Re-check assertion boundaries after any edit shifts line numbers.** Slice 29's
  first attempt asserted a stale line, so the removal no-opped while the require and
  include were already applied, breaking the load. The fix is `git checkout` the
  touched files and redo, not patch forward from a half-applied state.
- **Splitting is not always the answer.** Where every split point would force the
  same 5-6 values through loose parameters, keep the method whole and name the
  exception at the site (CODING_STANDARD §4). Precedent now in three places:
  `consume_if_candidate!` (18), `resolve_session_authority` (29), and the
  ModuleLength disables on the two CLI modules. Hoist duplicated reads into locals
  instead — that removes the real smell without loosening a contract.
- **Check the harness against HEAD before believing a diff.** Four times now a harness
  disagreement was the harness being wrong, and twice that check surfaced a real
  finding instead of a false alarm.
- **A durable-contract slice is verified by BYTES against a stashed HEAD**, with fully
  constant harness input — a temp path leaking into a digested document produced a
  false regression in slice 26.

## Owner-decision queue

- **NOTE (2026-08-07, slice 25) — a third unreachable branch, benign.** SecureFile's
  `rescue Errno::EISDIR` arm cannot fire: `open(2)` with `O_RDONLY` on a directory
  succeeds on both macOS and Linux, so the explicit `handle.stat.file?` check refuses
  the directory first (PermissionError "profile must be a regular file"). Verified
  against HEAD, which behaves identically. Recorded for completeness only — unlike the
  slice-23 finding, the protection IS achieved, just by the earlier check, so this is
  defensive redundancy like the slice-21 argv[0] branch. No decision needed.

- **OPEN (2026-08-07, slice 34) — a compare-and-swap that ignores what it compares.**
  `Memory::TransitionRegistry#cas_control(expected, replacement)` accepts `expected`
  and never reads it:

      def cas_control(expected, replacement)
        version = @store.head_version(CONTROL_NAMESPACE, CONTROL_KEY)   # re-read
        @store.put(CONTROL_NAMESPACE, CONTROL_KEY, replacement.to_h, if_version: version || nil)
      end

  The swap is guarded against the version this method RE-READS, not against the
  control record the caller already read. Between a caller's `control = read_control`
  and this re-read, another writer can change the control record and the swap will not
  detect it. All three call sites (`record`, `apply`, `release_or_finalize`) pass the
  control they read, so the intent to compare is explicit in every one.

  **Pre-existing and preserved byte-for-byte** — identical at HEAD, previously hidden
  inside this file's 25 baselined reek smells and its `.rubocop_todo.yml` exclusions.
  The extraction surfaced it. Left alone because whether the class's documented
  "singly-writer" discipline makes this safe is a concurrency-correctness question
  about a DURABLE registry, which is an owner decision, not a refactoring one.

  Note for whoever resolves it: rubocop's autocorrect renames the parameter to
  `_expected`, which silences both linters and disguises the question. Do not take it.
  If the answer is "single-writer makes it safe", the honest fix is to drop the
  parameter and say so in a comment; if not, the swap should use the caller's version.
  Either way it wants a characterization test.

- **FINDING (2026-08-07, slice 23) — a security guard that has never been able to
  fire.** `Profile::DocumentValidator#validate_root_spelling!` (was
  `Profile.validate_root!`) refuses a root that names a host implicitly:

      raise "... must not be an implicit host reference" if TIMEZONE_WORDS.include?(root.downcase)

  `TIMEZONE_WORDS` is `%w[local system host]`, but the guard immediately above it
  requires `root.start_with?(File::SEPARATOR)`. Every string that reaches the
  timezone check therefore begins with `/`, so `root.downcase` can never equal a
  bare word and the branch is **unreachable**. Verified against HEAD: the shipped
  code behaves identically (`/UTC` reports "is unavailable", not "implicit host
  reference"), so this is pre-existing and slice 23 preserved it byte-for-byte.

  Left in place deliberately — changing what a security guard rejects is a
  behaviour decision, not a refactor. It needs an OWNER decision because it is
  unlike the other dead branch found in slice 21: `argv[0] must be a program
  name` is harmless redundancy (an earlier check already covers it), whereas this
  one means the INTENDED protection is not achieved at all. Either the check
  should compare the basename / expanded final component, or the intent was
  already covered elsewhere and the guard should go with a note saying so.
  Suggest a small characterization test either way, so whatever is decided is
  pinned.

- **RESOLVED (2026-08-07) — owner chose option 2 (design out), applied in slice 18.**
  The stateless validation predicates got a home: `AdoptionDocument` and
  `TransitionDocument`, mirroring `Tamoz::SQLite::CheckpointWire` — parsed bytes in, one
  believability question out. `consume_if_candidate!` was kept whole per the paired
  recommendation (option 4 for that path): find/guard/mark/write/return is one atomic
  decision against one read, and splitting it had produced helpers that took the identity
  triple loose and made it possible to call the mark without the guard. It carries an
  inline `rubocop:disable` naming that exception at the site, per CODING_STANDARD §1.
  Result: the three extracted files went 51 → 0 reek smells and the repo ledger FELL
  (reek 4,536 → 4,494; rubocop raw 42,338 → 42,269).

  **Standing rule for the rest of the program** (do not re-decide per slice): when an
  extraction surfaces a debted file's baselined smells in its new home, design them out
  first — a stateless document/wire object is the shape this repo already uses — and
  carry a documented site-level `:reek:` disable only where the smell is irreducible
  (pure predicates, deliberate bangs, a locked critical section, a rubocop/reek conflict).
  Never add the new file to `.rubocop_todo.yml`. Regenerate the quality baseline as part
  of the slice; the drift gate will demand it. Note: `script/regenerate_quality_baseline`
  needs a UTF-8 locale — run it with `LANG=en_US.UTF-8`, or it dies on `US-ASCII`.

- ~~OPEN (2026-08-07) — how method-splitting interacts with the reek ratchet.~~ Raised by
  the profile.rb slice 1 attempt, which is IN THE WORKING TREE, UNCOMMITTED, gate red on
  reek only. What was done: `AdoptionRegistry`, `Transition`, and `TransitionRegistry`
  moved to `profile/{adoption_registry,transition,transition_registry}.rb`; profile.rb
  **1,547 → 1,222** lines; the four methods that broke Q6 ceilings in their new home
  (`consume_if_candidate!`, `validate!`, `valid_document?`, `valid_entry?`, plus
  `AdoptionRegistry#document`) split into named steps. rubocop **0**; all 113 profile
  tests green (42+24+11+15+11+10), including flock/concurrency and the v1/v2 codec.

  The measured effect on reek: profile.rb **126 → 84** (−42), new files **0 → 51**, repo
  total **4,536 → 4,545**. So the *extraction* is smell-neutral — 42 smells relocated
  with the code they describe — and the **+9 are the method splits' own**: the small
  private helpers are stateless (`UtilityFunction` ×5) and take the (profile_id, from,
  to) and (thread_id, consumed_by) clumps as parameters (`LongParameterList`,
  `DataClump`, one `TooManyStatements`).

  This is CODING_STANDARD §4 in the concrete: splitting to satisfy a line-count ceiling
  bought indirection that reek correctly flags. It will recur on every remaining
  extraction slice, so it is a program decision, not a slice decision. Options:
  1. **Suppress** — documented site-level `:reek:` disables on the 9, as slices 8–15 did
     (they carried 10–12 each). Cheapest; grows the suppression habit.
  2. **Design out** — give the stateless validation predicates a home, mirroring
     `Tamoz::SQLite::CheckpointWire` (the precedent in this repo): a small stateless
     wire/validator object per registry. Kills UtilityFunction and the clumps honestly,
     but is a second abstraction and a larger slice.
  3. **Accept the +9** and re-baseline, recording that the ratchet cannot distinguish a
     relocated smell from a new one. Honest only if the baseline note says so explicitly.
  4. **Do not split** — keep the moved methods whole, and add per-file Q6 exceptions
     naming why (the standard permits this; it is the "limits are diagnostic" clause).

  Recommendation: **2 for the validators, 4 for `consume_if_candidate!`.** The predicates
  genuinely belong to a wire object and the repo already has that shape; the consume path
  is one atomic locked read-modify-write whose cohesion is the point, and splitting it was
  the least defensible part of the attempt.

  Note for whoever resumes: the reek baseline is per-file, so ANY extraction out of a
  debted file surfaces that file's baselined smells in the new file. Whatever is chosen
  here should be written into the loop's slice recipe, not re-decided per slice.
