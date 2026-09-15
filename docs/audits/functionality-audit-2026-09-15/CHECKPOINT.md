# Audit synthesis checkpoint

| Field | State |
|---|---|
| Date | 2026-09-15 |
| Code baseline | branch `audit-15-09`, commit `582ae5566de1ae073aea82b69bb2bbf444494d3b` |
| Mode | Read-only functionality audit; no implementation requested |
| Package state | Documentation and analyst/challenge reports are in the shared audit folder; production code, tests, and configuration remain untouched |
| Closure | No row is closed; scanner completion and cross-flow closure remain pending under [BAR.md](BAR.md) |

## Filesystem evidence snapshot

The current shared folder contains 29 JSON analyst records expanding to 40 row
surfaces: all 27 gem responsibilities, the app and executable surfaces, and
the aggregate script/Rakefile rows. The declared row counters are 33
`IMPROVE` and 7 `PASS`. Direct parsing of the `findings` arrays and the
reconciled JSON counters both yield 188 finding records. `rollup.py` reports
those counters and is read-only.

All 27 gem IDs now have a standalone JSON row record. Twenty-five gem reports
cover all six lenses; F12 and F17 still lack scalability evidence. The app and
five executable rows also lack a scalability lens. Eight rows therefore remain
incomplete even before scanner and cross-flow gates are considered.

## Completed coordinator waves

| Row | Analyst report | Challenge evidence | Current disposition |
|---|---|---|---|
| F13 — approval | `analyses/F13-approval.md` and `.json` | `analyses/challenge-f13-approval.md` | Six major findings remain open; one scope lead demoted to minor; retention lead closed as accepted design |
| F18 — capabilities | `analyses/F18-capabilities.md` and `.json` | `analyses/challenge-f18-capabilities.md` | One major and two minor findings remain open; browser reachability lead closed as documented limitation |
| F21 — profile | `analyses/F21-agent-profile.md` and `.json` | `analyses/challenge-profile-authority.md` | One major and one minor finding remain open; secure-load and transition controls recorded as info |
| F20 — healing | `analyses/F20-agent-healing.md` and `.json` | `analyses/challenge-healing.md` + `analyses/review-f20-rel02.md` | Critical repetition proposal demoted to major; F20-REL-02 and F20-SEC-01 remain major/open |
| F25 — runtime | `analyses/F25-agent-runtime.md` and `.json` | `analyses/challenge-f25-runtime.md` | Two major findings remain open: cancellation projection and inert accepted budgets |
| F26 — evals evidence | `analyses/F26-evals.md` and `.json` | `analyses/challenge-f26-evidence.md` | Two major findings and one minor generator gap remain open; stale-artifact ownership narrowed |

The coordinator entries are in [FINDINGS.md](FINDINGS.md). Four confirmed
critical findings remain F07-SEC-01, F08-SEC-01, F09-SEC-02, and F25-SEC-01.
F23-SEC-01 and F20-REL-01 are recorded as major after challenge/demotion.
The CF07 occurrence report and its schedule challenge are also indexed as two
open major boundary findings. The separate CF09–CF11 flow report remains an
analyst artifact until its boundary findings receive explicit challenge and
coordinator ownership.

## Remaining work

1. Record a standalone scanner pass for each functionality and update the
   scanner counters; an analyst report alone does not close a row.
2. Complete the eight missing scalability-lens reviews and reconcile the
   report `counts` fields with their `findings` arrays.
3. Preserve independent challenge coverage for any new critical/major finding;
   F20-REL-02 was re-reviewed after the challenger introduced it, and no
   coordinator-indexed critical/major entry is now pending.
4. Trace CF01–CF13 end to end, including the already targeted CF02, CF04,
   CF05, and CF06 boundaries, and expand S01 into one row per support script.
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
