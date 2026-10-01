# File-operations audit — 2026-10-01

Repo-wide scan for raw filesystem operations that bypass `Tamoz::Core::AtomicFile`
(`gems/tamoz-core/lib/tamoz/core/atomic_file.rb`), which is the repo's one atomic
write primitive: temp file, fsync, rename-or-link, directory fsync.

Research-only. No code was changed by the audit itself; every finding below was confirmed by reading
the surrounding code, not just the scanner output. It was acted on afterwards: see
[QUALITY_BAR.md](QUALITY_BAR.md) for the verdict and outcome per finding.

## Method

- AST scan with Ripper (`Ripper.sexp`, Ruby 3.3.11) over 1,064 `.rb` files:
  `gems/`, `test/`, `script/`, and agenteval's first-party code
  (`agenteval/lib`, `adapters`, `test`, `skills`, `packs`, `subagents`,
  `memory`, `research` — `agenteval/sessions` (11.7k eval artifacts) excluded).
- The 6 extensionless executables in `bin/` were grepped separately.
- Patterns detected: `File.write/binwrite/rename/link/delete/unlink/truncate/chmod`,
  `File.open`/`open` with write or dynamic modes, instance-level
  `write/print/truncate/rename/chmod/unlink/mkpath/rmtree/open`,
  `FileUtils.*`, `Tempfile.*`, `Dir.mkdir/mktmpdir`, `Logger.new`, `CSV.*`,
  `Zlib::GzipWriter`/`Marshal`, plus `flush`/`fsync` markers to surface
  hand-rolled durability.
- Raw evidence: [inventory.json](inventory.json) (every hit with file, line, call).
  A parenthesized call is a `method_add_arg` node in Ruby 3.3's Ripper, not
  `command_call` — a scanner that only walks `command_call` sees almost nothing.

## Volume

2,606 hits total. Non-read hits by zone: repo `test/` 1,430 (fixture setup),
agenteval 85, gem-local tests 44, production `lib/` + `script/` ≈ 160. After
reading each production cluster, the real filesystem-write sites divide as below;
a large share of nominal hits are noise (`Hash#delete`, `String#delete`, console
`@out/@err` writes, and duck-typed stores that are SQLite-backed — e.g. the
stream cursor store resolves to `DurableSubscriberStore`
(`gems/tamoz-sqlite/lib/tamoz/sqlite/adapter.rb:53`), not a file).

## Findings — should use AtomicFile

### P1 — durable state rewritten in place (torn-write window)

| # | Site | What it does today | Risk |
|---|------|--------------------|------|
| 1 | `gems/tamoz-agent-cli/lib/tamoz/agent/cli_profile_commands.rb:285` (`install_profile`) | `File.open(target, WRONLY\|CREAT\|TRUNC, 0o600)` + write + chmod | The comment at 277-280 already states the intended property — "created 0600 from the first byte written", nothing unconfirmed ever lands. Only `AtomicFile.create` (link, `Errno::EEXIST` on race) delivers that property; truncating in place leaves a half-written profile on a crash. Strongest candidate in the repo. |
| 2 | `gems/tamoz-agent-profile/lib/tamoz/agent/profile/transition_registry.rb:196` (`write_document`) | `File.write` full rewrite + chmod, under `flock` on a separate `.lock` file (181) | Crash mid-write truncates the transition registry. The lock lives on its own file, so converting to `AtomicFile.replace` keeps the locking protocol intact. |
| 3 | `gems/tamoz-agent-profile/lib/tamoz/agent/profile/adoption_registry.rb:54` (`write`) | `File.write` + chmod, no lock | In-place rewrite of adoption state; the read-merge-write in `register` (42-45) is also unlocked. |
| 4 | `gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb:267` (`write_migrated_config!`) | temp + write + chmod + rename, no fsync | Hand-rolled atomic replace of the live runtime config; one fsync short of the facade. |
| 5 | `gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb:243` (`write_default_config!`) | `File.write` + chmod, guarded by `unless File.exist?` (66) | Creation-only but the guard is racy between two first runs; `AtomicFile.create` makes the race a clean `EEXIST`. |
| 6 | `gems/tamoz-agent-cli/lib/tamoz/agent/cli_telegram_commands.rb:221` (`write_private`, callers at 117, 177, 198) | `File.write` + chmod 0600 | Rewrites the runtime config, the telegram channel record (holds `credential_ref`), and the telegram profile YAML. A torn secret-bearing config bricks the gateway. |
| 7 | `gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:97` | `File.write(pin, ..., perm: 0o600)` | The `<thread>.harness.json` pin decides work routing on resume; a torn pin is caught only as a `JSON.parse` failure in `pinned_harness` (108). |
| 8 | `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:78` (`write_files`) | `File.write("#{path}.partial")` + rename, no fsync | The doc at 85-86 promises "a crash never leaves half a report"; without fsync the bytes may not survive the rename. Converting makes the existing claim true. |

### P2 — eval/benchmark artifacts; machinery duplicated from AtomicFile

