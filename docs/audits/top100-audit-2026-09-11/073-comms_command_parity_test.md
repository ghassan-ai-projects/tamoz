# Audit 073 — `test/comms_command_parity_test.rb`

Rank 73 · 514 lines · 2026-09-11 · **Verdict: IMPROVE** (4 minor) · Bar fails: TEST, DUP

Thorough command-surface parity tests undermined by private-implementation probes and duplicated
stub helpers.

## Findings

- **[minor][TEST]** Tests reach persistence internals via `store.__send__(:read, ...)` with raw
  SQL over `tamoz_comms_*` tables instead of a store-level read seam.
  (test/comms_command_parity_test.rb:495-512)
- **[minor][TEST]** `current_generation` reads `gateway.instance_variable_get(:@store)` — private
  ivar probe of the collaborator under test. (test/comms_command_parity_test.rb:437-442)
- **[minor][DUP]** `force_request_status` and `stub_request_status` are byte-identical
  implementations under two names. (test/comms_command_parity_test.rb:464-470)
- **[minor][DUP]** Gateway harness (descriptor, update factory, ScriptedTransport,
  graph_definition) is copy-pasted near-verbatim with context_control_exposure_test.rb. Owning
  seam: a shared test/support comms harness. (test/comms_command_parity_test.rb:354-423)

## Resolution — 2026-09-12

- **[minor][TEST] FIXED (read seam)** — the `store.__send__(:read, ...)` helpers now read the committed database file directly via `SQLite3::Database` over the public `adapter.path`; a store-level inbound/prompt read seam would need a gem-side change (named seam: `Tamoz::Comms` store readers for `tamoz_comms_inbound` / `tamoz_comms_approval_prompts`) and was not required for the contract.
- **[minor][TEST] FIXED (ivar probe)** — `current_generation` takes the bound store the harness already yields; `admit_turn(gateway, transport, store, id, ...)`; `gateway.instance_variable_get(:@store)` is gone (the `rescue KeyError → 0` fallback went with it — the row exists by construction post-admission).
- **[minor][DUP] FIXED** — `force_request_status` and `stub_request_status` merged into one `stub_request_status(store, projection)`; both call sites updated.
- **[minor][DUP] FIXED** — descriptor, update factory, `graph_definition(name)`, and `ScriptedTransport` hoisted to `test/support/comms_gateway_harness.rb` and shared with `context_control_exposure_test.rb` (and reused by `cancellation_visibility_test.rb`); the dead `ScriptedTransport#deliveries` capture was dropped in the hoist.
