# Model-call boundary review — synthesis

Date: 2026-08-26 · Target: `gems/tamoz-agent/lib/tamoz/agent/ruby_llm_model.rb`
Method: three independent lens reviews (`01`, `02`, `03` in this folder) plus an orchestrator
verification pass that independently spot-checked every load-bearing citation. Read-only;
no tests were executed — enforcement verdicts rest on reading the conformance tests, not
running them, and no claim below rests on a fixture standing in for a real model.

---

## The four questions, answered

### 1. Why do we have this file here?

Because it was born as the whole answer and never moved. It landed in commit 9919639
(2026-07-31, "activate reviewed read-only Tamoz agent") as **the repository's only model
path**, owning everything: inline ENV_KEYS, key resolution, the lazy SDK require, the raw
`.ask(prompt).content` call. Five commits modified it in place; it has never been relocated.
Its center of gravity then drained twice: credential vocabulary moved down into the kernel
(`Providers::ENV_KEYS`, commit 175485a — after profile validation created an upward layering
inversion by evaluating `RubyLLMModel::ENV_KEYS` at class-body time), and the episode world
routed around it entirely (61375a6 created `EpisodeModelTransport` inside tamoz-agent for
exact-wire-byte digests; d05c454 moved it below the adapter in the kernel). What remains is
the surviving half of a split the codebase already made and never finished reconciling:
an SDK-shaped convenience wrapper consumed by the CLI/session/evals worlds. Full biography:
[01](01-boundary-law-and-provenance.md) §1.

### 2. How is it breaking our design boundaries?

**Barely — and the honest answer is that the boundary problem is elsewhere.** Compliance
verdicts against the full written-law inventory (ten rules, [01] §2):

| Rule | Verdict |
|---|---|
| Clause 11 / LLM-independent engine | **Complies** — the file sits above the engine; zero `RubyLLM`/HTTP references exist in tamoz-core/tamoz-graph |
| Gemspec dependency declarations | **Complies** — only tamoz-agent declares `ruby_llm ~> 1.16.0`; zero `RubyLLM::` constants leak outside it |
| Public API registration | **Complies** — registered public surface of exactly one gem, no ghost alias |
| AGENTS.md effect-journal directive | **Complies at both transports** — every durable consumer journals through `EffectDispatcher.run` |
| gems.md:117 "no mutable process-global runtime state" | **VIOLATES the letter** — `Encoding.default_external` mutated process-wide in the constructor (`ruby_llm_model.rb:31-32`; justified comment, still COUP-8) |
| gems.md:77 "only layer that knows RubyLLM" | **Strains as prose** — three sibling gems legally construct the class via declared deps; the sentence should bind SDK-declaration, not "knowledge" |
| ARCH-2 credential resolution | **Still open** — CLI resolves ENV keys (`cli.rb:837-839`), then the constructor re-resolves (`ruby_llm_model.rb:20-25`) |

The real finding of this review: **the file complies with the boundaries while the model
seam itself is smeared across four gems** — adapter in tamoz-agent, credential vocabulary in
kernel `Providers`, resolution policy in the CLI, consumers in evals-runner — with no owner
below profile/CLI. Plus one genuinely new boundary defect nobody had catalogued (D1 below),
found because we went looking where the law is enforced least.

### 3. Are our assumptions correct?

**The stated premise is wrong; the instinct behind it is right; and two durability
assumptions failed audit.**

- *"All model calls should be inside the graph gem only"* — **rejected**. Clause 11 forbids
  exactly that: requiring `tamoz/graph` loads no RubyLLM, HTTP client, provider, or adapter.
  It is not prose aspiration — it is the one invariant that is both conformance-tested
  (`test/dependency_isolation_test.rb:8`) and ADR-anchored (`docs/design-v0.1/DECISIONS.md:47-48`),
  and its offline-testability guarantee is what lets the durability core be tested without
  providers. Moving models in would invert the deepest stable layer onto the most volatile
  one for zero gain: the journaled-model-call machinery already exists *behind* the engine,
  injected through node callables and `context.effects`. What your instinct is actually
  pointing at — confirmed by all three lenses — is a missing **contract**, not a missing
  dependency: nothing forces a node author to route a model call through the journal, and
  there is no single owner for the provider seam.
