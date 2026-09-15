# App, executable, support-script, and Rakefile synthesis — IMPROVE

Date / baseline: 2026-09-15, branch `audit-15-09`, code commit
`582ae5566de1ae073aea82b69bb2bbf444494d3b`.

This coordinator pass reads the shared item-level analyst reports and the
existing challenge records, then checks their ownership and overlap against the
live files. It adds no implementation. The detailed source paths, tests, and
blind spots remain in `analyses/apps-and-entry-points.md` and
`analyses/scripts-and-rake.md`; this file is the synthesis/disposition gate.

## Inventory reconciliation

The reference app has one row, the executable group has nine rows, and the root
Rakefile has one row. `script/` contains 45 top-level entries; one entry is the
`quality/` directory, whose tracked `coverage_totals.rb` is the 46th script file.
`scripts/start-tamoz-comms.sh` is a separate file. The truthful support-file
inventory is therefore 47 files (46 under `script/`, one under `scripts/`), even
though the original queue named 45 `script/` entries. All 45 entry points plus
the nested module have an item-level disposition in `scripts-and-rake.md`.

## Coordinator disposition

| Surface | Analyst evidence | Challenge evidence | Synthesis result |
|---|---|---|---|
| A01 reference app | `analyses/apps-and-entry-points.md` A01 section | `challenge-session-stream-gates.md` | IMPROVE; the namespace claim is demoted to minor because the manifest is inert; README coverage and unused version metadata remain info/minor debt |
| E01 installed `tamoz` | same report E01 | none required | PASS; wrapper, load path, exits, and documented flags agree |
| E02 installed `tamoz-eval` | same report E02; F26 CLI boundary | F26 challenge | PASS as an entry point; zero-byte artifact failure remains F26-ERR-01, not an E02 duplicate |
| E03 installed `tamoz-eval-runner` | same report E03 | none required | PASS by the literal threshold rule; missing `--help` is a minor open item |
| E04 chat probe | same report E04 | none required | IMPROVE; unknown probe exit status is a minor; two documentation/testability notes remain info |
| E05 chat sim | same report E05 | none required | PASS; the untested wrapper is an info limitation |
| E06 repository `tamoz-eval` | same report E06 | none required | PASS; wrapper equivalence and exit ladder were directly exercised |
| E07 repository `tamoz-eval-runner` | same report E07 | none required | PASS; bundle-context wrapper behavior is explicit |
| E08 stream subscriber | same report E08 | `challenge-session-stream-gates.md` | IMPROVE; infinite reconnect remains major/open; path and test notes are info |
| E09 stream worker | same report E09 | `challenge-session-stream-gates.md` | IMPROVE; trap-context SIGABRT remains major/open; startup-order and exit-assertion notes are info |
| S01 support scripts | `analyses/scripts-and-rake.md` item table 1–46 | `challenge-session-stream-gates.md` for S01-BEN-01 | IMPROVE; nine unbounded meaningful subprocess sites remain major/open; seven minor generator/quality/ADR/conformance items are carried |
| S02 comms launcher | same report S02 section | scanner correction in `scripts-and-rake.md` | IMPROVE; whole-`.env` export and stop-match behavior remain two minor/open items; the launcher does start both processes |
| R01 Rakefile | same report R01 section | `challenge-session-stream-gates.md` | IMPROVE; R01-GATE-01 and R01-GATE-02 remain major/open; R01-GATE-04 is the merged duplicate at the same composition seam |

The app/executable and support findings are indexed in `FINDINGS.md` below. The
Rakefile and support-script majors already have independent challenge records;
the only unresolved major challenge requirement in this group is none. Minor
and info observations do not require a separate challenge under `BAR.md`.

## Six-lens synthesis

### Correctness

The entry-point wrappers call the intended in-repo libraries and their argument
grammars match the documented commands. The reference app's `Tamoz::App`
namespace is not loadable, but the manifest is inert and the challenge removed
the assumed external consumer from the severity. The stream launcher's signal
trap is the material correctness/reliability exception: the same serving path
exits 134 on SIGTERM/SIGINT while its test ignores the process status.

The support-script review exercised every item at source level and kept the
nested quality helper in scope. It found no new misattributed cleanup defect;
the material correctness risk is gate composition in R01 and unbounded evidence
children in S01.

### Security and authority

