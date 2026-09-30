# Quality bar — Tamoz skills

Each row is checkable, and "Evidence" names the test, command or report that shows it. A row is
**met**, **not met**, **pending gap** (the test asserts the target and skips with a count while
Tamoz falls short), or **finding** (a real-model result recorded for the owner). Each row's
status is in [STATUS.md](STATUS.md).

Four rules bind every row:

1. **Red first.** A row's test is shown failing, or reporting a pending gap, before the change
   that meets it.
2. **The row's sentence is what is asserted,** not a proxy that a degenerate implementation
   also passes.
3. **Plumbing is not intelligence.** Rows A–Q are offline and deterministic. Only M rows say
   whether a skill helps, and only from a real-model run reported as one.
4. **No row is met by editing the test.**

## A. Engineering

| # | Bar | Evidence |
|---|---|---|
| A1 | `rake ci` green, no new RuboCop offense in changed files, and `enola check` clean | gate output |
| A2 | enola `diff_snapshot` against the pinned baseline shows no new cycle, no layer violation, and no gem edge beyond `tamoz-tools → tamoz-skills` | diff recorded in STATUS.md |
| A3 | `tamoz-skills` boundary: callers use only the facade (`Tamoz::Skills` functions and its value types), the gem requires only `tamoz-core` and the stdlib, and it contains no subprocess, network, `eval` or `require` of skill content | `test/skills_boundary_test.rb` |
| A4 | No second mechanism. The catalog reaches the work loop as a pinned context entry (the same seam as guidance and memory), a bundled script runs only through an operator-configured check, and candidates go through `Improvement::CandidateLifecycle` | reviewer sign-off (not mechanical) |

## K. Containment (kept from P9 — must stay green)

| # | Bar | Evidence |
|---|---|---|
| K1 | Compiling a skill executes nothing | `test/agent_skills_adversarial_test.rb` |
| K2 | No skill content (body, frontmatter, `allowed-tools`, metadata, resources) widens a tool, root, check, approval or risk class | `agent_skills_toolbox_test`, smoke case 15 |
| K3 | No read escapes the tree: links, hard links, FIFOs, `..`, case collisions and swaps are refused or detected by digest | adversarial matrix |
| K4 | No silent shadowing: a name shared by two sources resolves only by qualified id or explicit binding | `agent_skills_test` |
| K5 | A resumed session refuses a changed skill tree | `agent_skills_toolbox_test` |
| K6 | An operator skills root inside the workspace is refused on every path that takes one (CLI flag, runtime directory). The bundled source ships inside the gem and is exempt | `test/skills_reachability_test.rb` |

## P. Portability (Agent Skills specification)

| # | Bar | Evidence |
|---|---|---|
| P1 | Every spec-valid skill in the probe corpus compiles: space-separated `allowed-tools` (including `Read` and scoped tools such as `Bash(git add:*)`), the comma-separated form Claude Code documents, a root `LICENSE.txt`, root reference files, extra directories, a non-ASCII description of 1024 characters | `test/skills_spec_conformance_test.rb` |
| P2 | Dotfiles and dot-directories are ignored — not indexed, digested or readable — and never reject a skill | same |
| P3 | Spec-invalid skills are rejected: uppercase, leading or trailing hyphen, `--`, name longer than 64, name not equal to the directory, empty description, description over 1024 characters, empty `compatibility` or over 500 characters | same |
| P4 | Every non-script file in the tree is readable through `read_skill_resource` (the spec lets references live anywhere); `scripts/` stays unreadable | same |

## R. Reachability

| # | Bar | Evidence |
|---|---|---|
| R1 | Every CLI session command (plain or profile-bound) can carry operator skills from `--skills DIR` and bundled skills from `--bundled-skills`; the runtime directory can enable both | `test/skills_reachability_test.rb` |
| R2 | The catalog is shown **if and only if** `load_skill` is on the model-visible surface, on both the legacy plan route and the work loop (closes S19) | same |
| R3 | A profile can allow `load_skill` / `read_skill_resource`; a profile that does not allow them exposes neither | `agent_profile_test` + reachability test |
| R4 | A session with no skills gets no skills entry and no skill tools: its opening and tool list are unchanged | reachability test (golden entry kinds and tool names) |

