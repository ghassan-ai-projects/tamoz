# Implementation evidence

Evidence date: 2026-08-11. This record separates deterministic product proof from
provider-dependent release measurements.

## Implemented slices

| Area | Implemented behavior | Primary proof |
|---|---|---|
| Ephemeral routing | Fused route/response call; direct responses are `responded`, not verified completion; unsafe routes fall back | `test/agent_request_routing_test.rb`, `docs/ux-latency-investigation/latency-smoke.json` |
| Durable routing | v1 checkpoints keep the v1 graph; new experimental sessions use v2 route selection and read-only discovery | `test/agent_durable_routing_test.rb`, `test/agent_worker_test.rb` |
| Feedback | CLI and worker terminal output derive bounded progress and next actions from committed receipts | `test/agent_terminal_progress_test.rb`, `test/agent_cli_test.rb` |
| Delivery | Outbound claims and sends run in `DeliveryDrainer`; throttling is deferred, post-send ambiguity is `unknown`, and unknown rows are not retried | `test/delivery_drainer_test.rb`, `test/comms_gateway_test.rb`, autonomy case 15 |
| Channel controls | Durable accepted acknowledgement, typed `/help`, `/status`, and `/cancel`; command text never reaches the model | `test/comms_gateway_test.rb`, `test/comms_admission_test.rb`, autonomy cases 11–16 |
| Safety | Existing approval, authority, duplicate, crash, and unknown-effect invariants remain green in the scorecard | `docs/autonomy-scorecard.json` |

## Deterministic qualification

The owning offline smoke command is:

```text
rbenv exec ruby script/agent_latency_smoke
```

The committed artifact reports:

- direct one-call rate: `1.0`
- unsafe direct-route rate: `1.0` (all adversarial requests avoided the direct route)
- read-only discovery success rate: `1.0`
- qualification verdict: `passed: true`

These are scripted-model results. Their millisecond timings are harness timings, not
provider latency.

The autonomy scorecard currently reports `15/15` passing. Its channel case requires
exactly one terminal answer and separately verifies that the accepted acknowledgement
is first; the acknowledgement is not counted as a second answer.

## Structural and focused verification

- Enola: `PASS — no structural regression` with `--fail-on=cycles,layers` and a
  minimum confidence of `0.8`. The remaining hotspot findings are advisory below the
  failure policy.
- Focused UTF-8 suites pass independently: durable routing, delivery drainer,
  communications gateway, worker, worker MCP, CLI, terminal progress, and scorecard.
- The experimental routing switch is explicit. Omitting `--experimental-routing`
  selects the legacy graph; a resumed v1 thread remains on v1 even in an experimental
  process.

## Evidence not claimed

- No live provider timing is committed as a release gate. Provider control p50/p95
  still requires an explicitly configured provider and model role.
- No real Telegram inbox-to-send p95 is claimed. The fixture proves durable ownership,
  pacing, ambiguity handling, and one-pass behavior; network timing still needs a
  staging bot.
- The aggregate `rake ci`/`ci_full` runners still show subprocess/order-sensitive
  failures in scorecard, crash, worker, profile, and locale cases even though the
  corresponding focused suites pass independently. This is recorded as an evidence
  gap rather than hidden by weakening the tests.
- A generic second discovery pass is not implemented. The agent uses the existing
  bounded recovery behavior until a typed `missing_evidence` outcome can be defined
  without laundering planner or tool failures into discovery loops.
