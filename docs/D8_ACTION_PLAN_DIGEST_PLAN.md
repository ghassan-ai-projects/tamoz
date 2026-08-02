# D-8 — Real-model action plans: digest dependency, placeholder rejection, rejection disclosure

Status: **rev 2 — ACCEPT-WITH-REQUIRED-CORRECTIONS integrated** (RC-1..RC-9 from
`docs/reviews/D8_ACTION_PLAN_DIGEST_PLAN_REVIEW.md`; the fresh-context critic verified F1/F2
in full and partially refuted F3 — only structural-layer issues are Tamoz-authored). Not yet
implemented; implementation starts after P10 close (scorecard-baseline discipline). The
implementation round's critic runs the 10 held-out probes from the review record §7.

Origin: Round 15 live-model smoke — read-only works against a real model; action mode fails
on every digest-dependent patch task because the model cannot know `expected_sha256` before a
read executes, and structural review rejects the whole plan when the digest is a placeholder.
The scripted scorecard never exercises this (corpus hardcodes digests at authoring time), so
the gate is green while real use fails.

## 1. Findings (verified by the critic; F3 corrected)

| # | Severity | Finding | Evidence (critic-verified) |
|---|---|---|---|
| F1 | Blocking | A patch step's `expected_sha256` is knowable only after a read executes; structural review rejects the plan when it is missing/placeholder, so the plan's read step never runs | `toolbox.rb:281/283` (`expected_sha256` fetched → `KeyError` "missing tool argument" / "must be 64 lowercase hex characters"), `:341/343` for `create_file`; `deliberation.rb:121-123` validate-error → plan issue; `session_nodes.rb:916` `PlanRejectedError` after the 3-attempt loop (`:108-274`); corpus hardcodes digests at `agent_smoke_corpus.rb:650/695/883` + helper `:1448`; no test pins "missing tool argument" (zero hits in `test/`) |
| F2 | Medium | Models emit template placeholders (`<path from search result>`) for arguments expected from earlier steps; structural review accepts placeholder paths (free-form) but rejects placeholder digests (format check) — inconsistent; path case burns a recovery cycle | `deliberation.rb:100-134` no placeholder logic; `planning_prompt` `:41-89` no placeholder rule; paths pass structural review, fail only at execution (`toolbox.rb:1004-1011` ENOENT → `ToolArgumentError`), discovery keeps them as evidence (`session_nodes.rb:448`, `:783-792` action-only restriction) |
| F3 | Medium (scope corrected) | Plan-rejection failures disclose nothing ("A workflow step failed.") | Mechanism: `NodeError#safe_message` generic unless `original` is `DisclosableMessage` (`gems/tamoz-core/lib/tamoz/error.rb:116-127`); `PlanRejectedError` unmarked (`errors.rb:16`); CLI `error_summary` `cli.rb:566-571`. **Corrected premise:** only **structural-layer** issues are Tamoz-generated; semantic-review issues are model-authored free text (`session_nodes.rb:253-257`), protocol issues quote provider JSON (`plan.rb:76-77`). D-7b authorship rule (docs/reviews/AGENT_TOOL_ERROR_RECOVERY_CORRECTION.md) binds — normalization is not sanitization |

## 2. Fixes

### Fix A (F1, primary) — digest resolved from observation/content, never trusted to the model

- `toolbox.validate` for `apply_patch`/`create_file`: `expected_sha256` becomes OPTIONAL.
  When PRESENT, validation unchanged (64 lowercase hex; the stale-digest refusal must not
  weaken: `toolbox.rb:643-644`). No existing test pins the missing-digest rejection.
- **Single resolution, both drivers (RC-1/RC-2).** Resolution happens exactly once and the
  resolved digest is injected into the arguments passed to BOTH preview and execute, so the
  second binding stays live:

  | Site | Line | Driver | Behavior |
  |---|---|---|---|
  | `Deliberation.structural_issues` | `deliberation.rb:121` | Runtime + Session | accepts absent — safe, no execution |
  | `session_nodes.rb build_intent`/`effect_intent` | `:654-671` | Session | **resolve once** → `intent["before_state"]`; inject `expected_sha256 => before_state` into preview args (`:300`) and execute args (`:604`) |
  | `session_nodes.rb step_gate` preview | `:300` | Session | previews the RESOLVED state; build_intent→preview change → repairable `ToolArgumentError` "file changed" → evidence (`:301-312`/`:713`) |
  | `session_nodes.rb dispatch` execute | `:604` | Session | executes resolved args; post-approval change → `verify_intent_before_state!` (`:624-637`) → `ToolPolicyError` → terminal, fail-closed |
  | `runtime.rb Runtime#execute` preview | `:312` | **Runtime** | **resolve once at execute entry** (before preview) from observation; inject into preview args |
  | `runtime.rb Runtime#execute` execute | `:341` | **Runtime** | inject the SAME resolved digest into execute args → `prepare_patch` equality check (`:643-644`) is the live second binding: mutation between preview and execute, or inside the approval callback, → "file changed" error, no patch |

