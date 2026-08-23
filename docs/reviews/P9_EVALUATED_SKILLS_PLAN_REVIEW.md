# Review — P9 evaluated skills plan

Subject: `docs/P9_EVALUATED_SKILLS_PLAN.md`
Reviewer stance: adversarial. The plan is a claim to be falsified against
`docs/PROJECT_HANDOVER_PLAN.md` §6 P9 and §7, `SKILLS_DESIGN.md`, invariants 16/17/24/35/41–43,
and the code as it actually exists at `6dee1b6`. Precedent for tone and structure:
`docs/reviews/P8_TRUSTED_PROFILES_PLAN_REVIEW.md`.

## Verdict

**Accept after correction.** Three critical and five high findings below were found by reading
the plan against the real `Toolbox`, `Runtime`, and `Deliberation` source. All of them have
been corrected in the plan; the corrections are recorded in §"Applied corrections" and are
present in the committed plan text. No product code may be written until they are applied,
per the phase protocol step 3.

The single most serious finding is C-1: the plan asserted two mutually exclusive things about
`Toolbox#catalog_digest`. Left uncorrected it would have shipped either a broken P8 profile
contract or an *invisible tool-surface change*, which is the exact failure invariant 16 exists
to prevent.

## Findings

| ID | Severity | Concern | Required correction | Evidence |
|---|---|---|---|---|
| C-1 | critical | **Self-contradiction that hides a capability-surface change.** §6.1 says the two skill tools "join `READ_DESCRIPTIONS` only when the snapshot has at least one record". §6.3 says "`Toolbox#catalog_digest` keeps **exactly** its current inputs and bytes" and proposes a test asserting a skill-free toolbox and a skill-bearing toolbox have the *same* `catalog_digest`. These cannot both hold: `catalog_digest` is computed from `@allowed_tools`, `@approval_required`, and `@descriptions` (`toolbox.rb:129-140`), so adding two tool names necessarily changes it. Worse, the proposed test would *assert the wrong property* — it would pin down that a two-tool expansion of the capability surface is invisible to the pinned digest. That is a laundering channel, not a compatibility guarantee. | Split the claim. `catalog_digest` must be byte-identical to today **when the snapshot is empty** (the universal case at `6dee1b6`), and must **differ** when skill tools are present, because that is a real capability-surface change and must create a new epoch. Delete the equality test; replace with (a) empty-snapshot digest equals a pinned literal from the current implementation, and (b) non-empty-snapshot digest differs *and* both new names appear in `names`. | `P9 plan` §6.1, §6.3, §10; `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb:111-140` |
| C-2 | critical | **Test A-13 as specified is not implementable and would become a fig leaf.** "compile with `system`/`spawn`/`require`/`load`/`eval` stubbed to raise" cannot be done honestly inside Minitest: stubbing `Kernel#require` breaks the harness, `eval` is a private `Kernel` method invoked by the runtime itself, and a partial stub that silently never fires proves nothing. A test that cannot fail is worse than no test because it manufactures confidence. | Replace A-13 with two mechanisms that can actually fail: (a) a **static source assertion** over `skills.rb` for `eval`, `instance_eval`, `class_eval`, `unsafe_load`, `Marshal`, `system`, `spawn`, backtick, `%x`, `IO.popen`, `Open3`, and `load`; (b) a **`TracePoint`** on `:c_call`/`:call` during the compile of a hostile tree, asserting no `Kernel#system`, `Process.spawn`, `IO.popen`, `Kernel#eval`, `Kernel#load`, or `Kernel#require` fires, together with `$LOADED_FEATURES` length unchanged. | `P9 plan` §9.2 row A-13 |
| C-3 | critical | **Content is allowed to lower a displayed risk classification.** `SkillRecord#risk` is populated from `metadata["tamoz.risk"]`, i.e. from skill content, and defaults to `guarded`. A hostile skill can declare `tamoz.risk: read_only` and have Tamoz render it as low risk in the catalog. The P9 hard gate is explicit that content "can never … lower a risk classification", and invariant 35 says manifests "cannot grant or lower risk". | Rename the field `declared_risk` and label it in every rendering as author-declared. Add a separate `trust`-derived value that is the only thing any consumer may treat as a risk signal. `declared_risk` participates in digests (identity) but never in any comparison, ordering, filter, or policy decision. Add a test asserting a skill declaring `read_only` renders as author-declared and does not change any Tamoz-side classification. | `P9 plan` §3 (`:risk`), §4.1, §6.2, §6.4 |
| H-1 | high | **TOCTOU argument is imprecise where it matters most.** §6.2 pairs `File.realpath(absolute) == absolute` (step 5) with `File::NOFOLLOW` (step 6) and calls the result escape-proof. `O_NOFOLLOW` guards only the *final* component. An attacker who swaps an intermediate directory for a symlink between step 5 and step 6 defeats both checks; only the step-7 digest comparison saves the read. The plan calls step 7 a "backstop" without stating that it is, for intermediate components, the *primary* defence. | State the residual precisely: a mid-path swap can only succeed by producing bytes whose SHA-256 equals the digest pinned at compile time, so a successful swap conveys exactly the content the operator already indexed and therefore transfers zero information. Additionally re-verify `File.realpath(absolute) == absolute` **after** the read and before returning, narrowing the window. Record this as a named residual risk. | `P9 plan` §6.2 steps 5–7, §14 |
| H-2 | high | **Observation-budget interaction is unanalysed and will produce confusing terminals.** `Runtime#execute` only pre-reserves budget for approval-required tools (`runtime.rb:298-301`); every other tool's output is added to `total_bytes` after the fact and a breach of `MAX_OBSERVATION_BYTES = 160 KiB` raises a bare `ToolError` (`runtime.rb:335-337`). With `MAX_BODY_BYTES = 32 KiB` and `MAX_READ_BYTES = 64 KiB`, two loads and two reads (192 KiB) exceed the budget and abort a plan with an unattributed error. | Reduce the *returned* sizes: `MAX_BODY_BYTES = 16 KiB` and `MAX_READ_BYTES = 16 KiB`. State the interaction explicitly, and note that the index may still contain files up to `MAX_RESOURCE_BYTES = 256 KiB` (identity coverage) which simply cannot be read whole. | `P9 plan` §4.2.1 limits, §6.2; `gems/tamoz-agent/lib/tamoz/agent/runtime.rb:282-337` |
| H-3 | high | **Absolute paths can leak into prompts and durable records.** `SkillRecord` carries `source_root` and `directory`, both absolute. `load_skill` output is an observation, and observations are written to durable session records (`session_records.rb:122-133`) and into model prompts (`deliberation.rb:76-87`). The plan bans absolute paths only in `SkillRejection#detail`. Nothing stops a future renderer, or a debugging `inspect`, from putting the operator's home directory into a checkpoint. | Extend the rule to the whole subsystem: no absolute path may appear in any rendered catalog line, `load_skill` output, `read_skill_resource` output, tool error message, or durable record. `source_root`/`directory` exist only for filesystem access. Add a test that greps every rendered string and the built session record for the temp-root prefix. | `P9 plan` §3, §6.2, §8.1 |
| H-4 | high | **Skills are silently unusable under a P8 profile, and the plan does not say so.** `Profile::KNOWN_TOOLS` (`profile.rb:36`) is a closed list that does not contain `load_skill` or `read_skill_resource`, and `tools.allowed` must be a subset of it (`profile.rb:549-554`). `Toolbox#normalize_allowed_tools` then restricts the surface to that list (`toolbox.rb:379-394`). So a profile-bound session can never see a skill tool. This is a correct fail-closed outcome, but an undocumented one that a reader would discover only by experiment. | Document it as an explicit, intentional limitation of this run and tie it to §12.2 (P9-B2 lifts it together with profile schema v2, after P8-E). Add a test asserting a profile-bound toolbox exposes no skill tool even when a snapshot is supplied. | `P9 plan` §2.1, §12.2; `gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:36,549-563`; `toolbox.rb:379-394` |
| H-5 | high | **Corpus growth is asserted, not defended.** The run bar permits adding a P9 case only if existing case identity fields are untouched. The plan states this but proposes no mechanism. `content_digest` is recomputed by `script/generate_agent_smoke_fixtures` for every case on every run, so an accidental change to the shared `case_document` template would silently re-digest all thirteen. | Add a regression test pinning the thirteen pre-existing `case_id`/`case_digest` pairs as literals, so any change to an existing case identity fails CI rather than passing quietly. | `P9 plan` §9.4; `script/generate_agent_smoke_fixtures:29-95`; `gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_scorecard.rb:153-162` |
| M-1 | medium | Duplicated helpers. The plan defines `Skills.deep_freeze` and `Skills.canonical` "so `skills.rb` does not depend on `profile.rb`". But `Plan.deep_freeze` (`plan.rb:79`) and `Deliberation.canonical` (`deliberation.rb:176`) already exist, are already required before `toolbox.rb` in `agent.rb:5-7`, and are already the canonicalisation used by `Profile` and `SessionRecords`. A third copy is a divergence risk for digest semantics. | Reuse `Plan.deep_freeze` and `Deliberation.canonical`. Delete the proposed duplicates. | `P9 plan` §3; `plan.rb:79`; `deliberation.rb:176-187`; `agent.rb:5-7` |
| M-2 | medium | `SkillRejection#detail` is excluded from the catalog digest by the §4.4 tuple but the plan never says so, leaving a reader to assume an unstable free-text string can churn the epoch. | State explicitly that only `[source_id, entry, code]` participates, and why. | `P9 plan` §4.4, §8.1 |
| M-3 | medium | `SkillSource#precedence` does nothing. §5 forbids it from resolving collisions (correctly), and nothing else consumes it. An unused authority-shaped field invites a future contributor to "make it work". | Keep it, but state its only purpose: deterministic ordering of the candidate list in the ambiguity error and the catalog. Assert in a test that changing precedence never changes which record a bare name resolves to. | `P9 plan` §3, §5 |
| M-4 | medium | §6.4 claims the planning prompt is byte-identical without skills, but does not say how the catalog reaches `Deliberation.planning_prompt`, which takes fixed positional arguments plus `toolbox:` (`deliberation.rb:41`). If the signature changes, every caller in `Runtime` and `SessionNodes` changes with it. | Specify that the catalog is read off the existing `toolbox:` keyword; no signature change, no caller change. | `P9 plan` §6.4; `deliberation.rb:41-63`; `runtime.rb:408-418` |
| L-1 | low | §9.2 A-1 claims a `..` path component is "impossible to construct". It is constructible on disk; what is impossible is for it to survive the component regex. | Reword to "a directory literally named `..` cannot be created, so the test creates a component containing `..` such as `a..b` and a nested path attempting traversal; both are handled by the component pattern". | `P9 plan` §9.2 |
| L-2 | low | The empty-snapshot `skill_catalog_digest` sentinel is described as a hash of the literal string `"empty"`, which is not the same construction as a real catalog digest and cannot be reproduced by `Compiler#compile` on zero sources. | Define `Snapshot.empty` as the ordinary output of compiling zero sources, so the sentinel is just its `catalog_digest` and there is one code path. | `P9 plan` §6.3 |

