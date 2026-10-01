# Skills — improvement plan

Grounded in [REVIEW.md](REVIEW.md); every phase meets named rows of
[QUALITY_BAR.md](QUALITY_BAR.md). Phases 1–7 are built in this change. Phases 8–12 are
planned, with the seam each one extends named, so that nothing new duplicates machinery Tamoz
already has.

## Owner decisions (2026-09-30)

| # | Decision |
|---|---|
| D1 | Extract a `tamoz-skills` gem (supersedes ADR-033's "not a new gem"). |
| D2 | Implement everything feasible now; plan the rest. |
| D3 | Real-model eval on OpenRouter `deepseek/deepseek-v4.1-flash`. |
| D4 | Plan a skill creator, a skill optimizer and a skill catalog. |

## Challenges to the brief

These are the places where the request, taken literally, would buy the wrong thing. Each one
changes what is built or when.

1. **The gem extraction delivers no user value by itself.** The skills code already depends only
   on `tamoz-core` and sits in its own directory. Moving it costs a lockfile change, the benchmark
   seal cascade, the dependency review and public API updates, and about 20 touched files. It is
   still worth doing, because it gives the lint, bundled skills and operator helpers one home and
   a boundary test. But it comes *first* only because moving before editing is cheaper than
   editing and then moving, not because it matters most. **S1–S3 (skills unreachable) are what
   matter most.**
2. **A skill cannot guarantee "every finding is linked to its evidence". Only code can.** A
   SKILL.md is advice to a model, and a model can ignore it. The guarantee comes from the
   deterministic verifier — and only when the operator wires it as a check. That is why the
   verifier, not the prose, is the centrepiece of the audit skill. Without the check, Tamoz
   promises nothing about citations. The docs say so plainly.
3. **A verified quote proves provenance, not correctness.** The verifier proves that the quoted
   text is in the cited file at the cited lines, unchanged. It does not prove that the passage
   *supports* the conclusion. That judgement stays with the human reviewer, which is exactly why
   the agent can never approve its own findings. Calling the output "validated" would overclaim.
   The report says "citations verified; conclusions pending review".
4. **The skill may not beat the check.** The verifier's error messages alone can teach a model
   the output contract through the repair loop. So the honest question is not "skill vs nothing"
   but "skill vs the same task *with* the same verifier check". Every arm gets the check, and a
   null result is a legitimate finding to report, not something to tune away.
5. **Build the creator and optimizer after the evidence, not before.** Tamoz has no measured
   evidence yet that any skill helps any model. An optimizer that runs without a per-skill eval
   pack optimises noise, and a creator without an eval gate floods the catalog with plausible,
   unmeasured skills. Phases 9–10 are therefore **gated on the M2 result**: if the audit skill
   shows no lift, the next investment is selection and catalog quality, not generation. Even the
   deterministic scaffold (`tamoz skills new`) waits: nobody has asked to author a skill yet.
6. **A catalog at scale is not needed yet.** The rendered catalog fits about 12 skills in its
   4 KiB budget, and Tamoz ships one. Search and visibility filters would cover a case that has
   never happened (AGENTS.md: "do not cover rare cases"). The trigger for phase 8 is a real
   operator hitting the truncation line, which Tamoz already renders explicitly.

## Built in this change

### Phase 1 — `tamoz-skills` gem (S18; A2, A3)

Move `Tamoz::Tools::Skills` to `gems/tamoz-skills` as `Tamoz::Skills`, then simplify, in two
commits (move, then simplify).

- **Facade:** `Tamoz::Skills.compile(sources:, bindings:, limits:)`, `.empty`,
  `.operator_snapshot(root:, workspace_root:, bundled:)`, `.bundled_root`, `.render_load`,
  `.render_resource`, `.read_resource`, `.lint(record)`, and the value and query types
  `SkillSource`, `SkillRecord`, `SkillResource`, `SkillSnapshot`, `SkillCollision`,
  `SkillRejection`, `Catalog`, `Error`. The type names stay as they are; renaming them would be
  churn without a reader.
- **Internals** (`Compiler`, `Walk`, `Frontmatter`, `FrontmatterScanner`, `Rejected`) become
  private constants. `test/skills_boundary_test.rb` fails when a file outside the gem names one.
- `tamoz-tools` depends on `tamoz-skills`. The `Tamoz::Agent::Skills` alias and
  `Tamoz::Tools::Skills` are removed (no backwards compatibility); callers use `Tamoz::Skills`.
- `WorkerRuntime#skills_snapshot` and the CLI share `Skills.operator_snapshot`, which owns the
  "not inside the workspace" rule for an operator root, so it holds on every path that takes one
  (K6). The bundled source is the gem's own directory and is exempt.
  `WorkerRuntime#skill_rejections` (dead) goes.
- Bundled skills ship in the gem under `gems/tamoz-skills/skills/` as the `bundled` source
  (S15).
- ADR-056 records the gem, superseding ADR-033's placement clause; the Verification lines of
  ADR-033/034 and the design page are corrected (S14).

### Phase 2 — portability (S4, S5, S6, S7, S10; P1–P4, O2)

- `allowed-tools`: a string is split on whitespace and on commas outside parentheses, so the
  spec's form (`Bash(git add:*) Read`) and the comma form Claude Code documents (`Read, Grep`)
  both parse. A YAML list is still accepted, because existing skills use it. An entry may be any
  printable tool token up to 128 bytes, because it is only an upper bound shown to the model.
- The layout accepts any file or directory. Every non-script file is readable; `scripts/` stays
  identity-only (P9-C).
- Entries whose name starts with `.` are skipped: not walked, digested or readable.
- The name rejects `--`. Description and `compatibility` limits count characters, as the spec
  does (1024, and 1–500); Tamoz's byte limits on the manifest and body still bound memory.
- A rejection's `entry` is the skill directory, and the path goes in the detail.

### Phase 3 — reachability (S1, S2, S3, S19; R1–R4)

- CLI: `--skills DIR` adds the operator's directory and `--bundled-skills` adds the skills Tamoz
  ships. Either one enables skills. Both are operator authority on the command line, as P9 §2
  allows, and they apply to the plain and profile toolboxes alike. The runtime directory gains
  `sources.skills.bundled: true` for the worker.
- Work loop: when the toolbox has skills and `load_skill` is on the action surface, the opening
  carries one pinned `skills` entry holding the rendered catalog (the same seam memory and
  guidance use). A skill-free session's opening is unchanged.
- Legacy route: the catalog is added only when `load_skill` is in the toolbox's names (S19).
- Profile: `load_skill` and `read_skill_resource` join `KNOWN_TOOLS`. Whether a profile may use
  skills is its `tools.allowed` list; where skills come from stays operator configuration.
  Profile-carried *sources* (P9-B2) are not needed for that, so they are not built.

### Phase 4 — operability (S8, S9; O1, O3, O4)

- `tamoz skills list` prints accepted skills and rejections; `tamoz skills check` runs
  `Skills.lint` and exits 1 on any issue; `tamoz skills path NAME` prints a skill's directory so
  an operator can wire its script as a check. All three take `--skills DIR` / `--bundled-skills`.
- `--skill NAME` on a work-loop command (`tamoz code`): the named skill is loaded before the first
  model call and pinned in the opening. On a route with no opening it is refused. The work trace
  records a `skill_loaded` event (`skill`, `tree_digest`, `invoked_by: user|model`) for both user
  and model loads.

### Phase 5 — the evidence-audit skill (E1–E9)

`gems/tamoz-skills/skills/evidence-audit/`:

```text
SKILL.md                         the audit workflow (≤ 200 lines)
references/evidence-standard.md  what counts as evidence; quoting and line rules; absence of evidence
references/findings-contract.md  findings.json field by field, with an example
references/review-workflow.md    statuses, what the reviewer does, what the agent must never do
references/severity-rubric.md    high / medium / low / info
assets/findings.schema.json      JSON Schema of the output
assets/report-template.md        REPORT.md skeleton
scripts/verify_findings.rb       the deterministic verifier (stdlib only)
```

The agent writes `audit/findings.json` and `audit/REPORT.md` and never edits a source. The
operator wires the verifier as a check:

```text
SKILL_DIR=$(tamoz --bundled-skills skills path evidence-audit)
tamoz --root WS --bundled-skills --skill evidence-audit --allow-changes \
  --check "evidence=ruby $SKILL_DIR/scripts/verify_findings.rb audit/findings.json" \
  code "Audit the documents in policies/ against criteria.md"
```

So the agent's `run_check` runs the verifier with the operator's authority, and a failed
verification feeds the ordinary repair loop — no new execution path (S16). A human reviewer
runs the same script with `--reviewed` after marking findings, which checks that every
accepted or rejected finding names a reviewer and a decision time, and still verifies against
unchanged sources.

### Phase 6 — lint and the per-skill bar (Q1–Q6)

`Tamoz::Skills.lint(record)` returns the Q-row issues for one compiled record; it is used by
`tamoz skills check` and by a test that runs it over every bundled skill.

### Phase 7 — eval (S12; M1–M3)

See [EVAL.md](EVAL.md). An `agenteval skills` pack: `prove` (offline controls) and `run` (real
model). It is the first consumer of `metadata.tamoz.eval-suite` (S13): a bundled skill names its
pack, and a test checks that the pack exists.

## Built after the first evaluation (owner decisions, 2026-10-01)

The owner asked for the creator and optimizer after challenge 5, and narrowed the optimizer to the skill's
definition only, with `tamoz improve` and the improvement gem unchanged.

- **Creator.** `tamoz skills new` writes a scaffold that meets the bar. `tamoz skills create NAME
  --from-session THREAD` exports a verified thread (scrubbed) into a private drafting workspace, then runs a
  work turn guided by the bundled `skill-authoring` skill. The draft is staged as a digest-pinned candidate
  only when it meets the authoring bar.
- **Promotion.** `tamoz skills promote` installs a candidate exactly as staged: it copies only the digested
  files, digests the copy again, keeps the previous version aside, and logs the promotion. The approver must
  be named and must differ from the recorded creator. The manifest is an operator file, so the digest pin is
  the gate and the names are a record.
- **Optimizer.** `agenteval skills optimize` rewrites only `SKILL.md`. The proposer sees training scenarios
  only. A rewrite is kept when it audits better on held-out scenarios, or audits as well for at most 80% of
  the tokens; it is then staged for promotion. It stops on any trial that did not run, and reports one trial
  per scenario as indicative.
- **Catalog, partly.** `tamoz skills show` was added for reviewing candidates. Search and visibility remain
  planned (challenge 6).
- **Chat.** `tamoz telegram setup` offers the skill tools, pinning the digest they produce, when a skills
  source holding a skill is enabled. The owner's runtime has `sources.skills` enabled, with
  `evidence-audit` and `skill-authoring` in `~/.tamoz/skills`.

## Planned (not built in this change)

### Phase 8 — skill catalog at scale

What exists after phase 3: one rendered catalog of bundled plus operator skills, budget-capped
with explicit truncation. What a large catalog needs:

- **Several named sources** (`--skills name=DIR`, repeatable, and `sources.skills.roots` in the
  runtime config), each with trust and precedence; collisions already need explicit bindings.
- **Search once the catalog exceeds its budget:** a read-only `find_skills` tool (deterministic
  BM25 over name and description, no model call) replaces the truncated tail. The rendered
  catalog then says how many skills exist and how to search them.
- **Visibility** per surface (chat, CLI, scheduled) and per profile, as data in the source
  configuration.
- **Operator catalog view:** `tamoz skills show NAME` prints the body, resource index, digests,
  lint result and eval status.

Extends `Skills::Catalog` and the capability binding; no second catalog.

### Phase 9 — skill creator

Two ways in, one way out:

1. `tamoz skills new NAME` writes a lint-clean scaffold (SKILL.md with the sections the Q bar
   needs, and an eval-pack stub) into a staging directory. It is deterministic and makes no model
   call.
2. `tamoz skills create --from-session THREAD` asks the model to draft a skill from a
   **verified** trajectory (terminal `done`, checks passed), using the bundled `skill-authoring`
   skill as its instructions. The draft is a candidate, never installed by the agent.

The way out is the existing improvement lifecycle. The candidate tree is staged under the
runtime directory's `skills-staging/` and compiled; its tree digest is the candidate
`to_digest` in `Improvement::CandidateProposal` (scope `skill`, which already exists). Then it
is linted (Q bar), evaluated on its eval pack against a no-skill baseline, and promoted only by
a human (`CandidateLifecycle#approve!`; the creator can never approve — `SelfPromotionError`).
Install is an atomic rename into the operator root, which produces a new catalog epoch. A
session in flight keeps its epoch (K5).

### Phase 10 — skill optimizer

Improves an installed skill against its own eval, the way the research budget tuner improves
budgets (`Improvement::ResearchBudgetTuner` + `CandidateLifecycle`):

- **Trigger optimisation (description).** The eval pack carries labelled prompts — should
  select, should not select, confusable neighbours — split into train and held-out. The
  optimizer proposes description variants from the train failures; each variant is scored on
  selection precision and recall with the real model; only the held-out score is reported.
  Held-out isolation reuses the existing `HoldoutIsolationError` guard (raised today by
  `Improvement::Generator`); the seal and self-promotion gates are `EvaluationReport`'s.
- **Body optimisation.** It proposes edits from failed trials' transcripts (which step was
  skipped, which reference was never read) and scores them on the task scenarios, paired
  against the current skill.
