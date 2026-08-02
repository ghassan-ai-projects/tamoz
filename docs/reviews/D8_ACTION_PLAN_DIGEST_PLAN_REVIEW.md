# D-8 action-plan digest dependency — design review

Review target: `docs/D8_ACTION_PLAN_DIGEST_PLAN.md` (draft)
Reviewer role: harsh fresh-context critic — every claim verified against code, no trust.
Reviewed against: `gems/tamoz-agent/lib/tamoz/agent/{session_nodes,deliberation,toolbox,errors,runtime,session,agent,effect_dispatcher,plan}.rb`,
`gems/tamoz-core/lib/tamoz/error.rb`, `gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb`,
`docs/GAUNTLET_PROGRESS.md` (Round 15), `docs/design-v0.1/INVARIANTS.md`,
`docs/reviews/AGENT_TOOL_ERROR_RECOVERY_CORRECTION.md` (D-7b policy).

Verdict: **ACCEPT-WITH-REQUIRED-CORRECTIONS** — the diagnosis is accurate and Fix A's core
mechanism is sound on the durable path, but Fix A omits the ephemeral `Runtime` driver from
its caller enumeration (an approval-binding hole on the driver the scorecard actually uses),
Fix C as written discloses model-authored and provider-quoted text, and Fix B's placeholder
heuristic false-positives on legitimate patch text. Corrections RC-1…RC-9 below are required
before implementation.

---

## 1. Findings verification (F1/F2/F3)

| Claim | Verdict | Evidence |
|---|---|---|
| F1: patch `expected_sha256` knowable only after a read executes; structural review rejects missing/placeholder digest, so the plan's read step never runs | **CONFIRMED** | `toolbox.rb:281` `digest = normalized_arguments.fetch("expected_sha256")` (missing → `KeyError` → `"missing tool argument"`), `toolbox.rb:283` `"expected_sha256 must be 64 lowercase hex characters"`; same for `create_file` at `toolbox.rb:341/343`. Structural review wraps validate errors as plan issues: `deliberation.rb:121` validate, `:122-123` `rescue ToolError` → `step <id> is invalid: <message>`. Plan loop exhausts then raises at `session_nodes.rb:916` `PlanRejectedError, "no plan passed review after #{max_plan_attempts} attempts"` (loop at `deliberate` `session_nodes.rb:108-274`). The read step never runs because rejection happens before any `step_gate`. |
| F1: corpus hardcodes digests, gate green while real use fails | **CONFIRMED** (line drift) | `agent_smoke_corpus.rb:650`, `:695`, `:883` inline `Digest::SHA256.hexdigest(...)`; the 4th site is the `action_plan` helper default arg at **`:1448`**, not `:1454` as the doc says. The stale-digest case passes an explicit wrong digest (`:738` `action_plan(..., digest: "0" * 64)`), so no scripted case ever presents a *missing* digest. Raw smoke log is not in the repo; the committed evidence is GAUNTLET_PROGRESS Round 15, and the rejection mechanism (format check at `toolbox.rb:283`) is code-verified. |
| F2: no placeholder detection in structural review; paths free-form vs digests format-checked (inconsistent) | **CONFIRMED** | `deliberation.rb:100-134` `structural_issues` contains no placeholder logic; `planning_prompt` (`deliberation.rb:41-89`) has no placeholder rule. `validate_path_argument!` (`toolbox.rb:1028-1035`) checks only type/null/bytes/absolute — a `<path from search result>` path passes structural review and fails only at execution (`resolve` ENOENT → `ToolArgumentError "path does not exist"`, `toolbox.rb:1004-1011`), which in discovery becomes evidence while the plan continues (`evaluate` `session_nodes.rb:448`, `current_pass_tool_failure` restricted to action/repair at `:783-792`). Digest placeholders are rejected earlier by the format check — the inconsistency is real. |
| F3: plan-rejection failures disclose nothing; issues are "Tamoz-generated validation text" | **PARTIALLY REFUTED** | Mechanism confirmed: `NodeError#safe_message` returns generic unless `@original.is_a?(DisclosableMessage)` (`gems/tamoz-core/lib/tamoz/error.rb:116-127`); `PlanRejectedError < Error` with no marker (`errors.rb:16`); CLI renders `safe_message` (`cli.rb:567`, `error_summary` at `cli.rb:566-571`); Round 15 CLI verbatim `A workflow step failed. (node deliberate)`. **But** the premise "the rejection issues are Tamoz-generated" is false for the full issues pool: `deliberate` sets `feedback` from the semantic reviewer's `review.fetch("issues")` (`session_nodes.rb:253-257`) — free-form *model-authored* text that can quote evidence/file contents — and from `ProtocolError` messages (`session_nodes.rb:167-175`), and `Plan.parse` produces `"model returned invalid JSON: #{JSON::ParserError#message}"` (`plan.rb:76-77`), which quotes the raw provider payload. Only **structural-layer** issues qualify under the D-7b authorship rule. |
| F3: `NodeError#safe_message` at `error.rb:103-113` | **CONFIRMED, line drift** | The file is `gems/tamoz-core/lib/tamoz/error.rb`; `safe_message` is at **116-127**, `DisclosableMessage` at 21-23, `Error.disclosable_message` (512-byte clamp, control-char scrub) at 61-76. `MAX_DISCLOSED_BYTES = 512`. |

