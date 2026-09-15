# Functionality audit — coverage index

Baseline: branch `audit-15-09`, commit `582ae55`, 2026-09-15. The current
checkout contains 27 `gems/*/lib` directories. This file is the single source
of truth for queue ownership and completion. `MAPPED` means only that the
responsibility or surface was inventoried; it is not a review or a PASS.

## Counters

| Surface | Inventory | Scanner pass | Analyst report present | Six-lens complete | Synthesis complete |
|---|---:|---:|---:|---:|---:|
| Gem responsibilities | 27/27 | 27/27 | 27/27 | 27/27 | 6/27 |
| Reference app (`apps/tamoz-agent`, 2 files) | 1/1 | 1/1 | 1/1 | 1/1 | 0/1 |
| Gem and `bin/` executables | 9/9 | 9/9 | 9/9 | 9/9 | 0/9 |
| Support scripts (`script/` 45 files + `scripts/` 1 file) | 46/46 | 46/46 | 0/46 item-level | 0/46 item-level | 0/46 |
| Root `Rakefile` | 1/1 | 1/1 | 1/1 | 1/1 | 0/1 |
| Cross-gem flows | 13/13 | 13/13 | 1/13 partial | 0/13 | 0/13 |

No functionality row has met the closure bar at this checkpoint. The standalone
scanner pass is recorded in `analyses/scanner-pass.md` for all 27 gem rows, the
app, nine executable surfaces, 46 support-script files, and the Rakefile. The
complete cross-flow scanner pass is recorded in
`analyses/crossflow-scanner-pass.md`; analyst reports and scanner leads remain
separate gates. The filesystem currently contains
29 JSON analyst records expanding to 40 row surfaces, including all 27 gem IDs.
All 27 gem reports and all app/executable rows now have a scalability assessment.
The coordinator addendum `analyses/scalability-lens-review.md` records the eight
rows whose local bounds are proved but whose sustained-load measurements are
absent. A row cannot be closed by an inventory count, a historical report, a
scanner signal, or an issue-only analysis. See [BAR.md](BAR.md) for verdict and
finding rules.

## Synthesis progress — W1

The durable-session scanner (`/tmp/tamoz-agents/scan_durable_session.log`)
covered CLI/runtime, graph, checkpoint, request-inbox, and effect-journal paths.
The authority/tools scanner (`/tmp/tamoz-agents/scan_authority_tools.log`)
covered approval, profile, capability, toolbox, MCP, websearch, and session
authority paths. The standalone inventory/search pass in
`analyses/scanner-pass.md` now covers all gem/app/executable/support/Rakefile
surfaces, and `analyses/crossflow-scanner-pass.md` covers CF01–CF13. The
cross-flow analyst lanes still need end-to-end boundary review under the
six-lens bar.

The current analysis set includes standalone reports for F13 approval, F18
capabilities, F20 healing, F21 profile, F25 runtime, and F26 evals evidence in
addition to the earlier functionality rows and cross-gem probes. Their major
findings have independent challenge evidence (the F21 challenge is recorded in
`challenge-profile-authority.md`); the challenger-added F20-REL-02 has the
separate analyst re-review `review-f20-rel02.md`. The coordinator index in
[FINDINGS.md](FINDINGS.md) records these waves' dispositions; open findings and
the remaining scanner, flow, item-level script, and challenge work keep the
closure counters pending.

## Rolling queue

Each group is a bounded wave. The groups in the first two rows are the first
scan targets; later rows remain queued until their predecessors leave a clear
boundary brief. Gem IDs appear exactly once in the detailed inventory below.

| Queue | Group | Gem units | State | Next scan focus |
|---|---|---:|---|---|
| W1A | core / graph / SQLite / agent kernel / session | 5 | ACTIVE — 0/5 complete | durable state, replay, effects, routing, and session boundaries |
| W1B | authority / profile / tools / MCP / capabilities | 6 | ACTIVE — F13/F18/F21 synthesized; F08–F10 pending | trust, approval, egress, capability sealing, and tool execution |
| W2A | CLI / runtime | 2 | QUEUED — 0/2 complete | command routing, worker lifecycle, model and capability wiring |
| W2B | cancellation / concurrency / scheduler | 3 | QUEUED — 0/3 complete | signals, bounds, drains, leases, and schedule contracts |
| W3A | comms / gateway / Telegram | 3 | QUEUED — 0/3 complete | admission, rendering, transport, delivery, and channel recovery |
| W3B | stream | 1 | QUEUED — 0/1 complete | supervised episode worker, reverse channel, and Situation boundary |
| W4A | memory / healing / improvement | 3 | QUEUED — 0/3 complete | lifecycle, abstention, remediation, provenance, and promotion |
| W4B | observability / OTLP | 2 | QUEUED — 0/2 complete | signal catalog, bounded recording, projection, and export |
| W5 | evals / evals-runner | 2 | QUEUED — 0/2 complete | artifacts, digests, harnesses, scorecards, and release evidence |

