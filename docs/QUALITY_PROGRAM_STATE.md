# Quality Program — Live State

**Charter:** [`QUALITY_PROGRAM.md`](QUALITY_PROGRAM.md)
**This file is the single resume point.** Every session starts here. Update it at the end of
every slice and whenever the phase table changes.

---

## Checkpoint

- **Date:** 2026-08-07
- **HEAD:** `8151cc7` (main) — "Q3 profile.rb slice 5: extract the tools/unattended/policy authority triad"
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

## Owner-decision queue

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
