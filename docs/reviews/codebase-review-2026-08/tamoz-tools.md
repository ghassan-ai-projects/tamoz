# Codebase Review — gems/tamoz-tools

*12-agent codebase review, 2026-08. See [INDEX.md](INDEX.md). Scope: full gem (13 files, ~2,730 LOC) plus `.rubocop_todo.yml` entries and the test surface (`test/agent_toolbox_test.rb`, `agent_skills_*_test.rb`, `toolbox_staging_reaper_test.rb`, `p16_tools_gem_test.rb`, `capability_host_test.rb`).*

## Overall assessment

The security-relevant code (path resolution, TOCTOU handling, credential scrubbing, staging reaper) is careful and well-commented, and the boundary work is genuinely good: error taxonomy homed in tamoz-core with constant rebindings (`tools.rb:17-19`), `Toolbox.observe` homed so the agent's effect machinery delegates down (`toolbox.rb:166-170`), `CapabilityHost`/`LocalDispatcher` give the host zero authority. The structural debt is concentrated exactly where `.rubocop_todo.yml` says it is — `Toolbox`'s size, one suppressed duplicate-method defect, and a handful of stale namespace strings. Test surface looks proportionate; no obvious untested critical path found (`CheckReceipt#failure_signature` and `to_s` would be worth confirming — flagged as unverified by the reviewer).

## High

### H1 — `Toolbox` is a god class, 4.6× the repo ceiling

`gems/tamoz-tools/lib/tamoz/tools/toolbox.rb:15` is 1,166 lines and carries ~20 per-file excludes in `.rubocop_todo.yml` (Metrics, Lint, Style cops). It mixes policy (approvals, admission), path security (`resolve`), filesystem writes (`atomic_replace`/`atomic_create`), process orchestration (`run_check`), staging reaping, digest identity, and rendering. §2's "a file growing past ~250 lines is a signal to extract a responsibility" applies in full.

**Fix:** extract at minimum `PathResolver` (resolve/validate_path_argument!/validate_create_path!), `AtomicWriter` (atomic_replace/atomic_create/fsync_directory/revalidate_parent!), `CheckRunner` (run_check/read_bounded/terminate_group), and `StagingReaper` (reap_stale_staging/stale_staging_files) — all are already cohesive private clusters.

### H2 — Suppressed real defect: duplicate `allowed_tools` definition

`toolbox.rb:67` declares `attr_reader :allowed_tools` and `toolbox.rb:190` re-defines `def allowed_tools`. RuboCop's `Lint/DuplicateMethods` offense is hidden in `.rubocop_todo.yml:661-663` instead of being fixed; the attr_reader line is dead code.

**Fix:** drop `:allowed_tools` from the attr_reader list (and `:skill_catalog`, whose use pattern is worth double-checking) and remove the todo entry.

### H3 — Mutable global memoization in `Snapshot.empty`

`gems/tamoz-tools/lib/tamoz/tools/skills/snapshot.rb:20`: `@empty ||= Compiler.new(sources: []).compile` on a module singleton. Violates §5 "no hidden global state: explicit collaborators over memoized globals", and it is not thread-safe (two threads can compile twice; harmless here only because the result is frozen).

**Fix:** compute it in a frozen constant (`EMPTY = Compiler.new(sources: []).compile`) or pass the empty snapshot explicitly.

## Medium

### M1 — Stale `Tamoz::Agent::Skills` namespace in error messages

Three raise sites still name the pre-P16 home:

- `toolbox.rb:90` — `"skills must be a Tamoz::Agent::Skills::SkillSnapshot"`
- `gems/tamoz-tools/lib/tamoz/tools/skills/values.rb:49` — `"sources must be an Array of Tamoz::Agent::Skills::SkillSource"`
- `gems/tamoz-tools/lib/tamoz/tools/skills/catalog.rb:19` — `"catalog requires a Tamoz::Agent::Skills::SkillSnapshot"`

§7 says error message bytes are pinned contracts, so these may be intentionally frozen — but a message that names a class that does not exist misleads anyone debugging a constructor failure.

**Fix:** if tests pin these bytes, change them deliberately with a migration note; otherwise correct to `Tamoz::Tools::Skills::*`.

### M2 — Duplicated traversal + ignore policy

`Toolbox#stale_staging_files` (`toolbox.rb:503-531`) and `#searchable_files` (`toolbox.rb:1089-1103`) re-implement the same `Find.find` walk with the same symlink pruning, the same hard-coded ignore list `%w[.git vendor node_modules]`, and the same bounded-collect pattern. The ignore list is also the only place a third traversal would drift.