---

## 2. Fix A soundness (the load-bearing question)

### 2.1 Caller enumeration — verified, and it is INCOMPLETE

Every path that can run an `apply_patch`/`create_file` argument set through the toolbox:

| Site | Line | Driver | Digest-absent behavior under the draft |
|---|---|---|---|
| `Deliberation.structural_issues` | `deliberation.rb:121` | Runtime **and** Session (shared) | accepts absent — safe, no execution |
| `session_nodes.rb` `build_intent` → `toolbox.effect_intent` | `:654-671` (effect_intent `toolbox.rb:390`) | Session | must resolve into `intent["before_state"]` |
| `session_nodes.rb` `step_gate` → `toolbox.preview` | `:300` (preview `toolbox.rb:414`) | Session | must preview the **resolved** state |
| `session_nodes.rb` `dispatch` → `toolbox.execute` | `:604` (execute `toolbox.rb:359`) | Session | must execute the **resolved** args |
| `runtime.rb` `Runtime#execute` → `toolbox.preview` | `:312` | **Runtime** | **not addressed by the draft** |
| `runtime.rb` `Runtime#execute` → `toolbox.execute` | `:341` | **Runtime** | **not addressed by the draft** |

The draft's Fix A-3 names only "structural review / step_gate preview / execute path / reconcile
path" — all Session-path sites. It **omits the `Runtime` driver entirely** (`runtime.rb:312/341`).
This is material because the scripted scorecard runs `Tamoz::Agent.build` → `Runtime.new`
(`agent_smoke_corpus.rb:1366`, `agent.rb:37`), and `Runtime` has **no intent and no
`verify_intent_before_state!`**: today its only approval→execution binding is `prepare_patch`'s
equality check (`toolbox.rb:644` `"file changed: expected digest …, observed …"`). If
`prepare_patch` silently resolves an absent digest from its own read, a file mutated between
`preview` (`runtime.rb:312`) and `execute` (`runtime.rb:341`) is patched against bytes **nobody
reviewed**, with no error. RC-1.

### 2.2 The present-but-stale refusal and the second binding

`prepare_patch` (`toolbox.rb:635-644`) is the only stale-digest enforcer; the Session path adds
`verify_intent_before_state!` (`session_nodes.rb:624-637`, `EffectDispatcher.observe`) as the
primary binding and `prepare_patch` as a live second check during execution. If absent-digest
resolution is implemented as "prepare_patch resolves from its own read", that second check
becomes a tautology on the absent path (digest == the just-read content, always equal), and a
second, independent resolution also happens in `effect_intent` and `preview`, creating a
build_intent→preview TOCTOU where the preview can show bytes different from `before_state`.

**Required shape (RC-2):** resolve exactly **once**, in `build_intent`/`effect_intent`; inject
`expected_sha256 => intent["before_state"]` into the arguments passed to BOTH `preview`
(`session_nodes.rb:300` currently passes raw `step.fetch("arguments")`) and `execute`
(`session_nodes.rb:604` currently passes raw `arguments`). Then:
- a build_intent→preview change becomes a repairable `ToolArgumentError` ("file changed") at
  preview → evidence (step_gate's `rescue ToolArgumentError` → `tool_failure_update`,
  `session_nodes.rb:301-312`/`713`);
