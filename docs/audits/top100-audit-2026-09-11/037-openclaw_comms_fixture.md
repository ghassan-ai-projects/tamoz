# Audit 037 — `test/support/openclaw_comms_fixture.rb`

Rank 37 · 704 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: TEST

A faithful end-to-end comms fixture that nonetheless mutates a private ivar of WorkerRuntime even
though the public seam for exactly that exists.

## Findings

- **[major][TEST]** `wire_delivery_pipeline` injects the RecordingSink via
  `@runtime.instance_variable_set(:@delivery_sink, …)`, reaching behind WorkerRuntime — which
  already publishes `WorkerRuntime.open(..., delivery_sink:)` (worker_runtime.rb:42-60). Pass the
  wrapped OutboxDeliverySink through that parameter. (openclaw_comms_fixture.rb:405, 394-407)
- **[minor][TEST]** `read_rows` drives `@runtime.adapter.__send__(:read, …)` into a private Adapter
  method to query comms tables; a public read/projection API on the comms store owns fixture and
  benchmark reads. (openclaw_comms_fixture.rb:494-500)

## Resolution — 2026-09-11

- **[major][TEST] fixed.** `wire_delivery_pipeline` no longer does
  `@runtime.instance_variable_set(:@delivery_sink, ...)`. The named seam (`open(delivery_sink:)`)
  can't express this case — the sink wraps the runtime's OWN adapter/checkpoints, which only
  exist after `open`. Added a public `WorkerRuntime#install_delivery_sink(sink)`
  (through which `install_channel_delivery_sink` now also routes) and the fixture calls it.
- **[minor][TEST] not changed.** `read_rows` still uses `@runtime.adapter.__send__(:read, …)`;
  a public comms-store projection/read seam is the shared owner for the raw-SQL probes across
  005/012/037/073/092 and is tracked with the CommsStore projection work (006). Deferring the
  cross-cutting seam rather than adding a one-off here.