- **Promotion:** a candidate wins only if held-out selection and task pass^k do not regress,
  cost stays within the budget, and every gate stays at zero; then a human approves. The
  optimizer never evaluates with the candidate's own instructions (ADR-034).

### Phase 11 — lifecycle (P9-D2)

`tamoz skills install PATH|GIT_URL@COMMIT` stages the skill in quarantine, verifies the
expected digest, unpacks with the walk's limits, lints it, shows the capability diff
(requested `allowed-tools`, scripts added) and asks for approval before the atomic install.
`uninstall` tombstones the binding and keeps provenance.

### Phase 12 — scripts beyond checks (P9-C) and one identity (S11)

- Model-requested script execution: an ordinary reviewed tool with an exact script digest,
  sandbox, environment allowlist, egress policy and budgets. Checks already cover the
  operator-wired case, so this waits for a real need.
- Unify the stream `SkillSet` digest with the tree digest. This is a wire change shared with the
  Go authority (ADR-055) and needs a paired change in `agentic-stream`.

## Commit plan (this change)

1. `docs(skills)`: review, quality bar, plan, eval design.
2. `refactor(skills)`: move into `tamoz-skills` (move only).
3. `refactor(skills)`: facade, private internals, boundary test, operator snapshot (simplify).
4. `feat(skills)`: spec portability.
5. `feat(skills)`: reachability — CLI flag, work-loop catalog, profile tools.
6. `feat(skills)`: `tamoz skills list|check|path`, `--skill`, `skill_loaded` provenance.
7. `feat(skills)`: lint + the evidence-audit skill + verifier.
8. `test(agenteval)`: skills pack, controls, prove.
9. `docs(skills)`: ADR-056, design page and ADR corrections, status and real-run results.

Each commit is reviewed by a sub-agent before it lands.
