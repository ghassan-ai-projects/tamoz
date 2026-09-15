# Audit synthesis checkpoint

| Field | State |
|---|---|
| Date | 2026-09-15 |
| Code baseline | branch `audit-15-09`, commit `582ae5566de1ae073aea82b69bb2bbf444494d3b` |
| Mode | Read-only functionality audit; coordinator-led continuation per owner request; no implementation requested |
| Package state | Documentation and analyst/challenge reports are in the shared audit folder; production code, tests, and configuration remain untouched |
| Closure | CF01 has a complete PASS review, CF02–CF13 have complete IMPROVE reviews; item-level app/support synthesis and gem-row synthesis remain pending under [BAR.md](BAR.md) |

## Filesystem evidence snapshot

The current shared folder contains 42 JSON analyst records expanding to 53 row
surfaces: all 27 gem responsibilities, the app and executable surfaces, the
aggregate script/Rakefile rows, and CF01–CF13. The declared row counters are 44
`IMPROVE` and 8 `PASS`. Direct parsing of the `findings` arrays and the
reconciled JSON counters both yield 193 finding records. `rollup.py` reports
those counters and is read-only.

All 27 gem IDs now have a standalone JSON row record. All 27 gem reports and
the app/executable rows have a scalability assessment. The app, nine executable
surfaces, 47 support files, and the Rakefile now have item-level coordinator
synthesis in `analyses/entry-support-synthesis.md`. Eight rows retain an
explicit sustained-load measurement gap in
[analyses/scalability-lens-review.md](analyses/scalability-lens-review.md), but
the lens itself is no longer unreviewed. The remaining cross-flow analyst,
support-script, and synthesis gates keep the overall audit incomplete.

## Completed coordinator waves

| Row | Analyst report | Challenge evidence | Current disposition |
|---|---|---|---|
| F13 — approval | `analyses/F13-approval.md` and `.json` | `analyses/challenge-f13-approval.md` | Six major findings remain open; one scope lead demoted to minor; retention lead closed as accepted design |
| F18 — capabilities | `analyses/F18-capabilities.md` and `.json` | `analyses/challenge-f18-capabilities.md` | One major and two minor findings remain open; browser reachability lead closed as documented limitation |
| F21 — profile | `analyses/F21-agent-profile.md` and `.json` | `analyses/challenge-profile-authority.md` | One major and one minor finding remain open; secure-load and transition controls recorded as info |
| F20 — healing | `analyses/F20-agent-healing.md` and `.json` | `analyses/challenge-healing.md` + `analyses/review-f20-rel02.md` | Critical repetition proposal demoted to major; F20-REL-02 and F20-SEC-01 remain major/open |
| F25 — runtime | `analyses/F25-agent-runtime.md` and `.json` | `analyses/challenge-f25-runtime.md` | Two major findings remain open: cancellation projection and inert accepted budgets |
| F26 — evals evidence | `analyses/F26-evals.md` and `.json` | `analyses/challenge-f26-evidence.md` | Two major findings and one minor generator gap remain open; stale-artifact ownership narrowed |
| CF01 — load isolation | `analyses/CF01-load-isolation.md` and `.json` | none required; no critical/major finding | PASS after 22-run dependency isolation contract |
| CF02 — durable replay | `analyses/CF02-durable-replay.md` and `.json` | carried F07-REL-01 challenge evidence | IMPROVE; bounded claim starvation remains open |
| CF03 — plan/approval/effect/repair | `analyses/CF03-reviewed-plan-approval.md` and `.json` | existing F13/F20/F09/F07 challenge and re-review records | IMPROVE; carried authority and reliability findings, no double-counting |
| CF04 — effect identity/replay | `analyses/CF04-effect-replay.md` and `.json` | existing CF04/F17 and F07 challenge records | IMPROVE; CF04-REL-01 and F07-SEC-01 carried, no double-counting |
| CF05 — authority/capability/egress | `analyses/CF05-authority-egress.md` and `.json` | `analyses/challenge-profile-authority.md`; `analyses/challenge-mcp-websearch.md` | IMPROVE; CF05-SEC-01 demoted to info/documentation gap; existing authority and egress findings carried, no double-counting |
| CF06 — request/worker/control routing | `analyses/CF06-control-routing.md` and `.json` | existing `challenge-queue-comms-schedule.md`, `challenge-session-stream-gates.md`, `challenge-f25-runtime.md`, and `challenge-profile-authority.md` | IMPROVE; request identity, fencing, pause/resume, and recovery traced; F07/F22/F25 findings carried, no duplicate count |
| CF07 — schedule/occurrence/worker settlement | `analyses/CF07-schedule-settlement.md` and `.json` | `analyses/occurrence-contract-and-fencing.md` + `analyses/challenge-queue-comms-schedule.md` | IMPROVE; CF07-ARCH-01 and CF07-REL-02 upheld; F05 history/lease findings carried, no duplicate count |
| CF08 — channel/delivery/approval relay | `analyses/CF08-channel-delivery.md` and `.json` | `analyses/challenge-comms-otel-schedule.md` + `analyses/challenge-core-telegram-evals.md` | IMPROVE; F11-COR-01, F12-REL-01, and F14-COR-01 upheld; component demotions/closure carried, no duplicate count |
| CF09 — stream/learning/reverse channel | `analyses/CF09-stream-learning.md` and `.json` | `analyses/challenge-memory.md` + coordinator real-store probe | IMPROVE; CF09-SEC-01 (automatic layer/trust allowlist) upheld as major, CF09-OBS-01 remains minor, and the human-gate lead is demoted to info; F19/F23 findings carried without duplicate count |
| CF10 — memory/lifecycle/consolidation | `analyses/CF10-memory-lifecycle.md` and `.json` | `analyses/challenge-memory.md` + retention probes | IMPROVE; CF10-REL-01 upheld as the missing worker retention caller; the receipt and transition leads are carried under F19 without duplicate count |
| CF11 — healing/improvement/promotion | `analyses/CF11-healing-improvement.md` and `.json` | `analyses/challenge-healing.md`, `review-f20-rel02.md`, and `challenge-improvement-tools-kernel.md` | IMPROVE; all three lead proposals duplicate challenged F20/F23 findings; no new count |
| CF12 — observability/OTLP | `analyses/CF12-observability-otel.md` and `.json` | existing `challenge-observability.md` and `challenge-comms-otel-schedule.md` | IMPROVE; CF12-OBS-01 accepted as one new minor; F15/F16 findings carried without duplicate count |
| CF13 — evaluation/release evidence | `analyses/CF13-evaluation-release.md` and `.json` | existing `challenge-f26-evidence.md`, `challenge-core-telegram-evals.md`, and `challenge-session-stream-gates.md` | IMPROVE; no new machine-counted finding; F26/F27/S01/R01 evidence findings carried without duplicate count |
| Apps/entry/support/Rakefile | `analyses/entry-support-synthesis.md` plus item reports | `analyses/challenge-core-telegram-evals.md` and `analyses/challenge-session-stream-gates.md` | Grouped synthesis complete; A01/E03/E04/S01/S02 minors and E08/E09/R01 majors dispositioned; no new cross-flow count |