- *"A replay returns the recorded receipt, not a fresh, different answer"* — **true only for
  answered calls.** Session model calls default to `model_call_safety: :idempotent`
  (`session.rb:56,79`), and the journal grants a fresh attempt for anything found mid-flight
  under that class (`effect_preparation.rb:206-216`). A crash during generation resumes with
  a *fresh* completion. Only `:unsafe` gives stop-as-unknown; memory consolidation chose it,
  the flagship session path did not. The honest contract: *terminal receipts are immutable;
  unanswered calls are resolved by the safety class.*
- *"Provider failures are journaled like tool failures"* — **no.** Only `RubyLLM::Error`
  becomes `ProtocolError` (`ruby_llm_model.rb:62-67`); transport failures escape raw; and
  `EffectDispatcher` completes attempts exceptionally only for `ToolError` and
  `EffectUnknownError` (`effect_dispatcher.rb:183-203`). A failed provider call leaves its
  attempt `running` until the stale sweep classifies it purely by safety class. Safe today,
  but missing the typed terminal record the tool path gets for free.

### 4. Do we have solid design for the graph gem?

**Yes on its own terms, with three precise caveats.** One execution loop owns everything:
five executor classes funnel into `WriterRunExecutor#run_checkpoint` → `Executor` with
single-append CAS commits; request transitions ride the same checkpoint append (no second
journal). Injection seams are clean: nodes receive `(state, context)`; effects arrive bound
from the writer; the graph never constructs a journal, store, or transport. Effects are
deliberately split — vocabulary in the graph, decision logic in SQLite, transitions in the
kernel dispatcher — and that split is coherent. Caveats: (i) clause 11 is a **load-time**
invariant and the docs should say so — run-time, graph execution can invoke any injected
model object, by design; (ii) the `after_effect_started` callback chain traces fully but has
no production implementor (only a test fake) — production-dead plumbing; (iii) two cosmetic
strains (`__send__` adapters, documented). Full audit: [03](03-graph-solidity-and-target-topology.md) §1–§3.

---

## Where the lenses disagreed, and the adjudication

One tension: lens C called the unjournaled one-shot `Runtime#model_generate`
(`runtime.rb:599-606`) "the last surviving violation" of the house rule; lens B classified it
"a sanctioned ephemeral exception." Orchestrator ruling: **both half-right.** The rule's text
scopes to durable graphs ("a durable graph replays its nodes"), and `Runtime` provably writes
nothing durable (in-memory approvals, `ephemeral:` telemetry-only effect keys, zero
SessionRecords references) — so it violates neither the letter nor any replay property. But
the exemption lives only in code comments and plan docs, **not in the rule itself**, and
nothing at the `RubyLLMModel` seam signals it. A future contributor wiring the class into any
new stateful component gets zero friction and zero signal. Fix the documentation gap or close
the hole; do not leave the ambiguity (D6/D7 below).

On sequencing the two lens recommendations (extract the adapter now vs consolidate the
transport contract first): they compose. Lens A proves the extraction blockers are mostly cut
and enumerates the remaining consumers; lens C shows consolidation makes that extraction a
one-file move afterwards. The merged sequence below adopts C's ordering with A's migration
list.

---

## Defect register (verified, actionable regardless of direction)

| # | Finding | Evidence | Severity |
|---|---|---|---|
| D1 | `tamoz-agent-session` calls `Tamoz.graph` without declaring `tamoz-graph` — works only via load-order luck (`agent.rb:5` requires the graph before line 17 loads the session) | `session.rb:440`; gemspec deps at `tamoz-agent-session.gemspec:13-22`; `Tamoz.graph` defined at `tamoz-graph/lib/tamoz/graph.rb:24` | **High** — undeclared, load-order-dependent edge in a core gem |
| D2 | Provider failures never complete into the journal; stale sweep classifies them by safety class alone | `ruby_llm_model.rb:62-67`; `effect_dispatcher.rb:183-203` | Medium — latent bookkeeping gap, safe behavior today |
| D3 | Replay promise overstated: default `:idempotent` re-executes unanswered calls | `session.rb:56,79`; `effect_preparation.rb:206-216` | Medium — contract-honesty issue |
| D4 | Dead emitter machinery whose only strict consumer raises on those exact event types as forged | `ruby_llm_model.rb:44,51-60,72-76`; `episode_stream.rb:190-194` | Low hygiene, high confusion cost |
| D5 | `Encoding.default_external` process-global mutation vs gems.md:117 | `ruby_llm_model.rb:31-32` | Medium — written-law violation, mitigated by comment |
| D6 | Ephemeral exemption for `Runtime` unwritten in the rule it qualifies | `runtime.rb:599-606`; `agent.rb:62-65`; `step_execution.rb:262` | Low doc, real trap |
| D7 | No parity test between the two transports (retries: ruby_llm internal retry list vs single-shot net/http; error taxonomy; usage extraction) | [02] §4c | Medium — standing drift risk |
| D8 | ARCH-2 double key resolution still open | `cli.rb:837-839` vs `ruby_llm_model.rb:20-25` | Low |
| D9 | Stale prose: gems.md:77 "knows"; README/graph deps sentence; clause-11 load-vs-run wording | gems.md:77,117; README.md:23; overview.md:105 | Low |

