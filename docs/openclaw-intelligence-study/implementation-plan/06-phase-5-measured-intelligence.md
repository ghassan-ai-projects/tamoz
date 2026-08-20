# Phase 5 — measured intelligence

Status: not started. Phase 5A requires Phase 2; Phase 5B requires Phases 0–4.

Study reference: Stage 5 (`04`), "Measurement gates" (`05`), scenario matrix
evidence/scoring rules (`06`).

## Goal

Replace perception with measurement. No "more intelligent" claim exists until
a matched benchmark reports it.

## Work items

1. **Phase 5A — protocol and fixture plumbing.** Extend the existing benchmark
   controls (`script/benchmark_*`, `agenteval/`,
   `documentation/benchmark/`) with a versioned protocol, canonical mission
   schemas, separate fixture/real-provider artifact roots, readiness states,
   evidence manifests, and a runner that refuses to publish a final verdict
   when a required capability is absent. The existing fixture protocol remains
   unchanged and cannot be relabeled as intelligence evidence.
2. **Phase 5B — matched benchmark.** After Phase 4, run two tracks:
   - **common-subset** — matched provider/model, task, permissions, budget, and
     equivalent tools across Tamoz and the comparison target;
   - **native-envelope** — reports capability availability separately from
     model performance.
3. **Canonical missions.** Implement the matrix's composition tests as
   real-provider missions with tool selection *not* scripted: adaptive
   read-only, contradictory observation, governed mutation, capability
   availability, web/MCP, compaction, scheduled/restart, memory attribution,
   self-inspection. Each runs through both Telegram and durable CLI.
4. **Scenario records.** Every run records: provider/model identity, task and
   permission manifest, capability state (exists/reachable/authorized/
   attempted/effective/completed/verified), tool sequence and arguments,
   effect receipts and unknown states, approval/recovery events, task and
   delivery outcome, latency/token/tool-output cost.
5. **Reported metrics.** Tool selection and argument correctness; task
   completion and verification; unnecessary tool calls; unauthorized-action
   rate; duplicate and unknown-effect rate; recovery after restart/failure;
   latency/token/tool-output cost; Telegram/CLI semantic parity.
6. **Memory attribution.** Matched memory-on/memory-off missions with real
   retrieval, reporting retrieval correctness and task outcome separately. A
   scripted response change is never credited as improvement.

## Hard-zero rule

Any hard-zero failure (see `00-implementation-bar.md`) in any run is reported
as a failure of that run, not averaged away.

## Exit bar

- Phase 5A produces protocol/schema/fixture artifacts and proves that readiness
  and evidence separation work; it makes no intelligence claim.
- Phase 5B runs both tracks green on the canonical mission set only when every
  mission is `ready`, with results committed under the benchmark documentation
  conventions. A missing family is an unavailable result and blocks publication.
- Published claims are limited to what the matched data supports, with
  capability-availability differences reported alongside completion rates.
- The benchmark distinguishes fixture plumbing from real-provider evidence the
  way the existing protocol already does — extended, not weakened.

## Out of scope

Any new capability work; this phase measures what Phases 0–4 built.
