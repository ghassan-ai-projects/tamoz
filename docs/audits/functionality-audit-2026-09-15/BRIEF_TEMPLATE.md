# Functionality audit — analyst brief template (W2 onward)

Copy this skeleton for each row. Every field is mandatory; the "assert THIS"
clause is what stops an agent from softening the bar to fit what it found.

## Environment block (verbatim, every brief)

- Repo: `/Users/ghassan/my-projects/tamoz`, branch `audit-15-09`, HEAD `582ae55`.
- Shell prefix: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`
- Tests: ONE FILE PER COMMAND — `ruby -Itest test/<file>.rb`. Multiple files on one
  command line run only the first.
- Never `bundle install`. Never `git commit`. Never edit production code, tests,
  configuration, gemspecs, fixtures, or any doc outside the two allowed files below.
- Read-only audit. Do not implement fixes. Do not run `rake ci` / `rake ci_full`
  (too slow for a 45-minute budget); focused suites only.

## Read first (in this order)

1. `docs/audits/functionality-audit-2026-09-15/BAR.md` — the six lenses, the finding
   contract, the severity and confidence definitions, the verdict rules.
2. `docs/audits/functionality-audit-2026-09-15/COVERAGE.md` — the row IDs and the
   inventory this brief belongs to.
3. `docs/audits/functionality-audit-2026-09-15/FINDINGS.md` — already-recorded
   findings. Do not re-litigate them; if your row touches one, say how.
4. The row's real source path, end to end, before any test.

## Bar minimum (assert THIS, do not soften)

- Cover ALL SIX lenses explicitly. A lens with no evidence gets the literal words
  `not evidenced` plus one sentence saying what would prove it. Never leave a lens
  unmentioned, and never write "looks fine" without a `file:line`.
- Every claim cites `file:line` in the source you actually read. No claim from
  memory, from a prior audit, or from a scanner log alone.
- Distinguish **proven** from **lead**. A static tool result, a grep hit, an Enola
  heuristic, or a missing test is a lead until you trace the runtime consequence.
- A test you ran is quoted by command and pass count. A test you did not run says
  `not run` with the reason. A test that does not exist says `not found`.
- A finding is recorded only when you can name the observable behavior at risk AND
  the owning seam. Vague "this could be cleaner" items are not findings.
- Severity follows BAR.md verbatim. `critical` requires a boundary/invariant
  violation or unsafe action, not merely surprising code.
- Every critical/major finding needs a five-whys chain ending at a controllable
  design/ownership/evidence cause — not a restatement of the symptom.
- The recommendation is the SMALLEST credible action at the EXISTING owner seam.
  No rewrites, no new classes, no speculative machinery. If the simple path already
  delivers the property, say so and recommend nothing.

## Write exactly two files

1. `docs/audits/functionality-audit-2026-09-15/analyses/<slug>.md` — your report.
2. `docs/audits/functionality-audit-2026-09-15/analyses/<slug>.json` — machine
   summary the coordinator merges (schema below).

Nothing else. No scratch files anywhere in the repo. `chmod 644` both files.
Use `/tmp/tamoz-agents/<name>.log` for the liveness log, one line per unit.

### Report sections (all mandatory, in this order)

```
# <ROW-ID> <gem-or-surface> — <one-line verdict>
Row / queue / baseline (commit, date) / analyst / budget
## Scope and source map        — real files read, with line counts, and the entry seam
## Behavior path               — the end-to-end path, step by step, with file:line
## Lens: correctness            — evidence, or `not evidenced` + what would prove it
## Lens: security and authority
## Lens: reliability and durability
## Lens: observability and evidence
## Lens: scalability and resource bounds
## Lens: maintenance and architecture
## Tests and contracts         — command, pass counts, or `not found` / `not run`
## Findings                    — one block per finding, the full finding contract
## Blind spots                 — what you did NOT read and why it matters
## Verdict                     — PASS / IMPROVE / INCOMPLETE per BAR.md, with counts
```

### `<slug>.json` schema

```json
{
  "row": "F24",
  "surface": "gems/tamoz-agent-cli",
  "verdict": "IMPROVE",
  "counts": {"critical": 0, "major": 1, "minor": 2, "info": 1},
  "lenses": {"correctness": "reviewed", "security": "reviewed",
             "reliability": "reviewed", "observability": "not evidenced",
             "scalability": "not evidenced", "maintenance": "reviewed"},
  "findings": [
    {"id": "F24-ERR-01", "severity": "major", "confidence": "high",
     "status": "open", "title": "...", "seam": "file.rb#method",
     "citations": ["gems/.../file.rb:123"], "five_whys": true,
     "recommendation": "..."}
  ],
  "tests_run": [{"command": "ruby -Itest test/x_test.rb", "runs": 10,
                 "assertions": 50, "failures": 0}],
  "blind_spots": ["..."],
  "coordinator_flags": ["needs independent challenge", "possible duplicate of F07-REL-01"]
}
```

## Report-back to the coordinator (the last message of the run)

One short block, no prose padding:

```
row: F24 | verdict: IMPROVE | critical=0 major=1 minor=2
files: analyses/cli-runtime.md, analyses/cli-runtime.json
tests: ruby -Itest test/agent_cli_test.rb -> 86 runs / 512 assertions / 0F
findings: F24-ERR-01 (major, high, open) at cli.rb#dispatch
flags: needs independent challenge
```

## Housekeeping clause

`chmod 644` every file you create. Zero scratch files anywhere in the repo. End with
`git status --short` showing only the audit package as untracked and your two files
inside it.
