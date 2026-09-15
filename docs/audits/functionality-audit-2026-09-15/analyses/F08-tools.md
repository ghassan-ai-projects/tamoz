# F08 `tamoz-tools` — content never grants (proven), workspace escape is closed; the check child inherits operator secrets and user files matching the staging pattern are deleted

Row / queue / baseline (commit, date) / analyst / budget
- Row: **F08** — `tamoz-tools` — "The workspace toolbox, the skills compiler, the capability host."
- Queue: **W1B** (authority / profile / tools / MCP / capabilities), `COVERAGE.md:76`.
- Baseline: branch `audit-15-09`, HEAD `582ae55`, 2026-09-15. Analyst: independent read-only analyst (F08). Budget ~50 min, hard cap 60.

## Scope and source map

Read end to end (24 files, 3114 lines — `find gems/tamoz-tools/lib -name '*.rb' | sort`):

| File | Lines | Role |
|---|---:|---|
| `gems/tamoz-tools/lib/tamoz/tools.rb` | 22 | entry seam; rebinds `ToolError`/`ToolArgumentError`/`ToolPolicyError` to the tamoz-core classes |
| `…/tools/toolbox.rb` | 226 | public façade, constants, `execute`/`validate`/`preview`/`effect_intent`/`observe` |
| `…/tools/path_resolver.rb` | 135 | lexical + realpath containment, symlink policy, create-parent checks |
| `…/tools/tool_argument_validator.rb` | 248 | per-operation argument protocol (`VALIDATORS`) |
| `…/tools/tool_catalog.rb` | 82 | immutable policy-filtered surface + catalog/prompt-surface digests |
| `…/tools/tool_policy_normalizer.rb` | 116 | freezes operator checks/allowed_tools at construction |
| `…/tools/read_operations.rb` | 101 | `read_file`, `list_directory`, `search_text` |
| `…/tools/patch_preparation.rb` | 137 | digest verification, byte-safe replacement plan, diff render |
| `…/tools/patch_operations.rb` | 95 | atomic publish, receipt |
| `…/tools/creation_operations.rb` | 99 | no-overwrite atomic create + receipt verification |
| `…/tools/check_runner.rb` | 123 | `run_check` subprocess (argv, env, cwd, timeout, output bound) |
| `…/tools/check_receipt.rb` | 60 | immutable check result + failure signature |
| `…/tools/staging_reaper.rb` | 69 | stale `.tamoz-*.tmp` sweep |
| `…/tools/capability_host.rb` | 211 | sealed registry host, inventory projection, uniform dispatch, dispatcher binding |
| `…/tools/local_dispatcher.rb` | 67 | per-source dispatcher for `local` and `skill:<epoch>` |
| `…/tools/skills.rb` | 248 | skills module functions: resource read/verify, attributed render, limits |
| `…/tools/skills/compiler.rb` | 317 | source→snapshot compilation gauntlet |
| `…/tools/skills/walk.rb` | 192 | `Dir.children`+`lstat` canonical tree walk |
| `…/tools/skills/frontmatter.rb` | 182 | YAML frontmatter schema validation |
| `…/tools/skills/frontmatter_scanner.rb` | 85 | pre-parse Psych handler (tags/aliases/duplicate keys) |
| `…/tools/skills/catalog.rb` | 135 | stage-1 disclosure render, ambiguity resolution |
| `…/tools/skills/snapshot.rb` | 67 | snapshot assembly + catalog digest |
| `…/tools/skills/values.rb` | 90 | `SkillSource`/`SkillRecord`/`SkillSnapshot`/`Rejected` value types |
| `…/tools/version.rb` | 7 | version constant |

Also read: `gems/tamoz-tools/tamoz-tools.gemspec`; `gems/tamoz-core/lib/tamoz/core/capability/{registry,descriptor,source}.rb` (the seal F08 projects); `gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb` (admission set + descriptor construction + dispatch); `gems/tamoz-agent-session/lib/tamoz/agent/session_steps.rb`, `session_effects.rb`; `gems/tamoz-agent/lib/tamoz/agent/runtime/step_execution.rb`, `worker_runtime.rb`, `runtime_directory.rb`; `gems/tamoz-evals-runner/lib/tamoz/evals/harness/subprocess_runner.rb` (prior 051); `gems/tamoz-approval/policy/base.yaml` + `profiles/*.yaml`; `gems/tamoz-agent-kernel/lib/tamoz/agent/request_projection.rb`.

Docs read: `documentation/design/skills.md`, `documentation/architecture/security-model.md`, `documentation/architecture/invariants.md` (clauses 41–43), `documentation/limitations.md` §"Skill installation and update (invariant 43)" and §"Crash equivalence", root `README.md:69-71`.

**Entry seam.** `Tamoz::Tools::Toolbox#validate` → `#execute` (`toolbox.rb:113-129`) is the only effector surface; `CapabilityHost` (`capability_host.rb:31-36`, `147-172`) is the sealed registry that routes the same call through per-source dispatchers. `README.md:69-71` claims both the seal and "content never grants"; this report is the source-grounded verdict on that claim.

## Behavior path

