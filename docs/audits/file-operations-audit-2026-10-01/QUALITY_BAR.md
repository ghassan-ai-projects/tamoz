# Quality bar — consolidating file writes onto `Tamoz::Core::AtomicFile`

Goal: every durable file write in a gem's `lib/` goes through `Tamoz::Core::AtomicFile`,
except the sanctioned exceptions listed in the audit README. A change is done only when
every line below holds; otherwise loop.

## Verdict on the audit's claims

All 18 sites were re-read against the code. Findings 1-17 are accurate and convert.
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
5. `bundle exec rubocop` on the touched files adds no offense versus HEAD.

## Whole series

6. A boundary test fails on `File.rename`, `File.link` or `Tempfile` under `gems/*/lib`
   outside `tamoz-core` and the named exceptions (SQLite backup/database file, selector-control
   benchmark harness, skill directory swap, staging reaper).
7. `rake ci`, `rubocop`, `enola check` green; any red that predates the series is proven on a
   clean worktree of the base commit.
8. `diff_snapshot` against the pinned baseline: no new cycle, no new layer violation.
9. An independent sub-agent reviews the series; every finding is fixed or answered.
10. `.agent/rules/` records the lesson (one rule, grounded in the real seam).
