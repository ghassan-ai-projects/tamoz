# Functionality audit — coverage index

Baseline: branch `audit-15-09`, commit `582ae55`, 2026-09-15. The current
checkout contains 27 `gems/*/lib` directories. This file is the single source
of truth for queue ownership and completion. `MAPPED` means only that the
responsibility or surface was inventoried; it is not a review or a PASS.

## Counters

| Surface | Inventory | Scanner pass | Analyst report present | Six-lens complete | Synthesis complete |
|---|---:|---:|---:|---:|---:|
| Gem responsibilities | 27/27 | 27/27 | 27/27 | 27/27 | 27/27 |
| Reference app (`apps/tamoz-agent`, 2 files) | 1/1 | 1/1 | 1/1 | 1/1 | 1/1 |
| Gem and `bin/` executables | 9/9 | 9/9 | 9/9 | 9/9 | 9/9 |
| Support scripts (`script/` 45 entries + nested quality file + `scripts/` 1 file) | 47/47 | 47/47 | 47/47 item-level | 47/47 item-level | 47/47 |
| Root `Rakefile` | 1/1 | 1/1 | 1/1 | 1/1 | 1/1 |
| Cross-gem flows | 13/13 | 13/13 | 13/13 | 13/13 | 13/13 |

All functionality rows have completed the review and synthesis stages; open
findings keep their verdicts at `IMPROVE` where the bar requires it. The standalone
scanner pass is recorded in `analyses/scanner-pass.md` for all 27 gem rows, the
app, nine executable surfaces, 47 support-script files, and the Rakefile. The
complete cross-flow scanner pass is recorded in
`analyses/crossflow-scanner-pass.md`; analyst reports and scanner leads remain
separate gates. The filesystem currently contains
42 JSON analyst records expanding to 53 row surfaces, including all 27 gem IDs
and the completed CF01, CF02, CF03, CF04, CF05, CF06, CF07, CF08, CF09, CF10,
CF11, CF12, and CF13 flow reviews.
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
CF01–CF13 have direct analyst reports and coordinator synthesis. The grouped
app, executable, support-script, Rakefile, and all 27 gem rows also have
coordinator synthesis in `analyses/entry-support-synthesis.md` and
`analyses/gem-synthesis.md`.

The current analysis set includes standalone reports for F13 approval, F18
capabilities, F20 healing, F21 profile, F25 runtime, and F26 evals evidence in
addition to the earlier functionality rows and cross-gem probes. Their major
findings have independent challenge evidence (the F21 challenge is recorded in
`challenge-profile-authority.md`); the challenger-added F20-REL-02 has the
separate analyst re-review `review-f20-rel02.md`. The coordinator index in
[FINDINGS.md](FINDINGS.md) records these waves' dispositions; open findings
remain open by design and are not silently treated as implementation closure.

## Rolling queue

Each group is a bounded wave. The groups in the first two rows are the first
scan targets; later rows remain queued until their predecessors leave a clear
boundary brief. Gem IDs appear exactly once in the detailed inventory below.

| Queue | Group | Gem units | State | Next scan focus |
|---|---|---:|---|---|
| W1A | core / graph / SQLite / agent kernel / session | 5 | SYNTHESIZED — 5/5 | durable state, replay, effects, routing, and session boundaries |
| W1B | authority / profile / tools / MCP / capabilities | 6 | SYNTHESIZED — 6/6 | trust, approval, egress, capability sealing, and tool execution |
| W2A | CLI / runtime | 2 | SYNTHESIZED — 2/2 | command routing, worker lifecycle, model and capability wiring |
| W2B | cancellation / concurrency / scheduler | 3 | SYNTHESIZED — 3/3 | signals, bounds, drains, leases, and schedule contracts |
| W3A | comms / gateway / Telegram | 3 | SYNTHESIZED — 3/3 | admission, rendering, transport, delivery, and channel recovery |
| W3B | stream | 1 | SYNTHESIZED — 1/1 | supervised episode worker, reverse channel, and Situation boundary |
| W4A | memory / healing / improvement | 3 | SYNTHESIZED — 3/3 | lifecycle, abstention, remediation, provenance, and promotion |
| W4B | observability / OTLP | 2 | SYNTHESIZED — 2/2 | signal catalog, bounded recording, projection, and export |
| W5 | evals / evals-runner | 2 | SYNTHESIZED — 2/2 | artifacts, digests, harnesses, scorecards, and release evidence |

