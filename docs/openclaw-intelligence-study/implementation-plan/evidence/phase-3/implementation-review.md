# Phase 3 implementation review

Date: 2026-08-21
Status: partial; the Phase 3 exit bar and global implementation bar are not met.

## Scope delivered

- Canonical bounded turn context is sealed by thread/request identity, ordered
  fragments, UTF-8/control-character checks, byte limits, and a digest.
- Channel transcripts are read back from the durable request inbox through
  `SessionPlanningContext#transcript_from`; they are context only and do not
  grant authority.
- Session, worker, CLI, and channel status use an allowlisted lifecycle
  projection with bounded provenance/source/effect metadata.
- Task, effect, capability, and delivery state are represented separately;
  status failures are surfaced as bounded `unavailable` records rather than
  being silently omitted.
- Added a deterministic bounded-compaction fallback that preserves the
  allowlisted authoritative frame and can retain oversized observations in the
  existing artifact-store contract when one is explicitly supplied.
- Wired bounded compaction into legacy deliberation and adaptive decision
  prompts, routed intake/review, and verification; oversized frames may use a
  journaled `context_compact` model effect and record a digest-bound compaction
  envelope in checkpoint state.
- Bounded aggregate observations, retained graph revision, separated validated
  summaries from deterministic fallback metadata, and threaded the existing
  SQLite artifact store through durable CLI and worker sessions.
- Added a hard authoritative-frame byte bound, tenant/store binding, durable
  artifact resolution coverage, effect-receipt reuse after reopen, and graph
  version 4 for the compaction state channel.
- Added scheduler status projection with schedule/occurrence/request identity,
  grant revision, authority state, pause reason, and delivery outcome; the
  worker now acknowledges and completes materialized occurrences through the
  schedule store after durable graph execution.
- Commit `211ad47` added restart-boundary coverage for compaction, delivery
  deduplication, and replayed Telegram admission, plus canonical CLI/Telegram
  identity assertions. The focused continuation package now covers 108 runs
  and 541 assertions with zero failures.
- Commit `b66be46` extends the shared durable conversation status projection
  with lifecycle phase, event kind/sequence, next action, and terminal reason;
  Telegram `/status` now exposes those semantic fields alongside task/effect/
  capability/delivery state.

## Remaining gaps

- A real `SIGKILL` injected at the exact compaction checkpoint, and a full
  composed CLI/Telegram delivery trace artifact, remain external acceptance
  work; this patch does not claim those fixtures were run.
- The status projection is semantically aligned, but a live composed Telegram
  transport trace proving every lifecycle event across a worker restart is
  still absent.
- No provider or intelligence evidence is claimed; current tests are fixture
  and durable-plumbing tests.

## Verification

Focused commands passed during this slice:

```text
/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/core_turn_context_test.rb
3 runs, 4 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_session_status_projection_test.rb
2 runs, 7 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_phase3_context_lifecycle_test.rb
13 runs, 62 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_session_adaptive_test.rb
5 runs, 42 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/comms_gateway_test.rb
13 runs, 54 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/sqlite_comms_store_test.rb
17 runs, 58 assertions, 0 failures, 0 errors, 0 skips
```

The targeted production lint command was run with `--cache false`; all changed
production files are clean. Test-file lint retains unrelated pre-existing metric
offenses in older large fixtures.

Enola post-change verification:

```text
snapshot_id: sha256:d6bad7c50338c844cdbf099bd4617161c9d5bcbba8a8112a81665bfa165a9d73
enola: 0.2.7-51-g72cd079
facts: 10324; insights: 52; files parsed: 509/551; parse errors: 0
architecture diff: PASS — no structural regression; advisory findings only
```

The focused continuation suites also passed: adaptive session (5 runs, 42
assertions), child task (6, 17), child runtime (3, 9), worker (23, 107),
schedule/status (8, 60), session kill matrix (6, 65), session (11, 73),
communications gateway (13, 54), readiness (7, 27), runner (4, 19), and
readiness CLI (1, 4). The changed production seams linted cleanly with cache
disabled.

Repository gate status:

```text
/opt/homebrew/bin/rbenv exec bundle exec rake ci
not green: design validation passed; test_parallel reported the pre-existing
documentation link failure, sandbox-restricted localhost fixture errors,
sandbox-exec unavailability, benchmark protocol drift, and existing scorecard/
approval-environment failures. No hard-zero failure was introduced by the
focused slice suites above.
```

## Claims and blind spots

The canonical context, bounded compaction, worker recovery, and exact payload
parity assertions are plumbing evidence only. A real SIGKILL at the exact
compaction checkpoint, socket-restricted cross-surface delivery, and the full
trace artifact remain unproven in this record. The
pre-existing working-tree modification to `docs/openclaw-intelligence-study/README.md`
is preserved and is not part of this slice.

## This acceptance slice

Focused additions:

```text
/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_worker_test.rb
24 runs, 114 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_cli_test.rb
33 runs, 231 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/comms_gateway_test.rb
13 runs, 55 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_phase3_context_lifecycle_test.rb
13 runs, 62 assertions, 0 failures, 0 errors, 0 skips
```

The CLI suite still prints a background lease-conflict diagnostic from an
existing paused-session drain race while exiting green; it is not introduced by
the parity assertion. No real-provider or intelligence claim is made.
