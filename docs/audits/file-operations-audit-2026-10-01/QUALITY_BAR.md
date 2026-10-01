# Quality bar — consolidating file writes onto `Tamoz::Core::AtomicFile`

Goal: every durable file write in a gem's `lib/` goes through `Tamoz::Core::AtomicFile`,
except the sanctioned exceptions listed in the audit README. A change is done only when
every line below holds; otherwise loop.

## Verdict on the audit's claims

All 18 sites were re-read against the code. Findings 1-12 and 14-17 are accurate and convert.
Finding 13 (`persist_health`) is rejected after review: it runs on every dropped signal on the emitter's
thread, so atomic replace would add four fsyncs exactly when the queue is full.
Finding 18 (`skill_installation.rb` scaffold/stage writes) is rejected: plain creation into
a fresh per-run directory, no mode requirement, so AtomicFile adds machinery and no property.
The "third facade method" idea (publish a staged file) is rejected: one caller (SQLite backup),
which the audit itself calls not a defect.

## Per commit (one finding each)

1. The site calls `AtomicFile.replace` / `AtomicFile.create`; no raw `File.write`/`File.rename`/
   `Tempfile`/`File.chmod` pair remains at it, and the file's mode is set by the `mode:` argument.
2. A test proves the property the conversion buys (mode from first write, no temp file left,
   or an existing file survives a failed write) and was seen failing against the old code.
3. No new comment, no compatibility shim, no handling of a case that cannot occur.
4. The site's own test file passes (`ruby -Itest test/<file>.rb`, one file per command).
5. `bundle exec rubocop` and `bundle exec reek` on the touched files add no offense versus the base commit.

## Whole series

6. `test/file_facades_boundary_test.rb` fails on a staged-and-renamed write, a hand-rolled owner-only
   directory or a `flock` under `gems/*/lib` outside `tamoz-core`'s three facades and the named exceptions
   (SQLite, log rotation, the selector-control harness, the skill directory swap).
7. `rake ci`, `rubocop`, `enola check` green; any red that predates the series is proven on a
   clean worktree of the base commit.
8. `diff_snapshot` against the pinned baseline: no new cycle, no new layer violation.
9. An independent sub-agent reviews the series; every finding is fixed or answered.
10. `.agent/rules/` records the lesson (one rule, grounded in the real seam).

## Outcome

| Finding | Result |
|---|---|
| 1 `install_profile` | `AtomicFile.replace`, 0600 |
| 2 `TransitionRegistry#write_document` | `AtomicFile.replace`; its lock moved to `FileLock` |
| 3 `AdoptionRegistry#write` | `AtomicFile.replace`; `activate` now holds a lock for its read-modify-write |
| 4 `write_migrated_config!` | `AtomicFile.replace` |
| 5 `write_default_config!` | `AtomicFile.create`, only when no config exists |
| 6 telegram `write_private` | `AtomicFile.replace`, 0600 |
| 7 harness pin | `AtomicFile.replace`, 0600 |
| 8 `SessionEffects#write_files` | `AtomicFile.replace`, `DEFAULT_MODE` |
| 9, 10 comparison report, scoreboard | `AtomicFile.replace` |
| 11 recorded web answers | `AtomicFile.replace`, `DEFAULT_MODE` |
| 12 `SearchLedger#charge!` | `AtomicFile.replace` under a `.lock` file |
| 13 `persist_health` | rejected: per-drop write on the producer's thread |
| 14-17 evals harness files | `AtomicFile.replace` |
| 18 skill scaffold/stage writes | rejected: no property gained |

Found beyond the audit: the config backup was a `cp` then `chmod` (now `AtomicFile.create`), about ten
`mkdir_p` + `chmod 0o700` pairs (now `PrivateDirectory.secure`), and three copies of the lock-file idiom
(now `FileLock.exclusive`). `test/support/openclaw_comms_runner.rb` follows the CLI it simulates.
