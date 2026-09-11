# Audit 076 — `gems/tamoz-observability/lib/tamoz/observability/recorders.rb`

Rank 76 · 497 lines · 2026-09-11 · **Verdict: IMPROVE** (1 critical, 1 major, 3 minor) ·
Bar fails: ERR, DUP, SIZE

Fanout's error guard defeats itself in flush, and Memory/Journal duplicate the validation and
drop-ledger machinery verbatim.

## Findings

- **[critical][ERR]** `Fanout#flush`: when a child `flush` raises, `guarded` returns `:dropped`
  and `Integer(:dropped)` raises TypeError — the swallow resurfaces as a crash with a misleading
  class. The guard must map flush failures to 0.
  (recorders.rb:124-126, 135-139)
- **[major][DUP]** Memory and Journal duplicate `validate!`, `drop_key`, `drops_hash`,
  `count_invalid_drop`, and the strict-mode `record` rescue envelope verbatim. Owning seam: a
  shared Recorder validation/drop-ledger mixin. (recorders.rb:43-51,71-105 vs
  188-224, 262-264, 391-397)
- **[minor][ERR]** `Fanout#health` can inject the symbol `:dropped` into the JSON-serialized
  health hash when a child raises, corrupting the health contract. (recorders.rb:118-122, 135-139)
- **[minor][ERR]** `Journal#record` rescues any StandardError and books it as an 'invalid
  validation' drop, conflating route/IO/mutex failures with invalid signals.
  (recorders.rb:188-196, 262-264)
- **[minor][SIZE]** `Journal#initialize` takes 11 params, and Journal+Files (~350 lines of
  IO/rotation/query) live inside the generic recorders file. Owning seam: an observability journal
  module. (recorders.rb:146-186, 402-493)

## Resolution — 2026-09-11

- **[critical][ERR] fixed.** `Fanout#guarded` now takes an explicit per-call fallback;
  `flush` uses `guarded(0) { Integer(recorder.flush(...)) }` so a raising child counts 0
  unflushed instead of feeding `:dropped` into `Integer()`. Regression test added
  (`test_fanout_maps_a_raising_child_to_its_method_fallback_not_a_crash`).
- **[minor][ERR] fixed.** `Fanout#health` uses `guarded(UNAVAILABLE_HEALTH)`, so a raising
  child yields `{'enabled'=>false,'error'=>'unavailable'}` — no `:dropped` symbol in the
  JSON health contract.
- **[major][DUP] fixed.** `validate!`, `drop_key`, `drops_hash`, `count_invalid_drop`, and
  the strict-mode record envelope now live once in `Recorder::DropLedger`
  (`recorder_drop_ledger.rb`), included by `Memory` and `Journal`. Each recorder passes its
  accept action (`store`/`route`) as the `guard_record` block.
- **[minor][ERR] fixed.** The shared envelope now distinguishes `ValidationError`
  (booked `invalid:validation:bulk`) from any other `StandardError` (booked
  `record:error:bulk`), ending the mislabel of route/IO/mutex failures as invalid signals.
- **[minor][SIZE] fixed (file split).** `Journal` + `Journal::Files` moved to
  `recorder_journal.rb`; `recorders.rb` is now 127 lines (Null/Memory/Fanout).
  `Journal#initialize`'s 11 keyword params are left as-is: all are defaulted tuning knobs
  (queue/reserved sizes, rotation limits, interval, strict) that callers set zero-to-one of;
  a value object would force construction with no readability gain.