1. **Construction.** `Toolbox#initialize` (`toolbox.rb:48-74`) realpaths the root, freezes it, validates options, builds `Skills::Catalog`, builds `ToolCatalog` (policy-filtered surface + `catalog_digest` + `prompt_surface_digest`), builds the argument validator, and — only when `allow_changes` — sweeps stale staging files (`toolbox.rb:71`). `ToolCatalog#initialize` (`tool_catalog.rb:32-51`) runs `ToolPolicyNormalizer`, which freezes `checks`, `check_safeties`, `allowed_tools` (`tool_policy_normalizer.rb:19-27`).
2. **Sealing.** `CapabilityBinding#build_host` (`capability_binding.rb:302-306`) constructs `Tamoz::Tools::CapabilityHost.new(sources:, admission_set:)`; `CapabilityHost#initialize` calls `Tamoz::Core::Capability::Registry.build` (`capability_host.rb:32-34`), which `enforce_built_in_sources!`, `enforce_descriptor_ownership!`, then computes `surface` = descriptors ∩ admission set and freezes it (`registry.rb:22-35`, `114-122`).
3. **Dispatch.** `CapabilityHost#route` → `descriptor, dispatcher` (`capability_host.rb:147-157`), then `dispatcher.validate` / `dispatcher.execute` (`:162-172`); the local dispatcher forwards by the descriptor's id to the toolbox (`local_dispatcher.rb:33-41`), so the toolbox stays the single implementation.
4. **Reading.** `read_file` resolves via `PathResolver#resolve` (realpath containment) and bounds at 64 KiB (`read_operations.rb:19-33`); `list_directory`/`search_text` bound entries/results (`:35-56`).
5. **Mutating.** `step_execution.rb:277-290` / `session_effects.rb:300-327` resolve an absent `expected_sha256` once, at step entry, from `Toolbox.observe` (a realpath-following `Digest::SHA256` of the current bytes, `toolbox.rb:79-88`); the resolved arguments feed the approval preview (`step_execution.rb:128`), the intent record (`session_effects.rb:292-296`) and the execution, and `PatchPreparation#prepare` re-reads the file and re-verifies the digest immediately before publishing (`patch_preparation.rb:17-36`, `64-72`).
6. **Publishing.** `PatchOperations#atomic_replace` stages into `Tempfile.new(['.tamoz-', '.tmp'], dirname)`, fsyncs, chmods to the target mode, renames, fsyncs the directory (`patch_operations.rb:68-85`); `CreationOperations#atomic_create` stages into `.tamoz-create-*.tmp` and publishes with `File.link` (never `rename`), so an existing target is `EEXIST` (`creation_operations.rb:48-75`).
7. **Checks.** `CheckRunner#run` → `Open3.popen3(credential_free_env, *argv, chdir: root, pgroup: true)` with bounded readers and a timeout that escalates TERM→KILL on the process group (`check_runner.rb:37-119`).
8. **Skills.** `Skills::Compiler#compile` → per source `source_root`/`source_children`, then per child `validate_skill_directory!` → `Walk` → `require_manifest!` → `compile_manifest` → `validate_compiled_manifest!` → `build_record` (`compiler.rb:35-43`, `66-114`); `Snapshot.build` freezes records/collisions/rejections and computes `catalog_digest`/`epoch` (`snapshot.rb:29-63`). The record is consumed only by `Catalog#render` (catalog text), `Skills.render_load`, and `Skills.render_resource` (`skills.rb:200-230`).

## Lens: correctness

**Verified.**
- The `Toolbox` public contract (validate → execute → bytes) is exercised at 62 runs / 323 assertions / 0 failures (`test/agent_toolbox_test.rb`), including every patch rejection leaving the target byte-identical (`:177`) and every create_file rejection leaving the workspace byte-identical (`:1325`).
- The digest/apply contract is coherent end to end: `PatchPreparation#verify_digest` compares the SHA-256 of the bytes it just read against `expected_sha256` and raises `ToolPolicyError` on mismatch (`patch_preparation.rb:64-72`); `after_content` is derived from that same `content` (`:25`), and `PatchOperations#apply` publishes exactly `patch.fetch(:after_content)` and then computes `after_digest = Digest::SHA256.hexdigest(patch.fetch(:after_content))` from the identical frozen string (`patch_operations.rb:21-23`) — there is no re-read between the diff, the digest, and the write.
- `apply_patch` is atomic: stage + `fsync` + `chmod` + `fsync` + `File.rename` + directory `fsync` (`patch_operations.rb:68-85`); no partial target state is observable.
- `create_file` cannot overwrite — `File.link` fails `EEXIST` (`creation_operations.rb:61-64`) — and the receipt re-reads the published file and compares it against the approved digest, raising `ToolError, 'created file did not verify'` on divergence (`:83-95`).
- Replay/resume: a skill content swap changes `tree_digest` → `catalog_digest` → `epoch`, and a durable resume against a changed catalog raises `SkillSnapshotUnavailableError` on `continue`/`resume`/`recover` (`test/agent_skills_toolbox_test.rb:315-364`).
- **Prior 044 re-verified, current:** the A-20 hostile-tree test now compiles `clean` and `hostile` from genuinely different trees and asserts `refute_equal clean.epoch, hostile.epoch` first (`test/agent_skills_adversarial_test.rb:279-313`). What a hostile skills tree actually does to the compiler today: the injected body is stored verbatim in `record.body` and rendered inside the attribution fence; `before.names == after.names`, `before.catalog_digest == after.catalog_digest`, and both `validate("shell", …)` and `execute("read_file", "path" => "/etc/passwd")` still raise `ToolError`. The `catalog_digest` equality is a real claim, not a tautology: `ToolCatalog#initialize` hashes only `allowed_tools`, description keys/bytes, and check names/safeties/argv (`tool_catalog.rb:44-49`); the skill body never enters it. Status: **carried forward `done`, still correct.**
- Domain-knowledge check (B9 / P4 gate-4): `find gems/tamoz-tools/lib -name '*.rb'` contains **zero** diagnosis catalogs, operator prompts, intent/risk tables, compensation maps, watch rules, or fixture responses. The only literal string tables are the tool-description catalog (`tool_catalog.rb:13-26`), the check-environment pattern/name lists (`check_runner.rb:13-15`), and the closed `INVENTORY_REASONS` enum (`capability_host.rb:25-29`) — model-facing surface text, secret classification, and a closed protocol enum respectively, none of which is domain content (`test/fixtures/domains/` holds `aquaculture/climate/cold-chain/shipment/thermal-lab.json` for the benchmark domains, which this gem never reads). **No B9 violation.**

**Not evidenced:** no test asserts that a concurrent `apply_patch` from a *second process* between the digest observation and the write is refused; the in-process `File.rename` atomicity plus the re-verified digest (`patch_preparation.rb:64-72`) make the window small, but a two-process interleaving is unproven.

## Lens: security and authority

**Proven — "content never grants" is true at this gem.**