## Gem responsibility inventory

Responsibilities are copied from the root responsibility map and checked
against the corresponding live `lib` directory during setup. The analyst,
synthesis, and disposition columns remain pending until their gates are
completed; the scanner column is complete for all gem responsibility rows.

| ID | Gem | Responsibility | Queue | Scanner | Analyst | Synthesis | Disposition |
|---|---|---|---|---|---|---|---|
| F01 | `tamoz-core` | Shared values, context, secrets, canonical digests, durable circuit, sentinels | W1A | complete | pending | pending | open coverage |
| F02 | `tamoz-cancellation` | Cancellation token, signal traps, process groups, interruptible sleep | W2B | complete | pending | pending | open coverage |
| F03 | `tamoz-concurrency` | Bounded pools, stream/event sinks, shared-budget drain | W2B | complete | pending | pending | open coverage |
| F04 | `tamoz-graph` | Deterministic checkpointed graph execution and durability contracts | W1A | complete | pending | pending | open coverage |
| F05 | `tamoz-scheduler` | Schedule/occurrence values and the non-executing store contract | W2B | complete | pending | pending | open coverage |
| F06 | `tamoz-stream` | Supervised gRPC episode worker and Situation boundary | W3B | complete | pending | pending | open coverage |
| F07 | `tamoz-sqlite` | Durable checkpoints, inbox, effects, leases, schedules, and comms adapter | W1A | complete | pending | pending | open coverage |
| F08 | `tamoz-tools` | Workspace toolbox, skills compiler, capability host | W1B | complete | pending | pending | open coverage |
| F09 | `tamoz-mcp` | Governed MCP client and host | W1B | complete | pending | pending | open coverage |
| F10 | `tamoz-mcp-websearch` | Governed operator-side websearch egress adapter | W1B | complete | pending | pending | open coverage |
| F11 | `tamoz-comms` | Channel values, admission, rendering, transport and store contracts | W3A | complete | pending | pending | open coverage |
| F12 | `tamoz-comms-gateway` | Long-running gateway and delivery drainer over Comms seams | W3A | complete | pending | pending | open coverage |
| F13 | `tamoz-approval` | Policy-as-data approval engine, grants, decisions, and durable log | W1B | complete | complete | complete | 6 major + 1 minor open; 1 info lead closed |
| F14 | `tamoz-telegram` | Telegram Bot API transport adapter | W3A | complete | pending | pending | open coverage |
| F15 | `tamoz-observability` | Closed signals, correlation, bounded recorders, metrics, trace projection | W4B | complete | pending | pending | open coverage |
| F16 | `tamoz-otel` | Governed optional OTLP/HTTP exporter | W4B | complete | pending | pending | open coverage |
| F17 | `tamoz-agent-kernel` | Episode records/receipts, plan/review/execute/verify, effects, catalogs, routes, projections | W1A | complete | pending | pending | open coverage |
| F18 | `tamoz-agent-capabilities` | Sealed capability catalog and child-task dispatch | W1B | complete | complete | complete | 1 major + 2 minor open; browser limitation closed |
| F19 | `tamoz-agent-memory` | Durable memory admission, retrieval, lifecycle, consolidation, behavior transitions | W4A | complete | pending | pending | open coverage |
| F20 | `tamoz-agent-healing` | Typed failure classification, abstention, rules, reviewed remediation | W4A | complete | complete | complete | F20-REL-01 demoted; F20-REL-02 and F20-SEC-01 major/open |
| F21 | `tamoz-agent-profile` | Trusted profiles, authority/egress/check validation, secure files, registries | W1B | complete | complete | complete | 1 major + 1 minor open; info controls recorded |
| F22 | `tamoz-agent-session` | Durable deliberation records, planning, graph nodes, effects, routing, adaptive machinery | W1A | complete | pending | pending | open coverage |
| F23 | `tamoz-agent-improvement` | Candidate provenance, heuristic generation, evaluation, promotion/rollback | W4A | complete | pending | pending | open coverage |
| F24 | `tamoz-agent-cli` | `tamoz` executable and worker/schedule/profile/session/comms commands | W2A | complete | pending | pending | open coverage |
| F25 | `tamoz-agent` | Agent runtime, worker/durable execution, model/capability wiring, approval default | W2A | complete | complete | complete | 2 major findings open; cancellation projection and inert accepted budgets upheld |
| F26 | `tamoz-evals` | Artifact schemas, canonical digests, verification, release evidence | W5 | complete | complete | complete | 2 major + 1 minor open; stale artifact and zero-byte guard upheld |
| F27 | `tamoz-evals-runner` | Evaluation harnesses, scorecards, treatments, benchmarks, external inputs | W5 | complete | pending | pending | open coverage |

## Apps and entry points

