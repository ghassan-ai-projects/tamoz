# P16 — Tools gem extraction: implementation plan

Status: accepted for implementation (revision 3 — re-review ACCEPT-WITH-REQUIRED-
CORRECTIONS on revision 2; C1–C6 integrated: whole-module skills move, `Skills.
canonical` to core, Skills alias, explicit rescue sites, full-surface T2 harness,
T1 matrix axes; see `docs/reviews/P16_TOOLS_GEM_PLAN_REVIEW.md`)
Source question: "can we extract the tools to a gem?" — answered yes; this is the
phase. Authoritative inputs: `AGENT_DESIGN.md` §§3–5, invariants 17, 21, 24–27, 35,
the D-7 taxonomy, the Toolbox, the skills descriptor surface, and `docs/public-api.json`.
Depends on: P10 close; DR-1 (behavior-neutral — the extended prompt-surface identity
inputs move with the toolbox code). Activates after P10 close; its own reviewed round,
never a substitute for a phase proof.

## 1. Scope commitment

Extract the tool primitives and their invariant-bearing core into a new gem
`tamoz-tools`, move the D-7 error taxonomy into `tamoz-core`, and move the skills
descriptor surface (tool-facing) into `tamoz-tools` — WITHOUT changing any observable
behavior, any invariant, or any scorecard result.

| Outcome | Proof |
|---|---|
| `tamoz-tools` gem exists; runtime dependency graph `tamoz-core ← tamoz-tools ← tamoz-agent` with NO agent references inside tamoz-tools | clean-env harness (T2): construct + execute a toolbox with and without skills asserting zero `Tamoz::Agent::*` constants resolved at RUNTIME (load-only checks pass today while runtime coupling silently survives — the harness must execute, not just load) |
| tool primitives + skills descriptor surface moved; behavior byte-identical | T1 digest matrix + T3 + full `rake ci` under both locales; scorecard identical to the BASELINE MEASURED AT P16 START (whatever P10 leaves — never a hardcoded forecast) |
| D-7 taxonomy in `tamoz-core`; class-name serialization stable | T3b: error class/name/rescue-ancestry probes (below) |
| `tamoz-agent` re-exports via constant aliases | alias list + `public-api.json` regenerated; packaged-gem test |

Non-goals: no new tools; no behavior change; no refactor of tool semantics; NO
capability-host unification (that is P18 — MCP descriptors stay caller-supplied at the
agent level, untouched by P16).

## 2. Package boundary and what moves (corrected — the class moves wholesale)

New gem `gems/tamoz-tools` (depends on `tamoz-core` only):

| Moves to `tamoz-tools` (wholesale — one file, byte-verbatim) | Stays in `tamoz-agent` (consumers, not content) |
|---|---|
| `Toolbox` INCLUDING its approval/preview/effect surface: `approval_required` normalization, `DEFAULT_APPROVAL_REQUIRED`, `preview`, `effect_intent`, `catalog_digest` (digests `@approval_required`), `check_safety`, `maximum_effect_output_bytes`, `run_check`, compound-replacement machinery, atomic IO, UTF-8 policy, path/root/symlink validation | session nodes, effect dispatcher, deliberation, plan/review, profile policy, session records — the files that CONSUME Toolbox (session_nodes.rb, effect_dispatcher.rb, runtime.rb, cli.rb, agent.rb) |
| **Skills — WHOLE MODULE (seam decision, C1):** `skills.rb` moves WHOLESALE to
  `Tamoz::Tools::Skills` — the compiler, the descriptor/Data types
  (`SkillRecord`, `SkillResource`, `SkillCollision`, `SkillRejection`, `SkillSource`,
  `SkillSnapshot`, `Catalog`, `Skills::Error`), `LIMITS`,
  `SNAPSHOT_FORMAT_VERSION`, `CATALOG_DIGEST_DOMAIN`, `render_load`/`render_resource`/
  `read_resource`/`read_resource_entry!` — because the descriptor surface is
  interleaved with the compiler and Data types in ONE file; an enumerated split would
  create two `SkillSnapshot` types and break every intake. The "binding machinery
  stays" cell means session.rb's VERIFICATION (which stays), not the compiler. | skills binding/verification in session.rb (stays) |
| **`Skills.canonical` → core (C2):** `skills.rb:177 canonical` delegates to
  `Deliberation.canonical` (deliberation.rb:187) — a runtime agent reference inside
  the moved surface. `canonical` is pure: move it to `tamoz-core`, `Deliberation
  .canonical` delegates, `Skills.canonical` resolves in-tools. | — |