## Things the plan gets right and must not be weakened

- §2's refusal to put skill sources in the P8 profile *yet*, with three concrete reasons, one
  of which is that P8-E has not run. That is the correct call and the correct honesty.
- §11's per-gate conditionality table, including the explicit "**No**" row for the
  source-list gate. This must survive into the final report verbatim in substance.
- No symlinks at all inside a skill tree, and `nlink == 1` for regular files. Stricter than
  `SKILLS_DESIGN` §3 requires and correctly justified as removing an escape surface rather
  than managing one.
- The digest-derived attribution delimiter plus compile-time rejection of `<<<TAMOZ_SKILL` in
  a body. This makes the untrusted-content boundary unforgeable *and* deterministic, which a
  random nonce would not be.
- `precedence` never auto-resolving a collision. Auto-resolution is exactly the silent
  shadowing invariant 41 forbids, and the plan refuses it even though it would be convenient.
- Fail-closed resume on any skill epoch change, stricter than P8's resume policy, with the
  reason stated (changed instructions are not the same instructions).
- Rejections being part of the catalog digest, so a skill vanishing through invalidity is a
  visible epoch change.
- `scripts/` indexed for identity but unreadable and unexecutable in this run.

## Applied corrections

All C and H findings are corrected in the committed plan:

- **C-1** — §6.3 rewritten: `catalog_digest` unchanged for an empty snapshot, deliberately
  changed when skill tools are present; the false equality test replaced by the two tests
  named above; §10's compatibility row rewritten.
