# Codebase Review — gems/tamoz-sqlite

*12-agent codebase review, 2026-08. See [INDEX.md](INDEX.md). The reviewer read every file in `gems/tamoz-sqlite/lib` (9.5k lines) plus the gemspec, entrypoint, and the test inventory; the test suite was not run.*

## Overall assessment

Error taxonomy (`error.rb`, `exception_mapper.rb`) is clean and pinned; `ConnectionPool`, `DatabaseKernel`, and `LeaseGuard` handle fork-safety, deadlines, and `rescue Exception` exactly per §7 with inline disables; `Limits` is a model `Data.define` with full validation; test coverage is broad (25 sqlite test files including crash-recovery, boundary-registry, and determinism probes). The main structural debts are the migrator version-gap bug, CheckpointStore's size, the `__send__` privacy theater, and the clock-inconsistency outliers.

## High

### H1 — In-place upgrades from schema versions 2/3/4 are unreachable

`migrator.rb:645-653`. `migrate!` handles `when 0` and `when 1`, and every other version falls into `else → verify_connection!`, which requires `version == CURRENT_VERSION` and raises `MigrationError` for 2/3/4 instead of applying pending migrations. With `CURRENT_VERSION = 5` and comments documenting 1→2 and 4→5 transitions, any database created at versions 2–4 can never migrate forward.

**Fix:** apply migrations for any `version < CURRENT_VERSION` after verifying existing checksum rows (generalize the `when 1` branch), and add a migration test seeded at versions 2–4.

### H2 — `StreamStore` raises `Tamoz::Scheduler::StoreConflictError`

`stream_store.rb:53`. A stream deployment conflict surfaces a scheduler error identity across gem domains; stream callers have no reason to rescue a scheduler class.

**Fix:** raise a `Tamoz::Stream::StoreConflictError` (or shared core conflict error) and keep the scheduler error at `schedule_store.rb` sites only where the scheduler store is actually involved.

### H3 — `notifier` is a dead collaborator with a mutable-global default

`adapter.rb:51,65`. It is validated (`respond_to?(:instrument)`) and stored but never called anywhere in the gem (grep confirms zero uses). The default `Tamoz.configuration.notifier` is ambient global state (§5) buying nothing.

**Fix:** either wire instrumentation into `DatabaseKernel`/`Transaction` or delete the parameter entirely.

### H4 — `checkpoint_store.rb` (1759 lines) is a god class

It owns checkpoint commit/history/prune, the request inbox state machine (enqueue/claim/recover/transitions/terminal-fail), pending-activation persistence, and — plainly misplaced — `effect_census` (`checkpoint_store.rb:446`), a read-only audit over `tamoz_effects`/`tamoz_effect_attempts`, which is EffectJournal's domain.

**Fix:** extract a `RequestInbox` class (the request methods share `REQUEST_SELECT`, `request_row`, `append_request_transition!`) and move `effect_census` to `EffectJournal` or a standalone `EffectCensus` query object.

## Medium

### M1 — ~50 `adapter.__send__(:read/:transaction/…)` calls across 10 files

e.g. `checkpoint_store.rb:47`, `effect_journal.rb:88-96`, `lease.rb:46`, reaching `read`/`transaction`/`backend_time`/`validate_lease_in_transaction!`. The Adapter's `private` is fictional; every collaborator reaches through it with `__send__`, defeating encapsulation while pretending to keep it.

**Fix:** make `read`/`transaction` public `# :nodoc:` (or a documented internal `Kernel`-facing module) and drop the `__send__` ritual.

### M2 — `effect_journal.rb:925-944` duplicates CheckpointWire's enum guards

`enum_text!`/`checked_symbol!` are byte-for-byte the same logic as `CheckpointWire#enum_text`/`persisted_enum_symbol` (`checkpoint_wire.rb:24-37`). Also `TERMINAL_ATTEMPT_STATUSES` (`effect_journal.rb:16`) is frozen but never used — `materialize` re-lists the literal at line 875.

**Fix:** move both guards onto `Wire` (or a shared enum helper) and use the constant or delete it.

### M3 — `migrator.rb:724-732` duplicates `Wire::BACKEND_TIME_SQL` (`wire.rb:13`)

Two spellings of the same millisecond-clock SQL; drift here silently desynchronizes migration timestamps from backend time.