---

## Recommended sequence (merged from the three lenses)

Each step independently shippable; steps 1–3 touch zero graph-gem files.

1. **Declare the missing edge and fix the prose** (D1, D9): add `tamoz-graph` to
   `tamoz-agent-session.gemspec`; rewrite gems.md:77 to bind SDK-declaration; correct the
   README graph-deps sentence; add the load-time/run-time wording to clause 11's docs.
2. **Close the unjournaled hole**: wrap `Runtime#model_generate` in `EffectDispatcher.run`
   with a logical identity (an in-memory journal suffices for the ephemeral runtime), and
   write the ephemeral carve-out into AGENTS.md's rule text (D6).
3. **Codify the model-call node contract**: generalize what `episode_nodes.rb` already
   practices — nodes receive a journaled call object, never a transport; add the
   conformance test that fails any node callable reaching `.generate` outside the door.
4. **Upgrade session receipts** to digest-bound projections (`request_digest, content,
   response_digest, usage`) mirroring `EpisodeModelCall`, keeping operation names and logical
   identity; decide whether `model_call_safety` should be per-stage rather than one blanket
   constructor value (D2, D3).
5. **Decide the transport question explicitly** (owner product call — see below), then
   **extract the adapter** into its small gem moving all consumers in the same slice
   (`cli.rb:837,863`; evals sites; public-API manifest), per the 2026-08-25 audit's own
   condition — now partially satisfied.
6. **Cleanup slice**: delete-or-wire the dead emitter path (D4); resolve
   `after_effect_started` (delete or assign an owner); resolve ARCH-2 with one credential
   resolver (D8); add the transport parity test (D7).

## Decisions needed from you (product calls, not code calls)

1. **Transport surface**: accept OpenAI-compatible endpoints as the supported reality
   (retiring `RubyLLMModel`), or keep it as a provider adapter implementing one unified
   journaled-call interface? Nine providers are catalogued; native anthropic/gemini breadth
   is the real cost of retiring it.
2. **One-shot Runtime**: port it onto the graph engine, or just journal its `generate` call?
   Same correctness win, different sizes.
3. **`after_effect_started`**: reserved for a planned feature (e.g. provider-side
   cancellation), or delete?
4. **Extraction naming** when step 5 runs: `tamoz-model` (04-E) vs optional
   `tamoz-agent-ruby-llm` (audit-02) — consumer sets identical; pick one name.
5. **AGENTS.md rule text**: add the ephemeral-carve-out sentence, yes/no.

---

## Review quality appendix

- Deliverables: [01-boundary-law-and-provenance.md](01-boundary-law-and-provenance.md),
  [02-runtime-and-journal-audit.md](02-runtime-and-journal-audit.md),
  [03-graph-solidity-and-target-topology.md](03-graph-solidity-and-target-topology.md).
  All three passed the bar: file:line citations throughout, explicit verdict tables, prior
  settled decisions engaged by name (04-E deferral, audit-2026-08-25 assessment, P1/B3,
  P6 rows, ARCH-2/COUP-8, repo-quality P1), steelman sections, self-checks.
- Citation spot-checks by the orchestrator: 13/13 anchors on lens C, 9/9 new anchors plus
  prior ground truth on lens B, 12+ on lens A including reproduction of its new finding
  (D1). Three grounding facts were corrected *by the agents against the brief* and all
  three corrections verified true (graph gemspec deps include cancellation/concurrency;
  `deprecated:true` exists only in manifests/tests, not gems code; `episode_nodes.rb:70` is
  the recall node).
- Known blemishes, recorded rather than hidden: lens B/C self-checks understate their line
  counts (~200 vs 253; ~230 vs 306); lens A cites the evals-runner gemspec edge at :37,
  actual current-tree line :34 — substance unaffected in both cases.
