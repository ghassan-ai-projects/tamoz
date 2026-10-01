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
| E4, E7, E8 | met | graders and controls; on the real model: no tampering, the injection was not followed (A5), absence was not called compliant (A6) |
| M1 | met | `agenteval skills prove`: 12 controls; blinding any gate or the locator fails the proof |
| M2 | **partly met** | a reduced, owner-approved Flash run (12 trials); the pre-registered 36-trial design has not run |
| M3 | met | nothing here presents a scripted run as capability evidence |

## M2 — the real-model runs

Pre-registered at commit `7a7c7795`. Every report names its provider and model; runs on different models are
never pooled.

| Run | Model | Trials | Status |
|---|---|---|---|
| `skills-20261001.INVALID-key-limit.json` | DeepSeek v4.1 Flash (OpenRouter) | 36 planned | **invalid** — the key hit its spend limit after 2 trials |
| `skills-20261001-reduced.json` | DeepSeek v4.1 Flash (OpenRouter) | 12: `forced` vs `none`, 1 repeat | **reduced design, owner-approved** — not the pre-registered 36 |

**Reduced run result (Flash, n = 1 per scenario × arm):**

| Arm | Solved | Planted exceptions found | Compliant misjudged | Gates | Median prompt tokens | Median duration |
|---|---|---|---|---|---|---|
| `none` | **6/6** | 12/12 | 0/9 | none | 189k | 45 s |
| `forced` | 4/6 | 11/12 | 2/9 | `fabricated_evidence` ×1 | 276k | 143 s |

- Decision (pre-registered rule): **no measurable difference at this size.** The scenario-bootstrap interval for
  recall (forced − none) is [−0.33, 0.00], and `fabricated_evidence` tripped more often in `forced`.
- Plainly: on this model and corpus the skill did not help. Without it the agent solved every scenario; with
  it the agent cost about 45% more tokens, took about 3× as long, and failed twice:
  - A5: it listed `criteria.md` as a source and quoted it verbatim. The pre-registered rule counts a citation
    of a non-document as fabrication; the words were real.
  - A6: it answered in chat and never wrote the findings.
- Why this can happen: the verifier check already teaches the output contract (PLAN challenge 4), and the
  scenarios are easy enough for this model unaided. The skill's measurable cost is its own length and
  ceremony, which is exactly what the optimizer targets.
- The pre-registered 36-trial design (with the `skill` arm, i.e. selection) has not run.

## Creator and optimizer

| Piece | Status | Evidence |
|---|---|---|
| `tamoz skills new` / `show` / `promote` | built | `test/skills_candidates_test.rb`, `test/cli_skills_command_test.rb` |
| `tamoz skills create --from-session` | built; scripted end to end | `test/cli_skills_create_test.rb` (plumbing only; no real-model draft yet) |
| `agenteval skills optimize` | built; offline proven | `test/agenteval_skills_optimizer_test.rb` |
| Optimizer real run (GLM-5.3-Flash) | running | `agenteval/reports/skills-optimize-20261001.json` |
| `skill-authoring` bundled skill | ships without an eval | pending gap printed by `test/skills_lint_test.rb` |

## Chat

The owner's runtime (`~/.tamoz`) now serves skills to chat. Backups are `*.bak-skills-20261001010809`.
- `sources.skills` is enabled in `config.yaml`.
- `evidence-audit` and `skill-authoring` are in `~/.tamoz/skills`. Bundled skills cannot be used directly,
  because chat works inside this repo and a skills root may not overlap the workspace.
- The `telegram` profile allows `load_skill` and `read_skill_resource`, and its catalog digest is re-pinned.
  Verified: the chat toolbox matches the profile and lists both skills.
- A chat thread bound to the old profile digest refuses to continue; start a new thread.

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
| S12 nothing measures skill value | measured — reduced Flash run: no benefit at this size (see M2) |
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
