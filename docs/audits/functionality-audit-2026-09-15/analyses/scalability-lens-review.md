# Coordinator scalability-lens review — eight previously incomplete rows

Date: 2026-09-15
Checkout: `audit-15-09`, code baseline `582ae55`
Mode: read-only synthesis of the existing source traces and analyst records.

The eight rows below were already read by their analysts, but their JSON records
left the scalability lens as `not evidenced`. I rechecked the resource-owning
seams and recorded the distinction between a proved local bound and a missing
load/soak measurement. The lens is now assessed for each row; “measurement gap”
is retained as an explicit blind spot rather than treated as a clean performance
claim. No new finding was needed.

| Row | Source-grounded bound | Evidence gap retained | Review result |
|---|---|---|---|
| A01 | `apps/tamoz-agent/app.json:1-8` is static metadata; no runtime loader, loop, queue, or allocation path is present. | No consumer exists to load the manifest at volume. | Reviewed; no resource defect in the app metadata surface. |
| E01 | `gems/tamoz-agent-cli/exe/tamoz:4-6` is a six-line shim that invokes one `CLI.run`; all work and argv iteration belong to the library (`cli.rb:78-80`). | No launcher-specific load ceiling is measured. | Reviewed; proportional to explicit argv, with no shim-level queue/retry. |
| E05 | `bin/tamoz-chat-sim:63-89` owns one harness for the process lifetime and consumes one stdin line at a time; `/quit` ends it. | A long live-provider session was not run, so harness memory growth across arbitrary turns is unmeasured. | Reviewed; stdin and one harness bound the wrapper's own work. |
| E06 | `bin/tamoz-eval:4-10` makes one `Tamoz::Evals::CLI.run(ARGV)` call and adds no loop, pool, or buffer. | Artifact-set throughput is owned by the CLI/gem and was not load-tested at this shim. | Reviewed; no wrapper-specific resource path. |
| E07 | `bin/tamoz-eval-runner:4-11` makes one runner CLI call and adds no loop, pool, or buffer. | Scorecard/treatment corpus throughput belongs to `tamoz-evals-runner`, not this wrapper, and was not measured here. | Reviewed; no wrapper-specific resource path. |
| E09 | `bin/tamoz-stream-worker:102-144` builds one graph/runner/server; `WorkerServer` fixes the gRPC pool at `pool_size: 16` (`gems/tamoz-stream/lib/tamoz/stream/worker_server.rb:25-37`). | No concurrent-episode soak was run. The existing E09-REL-01 signal-abort defect can also defeat the five-second shutdown join (`worker_server.rb:61-73`), which is a liveness limitation, not a second scalability finding. | Reviewed; launcher adds no unbounded queue. |
| F12 | Gateway polling and draining use `@batch_size` (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb:214-220`, `delivery_drainer.rb:45-53`); outbox capacity refuses overflow (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:47-76`); control text is clamped (`gateway_delivery.rb:10-23`); inbound bytes are capped (`gateway_admission.rb:106-115`); transient backoff is capped at 30 seconds (`gateway.rb:31-35,235-247`). | No sustained-backlog measurement exists for per-pass throughput or rate-limit interaction. | Reviewed; bounds are proved, throughput remains an evidence gap. |
| F17 | Plan steps cap at 12 (`gems/tamoz-agent-kernel/lib/tamoz/agent/plan.rb:32-42`); catalog/frame/skill/ref limits and receipt-budget checks are named in the analyst trace; witness records are capped at 10,000 (`witness_gateway.rb:24-29`). | No load/soak or sustained-concurrency measurement exists for the kernel. | Reviewed; bounds are proved, measured throughput is unknown. |

## Disposition

All eight missing lens entries are now `reviewed` in their JSON records. This
does not promote any row to `PASS`: A01 and E01/E05/E06/E07/E09 retain their
existing findings or evidence gaps, F12 retains its open minor retry/observability
items, and F17 retains its existing major/minor findings. A bounded soak is still
the appropriate follow-up where a deployment needs throughput evidence.

The review used existing source citations and the earlier analyst traces; no
production, test, configuration, or generated release artifact was changed.
