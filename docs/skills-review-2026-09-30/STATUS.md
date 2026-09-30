# Skills — status (2026-10-01)

Status of every [QUALITY_BAR.md](QUALITY_BAR.md) row. Branch `improve-skills`.

| Row | Status | Evidence / note |
|---|---|---|
| A1 | met, lint excepted | `rake syntax test_fast` green; packaging test green. `stream:proto:check` cannot run on this machine (x86 `protoc` without Rosetta), which predates this change. RuboCop offenses in new code were left alone by owner instruction ("no need for linting fix"). |
| A2 | met | enola `diff_snapshot` against the pinned baseline shows no cycle and no layer violation. It flags `Tamoz::Skills` fan-in 14 (the facade, by design) and `cmd_skills` "no caller" (symbol-table dispatch, like every `cmd_*`). It resolved the dead `WorkerRuntime#skill_rejections`. |
| A3 | met | `test/skills_boundary_test.rb`, `test/dependency_isolation_test.rb` (skills loads core only) |
| A4 | met (reviewer) | The catalog is a pinned `guidance` entry; the script runs through an operator `--check`; no new loop, store or execution path |
| K1–K5 | met | existing suites, green throughout; the inertness test now scans every file in the gem, not only the facade |
| K6 | met | `test/skills_reachability_test.rb`: both directions, bundled included; `test/agent_worker_test.rb` |
| P1–P4 | met | `test/skills_spec_conformance_test.rb`: the four REVIEW probe skills now compile (they were 0/4) |
| R1–R4 | met | `test/skills_reachability_test.rb` (scripted model; plumbing only) |
| O1–O4 | met | `test/cli_skills_command_test.rb`, reachability test |
| Q1–Q5 | met | `test/skills_lint_test.rb`; `tamoz --bundled-skills skills check` → "1 skill(s) meet the bar" |
| E1–E3, E5, E6, E9 | met | `test/skills_evidence_verifier_test.rb` (16 tests, each rule with a failing twin) |
| E4, E7, E8 | met offline | graders and controls; not yet measured on a real model |
| M1 | met | `agenteval skills prove`: 12 controls; blinding any gate or the locator fails the proof |
| M2 | **not met — blocked on the owner** | see below |
| M3 | met | nothing here presents a scripted run as capability evidence |

## M2 — the real-model run

- Pre-registered at commit `7a7c7795` (EVAL.md, corpus, graders).
- **The run on 2026-10-01 is invalid and is not reported as a result.**
  - The OpenRouter key reached its $5 spend limit (`limit_remaining: 0`) after two trials, so 34 of 36 trials ended `model_key_refused`.
  - The DeepSeek direct account also has a zero balance.
  - The report is kept as `agenteval/reports/skills-20261001.INVALID-key-limit.json`.
  - The harness now fails closed: two consecutive provider refusals stop the run with exit 2, and any refused trial makes the decision "invalid".
- **What the valid real-model trials show — anecdotes, not a measurement:**
  - Smoke run (before the grader review, `forced` arm, A1): 3/3 planted exceptions found, 0 clean criteria misjudged, every citation verified, every finding `proposed`, 31 s.
  - Main run, A1 `skill` arm, trial 1: the model picked `evidence-audit` by itself from a catalog of five skills. It solved A1 under the corrected graders (3/3, citations verified, report consistent) in 101 s.
  - No valid `none`-arm trial exists, so nothing can be said yet about whether the skill beats the same task without it.
- **To finish M2:** raise the OpenRouter key limit (about $10–15 should cover 36 trials at the observed rate; the smoke trial used about 160k prompt tokens), then run:

  ```bash
  bundle exec rake agenteval:skills:run
  ```

## Findings

| Finding | Status |
|---|---|
| S1 CLI never loads skills | fixed — `--skills DIR`, `--bundled-skills` |
| S2 work loop never shows the catalog | fixed — pinned catalog entry iff `load_skill` is offered |
| S3 profile cannot allow skill tools | fixed — `KNOWN_TOOLS` |
| S4 comma-only `allowed-tools` | fixed — whitespace or commas, scoped tools |
| S5 files beside SKILL.md rejected | fixed |
| S6 dotfile rejects the skill | fixed — dotfiles ignored |
| S7 rejection names the file | fixed — names the skill; path in the detail |
| S8 rejections invisible | fixed — `tamoz skills list|check` |
| S9 no provenance / user invocation | fixed — `skill_loaded` trace, `--skill` |
| S10 limits disagree with the spec | fixed — `--` refused, character limits |
| S11 two skill identities (stream `SkillSet`) | open — a wire contract shared with the Go authority (ADR-055) |
| S12 nothing measures skill value | eval built and proven; real-model result blocked (M2) |
| S13 `tamoz.eval-suite` unused | fixed — the lint test requires the named pack to exist |
| S14 docs drift | fixed — ADR-056, ADR-033/034 verification, design page |
| S15 no skill ships | fixed — bundled `evidence-audit` |
| S16 no script path | used as designed — the verifier runs as an operator check |
| S17 16 KiB text-only reads | open — planned |
| S18 gem home | done — `tamoz-skills` |
| S19 catalog without `load_skill` | fixed |
| S20 (new) | a spend-limit 403 from OpenRouter surfaces as `model_key_refused` ("check the API key"), which sent this investigation the wrong way first. `session_evidence.rb` maps every 403 to a key problem. Open. |

## Noted in passing (not fixed; outside this change)

- `docs/code-quality-baseline.json` is stale repo-wide: `rake quality:reek` reports hundreds of files over baseline, and `quality:baseline_drift` fails. Neither is part of `rake ci`.