## Gem responsibility inventory

Responsibilities are copied from the root responsibility map and checked
against the corresponding live `lib` directory during setup. The scanner,
analyst, six-lens, synthesis, and disposition gates are complete for all gem
responsibility rows; open findings remain open in `FINDINGS.md`.

| ID | Gem | Responsibility | Queue | Scanner | Analyst | Synthesis | Disposition |
|---|---|---|---|---|---|---|---|
| F01 | `tamoz-core` | Shared values, context, secrets, canonical digests, durable circuit, sentinels | W1A | complete | complete | complete | IMPROVE; findings dispositioned |
| F02 | `tamoz-cancellation` | Cancellation token, signal traps, process groups, interruptible sleep | W2B | complete | complete | complete | IMPROVE; findings dispositioned |
| F03 | `tamoz-concurrency` | Bounded pools, stream/event sinks, shared-budget drain | W2B | complete | complete | complete | IMPROVE; findings dispositioned |
| F04 | `tamoz-graph` | Deterministic checkpointed graph execution and durability contracts | W1A | complete | complete | complete | PASS; two minors remain |
| F05 | `tamoz-scheduler` | Schedule/occurrence values and the non-executing store contract | W2B | complete | complete | complete | IMPROVE; findings dispositioned |
| F06 | `tamoz-stream` | Supervised gRPC episode worker and Situation boundary | W3B | complete | complete | complete | IMPROVE; findings dispositioned |
| F07 | `tamoz-sqlite` | Durable checkpoints, inbox, effects, leases, schedules, and comms adapter | W1A | complete | complete | complete | IMPROVE; findings dispositioned |
| F08 | `tamoz-tools` | Workspace toolbox, skills compiler, capability host | W1B | complete | complete | complete | IMPROVE; findings dispositioned |
| F09 | `tamoz-mcp` | Governed MCP client and host | W1B | complete | complete | complete | IMPROVE; findings dispositioned |
| F10 | `tamoz-mcp-websearch` | Governed operator-side websearch egress adapter | W1B | complete | complete | complete | IMPROVE; findings dispositioned |
| F11 | `tamoz-comms` | Channel values, admission, rendering, transport and store contracts | W3A | complete | complete | complete | IMPROVE; findings dispositioned |
| F12 | `tamoz-comms-gateway` | Long-running gateway and delivery drainer over Comms seams | W3A | complete | complete | complete | IMPROVE; findings dispositioned |
| F13 | `tamoz-approval` | Policy-as-data approval engine, grants, decisions, and durable log | W1B | complete | complete | complete | 6 major + 1 minor open; 1 info lead closed |
| F14 | `tamoz-telegram` | Telegram Bot API transport adapter | W3A | complete | complete | complete | IMPROVE; findings dispositioned |
| F15 | `tamoz-observability` | Closed signals, correlation, bounded recorders, metrics, trace projection | W4B | complete | complete | complete | IMPROVE; findings dispositioned |
| F16 | `tamoz-otel` | Governed optional OTLP/HTTP exporter | W4B | complete | complete | complete | IMPROVE; findings dispositioned |
| F17 | `tamoz-agent-kernel` | Episode records/receipts, plan/review/execute/verify, effects, catalogs, routes, projections | W1A | complete | complete | complete | IMPROVE; findings dispositioned |
| F18 | `tamoz-agent-capabilities` | Sealed capability catalog and child-task dispatch | W1B | complete | complete | complete | 1 major + 2 minor open; browser limitation closed |
| F19 | `tamoz-agent-memory` | Durable memory admission, retrieval, lifecycle, consolidation, behavior transitions | W4A | complete | complete | complete | IMPROVE; findings dispositioned |
| F20 | `tamoz-agent-healing` | Typed failure classification, abstention, rules, reviewed remediation | W4A | complete | complete | complete | F20-REL-01 demoted; F20-REL-02 and F20-SEC-01 major/open |
| F21 | `tamoz-agent-profile` | Trusted profiles, authority/egress/check validation, secure files, registries | W1B | complete | complete | complete | 1 major + 1 minor open; info controls recorded |
| F22 | `tamoz-agent-session` | Durable deliberation records, planning, graph nodes, effects, routing, adaptive machinery | W1A | complete | complete | complete | IMPROVE; findings dispositioned |
| F23 | `tamoz-agent-improvement` | Candidate provenance, heuristic generation, evaluation, promotion/rollback | W4A | complete | complete | complete | IMPROVE; findings dispositioned |
| F24 | `tamoz-agent-cli` | `tamoz` executable and worker/schedule/profile/session/comms commands | W2A | complete | complete | complete | IMPROVE; findings dispositioned |
| F25 | `tamoz-agent` | Agent runtime, worker/durable execution, model/capability wiring, approval default | W2A | complete | complete | complete | 2 major findings open; cancellation projection and inert accepted budgets upheld |
| F26 | `tamoz-evals` | Artifact schemas, canonical digests, verification, release evidence | W5 | complete | complete | complete | 2 major + 1 minor open; stale artifact and zero-byte guard upheld |
| F27 | `tamoz-evals-runner` | Evaluation harnesses, scorecards, treatments, benchmarks, external inputs | W5 | complete | complete | complete | IMPROVE; findings dispositioned |