- The Runtime row is RC-1 — the scorecard's own driver (`agent_smoke_corpus.rb:1366` →
  `agent.rb:37`) has no intent/`verify_intent_before_state!`; today its only approval→execution
  binding is `prepare_patch`'s equality check. With injection, that binding stays live on the
  absent-digest path. Probe 1 (review §7): approval callback mutates the target before
  returning → patch must NOT apply to the mutated bytes.
- **`create_file` (RC-6):** `expected_sha256` is the CONTENT digest, not an observed
  before-state (`toolbox.rb:345-346`, `:752`; `effect_intent` sets `before_state => "absent"`
  at `:403-408`). Resolution = `Digest::SHA256.hexdigest(content)` — no observation. Full
  surface consumes the computed digest: `validate`, `prepare_create_file` (`:698-709`),
  `effect_intent`, `preview` (`:414`), `render_create_preview` (`:765`).
- Invariants 25/26: the injected digest is execution metadata binding execution to the approved
  state; goal/steps/tools/verification are untouched — stated explicitly, not implied.
- Observation consistency: `observe` digests raw bytes (`effect_dispatcher.rb:115-126`),
  `prepare_patch` digests UTF-8-tagged content — identical bytes for valid UTF-8; the two
  digests agree.
- Journal/reconcile/resume: `reconcile_filesystem` (`effect_dispatcher.rb:89-113`) reads the
  resolved `before_state`/`after_digest`; replay re-resolves through the committed intent
  (`find_intent` `session_nodes.rb:697-705`) — resume re-binds to the approved state.

### Fix B (F2, supporting) — scoped placeholder rejection + prompt hardening (RC-4)

- `deliberation.rb structural_issues`: reject placeholder-shaped arguments with the issue text
  `step <id> arguments contain a placeholder; every argument must be a concrete value already
  known from evidence`. Heuristic scope — `<`+`>` containment applies ONLY to `path` arguments
  (never legitimate) and digest-shaped arguments (obsolete once Fix A lands); the whole-string
  rule `\A<.*>\z` and the reference phrases (`from step`, `from read_file`, `from search
  result`) apply to ALL string arguments. **Negative test:** legitimate `<`/`>` in
  `before`/`after`/`content`/`query` (e.g., `a < b` → `a >= b`, generics, HTML) passes
  structural review. A false rejection forces a replan inside `max_plan_attempts` (default 3,
  `session.rb:60`) — bounded, and it can never execute anything (structural rejections precede
  `step_gate`).
- `deliberation.rb planning_prompt`: add the explicit rule — never write placeholders or
  references to other steps in arguments; if a patch needs a digest, read the target in
  DISCOVERY and copy the digest verbatim from the read result. Prompt text is not digested
  (`catalog_digest` covers `ACTION_DESCRIPTIONS` only), so this does not move the catalog
  digest; relational catalog assertions are re-run anyway (RC-7).

### Fix C (F3, operator messaging) — structural-only rejection disclosure (RC-3)

