# Audit 092 — `test/comms_evidence_gated_approval_test.rb`

Rank 92 · 450 lines · 2026-09-11 · **Verdict: IMPROVE** (2 major, 1 minor) · Bar fails: TEST

Genuine oracle coverage undermined by reaching into Gateway's private `@transport` ivar (including
mid-test replacement) and driving the adapter's private transaction/read via `__send__`.

## Findings

- **[major][TEST]** `press()` and both C5 race cases fetch the transport with
  `instance_variable_get` and even replace it with `instance_variable_set`; boot already holds the
  transport locally (return it) and ScriptedTransport should model the surface variation itself.
  Owning seam: this test's ScriptedTransport fake / Gateway construction surface.
  (test/comms_evidence_gated_approval_test.rb:291, 315, 377-380)
- **[major][TEST]** The repin case and `inbound_dispositions` invoke the SQLite adapter's private
  transaction/read via `__send__` while the same file uses the public
  `bind_comms_decision_store` elsewhere. Owning seam: Comms store public query surface.
  (test/comms_evidence_gated_approval_test.rb:227-231, 397-404)
- **[minor][SIZE]** `press()` takes 8 params; the binding context (correspondent/surface/revision/
  message) could be one bound-press value. (test/comms_evidence_gated_approval_test.rb:374-385)

## Resolution — 2026-09-11

- **[major][TEST] fixed.** No `instance_variable_get`/`instance_variable_set` remains in this
  file (verified: count is 0). `boot` now returns a `Harness = Data.define(:gateway, :transport)`
  — it hands back the transport it already constructed instead of tests digging it out of the
  Gateway — with a `serve_once(now:)` delegate. `ScriptedTransport` models the surface variation
  itself via `bind_surface(surface_id:, surface_revision:)` (also used by `initialize`), so the
  cross-surface oracle re-binds the existing fake rather than constructing a replacement and
  poking it into the Gateway. `press` re-establishes the default binding per press, so no surface
  state leaks between presses.
- **[minor][SIZE] fixed.** `PressBinding = Data.define(:correspondent_id, :surface_id,
  :surface_revision, :message_id)` (defaults preserved via a keyword initialize) collapses
  `press` to `press(harness, data, update_id:, bound:, now:)` — 5 parameters, at the ceiling. The
  `Metrics/ParameterLists` disable is removed rather than left suppressing the count.
- **[major][TEST] deferred (deliberate).** The repin case's `store.__send__(:transaction, …)` and
  `inbound_dispositions`' `adapter.__send__(:read, …)` are unchanged — both need a public Comms
  store query surface that does not exist yet. This is the same shared seam named by
  005/012/037/073 and is tracked with the CommsStore projection work (006), not fixed one-off here.

Verified: 15 runs / 27 assertions / 0 failures before AND after; assertion-bearing line count
unchanged at 25; RuboCop clean both sides; both deferred `__send__` sites byte-identical.
