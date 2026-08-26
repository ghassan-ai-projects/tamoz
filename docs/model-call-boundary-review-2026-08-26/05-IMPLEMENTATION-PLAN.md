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
  (`gems/tamoz-agent/lib/tamoz/agent/runtime/effects_journal.rb`, Zeitwerk-mapped,
  frozen_string_literal, documented public surface): implements the dispatcher's duck-typed
  contract — `prepare(execution_id:, task_id:, call_index:, operation:, safety:, request:,
  logical_key:)`, `start`, `complete`, `key`, `logical_key`/`logical_identity`. Decision and
  record shapes REUSE the graph gem's vocabulary structs (`Tamoz::Graph::EffectRecord`,
  `EffectAttempt`) — no second vocabulary (lens PA A1). Semantics: first sight of a logical
  key → `:execute`; a terminal `succeeded` record for the same key → `:return` with
  `reused`; nothing else (an in-process ephemeral journal never sees mid-flight stale
  attempts; do NOT cover that case — owner directive).
- **Injection**: `Runtime.new` gains an `effects:` keyword defaulting to a fresh
  `EffectsJournal`; `Tamoz::Agent.build` passes it explicitly, exactly as it already passes
  the in-memory approval engine ("its grants live and die with this process",
  `agent.rb:57-59` — same decision, second application). `Runtime` holds a small immutable
  effect-context value exposing the four things the dispatcher reads
  (`effects`, `execution_id`, `task_id`, `request_id` from `@correlation`).
- **Identity** (lens PA finding 6): `operation: "model.generate.<stage>"`,
  `capability_id: "model:<stage>"`, canonical `{stage, system, prompt}` arguments,
  `iteration: @model_call_count` (post-increment value — every call in a turn gets a DISTINCT
  identity), `sub_operation: 0`, `authority_revision: toolbox.catalog_digest`,
  `catalog_revision`: digest over the empty catalog map. Safety `:idempotent` — mirrors the
  session default; the ephemeral carve-out sentence documents why in-memory is sufficient.
- **Telemetry preserved**: the observability span stays wrapped around the whole dispatched
  call.
- **Tests** (`test/agent_runtime_effects_test.rb`): journal-level — first prepare executes,
  second prepare of the same identity returns the recorded receipt with `reused: true`
  WITHOUT re-running perform, distinct identity executes fresh; runtime-level — a scripted
  model turn records prepare/start/complete transitions into the injected journal and the
  answer is unchanged; assert the dispatcher door is actually crossed (the journal saw the
  operation), which is the property the whole phase exists for.

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
  A2): Ripper-based source audit in the `boundary_source_audit.rb:543-577` style over
  production libs of `gems/{tamoz-agent-kernel,tamoz-agent-session,tamoz-agent-memory,tamoz-agent}/lib`.
  Deny: receiver-qualified `.generate(` outside the door allowlist
  {`session_effects.rb`, `consolidation.rb`, `episode_model_call.rb`, `runtime.rb`};
  `RubyLLM` references / `require "ruby_llm"` outside tamoz-agent;
  `net/http` require outside `episode_model_transport.rb`. Encode false positives: bare
  function-style `generate(...)` definitions/wrappers (DeferredModel, evals
  `memory_envelope.rb`), CLI dummy-model definitions (`cli_authority.rb:195`, `cli.rb:563`),
  `JSON.generate` (allowlist the receiver), test fakes excluded by scope. Each denial rule
  carries its §9 comment: what breaks if the rule goes.

### Step 4 — two-transport parity test (D7)

`test/model_transport_parity_test.rb` drives BOTH transports against ONE
`LocalModelEndpoint` in `:fixture` mode (real HTTP boundary, scripted OpenAI-compatible
envelope, independent digest log — never a real provider):
- Agreement: identical envelope in → identical extracted content string; usage token counts
  agree between the transport's `ModelCall::Usage` projection and ruby_llm's usage fields.
- Deliberate divergences PINNED as named assertions (the drift the docs must manage):
  error taxonomy (HTTP 500 → `ProtocolError` via RubyLLM::Error mapping vs raw transport
  error class) and retry posture (connection refused → ruby_llm's internal retry list vs
  single-shot net/http; count hits at the endpoint).

### Gates (phase 2)

Named suites above · `ruby -Itest test/dependency_isolation_test.rb` ·
`ruby -Itest test/public_api_test.rb` · `rake ci_full` under BOTH locales (durability
touched) · scoped rubocop on touched files · enola check.

### Ownership sketch (phase 2)

Owned: the two new lib/test files, `runtime.rb`, `agent.rb`, `AGENTS.md`,
`documentation/architecture/gems.md`, the three new/edited test files.
Forbidden: `gems/tamoz-graph/**`, `gems/tamoz-sqlite/**`, `gems/tamoz-stream/**`,
`gems/tamoz-agent-kernel/**` (episode machinery is read-only reference),
`test/support/**`.

Known-red carries over from phase 1's list, plus anything phase 1's commit records.

## 6. Phase 3 plan (owner-gated)

**The owner gate confirms exactly this:** retire `Tamoz::Agent::RubyLLMModel` and standardize
every model path on the digest-bound OpenAI-compatible transport contract. Nothing below
executes until that confirmation lands.

