# Future plan — stop re-encoding the whole graph state on every step

Deferred under the owner's "defer complexity to a future plan" rule (2026-10-04). Not built.

## Why

Session-driving tests are CPU-bound in `Tamoz::StateCodec`, not in their fixtures. A profile of
`work_loop_test` (`test_pressure_prunes_then_compacts_once_then_resets_with_a_handoff`, 171 graph steps)
after the JCS fixes of 2026-10-10 shows about two thirds of the run in codec walks: ~12,000 `StateCodec#dump`
and ~9,800 `#load` calls, about one million node visits per encode direction. The cost per step grows with the
state, so a turn's cost grows with the square of its length.

Per step the engine encodes the full state several times:

1. `StateManager#normalize_state` normalizes (dump + load) **every** channel, changed or not, then dumps the
   whole normalized state once more for the size check.
2. `StateOperations#append_prepared_checkpoint` dumps it again (`state_bytes`).
3. `CheckpointCodec#checkpoint_wire` → `CheckpointValues#verify_canonical_value_bytes` loads it and dumps it
   again to prove canonicality (a second, duplicate dump was removed on 2026-10-10).

Seven everyday files went to `SLOW_TESTS` on 2026-10-10 because of this cost (see the Rakefile).

## Measured so far

- An identity cache that lets `normalize` return a value the codec itself produced (deep-frozen) saved ~7%
  of the pressure test: unchanged channels are cheap; the full-state dumps dominate.
- Lazy error paths in the encoder/reader: ≤12% upper bound. Skipping `String#encode` for UTF-8 strings and a
  single-pass key-order check: ≤3%. None was kept.

## Candidate design

Encode the state once per step and carry the bytes: `normalize_state` returns the normalized value together
with its canonical bytes; `append_prepared_checkpoint` and `checkpoint_wire` take those bytes instead of
re-dumping; canonicality is verified on load (where bytes come from storage), not on the write path where the
bytes were just produced by the codec. Expected: 3–4 full-state encodes per step down to one.

## Tests

- Byte-identity: checkpoint bytes for a fixed graph are identical before and after (pin from HEAD).
- Corruption: a stored non-canonical state is still refused on load
  (`graph_checkpoint_codec_test` — `test_rejects_state_bytes_that_decode_but_are_not_canonical`).
- Size limit still enforced on the write path (`StateLimitError`).
- Re-measure the seven moved files on the CI runner; return each that fits under the cap.

## Open decisions (owner)

- Is skipping the write-path canonicality proof acceptable when the bytes were produced by the same codec in
  the same process, given that storage reads keep the proof?