**Fix:** reference `Wire::BACKEND_TIME_SQL`.

### M4 — N+1 query in `pending_outcomes`

`checkpoint_store.rb:1596-1631`. One `checkpoint.pending_writes` read transaction per activation row, each opening its own pooled connection checkout.

**Fix:** single JOIN over `tamoz_pending_activations` × `tamoz_pending_writes` grouped by task.

### M5 — Dead code in `stream_store.rb:34-37`

`now = 0` + `_ = now` with a comment explaining nothing uses it.

**Fix:** delete; if "deployment is metadata, no clock" is a real invariant, say it in one comment.

### M6 — Wall-clock `Time.now` in durable records

`adapter.rb:225`, `schedule_store.rb:615-616` while the rest of the gem enforces `backend_time` SQL and clock-rollback guards (`lease_operations.rb:206-221`). `BackupReport.created_at_ms` and schedule timestamps silently follow wall time.

**Fix:** route through the backend-time SQL for consistency, or document why these two fields are deliberately wall-clock.

### M7 — `deletion.rb:54` uses `JSON` without `require "json"`

Relying on require order in `tamoz/sqlite.rb`; same file defines three constants (`DeletionAuthorization`, `DeletionReport`, `DeletionReceipt`), violating §2 one-constant-per-file.

**Fix:** add the require and split the two plain `Data.define` reports into their own files.

### M8 — `lease.rb:73-90` — renewal loop swallows non-fatal errors silently

Only `FatalRuntimeFailure` is recorded; a `StandardError` from the SQLite driver inside `renew_lease` would kill the thread with `report_on_exception = false` and leave the writer renewing nothing.

**Fix:** rescue `StandardError`, store it in `@error`, and stop — fail closed like the fatal path.

## Low

- **L1 — Entrypoint hand-lists 25 `require_relative`s** (`tamoz/sqlite.rb:7-32`) instead of Zeitwerk autoloading (§2: "entrypoints stay thin: load the namespace, let Zeitwerk resolve the rest"). Every new file needs a manual, order-sensitive edit (the `deletion.rb` JSON issue above is a symptom). **Fix:** use the Zeitwerk setup the other gems use, with `Wire`/collapsing inflection as needed.
- **L2 — `store.rb:275-283` — `materialize` sniffs row shape by length** (`row.length == 7 ? 1 : 0`) to handle two SELECT column orderings. Positional-index decoding is already the gem's most error-prone idiom (rows addressed by bare `fetch(N)` throughout); the length-sniff makes it worse. **Fix:** give each query one canonical column list or return the key column consistently.
- **L3 — `wire.rb:88-98` — hand-rolled `secure_compare` exits early on length mismatch** and reimplements what `OpenSSL.fixed_length_secure_compare`/`Rack::Utils.secure_compare` do; also not constant-time across the length check. Digests are not secret-bearing here so impact is low, but stdlib `openssl` is already a transitive dep. **Fix:** use `OpenSSL.fixed_length_secure_compare` or document why the manual loop exists.
- **L4 — `boundary_source_audit.rb` (614 lines, Ripper-based static analyzer) ships in the production gem** but is exercised only from tests (`test/sqlite_boundary_source_audit_test.rb` et al. via `const_get`). It's build-time verification tooling carrying `ripper` into every downstream load. **Fix:** move to `test/support` or dev tooling; if it must stay in the gem (fault-injection charter), that decision deserves a note in the gemspec/README.
- **L5 — `checkpoint_wire.rb:39-43` — `request_status` duplicates `persisted_enum_symbol`** with a worse error path (single quotes vs the shared helper); `enum_text` also re-appears in EffectJournal. Same consolidation as M2 above.
- **L6 — Gem-boundary observation (not a defect):** `tamoz-sqlite` runtime-depends on `tamoz-graph`, `tamoz-scheduler`, and `tamoz-stream` (gemspec:12-14) and reaches into their internals (`include Tamoz::Scheduler::ScheduleStore`, `Tamoz::Core.canonical`, `Tamoz::Graph::CheckpointCodec` type checks). This inverts the usual "domain depends on persistence" direction and makes sqlite un-loadable without the full domain stack; the dependency-isolation test apparently permits it, but it's the likeliest future cycle source — worth a comment in `test/dependency_isolation_test.rb` stating why sqlite→scheduler/stream is allowed (the stores implement their contracts).