- *No content-to-source path exists.* `Capability::Source` requires `descriptors.all? { |d| d.is_a?(Descriptor) }` and `Descriptor#initialize` requires every policy field explicitly (`source.rb:22-24`; `descriptor.rb:144-153`). Nothing in `tamoz-tools` constructs a `Descriptor` at all — `grep -rn "Descriptor.new" gems/tamoz-tools/lib` returns nothing; descriptors are built only in `capability_binding.rb:228` and `:319`, both from operator policy.
- *The seal is an immutable snapshot, not a re-read.* `Registry#build` computes `surface` once, freezes it, and stores `sources`/`names`/`declared` frozen (`registry.rb:26-34`). `Registry#register` unconditionally raises `DescriptorConflictError` ("the capability registry is sealed", `:52-56`), `Registry.new` is private (`:62-64`), and `enforce_built_in_sources!` rejects any source id outside `local`/`skill:`/`mcp:`/`websearch:` (`:72-83`, `139-145`). `CapabilityHost#bind_dispatcher` refuses an unregistered source and refuses **rebinding** an already-bound source (`capability_host.rb:110-124`), so execution code cannot be swapped under a published capability.
- *Skill content reaches nothing that decides.* `requested_capabilities` is `list.uniq.sort`, stored in `SkillRecord#requested_capabilities` (`frontmatter.rb:136-144`, `compiler.rb:190`) and consumed only by `Skills.render_load`, which prints it and intersects it with `toolbox.names` **for display** (`skills.rb:198-216`). `declared_risk` is stored as `metadata['tamoz.risk']` and printed labelled "author-declared; not a Tamoz classification" (`compiler.rb:187`, `skills.rb:210`); there is no unqualified `risk` reader (`test/agent_skills_adversarial_test.rb:325-346` asserts `refute record.respond_to?(:risk)`). `allowed-tools: [shell, apply_patch, rm, sudo]` leaves `toolbox.names == %w[read_file list_directory search_text]` and `action_capable? == false` (`test/agent_skills_adversarial_test.rb:256-275`).
- *No authority is added to the admission set by content.* `admission_set` is `@toolbox.allowed_tools + [child_task] + @mcp.names` (`capability_binding.rb:165-169`), and `Toolbox#allowed_tools` is the frozen normalizer output derived from operator policy only (`tool_policy_normalizer.rb:92-98`). A skill snapshot never reaches it — the `skills:` constructor argument only changes `ToolCatalog`'s *description* table and `available_tools` (`tool_catalog.rb:33-35`, `59-70`), i.e. the rendered catalogue, never the admission set.
- *Skills cannot enter a profile-bound session.* The durable worker builds its profile toolbox without `skills:` (`worker_runtime.rb:1195-1207`) and `test/agent_skills_toolbox_test.rb:124-137` asserts a profile-bound toolbox exposes neither skill tool, with `catalog_digest == PRE_P9_READ_ONLY_DIGEST`.
- *Workspace skills cannot be written by the agent.* `RuntimeDirectory#skills_root` refuses any skills root inside the workspace (`runtime_directory.rb:151-166`).

**Workspace escape — every path-taking tool traced; no reachable escape found.**
`PathResolver#resolve` lexically cleans and rejects escape (`:89-105`), then `realpath`s and rejects realpath escape (`:60-72`, `107-111`); `resolve_without_symlinks` additionally demands `lexical.to_s == path.to_s` (`:32-34`) and is what `apply_patch` uses (`patch_preparation.rb:52-54`). Absolute paths and NUL bytes are refused up front (`:36-43`), `MAX_PATH_BYTES` 4096 bounds the input. `create_file` additionally refuses `.`/trailing-slash shapes, rejects an existing target, validates the parent, and re-validates the parent after staging (`creation_operations.rb:77-81`) before `File.link`.
- `..` — impossible: cleanpath + prefix check, and `Walk` never sees `.`/`..` (`Dir.children`).
- absolute — refused (`path_resolver.rb:95-99`).
- symlink — refused for reads that leave the root (`reject_realpath_escape!`) and refused outright for the patch path (`resolve_without_symlinks`); `test/agent_toolbox_test.rb:100-121` covers a symlinked target and `:1022` a symlinked parent. In-root symlinked directories are followed but still realpath-checked (`:107-111`), so they cannot leave the root; verified by probe — `read_file`/`list_directory` through a link to an outside file/directory raise `ToolPolicyError: path escapes the workspace root`.
- hardlink — nothing prevents reading a hardlinked inode inside the root, but a hardlink *to* outside content requires the outside content to already be linked into the workspace by a party that already has both, which is not a containment break the resolver can see; the skills compiler refuses it explicitly (`walk.rb:115-118`, `skill_hardlink_rejected`).
- TOCTOU — the residual window is on the intermediate component of the patch path; the compiler documents and defends the equivalent window with a pinned digest (`skills.rb:100-108`), and `PatchPreparation` re-reads and re-verifies immediately before publishing (`patch_preparation.rb:21-22`).
- argument the model controls — `ToolArgumentValidator#reject_unknown!` refuses unknown keys per tool (`tool_argument_validator.rb:240-245`); `run_check` accepts only `{"name": <configured>}` (`:144-151`), so the model cannot supply a program or argv.

**Not evidenced (proved absent, recorded as limitation):** the intermediate-component symlink swap between `resolve` and `File.rename` in `apply_patch` (`patch_operations.rb:68-85`) has no lstat/fstat guard; see **F08-REL-01**.

**Critical.** *The `run_check` child inherits operator secrets.* See **F08-SEC-01** — reproduced: a child sees `TAMOZ_SIGNING_KEY`.

## Lens: reliability and durability

- Patch publication is crash-safe at the file level (fsync of the temp file, chmod, rename, directory fsync) and the temp file is unlinked in an `ensure` (`patch_operations.rb:80-82`).
- The staging sweep is real and matches the documented contract: `StagingReaper` removes only regular files matching `/\A\.tamoz-(?:create-)?[A-Za-z0-9_.-]+\.tmp\z/`, owned by `Process.uid`, `mtime` older than 60 s, never following a symlink, skipping `.git`/`vendor`/`node_modules`, capped at 200 files (`staging_reaper.rb:13-16`, `23-65`); it runs only at action-capable construction (`toolbox.rb:71`). `documentation/limitations.md:213-215` ("the next action-capable session sweeps files older than 60 seconds") is **accurate**, and a probe confirmed real `Tempfile` stage names match the pattern.
- Though the sweep is real, it deletes files it does not own. See **F08-REL-02**.
- Check execution terminates a hostile child: TERM to the process group, 1 s join, KILL, join (`check_runner.rb:97-119`), with an `ESRCH`/`ECHILD`/`SystemCallError` fallback to a direct PID kill. `test/agent_toolbox_test.rb:264-284` covers a TERM-trapping child.
- **Prior 051 re-verified, current source:** `subprocess_runner.rb` is still 616 lines and the three SIZE findings are still present verbatim — `execute` spans `:166-218` (spawn → reader threads → wait/intervention arbitration → result assembly, plus rescue/ensure), `wait_for_child` `:273-306` and `escalate_termination` `:307-348` exceed 30 lines, and `normalize_text` still takes the boolean `allow_empty:` (`:575`). **Confirmed, status `todo` unchanged; this is a size/maintainability item with no behavioral consequence found.**
- **Correction to the brief's premise:** `gems/tamoz-tools` has no `subprocess_runner.rb`. Its subprocess seam is `check_runner.rb` (123 lines), which is *smaller and stricter* than the eval harness runner — array-form `Open3.popen3` (no shell), credential-stripped env, `chdir` to the workspace root, `pgroup: true`, a bounded reader per stream, and TERM→KILL escalation. The 616-line SIZE finding belongs to `tamoz-evals-runner` (F27), not F08.

