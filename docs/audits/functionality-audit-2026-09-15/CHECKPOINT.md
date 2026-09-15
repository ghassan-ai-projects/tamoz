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

## Completed coordinator wave

| Row | Analyst report | Challenge evidence | Current disposition |
|---|---|---|---|
| F13 — approval | `analyses/F13-approval.md` and `.json` | `analyses/challenge-f13-approval.md` | Six major findings remain open; one scope lead demoted to minor; retention lead closed as accepted design |
| F18 — capabilities | `analyses/F18-capabilities.md` and `.json` | `analyses/challenge-f18-capabilities.md` | One major and two minor findings remain open; browser reachability lead closed as documented limitation |
| F21 — profile | `analyses/F21-agent-profile.md` and `.json` | `analyses/challenge-profile-authority.md` | One major and one minor finding remain open; secure-load and transition controls recorded as info |

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
3. Challenge the five critical/major entries still marked `pending` in
   [FINDINGS.md](FINDINGS.md), then record coordinator dispositions and any
   merges or ownership transfers.
4. Trace CF01–CF13 end to end, including the already targeted CF02, CF04,
   CF05, and CF06 boundaries, and expand S01 into one row per support script.
5. Reconcile `README.md`, `COVERAGE.md`, `FINDINGS.md`, and this checkpoint
   after every bounded wave so the file ledger stays authoritative.

## Evidence and housekeeping

The F13, F18, and F21 analysts and the F13/F18 challengers ran only focused
tests and temporary probes under `/tmp`; no real provider, network service, or
full CI gate was used. The F18 worker HTTP fixture remains blocked by the
sandbox's `Errno::EPERM` socket restriction while its other focused tests pass.
All created audit files are mode `0644`; `git diff --check` and JSON parsing are
required before the integrator commits. No scratch file belongs in the repo.