## Apps and entry points

These surfaces are reviewed separately from gem responsibilities. The app is a
reference package; executable and script behavior is not inferred from the gem
row that it invokes.

| ID | Surface | Role | State |
|---|---|---|---|
| A01 | `apps/tamoz-agent/` (`README.md`, `app.json`) | Reference application metadata and usage | SYNTHESIZED; IMPROVE; metadata findings dispositioned |
| E01 | `gems/tamoz-agent-cli/exe/tamoz` | Installed `tamoz` command | SYNTHESIZED; PASS |
| E02 | `gems/tamoz-evals/exe/tamoz-eval` | Installed evaluation command | SYNTHESIZED; PASS as wrapper; F26 guard carried |
| E03 | `gems/tamoz-evals-runner/exe/tamoz-eval-runner` | Installed evaluation runner command | SYNTHESIZED; PASS threshold; E03-ERR-01 minor open |
| E04 | `bin/tamoz-chat-probe` | Chat finding probe harness | SYNTHESIZED; IMPROVE; E04-COR-01 minor open |
| E05 | `bin/tamoz-chat-sim` | Chat simulation harness | SYNTHESIZED; PASS with info limitation |
| E06 | `bin/tamoz-eval` | Repository evaluation wrapper | SYNTHESIZED; PASS |
| E07 | `bin/tamoz-eval-runner` | Repository runner wrapper | SYNTHESIZED; PASS |
| E08 | `bin/tamoz-stream-subscriber` | Stream subscriber launcher | SYNTHESIZED; IMPROVE; E08-REL-01 major open |
| E09 | `bin/tamoz-stream-worker` | Supervised stream worker launcher | SYNTHESIZED; IMPROVE; E09-REL-01 major open |
| S01 | `script/` (46 tracked files, 45 top-level entries) | ADR, benchmark, fixture, quality, conformance, release, and runtime tools | SYNTHESIZED item-level; IMPROVE; S01-BEN-01 major + seven minors open |
| S02 | `scripts/start-tamoz-comms.sh` | Comms process launcher | SYNTHESIZED; IMPROVE; two minors open |
| R01 | `Rakefile` | Repository task and gate composition | SYNTHESIZED; IMPROVE; R01-GATE-01/02 open; GATE-04 merged |

The grouped surface synthesis is in
`analyses/entry-support-synthesis.md`. `S01` has one disposition row for each
of its 45 top-level entries plus the nested `quality/coverage_totals.rb`; the
aggregate row is no longer being used as a substitute for item-level coverage.