## Lens: observability and evidence

- `CheckReceipt` is an immutable, frozen data value carrying `name`/`outcome`/`stdout`/`stderr`, a stable `failure_signature` over ANSI-stripped, CRLF-normalized, rstripped output (`check_receipt.rb:11-57`), and a `to_s` rendering consumed as the model-facing tool result.
- `Toolbox#effect_intent` produces the `before_state`/`after_digest`/`after_mode` triple that the durable intent records and the reconciler read (`toolbox.rb:131-146`; `session_records.rb:206-220`); `EffectDispatcher.reconcile_filesystem` proves completion only from the checkpointed digests, never from live state (`effect_dispatcher.rb:288-318`).
- `CapabilityHost#inventory` is a pure projection over the complete control-plane gate vector, with a closed `INVENTORY_REASONS` vocabulary and the rule that a source-contributed reason outside the enum degrades to `invalid_configuration` (`capability_host.rb:47-98`, `177-200`) — so a source cannot invent an evidence label.
- `Toolbox#observe` returns stable states `absent` / `not_a_regular_file` / `symlink` / `<sha256>` + `mode` / `unreadable` (`toolbox.rb:79-88`), which is what both the reconciliation and the before-state guard key on.
- `StagingReaper#reap` returns the relative paths it removed and `Toolbox#reaped_staging` exposes them (`staging_reaper.rb:23-36`, `toolbox.rb:71`); the sweep is therefore visible, not silent.
- `patch_operations.rb:52-66` emits a `replacement_digest` over the canonical JSON of `{byte_start, byte_end, before, after}` for compound patches, so the applied edit is reproducible from evidence.
- Not evidenced: nothing records `apply_patch`'s *content* digest into an observability signal inside this gem; the digest travels in the returned receipt string only. What would prove it: a session-level assertion that the `tool_completed` observation carries `before_sha256`/`after_sha256` — `step_execution.rb:80-97` currently records only `output` and the `check` sub-hash.

## Lens: scalability and resource bounds

Every tool has an explicit bound, and they are enforced by construction rather than by convention:

| Bound | Value | Seam |
|---|---:|---|
| `MAX_FILE_BYTES` (read, patch, create) | 64 KiB | `toolbox.rb:26`; checked at `read_operations.rb:21`, `patch_preparation.rb:19`, `tool_argument_validator.rb:206` |
| `MAX_PATCH_BYTES` per before/after text | 64 KiB | `toolbox.rb:31` |
| `MAX_REPLACEMENTS` | 32 | `toolbox.rb:27` |
| `MAX_DIRECTORY_ENTRIES` | 200 | `toolbox.rb:28` |
| `MAX_SEARCH_FILES` / `MAX_SEARCH_RESULTS` | 2000 / 100 | `toolbox.rb:29-30` |
| `MAX_CHECK_OUTPUT_BYTES` | 64 KiB (32 KiB per stream) | `check_runner.rb:63` |
| `check_timeout` | numeric, `0 < t ≤ 600` | `toolbox.rb:192-194` |
| `PathResolver::MAX_PATH_BYTES` | 4096 | `path_resolver.rb:20` |
| Skills: sources/skills/manifest/frontmatter/body/description/resource/tree/entries/depth | 8 / 64 / 64 KiB / 8 KiB / 16 KiB / 1 KiB / 256 KiB / 2 MiB / 512 / 8 | `skills.rb:67-84` |
| Catalog render budget | 4096 bytes, prefix-only truncation | `catalog.rb:67-91` |
| Reaper | 200 files, 60 s floor | `staging_reaper.rb:15-16` |

`Skills::Catalog#within_budget` stops at the first line that would exceed the budget and never partially renders a line (`catalog.rb:85-91`), so what the model sees is always a prefix of what exists. `ReadOperations#search_text` breaks at `MAX_SEARCH_RESULTS` and carries `remaining:` into the per-file scan (`read_operations.rb:48-56`, `85-98`). A check that produces gigabytes is bounded by the 32 KiB-per-stream reader plus the timeout plus the group kill (`check_runner.rb:63-95`).

Two gaps: the `MAX_FILES` head in `StagingReaper#stale_files` can starve unreached subtrees (see **F08-REL-03**), and no bound caps the *number* of `run_check` invocations per session inside this gem — that is a session-level budget (`session_steps.rb:93-98` bounds observation *bytes*, not call count).

## Lens: maintenance and architecture

- **Dependency direction is honest and narrow.** `tamoz-tools.gemspec` depends only on `tamoz-cancellation` and `tamoz-core`; `tools.rb:3-9` requires exactly those two plus local files. `Tamoz::Core::ToolError` is rebound, not re-defined (`tools.rb:18-20`), and `test/p16_tools_gem_test.rb:254-291` proves the aliases are object-identical.
- **The capability host adds no authority of its own.** `LocalDispatcher` is documented as forwarding every call to the toolbox by the descriptor's id and is stateless apart from its toolbox (`local_dispatcher.rb:17-30`); `CapabilityHost#route`'s unknown-id message is deliberately `Toolbox#validate`'s byte-for-byte, because the text feeds the planning prompt (`capability_host.rb:149-153`).
- **Ownership is explicit.** `PathResolver` owns containment; `ToolCatalog` owns the policy surface and its digests; `ToolPolicyNormalizer` owns freezing policy; `Walk` owns tree traversal; `Compiler` owns the compile gauntlet; `StagingReaper` owns deletion. No class duplicates another's capability.
- **Public surface is narrow.** `Toolbox` exposes 12 public methods; everything else is `private` or a collaborator. The three Reek suppressions are annotated with the *reason* (`path_resolver.rb:10-18`, `toolbox.rb:21-24`), not blanket-silenced.
- Debt: `read_only_names` duplicates part of `ToolCatalog`'s availability computation (`toolbox.rb:94-98` vs `tool_catalog.rb:33-35`); `Toolbox` re-exports five `CheckRunner`/`StagingReaper` constants (`toolbox.rb:40-44`) purely so `tamoz-agent` does not have to name the collaborators; `Skills::LIMITS` mixes `max_sources`/`max_skills_per_source` (compiler policy) with per-file byte caps (walk policy). All three are minor and bounded.

