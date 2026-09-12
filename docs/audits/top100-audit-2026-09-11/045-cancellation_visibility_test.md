# Audit 045 — `test/cancellation_visibility_test.rb`

Rank 45 · 634 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: TEST

The timeline semantics are well covered, but the rendering and observation cases rely on ivar
injection and `send` into private seams the file itself later drives black-box.

## Findings

- **[major][TEST]** Gateway is built with `transport: Object.new`, `@store` injected via
  `instance_variable_set`, then private `status_text` poked via `send` in four tests. Owning seam:
  Gateway's public status/command surface, as the CLI-view tests in this same file already use.
  (test/cancellation_visibility_test.rb:42, 66, 90, 109, 522-529)
- **[minor][TEST]** `worker.send(:observe_cancellation, ...)` white-box probe duplicates the
  observation behavior the file's own black-box claim-consume test proves without private pokes.
  Owning seam: Worker's public poll loop.
  (test/cancellation_visibility_test.rb:134-146, cf. 158-214)

## Resolution — 2026-09-12

- **[major][TEST] FIXED** — `with_engine` now deploys a real `Comms::Gateway` over the shared `CommsGatewayHarness::ScriptedTransport` and drives `/status` through the public `serve_once` command surface (reply read from the public `outbox_rows` seam); `transport: Object.new`, `instance_variable_set(:@store, ...)`, and all four `.send(:status_text, ...)` calls are gone. The idle-card aggregate test was kept with identical assertions. `THREAD` is now the deterministic `Comms::Admission.thread_id` the gateway itself derives, since gateway-driven admission no longer takes a caller-chosen thread.
- **[minor][TEST] FIXED** — the `worker.send(:observe_cancellation, ...)` test was deleted together with its `RuntimeStub`/`CancelProbe` private-interface fakes; the two properties the black-box claim-consume test did not cover (a redirect without a cancel task never stamps; a second consumption never moves the first-write-wins stamp) were folded into `test_a_real_worker_claim_consumes_a_cancel_redirect_and_stamps_observation` through `poll_once`.
