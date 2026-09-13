# Audit 087 — `gems/tamoz-core/lib/tamoz/state_codec.rb`

Rank 87 · 466 lines · 2026-09-11 · **Verdict: IMPROVE** (3 minor) · Bar fails: SIZE, NAME, DUP

Solid codec, but both tag-dispatch methods exceed the hard-30 line ceiling and two repo-lexicon
violations sit in public surface.

## Findings

- **[minor][SIZE]** `encode_node` (33 body lines, 9-way dispatch) and `validate_node!` (34 body
  lines, 10-way dispatch) both exceed the hard 30-line ceiling. Owning seam: per-tag shape handlers
  beside the already-extracted array/object/registered validators. (state_codec.rb:142-176, 249-284)
- **[minor][NAME]** `with_registration` returns a copy and never yields, violating the repo lexicon
  rule that with_* must yield. Rename to `add_registration` or yield-then-copy.
  (state_codec.rb:96-104)
- **[minor][DUP]** `count_items!` and `count_items_for_load!` are identical except the raised error
  class. Owning seam: one counter parameterized by the error class. (state_codec.rb:413-426)

## Resolution — 2026-09-11

- **[minor][SIZE] fixed.** `encode_node` now dispatches to extracted `encode_scalar` and
  `encode_array` handlers (13 lines); `validate_node!` dispatches to `validate_scalar_node!`
  (11 lines). Both are under the 30-line ceiling and read as pure tag dispatch beside the
  existing array/object/registered handlers.
- **[minor][NAME] fixed.** `with_registration` (returned a copy, never yielded) renamed to
  `add_registration`, honouring the lexicon rule that `with_*` must yield. All callers
  updated (surface.rb + core/graph codec tests).
- **[minor][DUP] fixed.** `count_items!` and `count_items_for_load!` collapsed into one
  `count_items!(..., error: StateLimitError)`; the load path passes
  `error: CheckpointCorruptionError`.