The coordinator entries are in [FINDINGS.md](FINDINGS.md). The standalone
inventory/search scanner pass is recorded in
[analyses/scanner-pass.md](analyses/scanner-pass.md); it covers all gem,
app/executable, support-script, and Rakefile surfaces. The complete cross-flow
scanner lane is recorded in
[analyses/crossflow-scanner-pass.md](analyses/crossflow-scanner-pass.md). Four confirmed
critical findings remain F07-SEC-01, F08-SEC-01, F09-SEC-02, and F25-SEC-01.
F23-SEC-01 and F20-REL-01 are recorded as major after challenge/demotion.
The CF07 occurrence report and its schedule challenge are also indexed as two
open major boundary findings. CF09, CF10, CF11, CF12, and CF13 now have
coordinator reports and syntheses; CF11's boundary proposals are explicitly
challenged and owned by the F20/F23 records, while CF12's upstream worker
projection finding is separate from the F15/F16 exporter findings. CF13 carries
existing release-evidence and gate-composition findings without a second count.

## Remaining work

1. Complete coordinator synthesis for the 21 remaining gem rows; the standalone
   scanner pass, item-level app/support review, and CF01–CF13 direct flow reviews
   are complete, and an analyst report alone does not close a row.
2. Preserve explicit throughput evidence gaps for the eight rows listed in
   `analyses/scalability-lens-review.md`; run bounded load/soak work only when
   deployment-level throughput evidence is required.
3. Preserve independent challenge coverage for any new critical/major finding;
   F20-REL-02 was re-reviewed after the challenger introduced it, and no
   coordinator-indexed critical/major entry is now pending.
4. Expand S01 into one row per support script and attach item-level evidence;
   cross-flow source scanning is complete but analyst review is still pending.
5. Reconcile `README.md`, `COVERAGE.md`, `FINDINGS.md`, and this checkpoint
   after every bounded wave so the file ledger stays authoritative.

## Evidence and housekeeping

The F13, F18, F21, F25, and F26 analysts and their challengers ran only focused
tests and temporary probes under `/tmp`; no real provider, network service, or
full CI gate was used. The F18 worker HTTP fixture and F26 MIG-15 witness remain
blocked by the sandbox's `Errno::EPERM` socket restriction while their other
focused tests pass.
All created audit files are mode `0644`; `git diff --check` and JSON parsing are
required before the integrator commits. No scratch file belongs in the repo.
