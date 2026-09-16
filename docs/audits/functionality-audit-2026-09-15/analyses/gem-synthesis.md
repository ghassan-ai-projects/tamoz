# Gem-row coordinator synthesis — all 27 responsibilities

Date / code baseline: 2026-09-15, branch `audit-15-09`, production code commit
`582ae5566de1ae073aea82b69bb2bbf444494d3b`.

This is the final coordinator pass over the shared gem reports. It reads every
`F01`–`F27` analyst JSON/Markdown record, the cited source seams, the challenge
records, and the current `FINDINGS.md` index. The delegated lanes are not used
for this pass. No production, test, fixture, configuration, or generated
artifact file was changed.

## Coverage and method

All 27 gem JSON records are present. Every record marks correctness,
security/authority, reliability/durability, observability/evidence,
scalability/resource bounds, and maintenance/architecture as reviewed. The
coordinator checked the entry seam, the highest-impact finding citations, the
challenge disposition, and the ownership boundary for each row. The detailed
analyst reports remain the source of the full file-by-file traces and test
transcripts.

| Row | Entry seam checked | Analyst verdict | Coordinator result |
|---|---|---|---|
| F01 `tamoz-core` | `Core`/JCS, circuit registry, error redaction | IMPROVE | Major proposals were challenged: the integer exemption is info/intended and the leak is demoted to a minor test gap; circuit/domain and public-surface minors remain open. |
| F02 `tamoz-cancellation` | token, trap, process-group signal | IMPROVE | Process-group authority is demoted to minor without a reachable unsafe caller; the worker cancellation record proposal is refuted as written; local token/default and PID-reuse minors remain open. |
| F03 `tamoz-concurrency` | `StreamSink#finish`, `Drain#close`, pool bounds | IMPROVE | Both shutdown-loss majors are upheld with production consumers and separate seams; backlog/ownership minors remain open. |
| F04 `tamoz-graph` | durable runner, checkpoint barrier, replay | PASS | Two minor documentation/observability gaps remain; crash/replay and version-refusal claims are directly evidenced and no major finding survives. |
| F05 `tamoz-scheduler` | schedule/occurrence values and `ScheduleStore` contract | IMPROVE | Misfire bound lead is demoted; the unexecutable store settlement contract remains major; occurrence fence and grant findings are carried without duplicate counts. |
| F06 `tamoz-stream` | `EpisodeRequestEnvelope`, runner, evidence reverse channel | IMPROVE | Authority serialization major proposals are demoted/qualified by the challenge; the remaining wire/failure-path observations are owned by F06 and the stream boundary. |
| F07 `tamoz-sqlite` | request claimer, effect reconciler, durable stores | IMPROVE | The cross-thread effect resolution critical is upheld; starvation and unbounded comms/inbox reads remain major/minor at SQLite seams. |
| F08 `tamoz-tools` | workspace check runner and staging reaper | IMPROVE | Credential inheritance critical is upheld on the live check path; reserved-prefix deletion remains major; orphan starvation, TOCTOU, and taxonomy minors remain open. |
| F09 `tamoz-mcp` | invocation/elicitation and host descriptor | IMPROVE | Durable elicitation interruption remains critical; the descriptor contract is demoted for reachability; the planner description and frame-budget notes remain owned by F09. |
| F10 `tamoz-mcp-websearch` | provider loader, egress circuit, outbound request | IMPROVE | Exact-host egress major is upheld; profile/admission overlap is merged into CF05; result-bound and circuit behavior remain minor/info items. |
| F11 `tamoz-comms` | admission, rendering, transport/store contracts | IMPROVE | Rendering truncation major is upheld; the store error leads are routed to F07 and the remaining delivery/observability minors stay open. |
| F12 `tamoz-comms-gateway` | gateway loop and delivery drainer | IMPROVE | Unknown-ordering major is upheld at the gateway; outbox attempts, process-local retry state, pairing memo, terminal visibility, and lifecycle notes remain open. |
| F13 `tamoz-approval` | policy document, engine resolve/rebind, grant log | IMPROVE | Seven major/qualified findings retain the F13 ownership and challenge outcomes; the retention lead is closed as accepted design. |
| F14 `tamoz-telegram` | Bot API client, poller, normalizer | IMPROVE | Send conflict classification major is upheld with F12 as co-owner; poller failure is demoted to minor and the remaining transport/security notes stay open. |
| F15 `tamoz-observability` | signal catalog, recorder, metrics/trace projection | IMPROVE | Secret-shaped reason path remains major; recorder/drop, metric cardinality, lock, and flat-trace minors are retained; the limitations section itself is verified. |
| F16 `tamoz-otel` | egress policy, async drain, OTLP body | IMPROVE | Export outcome and policy-content majors are upheld; the missing enable path is demoted to minor and conformance/typing/mapping notes remain open. |
| F17 `tamoz-agent-kernel` | effect dispatcher, session steps, catalogs | IMPROVE | `F17-REL-01` is the existing CF04 effect finding; the B9 wire literal is merged with its kernel catalog finding, and the failed-effect diagnostic remains a local minor. |
| F18 `tamoz-agent-capabilities` | capability registry, MCP source builder, binding | IMPROVE | Policy-to-resume pin bypass major is upheld; duplicate source identity and aggregate resource bound are open minors; browser reachability is a documented closed limitation. |
| F19 `tamoz-agent-memory` | admission/retrieval, lifecycle, transitions | IMPROVE | Admission-to-planning major and missing retention caller major are upheld; receipt/negative-admission and CAS-window notes remain open minors. |
| F20 `tamoz-agent-healing` | failure classification, remediation, rule registry | IMPROVE | Critical repetition proposal is demoted for absent production caller; raw-array verification and second verdict source remain major/open; observation/reachability notes remain open. |
| F21 `tamoz-agent-profile` | profile authority load/adoption/transition | IMPROVE | Pinned snapshot digest major is upheld; concurrent adoption remains minor/open and secure-load/transition bounds are info evidence. |
| F22 `tamoz-agent-session` | session bindings, cancel/recover, effect guards | IMPROVE | Terminal cancel rewrite and session profile guard majors are upheld; claim starvation is owned by F07; continuation/recovery/transcript/docs notes remain open. |
| F23 `tamoz-agent-improvement` | candidate lifecycle, evaluation report, promotion | IMPROVE | Candidate seal/rollback/pipeline majors remain open; human-gate critical proposal is demoted for no production caller; resource/policy/score-floor notes remain open. |
| F24 `tamoz-agent-cli` | command dispatch, rendering, durable observe | IMPROVE | Read-only model path and CLI status contract majors remain open; terminal escaping, follow memory, help taxonomy, and counter notes remain minor/info. |
| F25 `tamoz-agent` | worker runtime, settlement, approval default | IMPROVE | Cancellation projection and accepted-budget majors are upheld; child MCP reachability is unconfirmed and telemetry/scan cost remain minor. |
| F26 `tamoz-evals` | verifier, canonical digest, evidence CLI | IMPROVE | Zero-byte fail-closed and stale release-audit majors are upheld by challenge; zero-assertion status is an open minor contract gap. |
| F27 `tamoz-evals-runner` | input manifest, scorecard, readiness, scoreboard | IMPROVE | Scorecard hard gates are real; the scoreboard hard-zero proposal is demoted to a minor doc/ownership question; CLI tamper and whole-run bound notes remain open. |