## Tests and contracts

All commands one file per command, `ruby -Itest test/<file>.rb`, run from the repo root with `PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`.

| Command | Runs | Assertions | Failures |
|---|---:|---:|---:|
| `ruby -Itest test/agent_toolbox_test.rb` | 62 | 323 | 0 |
| `ruby -Itest test/agent_skills_test.rb` | 18 | 96 | 0 |
| `ruby -Itest test/agent_skills_adversarial_test.rb` | 37 | 249 | 0 |
| `ruby -Itest test/agent_skills_toolbox_test.rb` | 18 | 152 | 0 |
| `ruby -Itest test/agent_tool_error_recovery_test.rb` | 13 | 116 | 0 |
| `ruby -Itest test/subprocess_runner_test.rb` | 16 | 128 | 0 |
| `ruby -Itest test/p16_tools_gem_test.rb` | 15 | 129 | 0 |
| `ruby -Itest test/toolbox_staging_reaper_test.rb` | 10 | 33 | 0 |
| `ruby -Itest test/capability_host_test.rb` | 21 | 91 | 0 |
| `ruby -Itest test/capability_registry_test.rb` | 9 | 28 | 0 |
| `ruby -Itest test/capability_closed_world_test.rb` | 3 | 14 | 0 |
| `ruby -Itest test/capability_inventory_test.rb` | 3 | 18 | 0 |

Total: **225 runs / 1377 assertions / 0 failures / 0 errors / 0 skips.** `rake ci` / `rake ci_full` deliberately `not run` (brief forbids them).

Targeted probes run from `/tmp` (no repo scratch files): a credential-leak probe (`TAMOZ_DATABASE_PASSWORD` stripped, `TAMOZ_SIGNING_KEY` **inherited** by the child), a `Tempfile`-name vs `STAGING_PATTERN` probe (both real stage names match), a sweep probe (a stale `mode 0755` user file named `.tamoz-notes.tmp` was **deleted**), and a symlink-escape probe (`link.txt` → outside file and `linkdir` → outside directory both raise `ToolPolicyError: path escapes the workspace root`).

Not found: `test/skill_binding_contract_test.rb` does not exist.

## Findings

### F08-SEC-01 — the `run_check` child inherits operator credentials it does not name

- **Severity:** critical. **Confidence:** high. **Status:** open.
- **Observable behavior at risk.** `CheckRunner.execute` passes `self.class.credential_free_env` as the child's *complete* environment (`check_runner.rb:60`), but that hash is a redaction list, not a scrubber: `credential_free_env` sets a value to `nil` **only** for names where `credential_env?` returns true (`:17-19`). In Ruby's `spawn`, a hash value of `nil` unsets that variable and every name absent from the hash is inherited normally. Any credential-shaped-by-neither-list nor -pattern variable therefore reaches the child — and the child's stdout is captured into the check receipt, the model prompt, streams, and the durable log (the very reason invariant 24 exists). Reproduced: with `TAMOZ_DATABASE_PASSWORD` and `TAMOZ_SIGNING_KEY` exported, the child printed `["TAMOZ_SIGNING_KEY"]`; `credential_free_env` kept `TAMOZ_DATABASE_PASSWORD` (correctly nil-ed) and did not mention the signing key at all.
- **Owning seam.** `CheckRunner.credential_free_env` / `ENV_PATTERN` / `ENV_NAMES` (`gems/tamoz-tools/lib/tamoz/tools/check_runner.rb:13-24`), consumed at `:60`.
- **Source evidence.** `check_runner.rb:13-15` (the pattern requires a `_`-delimited suffix from a fixed list, or an exact match in a 13-name list), `:17-19` (`redactions[name] = nil if credential_env?(name)`), `:60` (`Open3.popen3(self.class.credential_free_env, *argv, …)`); `toolbox.rb:40-41`, `:76-77` re-export both. The named list covers only `AWS_*` and `*_API_KEY` for eight providers (`:14-15`).
- **Test/contract evidence.** `ruby -Itest test/agent_toolbox_test.rb` → 62 runs / 0F, but the only environment test uses a name the pattern happens to cover: `TAMOZ_TEST_API_KEY` (`test/agent_toolbox_test.rb:286-304`), and `test_credential_env_classification` asserts only the covered direction (`:306-315`). No test asserts that a secret *not* named `*_API_KEY`/`*_SECRET*`/`*_PASSWORD` is withheld. No test asserts a child's total environment — only `ENV.key?` for two names.
- **Scanner signal.** `grep -rn "credential_free_env\|ENV_PATTERN" gems/tamoz-tools/lib` — single definition, single call site.
- **Independent judgment.** Confirmed by direct execution, not by reading alone. The classification is a deny-list (`credential_env?`), while the code and the doc comment ("a credential-free environment", `check_runner.rb:8`) read as an allow-list. Full-env inheritance is a defensible design for a general subprocess runner — `tamoz-evals-runner`'s `SubprocessRunner` does it correctly with an explicit `environment:` hash plus `unsetenv_others: true` (`subprocess_runner.rb:222-233`) — but `run_check` is the model's effector with operator-only argv, and `SECURITY.md`'s claim that "the model … can never alter its … environment" is only true for the *program*, not for what the child can read.
- **Root cause (five whys).**
  1. Why does the child see operator secrets? Because the spawn environment is the ambient `ENV` minus matched names.
  2. Why is it not a scrubber? Because `credential_free_env` redacts by *matching a pattern* rather than constructing an allow-list.
  3. Why is a pattern considered sufficient? Because the pattern was written against the provider key names the project itself uses (`ENV_NAMES`, `check_runner.rb:14-15`).
  4. Why is that a defect rather than a design? Because the operator, not the project, decides what marks a secret (`TAMOZ_SIGNING_KEY`, `GH_TOKEN`, `TAMOZ_SMTP_URL`, `NPM_TOKEN`, `*_DSN`, base64 blobs in `TAMOZ_*`), and the environment is the agent's own process — it holds everything the CLI was launched with.
  5. Why does no test catch it? Because the one environment test picks a name inside the pattern, so the classification's completeness is never exercised.
  The contract that would prevent recurrence is an explicit statement of which variables a configured check is allowed to receive; the current one is an implicit "everything except these".
