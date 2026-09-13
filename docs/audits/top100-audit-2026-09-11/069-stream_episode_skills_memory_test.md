# Audit 069 — `test/stream_episode_skills_memory_test.rb`

Rank 69 · 528 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: DUP

Strong gate coverage over a fixture model endpoint, but the same endpoint/compose/run/teardown
block is hand-repeated in ten tests while the `run_with` helper that exists for exactly this sits
used once.

## Findings

- **[major][DUP]** Endpoint start → EpisodeComposition.build → runner.run → terminal extraction →
  adapter.close → `ensure endpoint&.stop` is copy-pasted in ~10 cases (121-146, 154-175, 178-197,
  199-221, 240-268, 286-306, 309-327, 330-350, 391-429, 435-460, 477-527) while `run_with`
  (52-58) covers only gate1 and no lifecycle. Owning seam: extend `run_with` to own endpoint
  lifecycle and return terminal+state. (test/stream_episode_skills_memory_test.rb)
- **[minor][DUP]** SituationRecall::Projection is constructed inline four times (225-235, 272-282,
  359-364, 464-474) and the replay case builds a second recaller shape via Class.new (365-389),
  duplicating StubSituationRecaller (17-32). Owning seam: a projection/recaller factory helper in
  this file.

## Resolution — 2026-09-11

- **[major][DUP] fixed.** The endpoint-start → build → run → terminal → teardown block, hand
  repeated in ~11 cases, is now owned by a block-form `run_episode(episode_id:, responses:,
  request:, skills:, **build_kwargs)` which guarantees teardown in an `ensure` and yields
  `(terminal, events, composition, endpoint)` so each case takes only what it needs.
  `episode_state(composition, episode_id:, fence:)` owns the durable_runner-fetch + `state.to_h`
  pair. All 12 cases converted; the old single-use `run_with` is deleted.
  - Two deliberate deviations from the obvious shape: the log filename derives from
    `episode_id` (keeping the helper within ParameterLists 5; nothing asserts on log paths),
    and state is fetched by a separate helper rather than yielded because ~6 cases end in
    `TERMINAL_STATUS_FAILED` with no checkpointed state and the replay case needs two fences.
- **[minor][DUP] fixed.** A `projection(...)` factory replaces the four inline
  `SituationRecall::Projection.new` constructions, and the replay case's anonymous `Class.new`
  recaller is gone — `StubSituationRecaller` gained an optional `later_projections:` that it
  returns after the first call, reproducing the "changed store" behaviour.

Verified against pristine: 12 runs / 49 assertions both before and after, and the
assertion-bearing line count is unchanged at 39 — no assertion dropped or weakened. File
528 -> 369 lines. RuboCop 5 -> 3 offenses (the 3 remaining are pre-existing).
