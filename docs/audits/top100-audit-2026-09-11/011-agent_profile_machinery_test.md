# Audit 011 — `test/agent_profile_machinery_test.rb`

Rank 11 · 1143 lines · 2026-09-11 · **Verdict: IMPROVE** (4 minor) · Bar fails: TEST, SIZE, DUP

Genuine DR5 acceptance coverage undermined by an over-claimed registry assertion and a bloated,
self-duplicating fixture helper layer.

## Findings

- **[minor][TEST]** DR5-07's comment claims "a v1-only reader refuses the v2 file typed — never a
  partial load", but the test only asserts `schema_version == 2`; the claimed refusal path is never
  exercised. Owning seam: a v1-codec reader fixture in test/support for that failure path.
  (agent_profile_machinery_test.rb:424-428)
- **[minor][SIZE]** `write_profile` fixture helper takes 10 params including boolean `activate:`
  (ceiling 5). Owning seam: a profile-fixture builder in test/support taking one keyword struct.
  (agent_profile_machinery_test.rb:1003-1042)
- **[minor][DUP]** `profile_document` re-builds the same profile document `write_profile` embeds,
  and `stub_model_factory`/`stub_model_factory_into` duplicate the factory-swap scaffold; both
  belong once in test/support. (agent_profile_machinery_test.rb:946-968, 1008-1063)
- **[minor][TEST]** Gate tests probe CLI privates via `send(:resolve_profile_roles, ...)`/`send(:build_model, ...)`
  alongside the e2e paths. Owning seam: a public profile-resolution intake entry for these cells.
  (agent_profile_machinery_test.rb:69, 131-134, 167-171, 255, 823)

## Resolution — 2026-09-11

- **[minor][TEST] fixed — and the finding was right to call it over-claimed.** A genuine v1-only
  reader is NOT constructible from the test: `TransitionDocument::SCHEMA_VERSIONS` is a constant
  of the shipped codec, so "an older binary" cannot exist without new production code. Rather
  than fake it, the comment was rewritten to drop the "a v1-only reader refuses the v2 file"
  claim and state what is actually pinned, AND two real assertions were added for the refusal
  MECHANISM such a binary would take: a document with an unaccepted `schema_version` (99) raises
  `Profile::AdoptionError`, and a v2 entry with `consumed_at` dropped (a key set matching neither
  v1's nor v2's) also raises `AdoptionError`. The "never a partial load, never a silent key drop"
  half is now genuinely proven. Assertions went UP (224 -> 226).
- **[minor][SIZE] fixed.** A keyword-initialized `ProfileFixture` value carries the nine fixture
  fields (with `suggestion?`/`destination` behaviour moved onto it), so `write_profile(fixture,
  activate: true)` is 2 parameters instead of 10. All 22 call sites updated.
- **[minor][DUP] fixed.** `write_profile` now builds its document THROUGH `profile_document`, so
  the document literal exists once; `stub_model_factory_into` is deleted and
  `stub_model_factory(capture, select: nil)` covers both call shapes.
- **[minor][TEST] deferred.** Gate tests probing CLI privates (`send(:resolve_profile_roles, …)`,
  `send(:build_model, …)`) are unchanged — they need a public profile-resolution intake on the
  CLI that does not exist, which is an API decision rather than a test fix.

Verified: 24 runs both sides; assertions 224 -> 226; the 2 failures are pre-existing and
identical before and after (`test_referenced_credential_unset_fails_typed_even_with_the_generic_key_set`,
`test_unavailable_credential_ref_is_typed_and_leaves_no_partial_session` — production reports the
generic key name rather than the ref name/role; a real pre-existing product defect, outside this
finding). RuboCop 0 offenses both sides.