- **Recommendation (smallest action at the existing seam).** Keep the deny-list, and make the child's environment the *intersection* rather than the complement: have `ToolPolicyNormalizer#normalize_check` accept an optional per-check `env` allow-list that is merged onto a minimal base (`PATH`, `HOME`, `LANG`, `TMPDIR`), and pass that hash to `Open3.popen3` with `unsetenv_others: true`. That is one keyword on the existing normalized check value plus one spawn option — no new class. Failing that, widen `ENV_NAMES` and `ENV_PATTERN` to cover `*_KEY`, `*_TOKEN`, `*_DSN`, `*_URL`, and any `TAMOZ_*` not on an explicit non-secret list. Either way, add one test that exports a secret name outside the current pattern and asserts the child cannot see it.
- **Disposition.** Open, pending coordinator decision. This is not CF05-SEC-01 (that is profile-to-MCP admission); it is a distinct environment-inheritance defect inside F08's own subprocess seam. If the coordinator rules that a configured check is trusted operator code and inheriting the operator's environment is intentional, this drops to `minor`/documentation — but the current code, comment, and security-model wording all claim otherwise.

### F08-REL-01 — the staging sweep deletes user files that match the reserved name shape

- **Severity:** major. **Confidence:** high. **Status:** open.
- **Observable behavior at risk.** `StagingReaper` unlinks any **regular file** under the workspace root whose basename matches `/\A\.tamoz-(?:create-)?[A-Za-z0-9_.-]+\.tmp\z/`, is owned by `Process.uid`, and is at least 60 s old (`staging_reaper.rb:13-16`, `62-63`), with no marker distinguishing a file *this system staged* from a file that merely has that name. Reproduced: after planting a stale `mode 0755` file named `.tamoz-notes.tmp` in a fresh workspace and constructing `Toolbox.new(root:, allow_changes: true)`, the file was deleted and reported in `reaped_staging`. The documented contract is "a **private** `.tamoz-*.tmp` staging file" (`documentation/limitations.md:213`), and the test suite's own comment says the sweep must be "narrow enough that a symlink wearing the name survives" (`docs/GAUNTLET_PROGRESS.md:1812`) — but ownership and age are the only narrowing rules, and both are satisfied by an ordinary user file that happens to use the prefix.
- **Owning seam.** `StagingReaper#collect` / `PATTERN` (`gems/tamoz-tools/lib/tamoz/tools/staging_reaper.rb:13-16`, `57-65`).
- **Source evidence.** `staging_reaper.rb:13` (pattern), `:62` (`stat.file? && PATTERN.match?(path.basename.to_s) && stat.uid == Process.uid && now - stat.mtime >= older_than`), `:29` (`File.unlink`); `toolbox.rb:71` (runs automatically at action-capable construction); `patch_operations.rb:70` and `creation_operations.rb:53` (the only legitimate producers, both via `Tempfile`, so the name shape is the sole signature of provenance).
- **Test/contract evidence.** `ruby -Itest test/toolbox_staging_reaper_test.rb` → 10 runs / 33 assertions / 0F. `test_the_sweep_refuses_everything_that_is_not_its_own_staging_file` (`:72-97`) plants a `notes.tmp`, a `.tamoz-abc123.tmp.bak`, a `.tamozzz.tmp`, a directory, and a symlink wearing the name — every one is a near-miss of the *pattern*, none is a pattern match that is not a staging file. The narrowing rules proven are pattern-shape, symlink-refusal, uid, age, and directory type; provenance is never asserted. No test asserts that a same-named regular file the system did not create survives.
- **Scanner signal.** `grep -rn "\.tamoz-" documentation/ docs/*.md` — five documents describe the orphan as "private" staging; none defines a provenance marker.
- **Independent judgment.** Confirmed by execution. The blast radius is narrow (dotfile, `.tmp`, 60 s old, uid-matched, action-capable session) and the reaper is genuinely careful about symlinks, directories, ignored trees, and volume. But this is the one place in the gem that *deletes* files in the operator's workspace, the narrowing rules are documented as complete, and they are not: age + uid + name-shape is not provenance. The pre-existing test comment ("everything that is not its own staging file") overstates what is proven.
- **Root cause (five whys).**
  1. Why can a user file be deleted? Because the sweep's only identity test is a filename pattern.
  2. Why is a filename pattern the identity test? Because `Tempfile`-staged files carry no marker beyond their name.
  3. Why was no marker added? Because the reaper was scoped to the pre-existing `.tamoz-*` seam and the name shape inherited from the publishing code was treated as sufficient.
  4. Why is that insufficient? Because the workspace is the operator's, `.tamoz-` is not an enforced reserved namespace, and nothing prevents a user or another tool from writing such a name.
  5. Why does no test catch it? Because every refusal test plants a *near-miss* rather than a *match that is not ours*.
  The contract that would prevent recurrence: a file is sweepable only if it is provably a staging artifact this system created.
- **Recommendation (smallest action at the existing seam).** Add one predicate to `StagingReaper#collect` that strengthens identity without new machinery: accept only names produced by `Tempfile` — i.e. require the `PID` and random-suffix shape `\A\.tamoz-(?:create-)?\d{8}-\d+-[a-z0-9]+\.tmp\z` (both real stage names observed in the probe match: `.tamoz-20260915-78979-onmqo0.tmp`, `.tamoz-create-20260915-78979-uc6hoz.tmp`), and add `&& stat.mode & 0o600 == 0o600`-style owner-only permission to the predicate. Then add the missing test: plant a `.tamoz-notes.tmp` regular file at the same age and assert it survives. Marking the intent in the *file mode* (the staging `Tempfile` is created `0600` before `chmod`, `patch_operations.rb:70-75`) is the cheapest provenance signal available at this seam.
- **Disposition.** Open. `documentation/limitations.md` should stop calling the file "private" until provenance is enforced.

### F08-REL-02 — the sweep's `MAX_FILES` head can starve an orphan indefinitely