- `PlanRejectedError` includes `Tamoz::DisclosableMessage` (per-class opt-in, D-7b mechanism)
  carrying the bounded summary of **structural-layer issues only** (first 3, ≤512 bytes via
  `Error.disclosable_message`, UTF-8 scrubbed). Semantic-review or protocol feedback yields a
  GENERIC bounded phrase ("the plan did not pass review; the last feedback is not
  discloseable") — model-authored text and provider payloads are never interpolated.
- CLI shows (structural case): `Error: no plan passed review after 3 attempts: step
  "patch-add-method" is invalid: …` — actionable, bounded, backtrace-free. NOT a blanket
  unredaction of `NodeError`.

## 3. Tests

- **T1 regression floor:** full scripted corpus identical — all 15 cases, same
  statuses/digests; `agent.stale-digest` (explicit wrong digest, `:735-740`) and
  `agent.malformed-plan` unchanged; zero "missing tool argument" pins (verified).
- **T2 absent-digest (both drivers):** structural review accepts; resolution is single
  (RC-2); preview digest == executed digest; check runs.
- **T3 placeholder (scoped):** placeholder path → structural issue with the exact message;
  3 attempts → `PlanRejectedError`; negative case: legitimate `<`/`>` passes.
- **T4 disclosure:** structural-reject ×3 → bounded structural issues in the CLI line, no
  model text; semantic-reject ×3 → generic phrase; not-JSON plan ×3 → generic (no provider
  payload quote).
- **T5 (Session driver, explicit scope):** mutate between approval and dispatch on an
  absent-digest plan → `ToolPolicyError`, file byte-identical.
- **T5R (Runtime driver):** approval callback mutates the target before returning `true` →
  patch refused ("file changed"), file byte-identical (probe 1).
- **T7 resume/kill:** kill between approval and dispatch on an absent-digest plan; resume
  re-verifies the committed intent before dispatch; changed workspace → terminal, untouched.
- **T8 repeated action:** repeated identical absent-digest plans → `repeated_action`.
- **T9 create_file:** absent content-digest resolved from `hexdigest(content)`; receipt
  verification passes; mismatch still refused.
- **T10 corpus case `agent.absent-digest-patch` (RC-5):** Runtime driver, absent digest,
  check passes, safety counters 0 — the regression floor on the driver the scorecard uses.
- **T6 THE GATE — real-model smoke re-run:** fresh sandboxed workspace; assert the target
  file bytes EXACTLY (`a + b`); assert `configured_check_passed == true` and
  `terminal_reason: check_passed` in the session record; assert no other file changed;
  record provider/model/commit/date in GAUNTLET_PROGRESS. A live run is not a CI floor — T10
  is.

## 4. Failure model

| Situation | Behavior |
|---|---|
| Unresolved digest reaches execution (either driver) | hard stop — resolution is single and injected into both preview and execute args; Runtime's equality check is the live second binding (RC-1/RC-2) |
| Stale-digest refusal weakened | T1 regression floor fails |
| Placeholder false positive on legitimate `<`/`>` | negative test pins; bounded replan inside `max_plan_attempts` |
| Disclosure widens to model/provider text | T4 semantic/protocol rows fail; `DisclosableMessage` restricted to structural summary |
| `ACTION_DESCRIPTIONS` text change | forbidden in this round (RC-7) — `catalog_digest` would move and P8 pinned profiles would fail closed |
| Real-model smoke still fails | D-8 not closed; diagnose the next link |

## 5. Scope / non-goals (RC-7 corrected)

- In scope: `toolbox.rb` validate + prepare paths, `session_nodes.rb` build_intent/effect_intent/
  step_gate/dispatch, `runtime.rb` Runtime#execute, `deliberation.rb` structural_issues +
  planning_prompt, `errors.rb` PlanRejectedError marker, CLI rendering, tests, one new corpus
  case (T10).
- `ACTION_DESCRIPTIONS` (`toolbox.rb:14-20`) is byte-UNCHANGED — descriptions are digested at
  `toolbox.rb:100-115`, and P8 profile binding (`session.rb:92-104 verify_profile_binding!`)
  would reject pinned profiles on any drift. The planning_prompt rule is prompt text (not
  digested), but relational catalog assertions and the full gate re-run anyway.
- Non-goals: no plan-schema change (`plan.rb` untouched); no new tools; no change to the effect
  journal, approval flow, or check semantics; approval descriptor and preview show the RESOLVED
  digest so the operator sees the exact bound state.

## 6. Definition of done

- [ ] F1/F2/F3 fixes landed with T2/T3/T4/T5/T5R/T7/T8/T9 + corpus case T10.
- [ ] T1 regression floor identical; `rake ci` green under both locales; scorecard unchanged
      (15/12/pass) except the new T10 case; safety counters 0.
- [ ] T6 real-model smoke-B passes and is recorded in GAUNTLET_PROGRESS.
- [ ] The 10 held-out probes from the review record §7 pass against the implementation
      (fresh-context critic).
- [ ] Round closed in trackers.
