# Audit 016 — `gems/tamoz-stream/lib/tamoz/stream/situation_request.rb`

Rank 16 · 976 lines · 2026-09-11 · **Verdict: IMPROVE** (2 major, 2 minor) · Bar fails: PLACE, FX, ERR, SIZE

Careful admission and receipt verification, but EpisodeRunner folds six concerns into one class and
stamps a nondeterministic clock into a stream the contract claims replays digest-identically.

## Findings

- **[major][PLACE]** EpisodeRunner (~600 lines) folds admission, stream lifecycle, checkpoint reads,
  verification-row writes, wire-event verification/emission, and artifact retention into one class.
  Owning seams: retention on the artifact-store seam, the wire projection in its own class.
  (situation_request.rb:368-974, 526-537, 803-867)
- **[major][FX]** `emit_model_part` stamps `emitted_at` from
  `Process.clock_gettime(CLOCK_MONOTONIC)` while the emit contract (649-656) claims replay is
  "ordinal- and digest-identical" — a nondeterministic field inside a claimed-deterministic wire
  stream. Derive it from the journaled receipt timestamps.
  (situation_request.rb:649-656, 728-740)
- **[minor][ERR]** `EpisodeRequestInvalidError` (a request-validation type) is raised for
  server-side terminal-state inconsistencies in `translate_decision` and
  `validate_terminal_memory_consistency!`. Owning seam: a typed stream-state error.
  (situation_request.rb:580-585, 781-790)
- **[minor][SIZE]** `EpisodeRunner#initialize` takes 6 collaborators; the optional stores
  (verification/artifact/tenant/episode_tools) should ride one wiring value.
  (situation_request.rb:378-388)

## Resolution — 2026-09-12 (round 5)

- **[major][FX] FIXED** — `emitted_at` is no longer a live clock read. The wire projection
  (`EpisodeModelEventProjection`, extracted below) derives the stamp from the journal record the
  receipt was just verified against: the succeeded attempt's durable `completed_at_ms / 1000.0`
  (`EffectAttempt#completed_at_ms`, written by the effect completion/reconciler). A replay reads
  the same journal rows, so the projected `StreamPart`s are identical — type, data, and stamp.
  Proof: `test/stream_episode_replay_test.rb#test_gate2_wire_projection_is_replay_identical_including_stamps`
  projects the receipts of a fresh run and a provider-disabled fence+1 replay and asserts equal
  part arrays, then asserts `part.emitted_at == succeeded_attempt.completed_at_ms / 1000.0`
  directly against the journal row. The old code cannot pass this gate (its stamp was a fresh
  `CLOCK_MONOTONIC` read, monotonic-uptime ~6e6 vs epoch ~1.8e9).
- **[major][PLACE] PARTIAL** — the wire-event verification/emission concern moved out of
  `EpisodeRunner` into `EpisodeModelEventProjection` (same file: round-5 ownership covers only
  `situation_request.rb` in this gem); the runner now delegates `emit_model_events` to it.
  The artifact-retention family stays on the runner for now — moving it onto the artifact-store
  seam needs `artifact_store.rb`, outside this round's file set. Seam to finish: retention as an
  artifact-store concern.
- **[minor][ERR] FIXED** — `EpisodeStreamStateError` (`CATEGORY "stream_state_invalid"`) is
  raised for the server-side terminal-state inconsistencies in `translate_decision` and
  `validate_terminal_memory_consistency!`; the request-validation type is client faults only.
  Defined beside its raise sites (`errors.rb` is outside this round's file set).
- **[minor][SIZE] REJECTED** — grouping the four optional collaborators into one wiring value
  changes the constructor call in the only production caller, `bin/tamoz-stream-worker`, which is
  outside round-5 file ownership. Seam: the launcher's runner composition.