- a post-approval change hits `verify_intent_before_state!` → `ToolPolicyError`
  (`session_nodes.rb:630-635`) → `repairable? == false` (`errors.rb:41-43`) → journalled
  `repairable: false` (`effect_dispatcher.rb:129-136`) → `step_execute` raises
  (`session_nodes.rb:403-406`) → terminal. Fail-closed, matching today's present-digest path;
- the approval preview and the executed bytes are the same bytes by construction.

### 2.3 Everything else checks out

- **Journal/reconcile:** `reconcile_filesystem` (`effect_dispatcher.rb:89-113`) reads
  `intent["before_state"]`/`intent["after_digest"]` — resolved values, semantics unchanged;
  the journal `request` records the raw plan arguments and replay re-resolves through the
  committed intent (`find_intent` `session_nodes.rb:697-705`), so resume re-binds to the
  approved state. Resume-safe.
- **create_file:** `expected_sha256` is the *content* digest, not an observed before-state
  (`toolbox.rb:345-346` mismatch check; `:752` receipt verification; `effect_intent` sets
  `"before_state" => "absent"` at `:406`). Resolution = compute `hexdigest(content)`, no
  observation needed; the draft's blanket "resolve via `EffectDispatcher.observe`" is imprecise
  here. `effect_intent` (`:403-408`), `render_create_preview` (`:765`) and
  `prepare_create_file` (`:698-709`) all consume the digest and must use the computed one. RC-6.
- **Stale-digest/malformed unchanged:** present-but-stale still refused (`toolbox.rb:643-644`),
  `agent.stale-digest` corpus case untouched (`agent_smoke_corpus.rb:735-740`), malformed-plan
  still a ProtocolError. A missing digest today raises `"missing tool argument"` — **no test
  pins that** (zero `missing tool argument` matches in `test/`), so relaxation breaks nothing.
- **Invariants 25/26:** the injected digest is execution metadata binding execution to the
  approved state, not a change to goal/steps/tools/verification — the doc should say this
  explicitly rather than leave it implied. `verify_intent_before_state!` is at
  `session_nodes.rb:624` (doc says "~600").
- **Observation consistency:** `observe` digests raw bytes (`effect_dispatcher.rb:115-126`),
  `prepare_patch` digests UTF-8-tagged content — identical bytes for valid UTF-8, so the two
  digests agree.

---

## 3. Fix B soundness (placeholder heuristic)

- **"Never executes" is TRUE:** a structural rejection routes `feedback = structural; next`
  (`session_nodes.rb:176-183`) with no `step_gate`/preview/execute reachable; replan is bounded
  by `max_plan_attempts` (default 3, `session.rb:60`, `agent.rb:32`).
- **"Bounded" is misleading:** bounded-in-attempts ≠ harmless. Three false rejections end the
  task with `PlanRejectedError` (`session_nodes.rb:916`). The rule "a value containing `<` and
  `>`" applied to *every step-argument string* false-positives on pervasive legitimate content:
  comparisons (`a < b`, `x >= y` — the very class of bug this round exists to fix), generics
  (`List<T>`, `Map<K,V>`), HTML/XML fragments, ERB/template text, shell redirects in docs,
  markdown. A real fix that turns `a - b` into `a + b` is safe, but `a < b` → `a >= b` dies in
  review. **RC-4:** apply `<`+`>` containment only to `path` (never legitimate; the observed F2
  failure) and digest-shaped arguments (obsolete once Fix A lands); keep the whole-string
  `\A<.*>\z` and reference-phrase (`from step` / `from read_file` / `from search result`) rules
  for other strings; add a negative test pinning that legitimate `<`/`>` in `before`/`after`/
  `content`/`query` passes structural review.
- The planning_prompt addition (Fix B) changes `feedback`/prompt bytes but no pinned prompt
  constant exists (`test/agent_skills_toolbox_test.rb:247-255` compares skill-free vs
  with-skills, not a literal), and ScriptedModel ignores prompts, so T1 is unaffected.

---

## 4. Fix C soundness (rejection disclosure)

- Mechanism verified end-to-end: marker → `NodeError#safe_message` (`tamoz-core/error.rb:116-127`)
  → `Error.disclosable_message` (`:61-76`, 512-byte clamp, UTF-8 scrub, control-char strip,
  fallback) → CLI `error_summary` (`cli.rb:566-571`). The doc's example CLI line is accurate
  *for structural issues*.
