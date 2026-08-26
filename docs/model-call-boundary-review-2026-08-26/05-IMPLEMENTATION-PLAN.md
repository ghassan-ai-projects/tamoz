# Implementation plan — model-call boundary review, risk-ordered phases

Date: 2026-08-26 · Branch: `feature/model-call-boundary-review-improvements`
Source: accepted review (`00`–`03`) + owner-accepted assessment (`04`). D1 stands retracted.
This file is the working plan: the bar, the phases, the per-phase process, and the settled
dispositions. Each phase gets a plan review (two lenses), then implementation, then three
code-review lenses, looping until the phase bar is met, then one commit per phase.
Plan reviewed 2026-08-26 by lens PA (architecture) and lens PC (completeness & correctness),
both PASS-WITH-GAPS; all findings folded into this revision (see phase log).

---

## 0. Settled dispositions (do not relitigate inside phases)

| Item | Disposition | Where |
|---|---|---|
| D1 | Retracted (false positive); no action ever | `00`, `01` §4a |
| D2 provider failures never completed into journal | **Scheduled, phase 3**: under the converged transport, failed model attempts get a typed terminal completion (the tool path's `ToolError`/`EffectUnknownError` treatment) instead of waiting for the stale-sweep safety-class ruling. Until then behavior is safe-by-analysis (`02` §3.3); recorded here so register closure is honest. | phase 3 |
| D5 `Encoding.default_external` mutation | **Keep with comment** as an accepted deviation until the transport decision resolves it structurally (the file likely retires whole). Written-law anchor moved: the no-mutable-global-state sentence is now `documentation/architecture/gems.md:121` (:117 is the section heading). | this file |
| `after_effect_started` chain | **Keep, and document its counterparty** — the review allowed delete *or* name the implementor; evidence picked the second branch. The chain is the autonomy scorecard's only mid-effect crash-injection seam: `crashing_factory(after: :effect_started)` (`test/support/autonomy_case.rb:427`) drives scorecard case 10 "unknown effect never retries automatically" (`test/autonomy_scorecard_test.rb:228`) by killing between `effects.start` and the receipt — exactly the state that test exists to exercise. Seam uniqueness: `CLI.run` injects only `model_factory:`/`comms_client_factory:` (`cli.rb:76`) and the harness charter forbids constructing Sessions/stores directly; deleting would silently disarm a durability gate, which CODING_STANDARD §1 forbids. Production models intentionally do not implement the hook. Phase 1 adds one-line counterparty comments at `SessionEffects#after_effect_started` and `DeferredModel#after_effect_started`. (Found independently by orchestrator pre-verification AND lens PA finding 1.) | phase 1 |
| One-shot Runtime fix | **Just journal it** (in-memory journal); porting Runtime onto the graph engine is rejected (`04`). Lens PA A1: journal lives runtime-local in tamoz-agent — NOT kernel (would plant a second competing effect model in the lowest substrate, which `effect_dispatcher.rb:7-10` forbids) and NOT a SQLite reuse (drags lease-guard/TTL fencing into an ephemeral turn); reuse the graph gem's existing `EffectRecord`/`EffectAttempt` vocabulary structs so no second vocabulary appears. | phase 2 |
| AGENTS.md ephemeral carve-out sentence | **Add it** (`04`) | phase 2 |
| Transport surface (gates phase 3) | Orchestrator recommendation to owner: **converge on the digest-bound OpenAI-compatible transport, retire `RubyLLMModel`**. Rationale: all documented real runs are DeepSeek (OpenAI-compatible); digest-bound receipts deliver replay-from-journal which `.ask(prompt).content` cannot; retiring deletes D5 structurally; lens PA A5 confirms no dependency inversion — transport/call-object/catalog all live in the kernel below every consumer. Consequences surfaced at the owner gate: frozen SETTINGS (`temperature 0`, `json_object`, non-streaming, `episode_model_transport.rb:24-31`) become the universal call shape, and receipts change `SessionEffects#model_call`'s return projection (`unwrap_model`, `session_effects.rb:37-43`). **Owner re-confirms before any code moves.** | phase 3 |
| Extraction naming | Irrelevant under the retire direction; revisit only if the owner overrides toward keep+extract | phase 3 |

House rules that bind every phase: `docs/CODING_STANDARD.md`; no backwards-compatibility
shims; simple solution over complicated; no rare-case coverage; domain knowledge stays data;
comments default to none; real models never faked in tests.

---

## 1. The bar (end result, all phases)

1. **Register closed.** Every defect row D2–D9 is either implemented or has a written,
   owner-visible disposition in this file. D1 remains retracted. (D2 scheduled phase 3 per §0.)
2. **Gates.** After every phase: `rake ci` + `rubocop` + `enola check` green. Any phase that
   touches durability/effects/journal semantics additionally runs `rake ci_full` under BOTH
   locales (gate policy). Sandbox note: RuboCop's default cache dir (`~/.cache/rubocop_cache`)
   is unwritable here — run `RUBOCOP_CACHE_ROOT=<workspace tmp> rubocop`; a crashed parallel
   cache-write can still exit 0 with "0 files inspected", which is NOT a pass.
   Known-red items not chased: repo-wide reek ratchet (stale global baseline, stale-pathed
   keys — per-file parity enforced instead), pre-existing requirements-audit missing-evidence
   rows, anything under `agenteval/`.
3. **Enforcement is executable, not prose.** The node model-call contract and the
   two-transport parity contract have named failing-if-violated tests. The one-shot journaling
   change has a test proving same-logical-key replay reuses the recorded receipt without
   re-calling the model.
4. **No structural regression.** Enola baseline pinned before the first edit; after each phase
   `enola check` shows no new cycle/layer violation; coupling deltas explained or fixed.
5. **Docs agree with code.** gems.md / README / overview / invariants / AGENTS.md carry the
   corrected wordings; grep proof that no stale sentence survives; every enforcement claim in
   prose matches what the named test actually asserts.
6. **Clean code.** Touched files gain zero RuboCop offenses and zero net reek smells;
   deletions shrink baselines where applicable. Stranded `.rubocop_todo.yml` exclusions on
   touched files are allowed to remain (TODO must only not grow); deliberately NOT
   regenerating the TODO in-phase — regeneration is how slice 28 silently absorbed 16 smells.
7. **Honest evidence.** Test results reported as plumbing/conformance evidence; nothing shown
   as model reasoning that came from a fixture.

### Per-phase exit bars

**Phase 1 — prose + hygiene.**
- D9 prose landed: gems.md:80 binds *SDK declaration* (not "knowledge"); README:23 and
  gems.md:90 `tamoz-graph` rows read core + cancellation + concurrency (+ zeitwerk like the
  core row treats it); clause 11 carries load-time vs run-time wording in
  `documentation/architecture/overview.md:105`, `documentation/architecture/invariants.md:15`,
  and `docs/design-v0.1/INVARIANTS.md:32`, with the enforcement citation scoped to what
  `dependency_isolation_test.rb` actually asserts — extended (step 1g) to assert the socket half too.
- D4 dead emitter path deleted from `ruby_llm_model.rb`: `emitter:` parameter (:44), the
  `ordinal = 0` local (:50), the three inline emit blocks (:51–60), `emit_model_event`
  (:72–76), and the now-orphaned helpers `usage_of` (:81), `integer_usage` (:94),
  `cost_microunits_of` (:99). Signature becomes `generate(stage:, system:, prompt:)`.
- `after_effect_started` chain kept; counterparty comments added at
  `session_effects.rb:154-157` and `deferred_model.rb:24-26`. Scorecard case 10 untouched.
- Grep proofs (exact tokens, explicit residuals): `\bemit_model_event\b`,
  `cost_microunits_of`, `usage_of` zero hits outside deleted code; `emitter:` still passed to
  `RubyLLMModel#generate` nowhere. Expected residual `model_started/model_delta` mentions:
  `gems/tamoz-core/lib/tamoz/stream_part.rb` and tamoz-stream contracts/gen/wire tests (their
  own wire vocabulary, untouched).
- Existing suites green unchanged: pre-change baselines recorded 2026-08-26 14:11
  (agent_ruby_llm_model_test 4/15, agent_session_effect_test 18/70, effect_identity_test
  5/12, public_api_test 3/1054 — all 0F).

**Phase 2 — the contract.**
- `Runtime#model_generate` crosses `EffectDispatcher.run` under a stable logical identity with
  a runtime-local in-memory effects journal (§0 disposition) that reuses the graph gem's
  effect-record vocabulary; logical identity composes operation/stage WITH the attempt ordinal
  (`@model_call_count`) so same-stage retries inside one turn get DISTINCT identities —
  otherwise replay hands back a rejected first answer (lens PA finding 6; cf. SessionEffects'
  iteration/sub_operation composition, `session_effects.rb:26-30`).
- Tests prove dedup/reuse on the same logical identity, fresh execution on distinct identity,
  and recorded outcomes after the turn.
- AGENTS.md rule text states the honest contract: terminal receipts immutable; unanswered
  calls resolved by safety class; ephemeral one-shot runtime journals in-memory by design.
- Model-call node contract codified (docs) + conformance test — mechanism PINNED (lens PA A2):
  static source audit in the `boundary_source_audit.rb:543-577` Ripper reject-list style,
  top-level `test/`. Scan production libs only: `gems/{tamoz-agent-kernel,tamoz-agent-session,tamoz-agent-memory,tamoz-agent}/lib`.
  Deny receiver-qualified `.generate(` outside the door allowlist {session_effects.rb:32,
  consolidation.rb:203, episode_model_call.rb, post-phase-2 runtime.rb}, `RubyLLM` refs /
  `require "ruby_llm"` outside tamoz-agent, `net/http` outside episode_model_transport.rb.
  Encoded false positives: JSON.generate (match qualified shape), DeferredModel/evals wrapper
  definitions, CLI dummy-model definitions (`cli_authority.rb:195`, `cli.rb:563`). tamoz-graph
  stays unscanned — clause 11 guards it separately.
- Two-transport parity test (D7): drive BOTH transports against one fixture
  `LocalModelEndpoint` (`test/support/local_model_endpoint.rb`, :fixture mode — real HTTP
  boundary, scripted envelopes, independent digest log); pin agreement on content extraction
  and usage mapping from identical envelopes, and pin the deliberate divergences (retry
  posture, error taxonomy surface) as named assertions.
- `rake ci_full` both locales green (durability touched).

**Phase 3 — transport decision executed + cleanup (owner-gated).**
Under the recommended direction (converge + retire):
- `SessionEffects#model_call` records digest-bound receipts `{request_digest, content,
  response_digest, usage}` mirroring `EpisodeModelCall`, keeping operation names and the
  structured logical identity; per-stage `model_call_safety` decided (blanket value stays if
  no stage needs otherwise).
- **D2 closes here**: failed model attempts complete into the journal with a typed terminal
  status (tool-path treatment) under the converged contract.
- Consumers migrated in the same slice: `cli.rb` model construction/key resolution, evals
  benchmark adapter sites, `environment_loader` if implicated, `cli_argument_parser.rb:69-70`
  (--model/--provider help text names RubyLLM), `lane_config.rb:11` comment, and the
  `tamoz-agent` re-export seam (`agent.rb:14`) — after retirement the CLI reaches the model
  construction seam through tamoz-agent's facade, so decide explicitly whether the surviving
  seam re-export moves or tamoz-agent-cli gains no new dep; `RubyLLMModel` deleted;
  `docs/public-api.json`, requirements manifest entry, `test/public_api_test.rb` updated in
  the SAME slice (no deprecation limbo); `tamoz-agent.gemspec` drops `ruby_llm ~> 1.16.0`;
  README/gems.md rows updated; ARCH-2 resolved by ONE credential resolver beside
  `Providers::ENV_KEYS` in the kernel (D8); D5 dies with the file.
- Scorecard/benchmark suites run per gate policy (agent/autonomy + persistence touched);
  `rake ci_full` both locales.
If the owner overrides toward keep+extract: the extraction slice moves the adapter behind the
unified journaled-call interface into its own gem with consumers migrated in the same change,
and the receipts upgrade still happens on the session path.

---

## 2. Phase order and why this order

Phases follow `04`'s value-over-risk ranking. Phase 1 removes the prose ambiguity that
mis-seeded the review and deletes machinery whose only strict consumer treats it as forgery —
no downside, shrinks phase 2's surface. Phase 2 is the review's thesis: journal-by-construction
for the last raw path, plus the contracts that stop drift. Phase 3 is packaging-scale work that
only phases 1–2 make cheap; it stays gated on the owner's transport confirmation.

Steps 1–3 of the review's migration sketch touch zero `tamoz-graph/lib` files; any phase-2
edit inside the graph gem has left the plan. (Phase 1's step 1g extends a top-level
conformance TEST about the graph's load surface — still zero graph-lib edits.)

---

## 3. Per-phase process (fixed loop)

1. **Plan.** Orchestrator writes/updates the phase section here with file-level steps, the
   named gate list, the known-red list, and file-ownership lists (per
   `docs/subagent-orchestration.md`).
2. **Two plan reviews in parallel** (subagents, read-only):
   - Lens PA — solid architecture: boundary law, layering, mechanism choice, duplication
     against existing seams.
   - Lens PC — completeness & correctness: register coverage, anchor verification against the
     current tree, missed consumers/tests, bar verifiability, risk coverage.
   Both return verdict PASS / PASS-WITH-GAPS / FAIL + findings with severity, file:line, and
   the concrete suggested edit.
3. **Revise** the plan until both lenses are ≥ PASS-WITH-GAPS with all HIGH findings resolved.
4. **Implement** per CODING_STANDARD (orchestrator, or bounded briefs to implementation
   subagents when the phase decomposes cleanly; integrator keeps commits).
5. **Three code reviews in parallel** (subagents, read-only): correctness &
   behavior-preservation · architecture & boundary law · clean code, tests & security.
6. **Loop:** every critical/high finding fixed, re-reviewed; medium/minor fixed or explicitly
   accepted with reasons in the phase log below.
7. **Gates + commit.** Full everyday gate (+ `ci_full` both locales when required), enola
   snapshot checked, one commit for the phase, phase log row appended here, next phase.

Subagent briefs follow the standing protocol verbatim: environment block, file ownership
(owned / forbidden / read-only), new-behavior model as assertions, named gate suites (~8 max)
plus known-red list, report format, housekeeping clause, ≤60-minute cap with ~30–40 minutes
of scoped work, monitoring log line per completed unit at `/tmp/tamoz-agents/<name>.log`.

## 4. Phase 1 plan (current phase)

### Steps

1. **Prose (D9).**
   a. `documentation/architecture/gems.md:80`: rewrite the "`tamoz-agent` is the only layer
      that knows RubyLLM" bullet to bind gemspec SDK declaration ("the only gem that declares
      the `ruby_llm` SDK"), keeping the accurate accept-a-callable sentence.
   b. `README.md:23` gem table `tamoz-graph` row deps cell: `tamoz-core` →
      `tamoz-core`, `tamoz-cancellation`, `tamoz-concurrency` (zeitwerk omitted like sibling
      rows).
   c. `documentation/architecture/gems.md:90`: same deps-cell fix.
   d. `documentation/architecture/overview.md:105` rule 1: append the load-time/run-time
      clarification (load-time invariant enforced by `test/dependency_isolation_test.rb`;
      run-time capability injection via node callables and `context.effects` by design).
   e. `documentation/architecture/invariants.md:15`: same clarification inside the clause-11
      parenthetical.
   f. `docs/design-v0.1/INVARIANTS.md:32` §11 row: extend the Required-behavior cell ONLY,
      preserving `| 11 | **…** |` row format, numbering 1..61, conformance-table coverage,
      single H1, balanced fences — `design:validate` hard-pins these and runs FIRST in
      `rake ci` (`Rakefile:416` → `validate_design.rb:60-90`; also re-checked by
      `test/documentation_test.rb:22-43` under LC_ALL=C).
   g. Extend `test/dependency_isolation_test.rb`'s GRAPH case with the comms-style
      net/http + socket refutation (`:208-241` pattern) so the prose's full claim becomes
      tested rather than softened. Fallback if the clean-process load proves flaky: scope the
      prose citation to the package-load assertion only. Either way bar #5 holds.
2. **Dead emitter deletion (D4)** in `ruby_llm_model.rb` per the phase-1 exit-bar list
   (signature :44; `ordinal` local :50; emit blocks :51–60; helper :72–76; orphaned usage
   helpers :81/:94/:99). Zero callers pass `emitter:` today (verified repo-wide by
   orchestrator, lens PA A3, and lens PC C3).
3. **Counterparty comments**: one line each at `SessionEffects#after_effect_started`
   (`session_effects.rb:154-157`) and `DeferredModel#after_effect_started`
   (`deferred_model.rb:24-26`) naming the autonomy-scorecard crash-injection counterparty and
   that production models intentionally do not implement the hook. No signature changes; no
   visibility-block changes (the earlier "private juggling" concern was wrong — lens PC C1).
4. **Verification:** named gates below; grep proofs per the exit-bar token list with the
   stated residuals; everyday gate trio.

### Named gates (phase 1)

`ruby -Itest test/agent_ruby_llm_model_test.rb` ·
`ruby -Itest test/agent_session_effect_test.rb` ·
`ruby -Itest test/effect_identity_test.rb` ·
`ruby -Itest test/public_api_test.rb` ·
`ruby -Itest test/dependency_isolation_test.rb` (step 1g touches it) ·
`ruby -Itest test/documentation_test.rb` (INVARIANTS.md structure) ·
`rake ci` · `RUBOCOP_CACHE_ROOT=<tmp> rubocop` · `enola check --fail-on=cycles,layers --min-confidence=0.8 .`

There is no dispatcher-contract test file (confirmed by lens PC C4); dispatcher coverage
travels through `agent_session_effect_test.rb` and `sqlite_kernel_test.rb`.

### Known-red (not chased in phase 1)

Repo-wide reek ratchet (stale baseline + stale-pathed keys; per-file parity only) ·
requirements-audit missing-evidence rows · `agenteval/` · autonomy/kill-matrix lanes
(`rake autonomy`, SLOW_TESTS) — unaffected this phase precisely because the
`after_effect_started` chain survives; case 10 rides unchanged.
**Pre-existing reds verified at HEAD during phase-1 verification (2026-08-26), not caused by
this work and deliberately not chased here:** (1) `test/benchmark_holdout_test.rb`
`test_generation_is_seed_deterministic` — domain-data pin drift, fails identically with the
phase changes stashed; candidate small future slice per QUALITY_PROGRAM_STATE's own list.
(2) Plain-tree `rubocop` reports 3,335 offenses — commits `5ad6d8a`/`839d043` moved eval
corpus/script files (e.g. `gems/tamoz-evals-runner/.../agent_smoke_corpus.rb` →
`test/support/`) but the `4521e2a` TODO regen carried only one line, leaving stale-pathed
excludes; touched-file scoped runs are 0 offenses. Needs a deliberate TODO path-refresh
slice (regeneration has an absorb-smells failure mode — slice 28 lesson — so it must be a
reviewed diff, not an in-phase regen).

### File ownership (phase 1)

Owned: `documentation/architecture/gems.md`, `README.md`,
`documentation/architecture/overview.md`, `documentation/architecture/invariants.md`,
`docs/design-v0.1/INVARIANTS.md`, `test/dependency_isolation_test.rb`,
`gems/tamoz-agent/lib/tamoz/agent/ruby_llm_model.rb`,
`gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb` (comment only),
`gems/tamoz-agent/lib/tamoz/agent/worker_runtime/deferred_model.rb` (comment only).
Forbidden: everything else, notably `gems/tamoz-graph/**`, `gems/tamoz-sqlite/**`,
`gems/tamoz-stream/**`, `test/support/**` (chain kept ⇒ harness untouched).

## 5. Phase 2 plan

Goal: the review's thesis — journal-by-construction for the last raw model path, plus the
contracts that stop drift. Touches zero `gems/tamoz-graph/lib` files.

### Step 1 — runtime-local memory effects journal + journaled `Runtime#model_generate`

- **New class** `Tamoz::Agent::Runtime::EffectsJournal`
  (`gems/tamoz-agent/lib/tamoz/agent/runtime/effects_journal.rb`, loaded by
  `require_relative` from `runtime.rb` like its sibling submodules — tamoz-agent does not
  Zeitwerk-map that directory): implements the dispatcher's minimal surface —
  `logical_identity` (all NINE keywords, including execution_id), `prepare`, `start`,
  `complete`. Decision/record/attempt shapes REUSE the graph gem's structs
  (`Tamoz::Graph::EffectDecision/EffectRecord/EffectAttempt`) — no second vocabulary.
- **Replay semantics (folded deliberately, lens PA2 finding 4):** first sight → `:execute`;
  terminal succeeded receipt on the same key → `:return` reused; terminal typed failure →
  `:failed` (mirrors durable replay; a failed model receipt is never retried blindly);
  non-terminal leftover attempt → abandoned, one fresh attempt; beyond
  `EffectDispatcher::MAX_ATTEMPTS` without terminal state → `:unknown`. The reconcile branch
  is unreachable by construction (journal never emits it; safety stays `:idempotent`).
- **Outcome projection (lens PC2 finding 4; corrected during implementation):** perform
  returns the raw String; `model_generate` unwraps `outcome.value`. The original
  "non-succeeded Outcome is unreachable" claim was WRONG — user-supplied models may raise
  `ToolError` (proven by agent_cli_test's raising_factory), and the dispatcher converts it
  into a failed Outcome. Implemented: on `:failed`, reconstruct the typed error from the
  journalled detail hash via the inverse of `serialized_tool_error_name` (class identity +
  message bytes preserved); any other non-succeeded status raises ProtocolError.
- **Key composition (lens PA2 finding 6):** the v1 domain INCLUDES execution_id/request_id,
  unlike SQLite v3 which excludes them. Deliberate: ephemeral dedup is WITHIN a turn only;
  a new turn must call the model fresh even for an identical prompt. `iteration` = the
  post-increment `@model_call_count` (1-based ordinal of this call in the turn);
  `authority_revision: toolbox.catalog_digest`; `catalog_revision:` digest over the empty
  catalog map.
- **Injection**: `Runtime.new` gains an `effects:` keyword defaulting to a fresh journal;
  exactly three direct construction sites exist (`agent.rb:66` + two tests), so existing
  constructors keep working unchanged. Per-turn isolation rides the rotating request_id in
  the key, so instance-lifetime journaling is correct.

### Step 2 — AGENTS.md rule text

Append to the effect-journal rule: *"Terminal receipts are immutable; an unanswered call is
resolved by its safety class (`:idempotent` grants a fresh attempt, `:unsafe` stops as
unknown). The one-shot ephemeral runtime journals through the same dispatcher over
in-memory stores by design."* — the D6 fix plus the honest-contract sentence from `02` §4a.

### Step 3 — model-call node contract: codification + conformance test

- Docs home: `documentation/architecture/gems.md` agent-session row area gets the stated
  rule (nodes receive journaled call objects, never transports; model events stay
  runner-emitted), referencing the enforcement test.
- **Test** `test/model_call_node_contract_test.rb` (top level, mechanism PINNED by lens PA
  A2 and re-verified empirically by lens PA2 A4): Ripper-based source audit over production
  libs of
  `gems/{tamoz-agent-kernel,tamoz-agent-session,tamoz-agent-memory,tamoz-agent}/lib`.
  Deny receiver-qualified `.generate(` outside the door allowlist {session_effects.rb,
  consolidation.rb, runtime.rb, deferred_model.rb} and
  `net/http` requires outside {episode_model_transport.rb, witness_gateway.rb}; deny any
  RubyLLM constant inside the scan set (comment-only mentions are invisible to Ripper —
  part of why the mechanism is right). Doors carry one-line reasons: deferred_model forwards
  only behind SessionEffects' perform block; witness_gateway is the P3 egress seam.
  (`episode_model_call.rb` holds zero `.generate(` calls today — lens PC2 finding 7 drops
  the dead door; when it gains one, the audit flags it and the door is added deliberately.)
  `tamoz-agent-cli`, `tamoz-evals-runner`, and `script/` are OUT OF SCOPE with reason:
  they are construction/harness layers whose model sites are phase-3 Slice-B migration
  targets, not node-bearing libs (lens PA2 finding 3).
- JSON.generate never trips the audit: the rule matches calls whose METHOD name is
  `generate` with any receiver — encode the door allowlist BY FILE so JSON.generate inside
  non-door files still denies; verified empirically that HEAD's four-gem set contains
  exactly the listed hits.

### Step 4 — two-transport parity test (D7)

`test/model_transport_parity_test.rb` drives BOTH transports against ONE
`LocalModelEndpoint` in `:fixture` mode (real HTTP boundary, scripted OpenAI-compatible
envelope, independent digest log — never a real provider):
- Agreement: identical envelope in → identical extracted content string; usage token counts
  agree between the transport's `ModelCall::Usage` projection and ruby_llm's parsed usage,
  observed at the SDK message object (`message.input_tokens/output_tokens`) against the
  fixture constants 42/21 — NOT through `RubyLLMModel#generate`, which returns content only
  post-D4 (lens PA2 finding 7). `RubyLLMModel` constructs with
  `assume_model_exists: true` ("local-model" is absent from the bundled registry).
- Deliberate divergences PINNED as named assertions:
  1. Error taxonomy AT CONNECTION REFUSAL: both paths point at a CLOSED localhost port
     (in-file listener teardown — no `test/support/**` modification, resolving lens PC2
     finding 2's ownership collision; the fixture's fixture mode always answers 200, so
     HTTP-500 taxonomy is simply not asserted). The divergent classes are the
     connection-refused errors plus retry count.
  2. Retry posture: faraday retries up to 3× incl. POST vs single-shot net/http — count
     hits at the endpoint.
  3. Request bytes never agree: the transport sends frozen SETTINGS (temperature 0,
     json_object, stream false) JCS body; ruby_llm sends provider defaults. The fixture is
     content-blind so extraction parity holds; digest non-agreement is pinned AS the
     phase-3 convergence target.

### Gates (phase 2)

Named suites above · `ruby -Itest test/dependency_isolation_test.rb` ·
`ruby -Itest test/public_api_test.rb` · direct one-shot feedback:
`ruby -Itest test/agent_runtime_test.rb`,
`ruby -Itest test/agent_request_routing_test.rb` (span/correlation assertions exercise the
changed seam directly — lens PC2 finding 6) · `rake ci_full` default locale +
`LC_ALL=C rake ci_full` (~145s/locale; durability touched) · scoped rubocop on touched
files (`RUBOCOP_CACHE_ROOT` set; confirm not-silent-zero) · enola check.
Autonomy lane (`rake autonomy`) NOT in this phase's gates with justification: the scorecard
drives the durable session path via SessionEffects, which phase 2 does not touch; the
journaled Runtime path preserves events and spans unchanged.

### Ownership sketch (phase 2)

Owned exactly (lens PC2 finding 9): new lib file
`gems/tamoz-agent/lib/tamoz/agent/runtime/effects_journal.rb`; edits to
`gems/tamoz-agent/lib/tamoz/agent/runtime.rb`, `AGENTS.md`,
`documentation/architecture/gems.md`; new tests `test/agent_runtime_effects_test.rb`,
`test/model_call_node_contract_test.rb`, `test/model_transport_parity_test.rb`; this plan
document.
Forbidden: `gems/tamoz-graph/**`, `gems/tamoz-sqlite/**`, `gems/tamoz-stream/**`,
`gems/tamoz-agent-kernel/**` (episode machinery is read-only reference),
`gems/tamoz-agent-session/**`, `gems/tamoz-agent-memory/**` (audit scan targets, read-only),
`test/support/**`.

Known-red carries over from phase 1's list, plus anything phase 1's commit records.
Final gate evidence on 2026-08-26 established one current repository red outside this
phase's ownership: `test/benchmark_holdout_test.rb` compares the generated protocol digest
`46a8b95dfa22c2e821806652e03a5934517d15033735a5aa2ff871ffbaa97e79` with the untouched
holdout-pin digest `cf4d59d24c3b6bec364fc147600cc738e5c6745f2f0419e82b61fde04a4c304c`.
Neither benchmark file is modified by this phase, so changing the pin is deferred as a
separate reviewed benchmark-data change rather than hidden as a Phase 2 fix. The first
gate attempts also exposed invocation/environment defects (sandbox socket denial and
PATH-selected system Ruby); the final gates used localhost permission plus the pinned
Ruby 3.3.11 directory first in PATH. Under that setup, the Phase 2 suites pass and the
holdout mismatch is the only `rake ci`/`ci_full` failure. Scoped RuboCop auto-corrected
21 offenses; the remaining 22 are test-only metrics/unused-argument findings left per
the owner's instruction not to spend time on small lint fixes, and `.rubocop_todo.yml`
was not changed.

## 6. Phase 3 plan — retire the RubyLLM boundary

Owner decision recorded 2026-08-26: **retire `Tamoz::Agent::RubyLLMModel`**. This phase
standardizes production model execution on the existing digest-bound
`Tamoz::Agent::EpisodeModelTransport`; it does not introduce a second model gem or a
compatibility adapter. The graph remains untouched.

### 6.1 Phase bar — implementation is not complete until every item is evidenced

1. **One production boundary.** No executable production path constructs or requires
   `RubyLLMModel`, `ruby_llm`, or another provider SDK. The only model egress is the
   existing `EpisodeModelTransport` behind `EffectDispatcher.run`.
2. **Receipt truth.** Durable session model effects record a codec-safe projection containing
   `request_digest`, `content`, `response_digest`, usage, and the non-secret provider
   configuration digest. A replay returns that projection without provider contact and first
   verifies the bound request/configuration identity. A configuration or received-response
   failure becomes a typed terminal `:failed` receipt; an unanswered transport attempt becomes
   `:unknown` and is never blindly retried.
3. **Wire determinism.** The session path uses the transport's canonical JCS request bytes,
   frozen settings, settings digest, exact response-envelope digest, and a non-secret
   provider-configuration digest. No SDK-generated defaults are part of the contract.
4. **Provider behavior is explicit.** Before implementation, check in
   `documentation/reference/model-providers.md` from the nine current
   `Providers::ENV_KEYS` entries. Every row names credential env key, API-base env key/default,
   model identifier rules, endpoint kind, protocol, and fail-closed behavior. Native protocols
   without an approved OpenAI-compatible contract are rejected with a typed configuration
   error; they are not silently redirected to a gateway. The matrix is a gate, not an
   aspirational support list.
5. **Consumer closure.** CLI construction, profile credential resolution, eval adapters,
   latency smoke tooling, environment loading, public API, gemspec/lockfile, requirements
   manifest, and user-facing docs agree with the retired boundary. No stale claim that
   arbitrary RubyLLM providers are supported survives outside the historical review record.
6. **No compatibility limbo.** `RubyLLMModel` is deleted in the same change that migrates
   its consumers. No deprecated alias, forwarding wrapper, or second provider path remains.
7. **Architecture.** The implementation extends the existing kernel transport and receipt
   vocabulary. It does not add a transport in `tamoz-agent`, put provider code in the graph,
   or create a second receipt model. Enola shows no new cycle/layer violation or unexplained
   package spillover.
8. **Evidence discipline.** Fixture/local HTTP tests prove plumbing, digest, replay, and
   failure semantics only. They are not presented as evidence of model intelligence. No test
   suite runs during planning, implementation, or review. The final verification is one
   ordered, sequential pass after implementation and review; no parallel or corrective test
   suites are part of the phase loop.

### 6.2 Settled implementation shape

The existing seams are the design, not merely references:

- `EpisodeModelTransport` owns canonical OpenAI-compatible request bytes, settings digest,
  HTTP egress, response-envelope digest, and usage extraction.
- `EffectDispatcher` remains the only durable side-effect door.
- `SessionEffects#model_call` remains the session node-facing seam. Its perform block will
  call the transport and store the full projection, while its public return remains the
  assistant content string for existing graph-node contracts.
- `EpisodeModelCall` remains the episode receipt builder and is reused as the receipt-shape
  reference. Add one kernel-private `ModelCallProjection` helper in
  `gems/tamoz-agent-kernel/lib/tamoz/agent/model_call_projection.rb` so
  `EpisodeModelCall` and `SessionEffects` convert the transport response through the same
  code; do not create a parallel receipt vocabulary.
- Provider and credential resolution moves to one kernel-owned
  `Tamoz::Agent::ModelClientFactory` beside `Tamoz::Agent::Providers::ENV_KEYS`. Its exact
  internal contract is:

  ```ruby
  ModelClientFactory.build(
    provider:, model:, profile_role:, environment:, explicit_api_base: nil, safety: :unsafe
  ) # => EpisodeModelTransport
  ```

  `profile_role` is the already-normalized `ModelCall::ModelRole` returned by
  `ModelCall.resolve_role`; the factory does not duplicate profile-role resolution. For a
  bare CLI selection it receives `nil` and the explicit provider/model pair. `environment` is
  a caller-supplied `Hash<String, String>` containing only runtime metadata plus the selected
  provider's credential/API-base names and, when a normalized profile role is present, its
  validated `credential_ref.name`; callers may filter keys using the factory's non-secret
  descriptor, but may not fetch, index, or validate a credential value. The factory alone maps
  `credential_ref` to an allowed environment name, reads the secret, resolves the endpoint,
  validates the provider matrix, and constructs the existing transport. Profile settings are
  the baseline; explicit non-secret CLI/API-base overrides win only where the current
  documented precedence permits them, and the resolved result—including `safety`—is frozen
  into the configuration digest. The returned `EpisodeModelTransport` gains the exact
  `generate(stage:, system:, prompt:) => EpisodeModelTransport::Response` contract, where the
  response carries `content`, `request_digest`, `response_digest`, `usage`,
  `settings_digest`, and `provider_configuration_digest`; no second HTTP client or model
  class is introduced.
- The factory's descriptor may expose names and endpoint metadata for environment-file
  filtering, never values. The secret exists only in the in-memory transport, and is excluded
  from logical identities, request documents, checkpoints, receipts, configuration digests,
  logs, `inspect`, and error text. Provider errors carry a stable code/status and body digest
  or byte count, never a response-body excerpt. Test doubles can still satisfy the existing
  injected `generate` protocol, but factory construction is the only built-in production path.

`ModelClientFactory` never constructs Tamoz's witness gateway. `openrouter` means the upstream
OpenAI-compatible provider gateway selected by its endpoint row. The existing
`EpisodeModelTransport(gateway:)` mode remains an explicit episode/witness seam with its
logical-call/frame-digest envelope; it is not reachable through the simple `generate` factory
contract and is not conflated with OpenRouter.

Known model failures must cross the journal boundary as a typed kernel error. Add
`Tamoz::Agent::ModelCallError < Tamoz::Core::ToolError` with stable code/status metadata and a
redacted disclosure message; `EpisodeModelTransport` converts configuration and received
HTTP/protocol failures to it. `EffectDispatcher` already converts `Tamoz::Core::ToolError`
to terminal `:failed`; the implementation must add the typed class to the kernel load surface,
safe detail serializer, and Runtime's `JOURNALED_ERROR_CLASSES`. Only
`Tamoz::EffectUnknownError` maps to `:unknown` for unanswered transport outcomes. Raw
`ProtocolError`, `Net::*`, or response-body text must not escape the model perform block.

The provider decision is explicit and narrow: the seven providers already aligned with the
frozen `/chat/completions` shape remain direct OpenAI-compatible rows; native Anthropic and
Gemini are rejected in this phase rather than hidden behind an implicit gateway. Operators who
need those models use the `openrouter` row and its provider-qualified model identifier. The
matrix to check in and test is:

| Provider | Phase-3 protocol | Default base | Credential | API-base override | Model rule |
|---|---|---|---|---|---|
| `openai` | direct OpenAI-compatible | `https://api.openai.com/v1` | `OPENAI_API_KEY` | `OPENAI_API_BASE` | non-empty provider model id |
| `deepseek` | direct OpenAI-compatible | `https://api.deepseek.com` | `DEEPSEEK_API_KEY` | `DEEPSEEK_API_BASE` | non-empty provider model id |
| `openrouter` | gateway, OpenAI-compatible | `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY` | `OPENROUTER_API_BASE` | provider-qualified model id |
| `ollama` | direct local OpenAI-compatible | `http://localhost:11434/v1` | optional `OLLAMA_API_KEY` | `OLLAMA_API_BASE` | non-empty local model id |
| `xai` | direct OpenAI-compatible | `https://api.x.ai/v1` | `XAI_API_KEY` | `XAI_API_BASE` | non-empty provider model id |
| `perplexity` | direct OpenAI-compatible | `https://api.perplexity.ai/v1` | `PERPLEXITY_API_KEY` | `PERPLEXITY_API_BASE` | non-empty provider model id |
| `mistral` | direct OpenAI-compatible | `https://api.mistral.ai/v1` | `MISTRAL_API_KEY` | `MISTRAL_API_BASE` | non-empty provider model id |
| `anthropic` | rejected native protocol | none | `ANTHROPIC_API_KEY` | `ANTHROPIC_API_BASE` | fail closed; use `openrouter` explicitly |
| `gemini` | rejected native protocol | none | `GEMINI_API_KEY` | `GEMINI_API_BASE` | fail closed; use `openrouter` explicitly |

The implementation must verify these defaults against the provider contracts before adding the
matrix file; a mismatch is a plan correction, not a silent runtime fallback. The factory's
configuration digest canonicalizes provider, model, endpoint, protocol, frozen settings,
profile canonical digest, and safety posture, never credential values.
- The production model object passed into `Session` and `Runtime` must be the transport-backed
  client produced by that kernel seam. Test doubles remain test-only and must not be described
  as real-provider evidence.

Factory construction is deterministic profile/provider preflight. The CLI and `WorkerRuntime`
perform it before constructing `Session`; a missing credential, unsupported provider, or rejected
native protocol is therefore a typed request-start failure, not an external model effect. Provider
I/O, received response validation, and projection failures occur inside the model effect and are
journaled as `:failed` or `:unknown` according to the transport taxonomy.

### 6.3 Ordered implementation slices

#### Slice A — freeze provider/configuration behavior and transport-backed client

1. Inventory the current provider labels in `Providers::ENV_KEYS`, CLI help/config docs,
   profile fixtures, and operator guides. Check in the nine-row provider matrix before editing
   runtime code. A row is accepted only when its endpoint/protocol/default/credential behavior
   is evidenced; otherwise its status is `rejected-until-explicitly-configured`, not implied
   support.
2. Add `Tamoz::Agent::ModelClientFactory` in
   `gems/tamoz-agent-kernel/lib/tamoz/agent/model_client_factory.rb` as the sole
   secret-resolution seam.
   It consumes the normalized role, validates `credential_ref` against the provider descriptor
   before any generic fallback, resolves the selected credential/API-base, computes a
   non-secret `provider_configuration_digest` over provider/model/endpoint/protocol/settings
   and profile digest, and rejects unsupported native protocols before any model call. Its
   public result exposes provider/model/configuration metadata and the transport-backed client,
   never the key. Add an object-inspection/error-redaction contract using a sentinel secret.
3. Extend `EpisodeModelTransport` with `generate(stage:, system:, prompt:)` returning the
   exact response projection above. `ModelCallProjection` is the shared conversion from that
   response to the journal hash used by both episode and session paths. The client must
   expose no raw key and no raw response body. Do not make `Session` or graph nodes know HTTP
   details.
4. Route `EnvironmentLoader` through the factory's non-secret provider descriptor for allowlist
   construction; the descriptor is parameterized by the normalized profile role so a custom
   validated `credential_ref.name` is included without the loader reading its value. It may
   select permitted names as opaque entries but must not resolve a credential or duplicate
   provider policy. Define normalized-settings precedence explicitly:
   profile role settings are the baseline, permitted explicit CLI/API-base overrides win, and
   the resulting canonical settings/configuration digest is the identity-bound value.
5. Add focused contract coverage for all nine provider rows, profile-vs-explicit precedence,
   missing/profile-mismatched credentials, unsupported providers, API-base overrides, the
   configuration digest, secret absence from `inspect`/errors, and the exact response projection.
   No provider is silently redirected to OpenRouter or another gateway.

#### Slice B — move durable session effects to digest-bound receipts

1. Update `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb` to build canonical
   request bytes and call the factory-produced transport inside `EffectDispatcher.run`.
2. Preserve operation names (`model.generate.<stage>`), call index, logical identity,
   authority/catalog revisions, and existing content return behavior. Add the resolved
   provider-configuration digest to the logical identity and journal projection so a changed
   endpoint/settings/profile cannot reuse an old receipt.
3. Store `{request_digest, content, response_digest, usage, settings_digest,
   provider_configuration_digest}` as the durable result. Validate all digest bindings before
   accepting the projection and reject malformed projections as typed protocol failures.
4. Define failure classification at the transport boundary: configuration errors and received
   non-success/invalid response envelopes are safe, redacted typed `:failed` outcomes;
   read-timeout, EOF, reset, and any other post-send unanswered network outcome become
   `EffectUnknownError` and therefore `:unknown`. Production model effects use `:unsafe` by
   default, with no automatic retry; any explicit idempotent override remains an operator
   choice and is recorded in the configuration identity. Never expose raw response bodies.
5. Add tests for: first call, same-key replay with zero endpoint hits, request/configuration
   mismatch, response/settings digest mismatch, typed failure completion, redacted error
   messages, unknown redispatch, usage unavailable, and same-stage ordinal identity.

#### Slice B.1 — keep the ephemeral Runtime on the same projection contract

`gems/tamoz-agent/lib/tamoz/agent/runtime.rb` is a second consumer of the durable door and
cannot be left on a string-only/raw-error path. It must:

1. call the same factory-produced `EpisodeModelTransport` and pass its
   `Response` through `ModelCallProjection`, returning only `content` to the existing
   deliberation/parser API;
2. bind `provider_configuration_digest` and request identity into its in-memory effect
   journal, so replay returns the projection without provider contact and a changed endpoint,
   model, settings, profile, or safety posture cannot reuse it;
3. use the client/factory safety posture (`:unsafe` for built-in production construction),
   not the current blanket `:idempotent`; injected test doubles may retain the explicit test
   configuration seam; and
4. map `ModelCallError` through the same redacted `JOURNALED_ERROR_CLASSES` path and preserve
   `EffectUnknownError` as unknown. One-shot construction in CLI/runtime call sites is part of
   this slice, not a separate provider implementation.

The episode path is also upgraded in this phase: `EpisodeModelCall` and `ModelReceipt` carry
and validate `provider_configuration_digest` alongside `settings_digest`. The shared
projection is the only conversion from `EpisodeModelTransport::Response` to either session
effect value or episode receipt; no path invents a second response/receipt shape.

#### Slice C — migrate all construction and evaluation consumers

Migrate these production seams in one ownership slice:

- `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb`: model construction and credential lookup
  becomes one factory call; no direct secret read or provider credential-map indexing remains
  in CLI. Include `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb` and
  `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb` in the construction census;
  injected `model_factory` remains a narrow test seam and production defaults call the kernel
  factory.
- `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/environment_loader.rb` and
  `openclaw_durable_cli_adapter.rb`: provider environment and model construction through the
  same factory; no eval-specific credential lookup remains.
- `script/agent_latency_smoke`: transport-backed construction and evidence labels.
- `gems/tamoz-agent-cli/lib/tamoz/agent/cli_argument_parser.rb` and
  `gems/tamoz-agent/lib/tamoz/agent/lane_config.rb`: remove RubyLLM-specific wording.
- `gems/tamoz-agent/lib/tamoz/agent.rb`: remove the adapter require/re-export seam without
  creating a new dependency direction.

All construction paths must use the same provider/configuration seam and the same transport
contract. The eval harness must continue to distinguish fixture plumbing from real-provider
qualification.

#### Slice D — delete the adapter and close generated/public surfaces

- Delete `gems/tamoz-agent/lib/tamoz/agent/ruby_llm_model.rb` and
  `test/agent_ruby_llm_model_test.rb`; replace tests with transport/configuration contracts.
  Migrate the direct monkey-patch helpers and assertions in
  `test/agent_profile_machinery_test.rb`, and remove the RubyLLM allowlist entry from
  `test/model_call_node_contract_test.rb`.
- Remove `ruby_llm` from `gems/tamoz-agent/tamoz-agent.gemspec`, regenerate the lockfile,
  and verify no transitive RubyLLM dependency remains. Because the surviving kernel
  transport uses `Net::HTTP` directly, its gemspec must declare the `net-http` runtime
  dependency rather than relying on the retired SDK's transitive closure.
- Rewrite `test/model_transport_parity_test.rb` so it no longer loads RubyLLM; retain the
  meaningful content, usage, error, retry, request-byte, and response-digest assertions for
  the canonical transport.
- Update `test/model_call_node_contract_test.rb`, dependency-isolation assertions,
  `test/public_api_test.rb`, `docs/public-api.json`, and the generated requirements surfaces
  using both `script/generate_requirements_manifest` and
  `script/generate_requirements_audit`; the generated manifest/audit and their test gate must
  no longer name the deleted adapter.
- Regenerate the dependency review through `script/generate_dependency_review`, update
  `docs/dependency-review.json` and `docs/DEPENDENCY_REVIEW.md`, and retain its test gate.
- Record the accepted retirement in `docs/design-v0.1/DECISIONS.md` and regenerate any
  requirements artifacts that consume that source. Update current (not historical) README,
  gem README, `documentation/reference/public-api.md`, `documentation/architecture/gems.md`,
  `documentation/architecture/overview.md`, `documentation/overview/compatibility.md`,
  `documentation/overview/product.md`, `documentation/design/README.md`,
  `documentation/adr/README.md`, install, CLI, config, and operator docs. Keep the review
  package, the test-suite audit timing records, and other dated audit records historical; do
  not rewrite them to erase provenance.
- Explicitly classify the undated design sources `docs/M4_PLAN.md` and
  `docs/design-v0.1/AGENT_DESIGN.md`: update them if they remain current authority, or mark
  them as superseded historical records with no current RubyLLM support claim. The completion
  evidence must include a residual `RubyLLMModel`/`ruby_llm` search with an exact historical
  allowlist, not a blanket “docs are historical” exception.
- Apply only the narrow generated `docs/code-quality-baseline.json` deletion entry required by
  removing the adapter. Do not spend review time on unrelated baseline or RuboCop debt.

### 6.4 Ownership and forbidden paths

**Owned:** the Phase 3 plan; the existing kernel provider/transport/receipt seams selected by
Slice A; `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb`; the listed CLI/evals/
script consumers; `gems/tamoz-agent/lib/tamoz/agent.rb` and
`gems/tamoz-agent/lib/tamoz/agent/runtime.rb`; `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb`;
`gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb`, `errors.rb`,
`model_receipt.rb`, `episode_model_call.rb`, `episode_model_transport.rb`, and the shared
projection/factory files; the adapter/gemspec; the explicitly listed tests; generated public
API/requirements/dependency-review artifacts; the provider matrix at
`documentation/reference/model-providers.md`; and the listed current docs.

**Read-only reference:** `gems/tamoz-graph/**`, `gems/tamoz-sqlite/**`, existing episode
runner/witness implementation except the selected kernel seam, and `test/support/**`.

**Forbidden:** compatibility aliases, new `tamoz-model` extraction, raw provider SDK calls,
a second model HTTP implementation or model-client class, changes to graph semantics, changes
to benchmark protocol/pins, and unrelated lint/baseline cleanup.

### 6.5 Final gates and known reds

No test suites run during planning, implementation, or review. After the reviewed code is
complete, run one ordered sequential final pass on pinned Ruby 3.3.11 with the pinned Ruby
directory first in `PATH`: focused provider/transport/session/receipt/profile/CLI-eval/
dependency/public-API/documentation contracts first; then `rake ci`; then `rake ci_full` in
the default locale and `LC_ALL=C`; then scoped RuboCop auto-fix followed by a scoped check;
then `enola generate_snapshot`, `diff_snapshot` against the Phase 2 baseline, and `enola check`.
This is one final verification stage, not parallel suites or repeated mid-phase checks.
RuboCop changes are auto-fix only; do not manually fix small style findings.

The verified Phase 2 benchmark-pin mismatch remains out of scope and must be reported by
exact digest, not called green. Do not update benchmark data in this phase. Any new failure
in a touched consumer, transport contract, dependency graph, or documentation surface is a
Phase 3 blocker.

### 6.6 Review questions for the two plan lenses

- **Architecture lens:** Does the provider/configuration seam extend existing kernel
  ownership without duplicating `EpisodeModelTransport` or `ModelReceipt`? Does the session
  path preserve graph independence, complete mediation, digest binding, and dependency
  direction? Is the proposed transport-backed model client simpler than preserving a second
  adapter?
- **Completeness/correctness lens:** Are all executable consumers, generated surfaces,
  provider promises, public API entries, failure/replay semantics, and test evidence covered?
  Does the provider matrix avoid silently breaking currently documented providers? Are the
  final gates and allowed benchmark red precise and reproducible?

---

## 7. Phase log

| Phase | Status | Reviews | Findings → resolutions | Commit |
|---|---|---|---|---|
| 1 | plan-reviewed | PA: PASS-WITH-GAPS (7) · PC: PASS-WITH-GAPS (8) | HIGH×2: scorecard case-10 dependency → chain kept + counterparty documented (§0; found independently by orchestrator and PA); D2 unscheduled → scheduled phase 3 (§0). MED×5 folded: conformance mechanism pinned (§1/§5); clause-11 enforcement wording backed by new socket/net-http probe w/ scoped-wording fallback (step 1g); `ordinal` :50 + emit blocks :51-60 named (step 2); nonexistent dispatcher-contract gate replaced with real files; grep tokens made exact + residual allowlist; INVARIANTS.md edit constraints named (step 1f). LOW×4 folded: anchors corrected (:80, :90, :121); "private juggling" dropped; identity-composition note (§5); stranded-TODO policy recorded (bar #6). Pre-change baselines recorded (4 suites green, enola PASS, rubocop 3335 raw offenses = committed-TODO state). | — |
| 1 | implemented + reviewed → bar met | R1: PASS (2) · R2: PASS (2) · R3: PASS-WITH-GAPS (4); zero CRITICAL/HIGH | R1 LOW socket matcher hardened to `%r{/socket\.(rb\|so\|bundle)\z}` (portability; matcher unit-checked true/true/true/false/false, suite re-green 22/221). R2 LOW#1 probe comment now states its deliberate difference from the comms case (comms pre-requires socket; graph case refuses it). R2 LOW#2 clause-11 nouns provider/adapter covered transitively — accepted, noted here. R3 LOW#1 landed deps cells INCLUDE Zeitwerk (deviation from plan's "omit like siblings") — docs match gemspec, which is the stronger truth; deviation recorded. R3 LOW#2 Encoding comment stays 3 lines (D5-sanctioned; file retires in phase 3). R3/R1 provenance flag: the transient graph.rb modification both reviewers saw was the orchestrator's sanctioned §9 mutation-proof (require net/http injected → probe fails as designed → restored byte-identical at blob ba33ec20); single-writer discipline held. R2 bonus: INVARIANTS.md:143's pre-existing conformance claim ("inspecting loaded features") had NO test before this diff — the new probe makes a standing design-doc claim true. Verification record: suites ruby_llm_model 4/15 · session_effect 18/70 · effect_identity 5/12 · public_api 3/1054 · documentation 3/919 · dependency_isolation 22/221 · agent_latency_smoke 2/18; design:validate PASS; scoped rubocop 0 offenses on all touched files; enola PASS no structural regression; deletion greps ZERO with predicted stream residuals. | this commit |
| 2 | plan-reviewed | PA2: PASS-WITH-GAPS (9) · PC2: PASS-WITH-GAPS (9); zero CRITICAL | HIGH×2 folded into §5: conformance doors corrected against HEAD ground truth — `deferred_model.rb` joins generate-doors, `witness_gateway.rb` joins net/http-doors (PA2 F2 / PC2 F1, independently found); dead false-positive encodings dropped, cli/evals/script declared out-of-scope with phase-3 rationale (PA2 F3). MED×5 folded: replay semantics + MAX_ATTEMPTS bound written into step 1 deliberately (PA2 F4); outcome projection specified with one assertion line on non-succeeded status (PA2 F5 + PC2 F4); v1 key composition includes execution_id with recorded rationale — ephemeral dedup is within-turn only (PA2 F6); parity honesty fixes — usage observed at SDK message object not through the adapter, 500-taxonomy replaced by connection-refused classes via closed in-test port (no `test/support/**` change), request-digest non-agreement named third divergence, `assume_model_exists` required (PA2 F7 / PC2 F2). LOW×4 folded: require_relative not Zeitwerk (both lenses), call_index = ordinal pinned, agent.rb anchor :62-64/:66, exact ownership enumeration. Provenance record (PA2 F1): orchestrator implemented step 1 IN-TREE while PA2/PC2 ran — sanctioned by round-budget pressure, single-writer discipline held (no subagent touched the tree); the draft was reviewed by PA2 A1 as the step-1 candidate and its deviations (:failed replay, abandon+bound) were then folded INTO the plan text rather than trimmed. PA2 A4 empirical scan + PC2 C1 door census agree with the final door lists. | — |
| 2 | implemented + reviewed → scoped bar met; repository baseline red recorded | R1: PASS after correction · R2: PASS after correction · R3: semantic findings resolved; its remaining objection was final-gate evidence, now recorded here (no small-change re-review requested) | Files: effects_journal.rb (new), runtime.rb (effects kwarg + journaled model_generate + EffectContext), AGENTS.md rule append + Runtime pointer, gems.md enforced-rule sentence, and 3 new tests. Journal corrections closed the material review findings: current-attempt fencing rejects nil/stale tokens; terminal receipts are immutable; `:unknown` replays as unknown; request identity is binding-checked; same-stage calls use ordinal + turn identity. The conformance scanner is root-anchored, exact-path allowlisted, and locale-stable; parity separates closed-port error taxonomy from retry posture and pins both. Final targeted evidence: effects 8/33 · node contract 7/12 (including LC_ALL=C) · parity 5/15 · runtime 11/54 · routing 14/221 · dependency isolation 22/221 · public API 3/1054, all 0F. Correctly invoked `rake ci` and `ci_full` (default + LC_ALL=C, Ruby 3.3.11 with localhost access) ran all repository tests; the sole failure in each was the independently verified, untouched benchmark holdout digest mismatch above. Enola snapshot: 13,099 facts; diff regressions 0; `enola check` PASS. Scoped RuboCop auto-fix corrected 21 offenses; 22 test-only style findings remain by owner direction; `.rubocop_todo.yml` stayed byte-identical. | 3325eeb |
| 3 | plan-reviewed | PA3: PASS · PC3: PASS; zero CRITICAL/HIGH/MEDIUM/LOW blockers after correction | Initial re-review found Runtime projection/safety coverage and dispatcher error mapping gaps, plus profile credential-ref, witness-gateway, episode-receipt, and undated-doc omissions. Folded into §6.2–§6.5: exact Runtime/one-shot path; `ModelCallError < Tamoz::Core::ToolError`; `ModelCallProjection`; factory safety binding; custom credential-ref descriptor; OpenRouter/witness distinction; episode configuration digest; and explicit current-vs-historical documentation inventory. Both lenses re-reviewed the corrected plan and returned PASS. No tests run by design. | — |
