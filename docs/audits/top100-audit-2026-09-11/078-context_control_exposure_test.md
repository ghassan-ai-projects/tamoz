# Audit 078 — `test/context_control_exposure_test.rb`

Rank 78 · 494 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: DUP

Good cross-surface parity coverage, but its harness is a near-verbatim copy of the comms parity
test's.

## Findings

- **[major][DUP]** Entire gateway harness (ExposureUpdate, ScriptedTransport, descriptor,
  graph_definition, controls_session) duplicated near-verbatim from comms_command_parity_test.rb.
  Owning seam: a shared test/support comms gateway harness.
  (test/context_control_exposure_test.rb:328-338, 420-492)
- **[minor][TEST]** `drive` probes `gateway.instance_variable_get(:@store)` for the outbox row
  while `Surface` already carries the store used by `reply_for`. Owning seam: one public lookup
  seam. (test/context_control_exposure_test.rb:186-198, 298-302)

## Resolution — 2026-09-12

- **[major][DUP] FIXED** — descriptor, update factory, `ScriptedTransport`, and `graph_definition` now come from `test/support/comms_gateway_harness.rb`, the single hoist shared with `comms_command_parity_test.rb` (both docs confirmed the duplication); `ExposureUpdate` is gone. The controls seam itself (`controls_session`, `RecordingControls`, `ControlsModel`) stays local on purpose — the current worker-owned-controls shape was kept, not resurrected.
- **[minor][TEST] FIXED** — `drive(gateway, store, transport, text, id)` takes the store the `Surface` already carries (the same public `outbox_rows` seam `reply_for` uses); `gateway.instance_variable_get(:@store)` is gone.