These surfaces are reviewed separately from gem responsibilities. The app is a
reference package; executable and script behavior is not inferred from the gem
row that it invokes.

| ID | Surface | Role | State |
|---|---|---|---|
| A01 | `apps/tamoz-agent/` (`README.md`, `app.json`) | Reference application metadata and usage | MAPPED; scanner complete; review pending |
| E01 | `gems/tamoz-agent-cli/exe/tamoz` | Installed `tamoz` command | MAPPED; scanner complete; review pending |
| E02 | `gems/tamoz-evals/exe/tamoz-eval` | Installed evaluation command | MAPPED; scanner complete; review pending |
| E03 | `gems/tamoz-evals-runner/exe/tamoz-eval-runner` | Installed evaluation runner command | MAPPED; scanner complete; review pending |
| E04 | `bin/tamoz-chat-probe` | Chat finding probe harness | MAPPED; scanner complete; review pending |
| E05 | `bin/tamoz-chat-sim` | Chat simulation harness | MAPPED; scanner complete; review pending |
| E06 | `bin/tamoz-eval` | Repository evaluation wrapper | MAPPED; scanner complete; review pending |
| E07 | `bin/tamoz-eval-runner` | Repository runner wrapper | MAPPED; scanner complete; review pending |
| E08 | `bin/tamoz-stream-subscriber` | Stream subscriber launcher | MAPPED; scanner complete; review pending |
| E09 | `bin/tamoz-stream-worker` | Supervised stream worker launcher | MAPPED; scanner complete; review pending |
| S01 | `script/` (45 files) | ADR, benchmark, fixture, quality, conformance, release, and runtime tools | MAPPED by inventory; 45 item reviews pending |
| S02 | `scripts/start-tamoz-comms.sh` | Comms process launcher | MAPPED; scanner complete; review pending |
| R01 | `Rakefile` | Repository task and gate composition | MAPPED; scanner complete; review pending |

Before this surface group can close, `S01` must be expanded to one row per
script and each script must have its own source path, caller, evidence, and
disposition. The aggregate count is an inventory aid only.

## Cross-gem flow inventory

Cross-flow coverage deliberately overlaps the gem rows. Each flow needs an
end-to-end trace and an independent analyst because a sound local component can
still fail at a boundary.

| ID | Flow | Primary surfaces | State |
|---|---|---|---|
| CF01 | Load and dependency isolation | gem entry points, gemspecs, Zeitwerk, public API tests | SCANNER COMPLETE; analyst review pending |
| CF02 | Durable graph checkpoint, crash recovery, and replay | `tamoz-agent-session` → `tamoz-graph` → `tamoz-sqlite` → `tamoz-core`/cancellation | SCANNER COMPLETE; analyst review pending |
| CF03 | Reviewed plan, approval, execution, verification, and repair | agent/session/kernel → tools/capabilities → approval → SQLite → observability | SCANNER COMPLETE; analyst review pending |
| CF04 | Model/tool effect identity, journal, unknown outcome, and replay | agent runtime/session → graph dispatcher → SQLite effect journal | SCANNER COMPLETE; analyst review pending |
| CF05 | Trusted authority, capability intersection, and governed egress | profile/approval → capabilities/tools → MCP/websearch → session | SCANNER COMPLETE; analyst review pending |
| CF06 | Request, worker, and multi-turn control routing | CLI → agent runtime/session → SQLite inbox/leases → graph | SCANNER COMPLETE; analyst review pending |
| CF07 | Schedule admission, occurrence leases, and worker execution | scheduler contract → SQLite schedule store → CLI/runtime/graph | SCANNER COMPLETE; analyst review pending |
| CF08 | Channel admission, rendering, outbox delivery, and approval relay | Telegram → Comms → gateway → SQLite → agent/approval | SCANNER COMPLETE; analyst review pending |
| CF09 | Supervised stream episode, evidence pull, learning loop, reverse channel | stream → session/runtime → SQLite/memory/improvement/approval | SCANNER COMPLETE; analyst review pending |
| CF10 | Memory admission, retrieval, deletion, consolidation, and transitions | agent-memory → SQLite → kernel/session/tools | SCANNER COMPLETE; analyst review pending |
| CF11 | Failure classification, safe remediation, candidate improvement, promotion/rollback | healing/improvement → kernel/memory → session/effects/approval | SCANNER COMPLETE; analyst review pending |
| CF12 | Signal recording, metrics/traces, bounded drains, and OTLP export | runtime components → observability → OTel | SCANNER COMPLETE; analyst review pending |
| CF13 | Evaluation corpus, harness, scorecard, verification, and release evidence | evals/evals-runner ↔ runtime entry points and artifacts | SCANNER COMPLETE; analyst review pending |

Historical audits listed in `README.md` are lead sources only. They do not move
any row above from pending to complete without current source evidence and an
independent analyst judgment.