## Six-lens and boundary results

The six lenses are complete for all 27 rows. The recurring cross-row conclusions
are:

- **Correctness:** local state machines and validators are usually sound; the
  material failures occur at composition seams (effect resolution, terminal
  cancellation, rendering, schedule settlement, and gate composition).
- **Security and authority:** the four confirmed criticals are F07-SEC-01,
  F08-SEC-01, F09-SEC-02, and F25-SEC-01. Other authority leads were narrowed
  or demoted when no production caller or bypass was found.
- **Reliability and durability:** durable journals/checkpoints are generally
  bounded and fenced, but unknown/failed outcomes, retry ceilings, leases, and
  process shutdown still have open major boundaries.
- **Observability and evidence:** the scorecard and signal catalogs are explicit,
  while stale generated evidence, dropped terminal outcomes, flat traces, and
  hardcoded counters remain open at their owners.
- **Scalability and resource bounds:** local caps are documented in every row;
  eight rows retain a deliberate sustained-load measurement gap in
  `analyses/scalability-lens-review.md`. Unbounded whole-run scripts and retry
  loops remain finding-grade where they have operational reach.
- **Maintenance and architecture:** dependency direction is mostly honest and
  existing seams are reusable. The remaining structural debt is concentrated in
  gate composition, duplicated verdict vocabulary, and a few oversized boundary
  owners already named by the finding records.

## Challenge and overlap decisions

Every coordinator-indexed critical or major finding has a challenge record or a
specific re-review in the shared folder; no such row remains marked `pending` in
`FINDINGS.md`. The important merges and demotions are:

| Decision | Result |
|---|---|
| F17-REL-01 / F22-REL-01 | Duplicate the existing CF04/F07 effect and claim-starvation owners; not counted again. |
| F17-B9-02 | Merged with the kernel B9 catalog finding; one wire-vocabulary owner remains. |
| F10-SEC-03 | Merged with CF05-SEC-01's profile/admission contract decision. |
| F20-REL-01 / F23-SEC-01 | Critical proposals demoted to major because the production callers are absent; the underlying contract observations remain open. |
| F27-COR-01 | Demoted to minor after the benchmark contract and positive scoreboard test were re-read; readiness owns publication blocking, scoreboard owns interval trend recording. |
| R01-GATE-04 | Merged into R01-GATE-01 because both are the same gate-composition root cause. |
| F26-EVD-01 | Ownership narrowed to the S01/R01 generated-audit freshness boundary; F26 is the affected verifier/evidence consumer. |

## Evidence boundary

The reports contain exact focused test results and all known environment reds.
The coordinator did not regenerate committed evidence, call a real model or
external service, run a full release rehearsal, or claim a deployment soak. The
known loopback `Errno::EPERM` failures are preserved as environment deviations;
they do not become product PASS evidence. Open findings remain open because this
package records audit results and recommendations only.

## Net result

All 27 gem responsibilities now have scanner coverage, an independent analyst
record, six-lens evidence, challenge coverage for material findings, and a
coordinator disposition. F04 is the only synthesized gem row at `PASS`; the
other 26 are `IMPROVE` because they retain accepted open critical/major findings
or three-or-more accepted minors. This is audit completion under `BAR.md`, not a
claim that production quality increased: implementation and remediation remain
future work.