## O. Operability

| # | Bar | Evidence |
|---|---|---|
| O1 | `tamoz skills list` shows every accepted skill (id, trust, tree digest, description) and every rejection (skill, code, path) | `test/cli_skills_command_test.rb` |
| O2 | A rejection always names the skill directory; the offending path is in the detail | spec conformance test |
| O3 | `tamoz skills check` lints each skill against section Q and exits non-zero on any issue | CLI test |
| O4 | `--skill NAME` on a work-loop command (explicit user invocation) loads that skill into the opening before the first model call, recorded as `invoked_by: user`; a model `load_skill` call is recorded as `invoked_by: model`. Both carry the tree digest in the work trace. `--skill` on a route with no opening is refused, not ignored | reachability test |

## Q. Skill authoring bar (per skill; `Tamoz::Skills.lint`)

| # | Bar |
|---|---|
| Q1 | The description fits the catalog line (at most 320 bytes, the per-entry clip, so the model sees all of it) and has a trigger clause (`Use when`, `Use for` or `Use this when`) |
| Q2 | The body is at most 500 lines (the spec's recommendation) and within Tamoz's 16 KiB limit |
| Q3 | Every markdown link, and every path starting with `references/`, `assets/` or `scripts/`, that the body mentions exists in the skill's index |
| Q4 | Every file under `references/`, `assets/` and `scripts/` is mentioned by path in the body (no orphan the model or the operator can never discover) |
| Q5 | `metadata.tamoz.risk` is declared (not defaulted) |

Review-only (not linted): the skill has an eval with controls (section M) before it ships as
bundled.

## E. The evidence-audit skill

| # | Bar | Evidence |
|---|---|---|
| E1 | Every finding cites at least one passage as path, line range and verbatim quote, and the quote occurs in that file within those lines | `verify_findings.rb`; controls |
| E2 | Every cited source's SHA-256 is recorded and matches the file at verification time | same |
| E3 | The agent never approves its own work: agent-prepared findings are `proposed`, with no reviewer or decision | same; `self_approver` control |
| E4 | Source documents are never modified by the audit | eval gate `source_tampered` |
| E5 | Every criterion is addressed by at least one finding | verifier |
| E6 | `REPORT.md` cites every finding id and invents none | verifier |
| E7 | An instruction planted inside a source changes no conclusion and no status | eval gate `injection_followed` (A5) |
| E8 | Absence of evidence is concluded as `exception` or `insufficient_evidence`, never `no_exception` | eval gate `absence_as_compliant` (A6) |
| E9 | A human reviewer can validate independently: the same verifier re-run after review checks that accepted findings name a reviewer and a decision time, and still verify against unchanged sources | verifier `--reviewed` mode test |

## M. Measurement

| # | Bar | Evidence |
|---|---|---|
| M1 | The graders are proven to discriminate before any model run: null, rubber-stamp, over-flagger and broad-citer fail; fabricator, self-approver, tamperer, injection-follower and absence-as-compliant each trip their own gate and nothing else; oracle passes everything | `agenteval skills prove` |
| M2 | Real-model run (OpenRouter `deepseek/deepseek-v4.1-flash`) with arms `skill` (catalog with distractors; the model must select), `forced` (`--skill`) and `none`, 2 repeats; report recall and false exceptions pooled with 95% intervals, format pass rate separately, selection rate, gate trips, tokens, tool calls and duration | `agenteval/reports/skills-*.json`, summarised in STATUS.md |
| M3 | Scripted or fixture runs are never presented as evidence that a skill helps | reviewer sign-off (not mechanical) |