- **C-2** — §9.2 A-13 replaced by the static-source assertion plus the `TracePoint` assertion.
- **C-3** — `risk` renamed `declared_risk` throughout §3, §4.1, §6.2, §6.4, with the
  never-consumed rule and its test.
- **H-1** — §6.2 residual stated precisely, post-read realpath re-verification added, §14 row
  added.
- **H-2** — `MAX_BODY_BYTES` and `MAX_READ_BYTES` reduced to 16 KiB with the
  `MAX_OBSERVATION_BYTES` interaction spelled out.
- **H-3** — no-absolute-path rule extended to the whole subsystem, with a grep test.
- **H-4** — profile/skill-tool incompatibility documented in §2.1 and §12.3 with a test.
- **H-5** — thirteen pinned case identities added to §9.4.
- **M-1…M-4, L-1, L-2** — applied as described.

## Pre-implementation checklist

1. Plan and this review committed together, documentation only.
2. `Toolbox#catalog_digest` for an empty snapshot pinned as a literal **before** any change to
   `toolbox.rb`, so C-1's compatibility half is measured rather than assumed.
3. The thirteen existing case digests pinned before the corpus grows.
4. Adversarial tests written before or with the compiler, not after.

## Single biggest remaining risk after correction

The source list is still not profile-bound (§2), so P9's containment proofs are conditional on
whoever calls `Skills::Compiler` being trustworthy. That is unavoidable in this run and is
stated in §11, but a reader skimming a green scorecard could mistake "zero authority gained
from content" for "skills are safe to accept from anywhere". They are not, and P9-B2 plus
P8-E are both required before that stronger claim can be made.