### Slice A — session receipts go digest-bound (D2 + D3 closure)

`SessionEffects#model_call` builds canonical request bytes through
`EpisodeModelTransport`'s JCS framing and records `{request_digest, content,
response_digest, usage}` like `EpisodeModelCall#perform_call`, keeping operation names
(`model.generate.<stage>`) and the structured logical identity. Failed model attempts get
typed terminal completion (the tool path's treatment) instead of lingering until the stale
sweep — D2 closes here. Per-stage `model_call_safety`: default stays blanket unless the
session stages disagree (decide by reading the stage list, not speculatively). Schema-visible;
fresh-schema per house rules. Tests: receipt reuse from journal without provider contact on
replay; typed failure completion visible in the journal.

### Slice B — consumers onto the transport contract

Migration list (lens PA finding 4 included): `cli.rb` model construction + ENV-key
resolution (`cli.rb:837-869`), evals benchmark adapter sites
(`openclaw_durable_cli_adapter.rb:904-908`), `environment_loader.rb:55` if implicated,
`cli_argument_parser.rb:69-70` help text, `lane_config.rb:11` comment. ARCH-2 resolves here:
ONE credential resolver beside `Providers::ENV_KEYS` in tamoz-agent-kernel; CLI and adapters
call it instead of re-implementing ENV lookup.

### Slice C — retire RubyLLMModel

Delete `ruby_llm_model.rb`; remove `ruby_llm ~> 1.16.0` from `tamoz-agent.gemspec`;
update `docs/public-api.json`, requirements manifest entry, and `test/public_api_test.rb`
in the SAME commit; decide the `agent.rb:14` re-export seam explicitly (the CLI reaches
model construction through tamoz-agent's facade — after retirement either the facade keeps
a construction seam over the kernel transport or the call sites take the kernel class
directly; no new gem dependency). README/gems.md rows updated. D5 dies with the file.
Native anthropic/gemini operators get the gateway/openrouter story documented in the same
slice, not after.

### Alternative if the owner overrides (keep + extract)

One extraction slice moves `RubyLLMModel` behind the unified journaled-call interface into a
small `tamoz-model` gem with all consumers migrated in the same change (04-E / audit-02
conditions now satisfied); Slice A still happens (receipts upgrade is independent of where
the adapter lives); Slices B/C collapse into the extraction.

### Gates (phase 3)

Everything in phase 2's gate list, plus agent/autonomy scorecard suites and benchmark-family
gates per QUALITY_PROGRAM gate policy (persistence + agent surfaces touched);
`rake ci_full` both locales.

---

## 7. Phase log

| Phase | Status | Reviews | Findings → resolutions | Commit |
|---|---|---|---|---|
| 1 | plan-reviewed | PA: PASS-WITH-GAPS (7) · PC: PASS-WITH-GAPS (8) | HIGH×2: scorecard case-10 dependency → chain kept + counterparty documented (§0; found independently by orchestrator and PA); D2 unscheduled → scheduled phase 3 (§0). MED×5 folded: conformance mechanism pinned (§1/§5); clause-11 enforcement wording backed by new socket/net-http probe w/ scoped-wording fallback (step 1g); `ordinal` :50 + emit blocks :51-60 named (step 2); nonexistent dispatcher-contract gate replaced with real files; grep tokens made exact + residual allowlist; INVARIANTS.md edit constraints named (step 1f). LOW×4 folded: anchors corrected (:80, :90, :121); "private juggling" dropped; identity-composition note (§5); stranded-TODO policy recorded (bar #6). Pre-change baselines recorded (4 suites green, enola PASS, rubocop 3335 raw offenses = committed-TODO state). | — |
| 1 | implemented + reviewed → bar met | R1: PASS (2) · R2: PASS (2) · R3: PASS-WITH-GAPS (4); zero CRITICAL/HIGH | R1 LOW socket matcher hardened to `%r{/socket\.(rb\|so\|bundle)\z}` (portability; matcher unit-checked true/true/true/false/false, suite re-green 22/221). R2 LOW#1 probe comment now states its deliberate difference from the comms case (comms pre-requires socket; graph case refuses it). R2 LOW#2 clause-11 nouns provider/adapter covered transitively — accepted, noted here. R3 LOW#1 landed deps cells INCLUDE Zeitwerk (deviation from plan's "omit like siblings") — docs match gemspec, which is the stronger truth; deviation recorded. R3 LOW#2 Encoding comment stays 3 lines (D5-sanctioned; file retires in phase 3). R3/R1 provenance flag: the transient graph.rb modification both reviewers saw was the orchestrator's sanctioned §9 mutation-proof (require net/http injected → probe fails as designed → restored byte-identical at blob ba33ec20); single-writer discipline held. R2 bonus: INVARIANTS.md:143's pre-existing conformance claim ("inspecting loaded features") had NO test before this diff — the new probe makes a standing design-doc claim true. Verification record: suites ruby_llm_model 4/15 · session_effect 18/70 · effect_identity 5/12 · public_api 3/1054 · documentation 3/919 · dependency_isolation 22/221 · agent_latency_smoke 2/18; design:validate PASS; scoped rubocop 0 offenses on all touched files; enola PASS no structural regression; deletion greps ZERO with predicted stream residuals. | this commit |