| # | Site | What it does today |
|---|------|--------------------|
| 9 | `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/comparison_executor.rb:41-53` | `Tempfile.create` + write + flush + fsync + close + `File.rename` — a line-for-line duplicate of `AtomicFile.replace` minus the directory fsync. |
| 10 | `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/scoreboard.rb:525-535` | Same hand-rolled duplicate for the scoreboard document. |
| 11 | `gems/tamoz-mcp-websearch/lib/tamoz/mcp/websearch/recorded_web.rb:64` (`recorded`) | `.partial` + rename cache entries, no fsync. |
| 12 | `gems/tamoz-mcp-websearch/lib/tamoz/mcp/websearch/recorded_web.rb:21-32` (`Ledger#charge!`) | Read-modify-write **in place** under `flock`, `file.write` + `file.truncate`. A crash mid-write corrupts the spend ledger. Note: converting to `replace` changes lock semantics — rename swaps the inode out from under the flock, so the lock must move to the directory or a dedicated lock file (the pattern `transition_registry` already uses). |
| 13 | `gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb:221` (`persist_health`) | `File.write(..., mode: 'w', perm: 0o600)` health sidecar; rescue-protected but a torn health file is read by operators. |

### P3 — low stakes, optional

| # | Site | Note |
|---|------|------|
| 14 | `gems/tamoz-evals-runner/lib/tamoz/evals/harness/memory_store.rb:170` (`write_stable`) | Durable memory-store files in the harness; converting keeps the harness honest about production write semantics. |
| 15 | `gems/tamoz-evals-runner/lib/tamoz/evals/harness/heuristic_corpus.rb:110` (`write_corpus_file`) | Creation into a freshly mkdir'd tree. |
| 16 | `gems/tamoz-evals-runner/lib/tamoz/evals/harness/memory_holdout.rb:24` | Creation into a fresh `Dir.mktmpdir`. |
| 17 | `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb:110` | Creation of a uniquely-named change profile. |
| 18 | `gems/tamoz-agent-cli/lib/tamoz/agent/skill_installation.rb:20,26` | Scaffold/stage writes into fresh per-run directories. |

## Findings — correctly NOT AtomicFile (leave as-is)

- **Append-only logs.** `recorder_journal.rb:203` (`'ab'`, plus rotation renames
  at 187-197 — rotation is inherent to logs), `witness_gateway.rb:220` (`'a'`,
  signed evidence), `skill_installation.rb:41` (promotions ledger `'a'`),
  `bin/tamoz-stream-subscriber:44` (log `'a'`). Append is the right primitive
  for these; replace would be wrong.
- **SQLite owns its files.** `gems/tamoz-sqlite`: `database_file.rb` uses
  `EXCL|NOFOLLOW` creation and chmod repair (96-100, 124); `backup.rb` stages a
  temp, verifies integrity, chmods, then renames (163-170). SQLite is itself
  transactional; atomically replacing a live database file would be wrong.
  **Facade gap:** `AtomicFile.replace/create` accept in-memory bytes only — the
  backup's bytes are streamed by SQLite into an external temp file, so this site
  cannot convert without a "publish an already-staged file" facade entry point.
- **Deliberate low-level harness.** `sqlite_selector_control.rb` /
  `sqlite_selector_control_stopper.rb` (tamoz-evals-runner) implement their own
  inode layout, `sync_directory` (564-569) and fsync'd control files (150-158)
  to inject torn writes in durability benchmarks. Converting them would defeat
  their purpose.
- **Directory-level swap.** `skill_installation.rb:47-78` stages a copy, checks
  the tree digest, retires the old version, renames the directory in. That is a
  multi-file primitive AtomicFile does not cover; the digest check is the
  safety net.
- **Cleanup.** `staging_reaper.rb:32` unlinks stale staged files — complements
  AtomicFile's `.tamoz-` staging prefix.
- **Core internals.** `tamoz-core`'s only temp+rename is `atomic_file.rb` itself
  (as it should be); the remaining core hits are socket writes (`raw_http.rb:31`)
  and in-memory hash edits.
- **`script/*.rb`** (4 sites) — dev scripts generating ADR/coverage artifacts.

## Adjacent zones (out of scope for conversion)

- **`test/` (1,430 non-read hits) and gem-local tests (44)** — fixture setup;
  raw writes are fine there. Worth revisiting only `test/support/`
  (`openclaw_comms_runner.rb`, `approval_case.rb`), which hand-roll temp+rename
  to simulate the CLI — if the P1 sites convert, the simulation should follow.
- **agenteval (85 hits)** — first-party eval tooling (`research/pack.rb` 17,
  `skills/pack.rb` 16, `lib/agenteval/workspace.rb` 9, `session_chain.rb` 8,
  `trial.rb` 5); `agenteval/**` is excluded from the quality gates
  (`.rubocop.yml:22`) and ships in no gem. Separate decision, not a gem-boundary
  concern.

## Facade observations

The established seam is `Tamoz::Core::AtomicFile`, already used at
`gems/tamoz-tools/lib/tamoz/tools/creation_operations.rb:48` (`create` +
`before_publish`), `gems/tamoz-tools/lib/tamoz/tools/patch_operations.rb:67`
(`replace`), and
`gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_mission_runner.rb:529`
(`replace`). The P1/P2 sites above predate it or duplicated it locally.

Two real needs do not fit the current two-method facade: publishing an
externally-staged file (SQLite backup) and a directory-atomic swap (skill
install). Neither is a defect — but if more staged-file publishers appear, a
third facade method beats re-hand-rolling fsync at each site.

If the findings are acted on, a boundary test in the style of
`test/memory_boundary_test.rb` (fail on `File.rename`/`Tempfile` outside
`tamoz-core` and the sanctioned harnesses) would keep the property enforced.