| `LEGACY_SKILL_EPOCH` → **`tamoz-core`**; ALL consumers updated: `toolbox.rb:220`,
  `session.rb:149`, `session_records.rb:23,251` | — |
| `ToolError`/`ToolArgumentError`/`ToolPolicyError` + `DisclosableMessage` normalization → **`tamoz-core`** | all other `Tamoz::Agent::Error` classes |

**Shim (correction 5):** CONSTANT REBINDING, not subclass/delegation:
`Tamoz::Agent::Toolbox = Tamoz::Tools::Toolbox` (and `CheckReceipt`,
`ToolError`, `ToolArgumentError`, `ToolPolicyError` aliases in `tamoz-agent`). A
subclass breaks class identity and `Tamoz::Agent::Toolbox::MAX_*` constant references
in ~20 test files + the evals harness; a delegation wrapper breaks the same plus
attr_readers. **Alias list (C1/C6):** `Toolbox`, `CheckReceipt` (public-api entry),
`ToolError`, `ToolArgumentError`, `ToolPolicyError`, AND `Skills = Tamoz::Tools::Skills`
(the harness uses `Tamoz::Agent::Skills::Compiler`/`SkillSource`/`Catalog`/
`Snapshot.empty` at agent_smoke_corpus.rb:1303-1360 and three test files do
`Skills = Tamoz::Agent::Skills`). An **alias-inventory probe** asserts each enumerated
alias is object-identical to the tools constant. `Tamoz::Tools::ToolError` is the
real class the moved toolbox's own raise sites use (namespace `tamoz/tools` stated).

**Class-name serialization (correction 3):** three sites serialize `error.class.name`
— `effect_dispatcher.rb:188` (effect journal "class"), `session_nodes.rb:306`
(`error_class:` in the session record), `runtime.rb:401` (model-visible failure
payload fed to repair loops). After the move these emit `Tamoz::Core::ToolError`.
Fix: a stable mapping at the three sites (`Core::TOOL_ERROR_CLASS_NAMES`:
`Tamoz::Core::ToolError → "Tamoz::Agent::ToolError"`, etc.), plus a probe comparing
event/record serialization for a scripted failed-effect run byte-for-byte. Verified
safe for the repair loop: the dedup keys (`failure_signature`, `tool_failure_signature`)
hash kind/tool/reason/arguments_digest — NO class name — so the mapping cannot churn
dedup. Downstream string consumers updated: session_nodes.rb:777-779 fallback literal,
agent_tool_error_recovery_test.rb:174/326.

**Rescue ancestry (corrections 4/5):** in core the taxonomy subclasses `Tamoz::Error`
(never `Agent::Error` — that would invert the dependency). Two production rescue
sites catch `Tamoz::Agent::Error` and would silently stop catching the ToolError
family: `cli.rb:51` (bad `--root`) and `agent_smoke_corpus.rb:1382`. Both are updated
to rescue `Tamoz::Agent::Error, Tamoz::Core::ToolError` EXPLICITLY — NOT widened to
`Tamoz::Error` (which also covers StoreError/LeaseLostError/ConfigurationError/
Checkpoint* — widening would convert backtraces on those paths into clean
"tamoz: …" exit-1 output, an observable behavior change). Probe test for the bad-root
CLI path (T3b) AND a StoreError-path probe asserting the backtrace still surfaces.

## 3. Migration and compatibility (corrected)

1. Move files + constants with aliases in one commit; full gate (aliases keep tests
   green; the clean-env harness proves the runtime boundary).
2. `docs/public-api.json` regenerated with the deprecation CONVENTION stated
   (correction 9): the file is a flat string list asserted by `public_api_test.rb` —
   "deprecated" is represented by a new `deprecated: true` entry in the pinned hash
   (test change) or an explicit convention; the plan picks the pinned-hash field.
3. Old-session resume: session records untouched (no schema change); the construction
   site moves, the record stays.
4. The `.tamoz-*` orphan temp-file seam moves with the atomic IO code — recorded; its
   fix lands in P15-C with the same discipline.