The installed and repository wrappers do not add capability or secret access;
the real-provider scripts are explicitly operator-gated and their credential
values are not printed. `scripts/start-tamoz-comms.sh` is the exception in
degree, not in class: it exports the whole `.env` to both children, contrary to
its own C7 comment. This is `S02-SEC-01`, a minor/open boundary item because the
Ruby children also apply their own allowlists and no leak was demonstrated.

The app metadata and executable help paths are inert. Egress, profile, and
manifest authority findings remain owned by F26/F27 and the relevant gem rows;
this grouped pass does not duplicate them.

### Reliability and durability

The `tamoz`/eval wrappers return typed exits for the paths exercised. The stream
subscriber's retry loop has no ceiling, and the worker's trap calls a
synchronizing gRPC stop from signal context; both are challenged major findings
with clear existing seams. The support scripts that write evidence generally
use caller-owned paths and cleanup, but the nine meaningful `Open3.capture*`
sites have no deadline (`S01-BEN-01`). Rake release rehearsal also runs `ci`
instead of the declared full gate (`R01-GATE-02`).

### Observability and evidence

Entry wrappers expose usage and exit status in the tested cases. The chat probe
prints a warning but exits zero for an unknown name (`E04-COR-01`), which can
make an empty probe set look successful. Release/evidence scripts record their
outputs, but the requirements audit can be stale (`F26-EVD-01`) and the quality
gate composition is not visible in the release rehearsal (`R01-GATE-01/02`).
Those are existing owner findings, not new app/support counts.

### Scalability and resource bounds

The grouped wrappers have no independent queue or memory surface. The stream
subscriber's retry rate is fixed at roughly one attempt per second with no
ceiling (`E08-REL-01`), and S01's unbounded child calls can hold a release or
evidence process indefinitely. The component report records the eight explicit
sustained-load evidence gaps; this synthesis does not claim them measured.

### Maintenance and architecture

The wrappers consistently require the library they invoke, while the app
manifest, documentation checks, Rake tasks, and generated artifacts have split
contracts. `quality:architecture` can no-op without enola, `rake quality` is
enola-only, and `release_rehearsal` names `ci` as its full gate. The challenge
merged R01-GATE-04 into R01-GATE-01; no second quality-composition finding is
created here. The `script/` item table gives each of the 46 tracked script files
an owner, caller, write behavior, and disposition.

## Evidence used

The existing focused results were rechecked from the shared files. This turn
also ran:

| Command | Result |
|---|---|
| `ruby -Itest test/public_api_test.rb` | 3 runs, 1051 assertions, 0 failures |
| `ruby -Itest test/documentation_surface_test.rb` | 9 runs, 87 assertions, 0 failures |
| `ruby -Itest test/agent_cli_test.rb` | inherited item report: 34 runs, 764 assertions, 0 failures |
| `ruby -Itest test/ci_configuration_test.rb` | 2 runs, 15 assertions, 0 failures |
| `ruby -Itest test/release_rehearsal_evidence_test.rb` | 9 runs, 44 assertions, 0 failures |
| `ruby -Itest test/runner_input_manifest_test.rb` | 7 runs, 13 assertions, 0 failures |

The wrapper/launcher negative probes and all 46 support-script source paths are
listed in the two analyst reports. No real provider, Telegram endpoint, full
release rehearsal, or full `rake ci`/`ci_full` run was used. Those boundaries
remain explicit evidence gaps.

## Net disposition

No new machine-counted finding is introduced by this synthesis. Existing
findings are owned as follows:

- app/executable: A01-COR-01 (challenged minor), A01-MNT-01/02, E03-ERR-01,
  E04-COR-01, E04-MNT-01/02, E05-MNT-01, E08-REL-01/MNT-01/MNT-02, and
  E09-REL-01/MNT-01/MNT-02;
- support: S01-BEN-01, S01-GEN-01/02/03, S01-QUAL-01, S01-BEN-02,
  S01-CONF-01, S01-ADR-01/02, S02-SEC-01, and S02-REL-03;
- Rakefile: R01-GATE-01, R01-GATE-02, with R01-GATE-04 merged into the first.

All required lenses, source paths, item-level dispositions, challenge records
for majors, and blind spots are present. The grouped surface remains **IMPROVE**
because E08, E09, S01, and R01 retain open major findings.