## Cross-gem flow inventory

Cross-flow coverage deliberately overlaps the gem rows. Each flow needs an
end-to-end trace and an independent analyst because a sound local component can
still fail at a boundary.

| ID | Flow | Primary surfaces | State |
|---|---|---|---|
| CF01 | Load and dependency isolation | gem entry points, gemspecs, Zeitwerk, public API tests | ANALYST COMPLETE; PASS; synthesis complete |
| CF02 | Durable graph checkpoint, crash recovery, and replay | `tamoz-agent-session` → `tamoz-graph` → `tamoz-sqlite` → `tamoz-core`/cancellation | ANALYST COMPLETE; IMPROVE; synthesis complete |
| CF03 | Reviewed plan, approval, execution, verification, and repair | agent/session/kernel → tools/capabilities → approval → SQLite → observability | ANALYST COMPLETE; IMPROVE; synthesis complete; carried F13/F20/F09/F07 findings |
| CF04 | Model/tool effect identity, journal, unknown outcome, and replay | agent runtime/session → graph dispatcher → SQLite effect journal | ANALYST COMPLETE; IMPROVE; synthesis complete; CF04-REL-01 carried |
| CF05 | Trusted authority, capability intersection, and governed egress | profile/approval → capabilities/tools → MCP/websearch → session | ANALYST COMPLETE; IMPROVE; synthesis complete; CF05-SEC-01 demoted to info/documentation gap; carries existing authority and egress findings |
| CF06 | Request, worker, and multi-turn control routing | CLI → agent runtime/session → SQLite inbox/leases → graph | ANALYST COMPLETE; IMPROVE; synthesis complete; carries F07-REL-01, F22 control findings, F25 cancellation/profile findings, no duplicate counts |
| CF07 | Schedule admission, occurrence leases, and worker execution | scheduler contract → SQLite schedule store → CLI/runtime/graph | ANALYST COMPLETE; IMPROVE; synthesis complete; CF07-ARCH-01 and CF07-REL-02 upheld; F05 schedule findings carried without duplicate counts |
| CF08 | Channel admission, rendering, outbox delivery, and approval relay | Telegram → Comms → gateway → SQLite → agent/approval | ANALYST COMPLETE; IMPROVE; synthesis complete; F11-COR-01, F12-REL-01, and F14-COR-01 upheld; demoted/closed component leads carried without duplicate counts |
| CF09 | Supervised stream episode, evidence pull, learning loop, reverse channel | stream → session/runtime → SQLite/memory/improvement/approval | ANALYST COMPLETE; IMPROVE; synthesis complete; CF09-SEC-01 upheld, CF09-OBS-01 open, CF09-MNT-01 demoted to info; existing F19/F23 findings carried without duplicate count |
| CF10 | Memory admission, retrieval, deletion, consolidation, and transitions | agent-memory → SQLite → kernel/session/tools | ANALYST COMPLETE; IMPROVE; synthesis complete; CF10-REL-01 upheld as the missing worker retention caller; F19 receipt/transition findings carried without duplicate count |
| CF11 | Failure classification, safe remediation, candidate improvement, promotion/rollback | healing/improvement → kernel/memory → session/effects/approval | ANALYST COMPLETE; IMPROVE; synthesis complete; lead proposals duplicate challenged F20/F23 findings; no new count |
| CF12 | Signal recording, metrics/traces, bounded drains, and OTLP export | runtime components → observability → OTel | ANALYST COMPLETE; IMPROVE; synthesis complete; CF12-OBS-01 accepted as a minor; F15/F16 findings carried without duplicate count |
| CF13 | Evaluation corpus, harness, scorecard, verification, and release evidence | evals/evals-runner ↔ runtime entry points and artifacts | ANALYST COMPLETE; IMPROVE; synthesis complete; carries F26/F27/S01/R01 evidence findings without duplicate count |

Historical audits listed in `README.md` are lead sources only. They do not move
any row above from pending to complete without current source evidence and an
independent analyst judgment.