- **Unsound as written.** "First 3 issues" drawn from the reviews pool can be:
  1. semantic-review issues — model-authored free text (`session_nodes.rb:253-257`), able to
     quote file contents or evidence the model was shown;
  2. protocol issues — `"model returned invalid JSON: #{parser.message}"` (`plan.rb:76-77`),
     which quotes the raw provider payload.
  Both violate the D-7b authorship rule ("must never interpolate a provider response body…
  file contents"). `Error.disclosable_message` normalization is **not sanitization** — scrubbing
  control characters cannot make model text safe. **RC-3:** the disclosed summary must be
  restricted to `layer == "structural"` review records; when the last attempt's feedback was
  semantic or protocol, disclose a generic bounded phrase. (Invariant 24 is the wrong frame —
  its subject is `Tamoz::Secret`; the binding constraint is the D-7b rule, which the doc cites.)
- Procedurally consistent: the D-7b record explicitly deferred widening `PlanRejectedError`
  "not widened without a reason"; Round 15 supplies the reason. Good — provided RC-3.
- Structural-issue text interpolates model-supplied step ids/argument names, which falls inside
  D-7b rule (3) ("already visible in the approval preview / plan record / review issues") and is
  additionally bounded by the 512-byte clamp. Acceptable.

---

## 5. Test plan

- **T1:** implementable. The corpus drives the **Runtime** (`agent_smoke_corpus.rb:1366` →
  `agent.rb:37`), all 15 cases supply digests, and ScriptedModel ignores prompts, so neither the
  optional-digest relaxation nor the prompt change moves any case. `rake ci` locale floor as
  recorded.
- **T2:** seams exist, but "preview digest == executed digest" only holds under RC-2
  (single-resolution injection). Without it the property is a test artifact, not a guarantee.
- **T5:** implementable **only on the Session driver** (Runtime has no approval→dispatch
  binding; a mutation inside the approval callback would be silently applied). The doc must
  scope T5 to Session and add Runtime coverage separately. **RC-5.**
- **Missing — the gate can still regress on the driver the scorecard uses:** the doc's own
  scope line forbids corpus changes while the corpus (Runtime) is the only driver without new
  coverage. Add scorecard case **`agent.absent-digest-patch`** (Runtime driver, absent digest,
  check passes, safety counters 0) and/or parametrize T2/T3/T5 over both drivers — the D-7b
  precedent explicitly runs its behavioural case "on Runtime and on Session"
  (`test/agent_tool_error_recovery_test.rb`). Also missing: resume/kill re-binding on an
  absent-digest plan (committed-intent re-verification on resume), repeated identical
  absent-digest plans → `repeated_action`, create_file absent-digest path, and the Fix B
  negative case.
- **T6:** usable as a manual go/no-go gate; tighten to: fresh sandboxed workspace, assert the
  target file bytes exactly `a + b`, assert `configured_check_passed == true` /
  `terminal_reason: check_passed` in the session record, assert no other file changed, and
  record model/provider/commit/date in GAUNTLET_PROGRESS. A live-model run cannot be a CI
  regression floor — hence the corpus case above. **RC-8.**

---

## 6. Scope check

- **No plan-schema change:** true (`plan.rb` untouched). But the tool *argument contract*
  changes (digest optional) and, if the doc touches `ACTION_DESCRIPTIONS`
  (`toolbox.rb:14-20`), the `catalog_digest` changes (descriptions are digested at
  `toolbox.rb:100-115`) → P8 profile binding (`session.rb:92-104` `verify_profile_binding!`)
  rejects existing pinned profiles until re-imported, and `test/agent_skills_toolbox_test.rb:63`
  pins `PRE_P9_READ_ONLY_DIGEST` (read-only surface only — unaffected) while P8-era relational
  assertions must be re-run. The doc's scope section silently claims "no scorecard corpus
  change" (contradicted by RC-5) and says nothing about the catalog/profile impact. **RC-7.**
- **Approval flow:** unchanged (same interrupt/descriptor); recommend the approval descriptor
  and preview show the *resolved* digest so the operator sees the exact bound state.
- **Effect journal / check semantics:** unchanged as designed, given RC-2.
- **Failure model table:** "Unresolved digest reaches execution → hard stop" is currently
  unenforceable on the Runtime driver — the table itself is evidence of the Fix A-3 gap.

---

## 7. Held-out probes (to run against the implementation)

1. Runtime driver, absent digest, approval callback mutates the target file before returning
   `true` → the patch must NOT be applied to the mutated bytes (fail closed). Fails under the
   draft as written.
2. Session driver, absent digest, mutate between approval and dispatch → `ToolPolicyError`,
   file byte-identical (T5).
3. Present-but-stale digest, both drivers → repairable evidence → `repeated_action`, unchanged
   vs baseline.
4. Legitimate `<`/`>` in `before`/`after` (e.g., `a < b` → `a >= b`) → structural review
   accepts; plan executes.
5. `path: "<path from search result>"` → structural issue with the exact placeholder message;
   three attempts → `PlanRejectedError`; CLI line shows the bounded reason and **no model text**.
6. Semantic-review-reject ×3 → `PlanRejectedError` message contains **structural issues only**
   (no model-authored text).
7. Not-JSON plan ×3 → message stays generic (no provider payload quote).
8. After any description/prompt change: old pinned profile fails closed; relational
   catalog-digest assertions updated; `rake ci` green under both locales; scorecard unchanged.
9. Kill between approval and dispatch on an absent-digest plan, resume → re-verifies committed
   intent before dispatch; changed workspace → terminal, untouched file.
10. Invariant-17 matrix extended: absent digest accepted at `validate`; all reject rows leave
    the workspace byte-identical.

---

## 8. Required corrections

| ID | Severity | Correction |
|---|---|---|
| RC-1 | Critical | Enumerate the `Runtime` driver (`runtime.rb:312/341`) in Fix A-3 and bind it: resolve at preview, re-verify before execute (or prove unreachable and test that proof). The scorecard's own driver cannot execute absent-digest patches unbound. |
| RC-2 | High | Single resolution in `build_intent`; inject the resolved digest into the arguments for both `preview` (`session_nodes.rb:300`) and `execute` (`:604`) so `prepare_patch:643-644` stays a live second binding and preview == execution bytes. |
| RC-3 | High | Fix C discloses **structural-layer issues only**; semantic/protocol feedback yields a generic bounded phrase. Normalization is not sanitization. |
| RC-4 | High | Fix B: `<`+`>` containment only on `path` (and digest-shaped) arguments; whole-string/reference-phrase rules elsewhere; add the legitimate-`<`/`>` negative test. |
| RC-5 | High | Add `agent.absent-digest-patch` scorecard case (Runtime driver) and/or parametrize T2/T3/T5 over both drivers; scope T5 to the Session driver explicitly. |
| RC-6 | Medium | Spec the full toolbox surface (validate, `prepare_patch`, `prepare_create_file`, `effect_intent`, `preview`, `render_create_preview`) and create_file's content-derived (not observed) resolution. |
| RC-7 | Medium | Disclose the `catalog_digest` / P8 profile-binding impact of any description/prompt text change; decide the `ACTION_DESCRIPTIONS` wording explicitly. |
| RC-8 | Medium | T6: pin the workspace-byte oracle, `configured_check_passed`/`terminal_reason`, and record provider/commit/date; add resume re-binding and repeated-action tests. |
| RC-9 | Low | Doc line fixes: corpus digest sites are `:650/695/883/1448` (not 1454); `error.rb` is `gems/tamoz-core/lib/tamoz/error.rb` (`safe_message` 116-127); `cli.rb` `error_summary` 566-571; `verify_intent_before_state!` at `session_nodes.rb:624`. |

---

## 9. Verdict

**ACCEPT-WITH-REQUIRED-CORRECTIONS.** F1/F2 are verified accurate; the Fix A mechanism is
sound on the durable path; the D-7b precedent supports a restricted Fix C. The draft cannot be
implemented as written because (a) its own "no site may reach execution with an unresolved
digest" requirement is unenforceable on the Runtime driver, (b) Fix C would disclose
model/provider text, and (c) Fix B would reject legitimate patches containing `<`/`>`.

**Single biggest remaining risk:** the `Runtime` driver. The scripted scorecard and the public
`Tamoz::Agent.build` API run on it, it has no `verify_intent_before_state!`, and an absent-digest
patch whose target changes between preview and execute would be applied to bytes nobody
reviewed. Every other gap fails closed through existing machinery; this one is silent by
design if the enumeration is not corrected.