**Plumbed files enumerated (corrections 6/10):** `test/test_helper.rb` `GEM_ROOTS`;
`test/packaging_test.rb` install-names array gains `tamoz-tools`
(`test_packaged_agent_scorecard_runs_with_only_installed_tamoz_gems`) and
`test_package_versions_are_valid_and_begin_in_prerelease` (tamoz-tools VERSION must
equal the agent's); `test/public_api_test.rb` is a pinned HASH asserted against
public-api.json — it gains a `tamoz-tools` block and the tamoz-core taxonomy entries
(new field `deprecated: true` for the aliases); a new `dependency_isolation_test`
case for the `tamoz-tools` boundary; the agent gemspec gains
`["tamoz-tools", "= #{VERSION}"]`; the alias-inventory probe (C6).

## 4. Tests (corrected — clean-env harness with teeth)

- **T1 digest matrix (corrected):** compare `catalog_digest`, `prompt_surface_digest`,
  `descriptions`, and constructor-rejection error messages byte-for-byte across
  `{skills empty/nonempty} × {allow_changes} × {checks ∅/present} × {approval_required
  nil/custom} × {check_safeties ∅/present} × {allowed_tools nil/explicit}` (C4 —
  `check_safeties` and `allowed_tools` are digest inputs via `check_safety(name).to_s`
  and the allowed list; `maximum_effect_output_bytes` is method-derived, NOT a digest
  input, excluded explicitly).
- **T2 clean-env runtime harness (corrected — full surface, C3):** a subprocess that
  loads ONLY `tamoz/tools` (+ `tamoz/core`), then constructs AND CALLS the complete
  toolbox surface: both `skill_epoch` branches (empty + skills — the
  `LEGACY_SKILL_EPOCH` NameError path), every `execute` tool incl.
  `load_skill`/`read_skill_resource` with a real skills catalog, `run_check` with a
  real configured check (exercises Open3 + `credential_free_env` + CheckReceipt
  identity), `preview`, `effect_intent`, and a mutation (`apply_patch`/`create_file`)
  in a tempdir. Assertion form: `refute defined?(Tamoz::Agent)` after successful
  execution + a `$LOADED_FEATURES` scan — a leaked require or a
  `Tamoz::Agent::*` reference either raises NameError, fails the run, or defines the
  module. This is the harness that exposes the skills seam and the `skill_epoch`
  NameError — a load-only check passes while runtime calls raise.
- **T3 taxonomy move:** `repairable?` matrix unchanged; disclosure normalization
  unchanged; the class-name mapping probe (correction 3) byte-compares journal/session/
  failure-payload serialization for a scripted failed-effect run.
- **T3b rescue-ancestry probe:** the bad-root CLI path renders `"tamoz: …"` exit 1
  (no backtrace) post-move.
- **T4 scorecard:** identical to the baseline MEASURED AT P16 START (correction 6) —
  capture the pre-extraction aggregate first; compare against it, not a forecast.
- **T5 adversarial:** the D-2/D-4/D-5 multibyte/UTF-8/encoding probes pass on the
  extracted code with zero diffs.
- **T6 packaged gem:** `tamoz-tools` installs in isolation with only `tamoz-core`,
  constructs + executes a toolbox (clean env, correction D).

## 5. Failure model

| Situation | Type | Behavior |
|---|---|---|
| runtime agent reference leaks into tamoz-tools | T2 clean-env harness | fails; boundary enforced |
| shim divergence (class identity/constants) | T1 matrix + T3 | release-blocking until identical |
| class-name serialization drift | T3 mapping probe | fails |
| rescue-ancestry drift (uncaught ToolError) | T3b | fails |
| dependency leak (tamoz-tools requires agent/graph/sqlite) | dependency-isolation test | fails |
| packaged install missing a file | T6 packaged-gem test | fails |
| scorecard delta vs measured baseline | T4 | fails |

## 6. Stop / redesign criteria

- Any behavior byte-diff in the model-visible surface, any scorecard delta, any
  invariant weakened (24–27, 35), any dependency boundary violation, or any
  runtime agent constant resolved inside tamoz-tools.
- If extraction requires touching session/effect semantics to compile, STOP — the seam
  is wrong; report and redesign the boundary.

## 7. Definition of done

- [ ] `tamoz-tools` gem with gemspec, dependency-isolation proof, packaged-gem test
      (T6), runtime clean-env harness (T2).
- [ ] Taxonomy in `tamoz-core`; class-name mapping (T3); rescue sites updated (T3b);
      constant aliases enumerated.
- [ ] Skills descriptor surface moved; LEGACY_SKILL_EPOCH in core; agent re-exports.
- [ ] `public-api.json` + dependency-isolation + packaged tests + gemspec plumbed.
- [ ] Full `rake ci` under both locales; scorecard identical to the P16-start
      baseline; safety counters 0.
- [ ] Trackers updated; the `.tamoz-*` seam and deferrals recorded.