- **Severity:** minor. **Confidence:** high. **Status:** open.
- **Observable behavior at risk.** `StagingReaper#stale_files` walks with `Find.find`, appends matches in traversal order, and `break`s once `found.length >= MAX_FILES` (200) (`staging_reaper.rb:40-51`); `reap` then unlinks at most the first 200 in that same order (`:23-36`). Because traversal order is depth-first and stable, a workspace that permanently holds 200 stale matching files earlier in the walk order will never reach an orphan that sorts later — the same fixed-window starvation shape the coordinator already recorded as F07-REL-01 for the request inbox.
- **Owning seam.** `StagingReaper#stale_files` (`gems/tamoz-tools/lib/tamoz/tools/staging_reaper.rb:38-51`).
- **Source evidence.** `staging_reaper.rb:44` (`break if found.length >= MAX_FILES`), `:26` (`break if removed.length >= MAX_FILES`), `:48` (`found.sort_by(&:to_s)` — the sort happens *after* the break, so it orders the already-truncated window, it does not widen it).
- **Test/contract evidence.** `test_the_sweep_is_bounded` (`test/toolbox_staging_reaper_test.rb:137-…`) asserts only that the number removed is bounded by `MAX_REAPED_STAGING_FILES`; `not found`: no test asserts that an orphan beyond the window is eventually swept. Command: `ruby -Itest test/toolbox_staging_reaper_test.rb` → 10 runs / 0F.
- **Scanner signal.** `grep -rn "MAX_FILES\|break if found.length" gems/tamoz-tools/lib`.
- **Independent judgment.** Confirmed by reading; I did not construct the 200-file fixture. The consequence is bounded (leftover state, not corruption), it requires a workspace holding ≥200 stale matching files, and the reaper is best-effort housekeeping by design — hence minor, not major. It is still a real liveness hole of the same family as F07-REL-01 and it is undocumented.
- **Root cause.** A bounded *scan window* was chosen to cap cost, but the bound was placed on the candidate list rather than on the unlink count, so the window is not rotated across sessions.
- **Recommendation.** Cheapest fix at the seam: drop the `break` at `staging_reaper.rb:44` and let `reap` enforce `MAX_FILES` on removal while `stale_files` returns sorted results — `MAX_FILES` then bounds *deletions per session*, which is the property the test actually claims, at the cost of a full walk (already bounded by the workspace's entry count and the ignored-directory prunes).
- **Disposition.** Open, minor; coordinator may reasonably defer as a documented limitation instead.

### F08-SEC-02 — the `apply_patch` publication renames onto a path with no lstat/fstat guard (intermediate-component TOCTOU)

- **Severity:** minor. **Confidence:** medium. **Status:** open.
- **Observable behavior at risk.** `PatchPreparation#resolve` calls `resolve_without_symlinks`, which realpath-checks the target and every intermediate component (`path_resolver.rb:32-34`, `60-72`); but the actual `File.rename` happens later, in `PatchOperations#atomic_replace` (`patch_operations.rb:78`), on `path` — the `Pathname` object resolved earlier. No `lstat`/`fstat` re-check or `O_NOFOLLOW` is applied at publication time, so a concurrent process that replaces an *intermediate* directory component with a symlink in that window causes the rename to land at the symlink's target. (The *final* component is safe in the common case: `File.rename` replaces a symlink rather than following it.) Impact is the same class the resolver already refuses.
- **Owning seam.** `PatchOperations#atomic_replace` (`gems/tamoz-tools/lib/tamoz/tools/patch_operations.rb:68-85`), with the check owned by `PathResolver#resolve_without_symlinks` (`path_resolver.rb:32-34`).
- **Source evidence.** `patch_preparation.rb:52-54` (resolve), `patch_operations.rb:21-22` (prepare then publish — no re-resolve), `:69` (`path.stat.mode` — an fstat on the target path, not a component re-check), `:78` (`File.rename(temporary.path, path.to_s)`). Contrast `CreationOperations#revalidate_parent` (`creation_operations.rb:77-81`), which *does* re-check the parent inside the publication window — so the create path has the defence the patch path lacks.
- **Test/contract evidence.** `test/agent_toolbox_test.rb:100-121` (symlinked target refused), `:1022` (symlinked parent refused for `create_file`), `:177` (every rejection leaves the target byte-identical). `not found`: no test swaps a component between resolve and rename. Command: `ruby -Itest test/agent_toolbox_test.rb` → 62 runs / 0F.
- **Scanner signal.** `grep -rn "lstat\|NOFOLLOW\|realpath" gems/tamoz-tools/lib` — `NOFOLLOW` appears only in the skills path (`skills.rb:144`, `walk.rb:132`), never in `patch_operations.rb`.
- **Independent judgment.** The window is small (microseconds between `path.stat` and `File.rename`) and requires a concurrent local process attacking the workspace, which is at the edge of the threat model for a local-operator tool. What makes it a finding rather than a non-issue is that the *sibling* publication path already implements the re-check (`creation_operations.rb:80`), so the property is achievable at this seam and simply absent here — and the compiler spells out the equivalent window and its defence (`skills.rb:100-108`), so the reasoning exists in the codebase.
- **Root cause.** The digest is re-verified after the last filesystem read (`patch_preparation.rb:22`, `64-72`) but the *path topology* is not re-verified after the last filesystem read, because `atomic_replace` receives a resolved `Pathname` rather than the raw argument.
- **Recommendation.** Reuse the existing defence: call `toolbox.__send__(:validate_create_path!…)`'s sibling — i.e. re-run `parent.realpath.to_s == parent.to_s` on `path.dirname` inside `atomic_replace` immediately before `File.rename`, exactly as `CreationOperations#revalidate_parent` does. One extra call, no new machinery.
- **Disposition.** Open, minor; coordinator may defer as a documented TOCTOU boundary.

### F08-MNT-01 — the check `ENV_PATTERN` deny-list is the single point of failure for invariant 24

- **Severity:** minor. **Confidence:** high. **Status:** open (boundary evidence for F08-SEC-01).
- **Observable behavior at risk.** The `run_check` child's environment is derived from a hardcoded regex plus a 13-name list (`check_runner.rb:13-15`). Any credential whose name does not contain one of the enumerated tokens is inherited. This is recorded separately from F08-SEC-01 because it is the maintainability seam: the pattern is duplicated in intent (not in code) with `Tamoz::Core::SECRET_VALUE_PATTERNS` (`tamoz-core/lib/tamoz/core.rb:47-52`), which classifies secrets *by value* for durable records — two independent, differently-shaped secret taxonomies that can drift apart with no test binding them.
- **Owning seam.** `CheckRunner::ENV_PATTERN` / `ENV_NAMES` (`check_runner.rb:13-15`).
- **Source evidence.** `check_runner.rb:13-15`, `:21-24`; `tamoz-core/lib/tamoz/core.rb:47-52`, `:129-140`; `toolbox.rb:40-41`.
- **Test/contract evidence.** `test/agent_toolbox_test.rb:306-315` asserts only positive/negative classification for five names. `not found`: no test asserts the two taxonomies agree, and no test enumerates the operator's realistic secret names.
- **Scanner signal.** `grep -rn "ENV_PATTERN\|SECRET_VALUE_PATTERNS" gems/`.
- **Independent judgment.** Confirmed. Recorded as minor because it is a testability/ownership gap, not itself an unsafe action; its consequence is F08-SEC-01.
- **Root cause.** Secret classification was implemented twice, for two different purposes, at two different times, with no binding contract between them.
- **Recommendation.** Add one test that asserts the property rather than the list: for a set of representative operator secret names, `credential_env?(name)` is true — and, where a value crosses a durable boundary, `Core.secret_shaped?` is applicable. No production change required beyond F08-SEC-01's recommendation.
- **Disposition.** Open, minor; keep as supporting evidence for F08-SEC-01 rather than an independent action item.

### Carried forward (verified against current source, not re-litigated)

- **Top-100 044** — `test/agent_skills_adversarial_test.rb`, `done`. **Still resolved.** A-20 compiles `clean` and `hostile` from different trees, asserts `refute_equal clean.epoch, hostile.epoch` first (`:300-302`), and the surviving `catalog_digest` equality is a real claim because `ToolCatalog#initialize` hashes only the tool surface (`tool_catalog.rb:44-49`). What a hostile tree does today: body stored verbatim and fenced (asserted at `:298-299`), surface, digest and read-only set unchanged, `validate("shell")` and `execute("read_file", "/etc/passwd")` still raise. Command: `ruby -Itest test/agent_skills_adversarial_test.rb` → 37 runs / 249 assertions / 0F.
- **Top-100 051** — `subprocess_runner.rb`, `todo`, SIZE. **Confirmed, unchanged**; see the reliability lens. **Premise correction:** the file is `gems/tamoz-evals-runner/lib/tamoz/evals/harness/subprocess_runner.rb` (616 lines), not a `tamoz-tools` file. F08's own subprocess seam is the much smaller and stricter `check_runner.rb`.
- **Top-100 004** — `test/agent_toolbox_test.rb`, `done` (public preview/execute/bytes contract). **Still resolved**; the suite is 1359 lines, 62 runs, 0F.
- **CF05-SEC-01** (major/contract, open; `analyses/mcp-profile-admission.md`). **F08's verdict on the half it owns: "content never grants" is TRUE and proven at this gem.** Every grant input is operator policy frozen at construction (`tool_policy_normalizer.rb:19-27`, `94-98`); the registry's admission set is computed once and the surface frozen (`registry.rb:26-34`, `114-122`); `register` always raises and `new` is private (`:52-64`); dispatcher rebinding is refused (`capability_host.rb:110-124`); skill `allowed-tools`, `metadata`, `tamoz.risk`, body and resources reach only the render functions and the digest inputs (`skills.rb:198-230`, `compiler.rb:178-199`); a profile-bound toolbox exposes no skill tool at all (`test/agent_skills_toolbox_test.rb:124-137`). The conflicting description CF05-SEC-01 found lives in the MCP admission surface (`capability_binding.rb:165-169`), not in the content-to-authority path this row owns — F08 neither confirms nor extends it.

## Blind spots

- **Concurrent multi-process publication** was not exercised. The digest/rename contract was traced and unit-verified, but no probe ran two writers against one target; F08-SEC-02's severity rests on reading, not on a reproduced race (`medium` confidence).
- **`Tamoz::Agent::Profile` / authority roots** were read only as far as the toolbox binding (`runtime_directory.rb:151-166`, `worker_runtime.rb:1195-1207`). What a profile can and cannot widen is F21's row; the profile↔toolbox digest binding (`session_options.rb:143-165`) was read for context, not audited.
- **MCP and websearch descriptors** are constructed outside this gem (`capability_binding.rb:222-248`) and were read only to establish that F08's admission set is a pure input. CF05-SEC-01 owns that boundary.
- **`tamoz-evals-runner`'s `SubprocessRunner` callers** (the three harness adapters) were not audited; F27 owns that row. Only the runner itself was read, to re-verify prior 051 and to compare its environment handling with `check_runner.rb`.
- **Stream/`tamoz-stream` capability host** (`gems/tamoz-stream/lib/tamoz/stream/capability_host.rb`) is a different class with the same name in another gem; it was not read and is not part of F08.
- **No soak or load evidence** exists for `MAX_SEARCH_FILES`/`MAX_SEARCH_RESULTS`/`MAX_DIRECTORY_ENTRIES` on a genuinely large workspace; the bounds were verified as code, not as measured behaviour.
- **`documentation/design/skills.md:75`** describes a full staged supply-chain promotion workflow (quarantine, provenance, atomic activation, uninstall tombstone) that `documentation/limitations.md:88-94` explicitly disclaims as not implemented. The two documents disagree; I read the limitations text as the accurate one and did not treat the design text as a contract F08 fails — but the coordinator may want a documentation finding for the design page's completeness claim.

## Verdict

**IMPROVE** — per `BAR.md`: one accepted `critical` (F08-SEC-01), one accepted `major` (F08-REL-01), two `minor` (F08-REL-02, F08-SEC-02) and one `minor` supporting item (F08-MNT-01); counts `critical=1, major=1, minor=3, info=0`.

All six lenses reviewed with source citations. The row's flagship claim — **"content never grants"** — is **true and proven**: the seal is an immutable snapshot, not a re-read, and no skill, catalog, or workspace content reaches authority, effect class, or approval verdict at this seam. The workspace-escape lens is **closed**: every path-taking tool was traced through `..`, absolute paths, symlinks, hardlinks, and the create/patch publication windows, with no reachable escape found. The two open defects are elsewhere in the row: the `run_check` child's environment inherits operator secrets the deny-list does not name, and the staging sweep deletes regular user files that merely match the reserved name shape.