**Fix:** extract a private `walk_workspace(base) { |path, stat| ... }` with the prune policy in one constant.

### M3 — `validate` is a ~120-line case with mixed responsibilities

`toolbox.rb:246-370`: per-tool argument validation (eight tools), digest *resolution* (`create_file` recomputes and injects `expected_sha256`, lines 347-365), and a filesystem read (`Skills.read_resource_entry!`, line 336) all live in one method. The `create_file` digest injection means `validate` mutates semantics — it is part `validate_*`, part `resolve_*` (§3.1 verb discipline).

**Fix:** split per-tool validators into named methods and move the digest resolution into a `resolve_create_digest` step the caller invokes explicitly.

### M4 — `initialize` ~80 lines of sequential policy wiring

`toolbox.rb:70-146`: constructor validates, builds the available/allowed sets, renders descriptions, computes two digests, and runs the staging reaper (a filesystem side effect in a constructor). The reaper side effect is documented (P15-C) but a constructor that deletes files is surprising; §6.2 would put this behind an explicit call.

**Fix:** extract `build_surface` (descriptions/digests) and consider `Toolbox.reap_staging(root)` as a separate step the session calls.

### M5 — Public helpers on `Catalog` that read as internal

`gems/tamoz-tools/lib/tamoz/tools/skills/catalog.rb:50-91`: `resolve_ambiguous`, `unknown_skill`, and `within_budget` are public but are steps of `resolve`/`render`. §6 (narrow public APIs) and §11 (`# :nodoc:` for internals) apply.

**Fix:** make them private or mark `:nodoc:`.

### M6 — `CapabilityHost#dispatch` re-raise style

`gems/tamoz-tools/lib/tamoz/tools/capability_host.rb:98-103`: `rescue Tamoz::Error, Tamoz::Core::ToolError => error; raise error` — since `ToolError = Tamoz::Core::ToolError` and `Tamoz::Error` is presumably its ancestor, the first rescue may be redundant, and `raise error` (vs bare `raise`) is non-idiomatic.

**Fix:** collapse to one ancestor rescue with bare `raise`, and confirm `Tamoz::Core::ToolError < Tamoz::Error` so the pair can't drift.

### M7 — `atomic_replace` cleanup condition is unreadable

`toolbox.rb:999`: `temporary.close! unless temporary.closed? && !File.exist?(temporary.path)`. Double negation guarding resource release; also an extra `File.exist?` syscall per patch.

**Fix:** replace with a `begin/rescue SystemCallError` around `close!` (the same idiom already used at `toolbox.rb:848-852` in `atomic_create` — the two writers disagree on style, which is itself the smell).

## Low

- **L1 — Magic numbers in `maximum_effect_output_bytes`.** `toolbox.rb:237-244`: `6 * 1024` appears twice unnamed, and `MAX_CHECK_OUTPUT_BYTES + 1024` embeds an unexplained slack. **Fix:** name `MAX_PATCH_RECEIPT_BYTES = 6 * 1024` and comment the 1 KiB overhead.
- **L2 — Two `verify_realpath!` calls bracketing the read.** `gems/tamoz-tools/lib/tamoz/tools/skills.rb:138-160`: deliberate TOCTOU narrowing (commented), fine as-is, but the second call's reason is only a one-liner; given §11's "why comments earn their place", this is the model case and could carry the full threat note.
- **L3 — Mixed quote style.** `check_receipt.rb` and the `skills/*` files use single quotes; `toolbox.rb` uses double. Harmless if RuboCop's `Style/StringLiterals` is permissive, but inconsistent within one gem.
- **L4 — `FrontmatterScanner` uses `define_method(:alias)`.** `frontmatter_scanner.rb:37-39`: `alias` can't be a `def` name, so this is forced; a one-line comment saying *why* define_method is used would save the next reader a double-take.
- **L5 — `LocalDispatcher#execute` accepts `context: nil` it ignores.** `local_dispatcher.rb:39-41`: documented (uniform protocol), but the keyword default `nil` vs the host's `context: {}` default (`capability_host.rb:94`) disagree; align the defaults so the protocol has one spelling.

## Gem-boundary assessment

The only boundary dirt is *textual*: the stale `Tamoz::Agent::Skills` strings in M1 — evidence the P16 move didn't sweep messages. The skills subsystem (~1,000 LOC across 8 files, self-contained, depends only on tamoz-core) is a plausible future `tamoz-skills` gem, but §6.2's "two real consumers" bar isn't met today; keep it, note it.
