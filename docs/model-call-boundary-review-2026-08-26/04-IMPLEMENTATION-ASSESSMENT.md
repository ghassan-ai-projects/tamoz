# Implementation assessment — is the model-call boundary review worth acting on?

Re-review date: 2026-08-26 · Author: orchestrator re-review pass over `00`–`03`.
Scope: (a) verify the review's load-bearing claims against the current tree, (b) give the owner
a straight buy/no-buy on implementing it, and in what order. Read-only; no tests run.

---

## Bottom line

**Recommend implementing — but a deliberately smaller slice than the six-step sequence in `00`,
and one of its steps is now deleted, not deferred.** The review's core judgments survived
re-verification: the file complies with the written boundaries, moving model calls *into*
`tamoz-graph` is the wrong move (it would invert the one clause that is both conformance-tested
and ADR-anchored, for zero behavioral gain), and the real problem is a missing *contract*, not a
missing dependency. Those are correct and well-evidenced. What changed on re-review:

- **D1 is retracted.** The review's only "genuinely new, High-severity" finding — an undeclared
  `session→graph` gemspec edge — is a false positive. `tamoz-agent-session.gemspec:21` declares
  `tamoz-graph`; `gemspec_helper.rb:56-57` turns it into a real `add_runtime_dependency`. Both the
  lens-A agent and the orchestrator's first verification pass missed line 21 (they grepped for
  `add_runtime_dependency`, which `TamozGemspec.build` hides). **Do not implement step 1's "declare
  the missing edge" — there is nothing to declare.** Corrected in `00` and `01`.
- Every other anchor I spot-checked held (`ruby_llm_model.rb:20-25/31-32/62-67`,
  `runtime.rb:600-606`, `session.rb` safety default `:idempotent`, `providers.rb` nine-provider
  catalog, `episode_model_transport.rb` OpenAI-compatible shape). Net reliability: high.

So: the *analysis* is sound and the direction is right; the *action list* needed one correction
and benefits from being sequenced by risk rather than shipped whole.

## What to implement, ranked by value-over-risk

The review already establishes that steps 1–3 touch zero graph-gem files. I rank the actual work:

| Do it? | Item (review ref) | Why | Effort | Risk |
|---|---|---|---|---|
| **Yes, now** | Fix the prose: gems.md:77 → "only gem that *declares* the ruby_llm SDK"; README graph-deps "core + cancellation + concurrency"; clause 11 load-time-vs-run-time wording (D9, `03`§2.3) | Removes the exact ambiguity that mis-seeded this whole review; free | XS | none |
| **Yes, now** | Delete-or-wire the dead emitter path in `ruby_llm_model.rb:44,51-60,72-76` (D4) | Dead machinery whose only strict consumer treats its events as forgeries; it actively *misled this review's premise* — highest confusion-cost-per-line in the file | S | low |
| **Yes, now** | Resolve `after_effect_started` — delete it or assign an owner (`03`§2.4) | Contract with no production counterparty (only a test fake implements it) | S | low |
| **Yes, soon** | Codify the model-call node contract + conformance test: a node reaches a model only through a journaled call object, never a transport (`03`§6 step 2) | This is the review's actual thesis — turns "journaled by convention" into "journaled by construction". The single most valuable structural item | M | low–med |
| **Yes, soon** | Close the unjournaled one-shot hole: wrap `Runtime#model_generate` in `EffectDispatcher.run` with an in-memory journal, and write the ephemeral carve-out into AGENTS.md (D6, `02`§3.1) | Converts the last raw model path into recorded receipts; removes the "future contributor wires this into a stateful component with zero signal" trap | M | low |
| **Yes, soon** | Add the two-transport parity test (D7, `02`§4c) | Names the standing drift cost (retries, error taxonomy, usage extraction) before it bites | S | low |
| **Conditional** | Upgrade session receipts to digest-bound projections; decide per-stage `model_call_safety` (D2, D3, `03`§6 step 3) | Real honesty/robustness win, but schema-visible and only worth doing as the on-ramp to the transport decision | M–L | med |
| **Decide first** | Consolidate on one digest-bound journaled call contract, then extract the adapter (`03` option c → `01`/`02` extraction) | The big one. Depends entirely on the transport product call below | L | med–high |
| **No** | Relocate model calls into `tamoz-graph` (owner's original premise, option d) | Rejected by all three lenses and confirmed here: destroys clause 11's tested mechanism for nothing | — | — |

Read that as three waves: **(1) prose + hygiene** (the top three rows — a half-day, no downside,
do it regardless of everything else); **(2) the contract** (node-contract test + one-shot journal
+ parity test — this is where the review earns its keep); **(3) the transport question** (gated on
a decision, see below).

## The one decision everything else waits on

The review's five "decisions needed" collapse to one that actually gates work: **do we keep
`RubyLLMModel` as a multi-provider SDK adapter, or retire it in favor of the digest-bound
OpenAI-compatible transport (`EpisodeModelTransport`) as the single call contract?**

Grounded recommendation: **converge on the digest-bound OpenAI-compatible contract; keep
`RubyLLMModel` only if and while native anthropic/gemini are actually in use.** Rationale from the
tree, not preference:

- The nine-provider catalog (`providers.rb:10-20`) is mostly OpenAI-compatible already — deepseek,
  openai, openrouter, ollama, xai, perplexity, mistral all speak the `/chat/completions` shape the
  frozen transport uses. Only **anthropic** and **gemini** need native APIs, and both are reachable
  through openrouter or a gateway.
- This project's own documented runs use **DeepSeek** (OpenAI-compatible). So the "real cost of
  retiring `RubyLLMModel`" that `00` flags — native provider breadth — is, for current usage,
  close to zero. That materially de-risks option (c).
- The digest-bound path is strictly stronger on the property the whole review is about: its receipt
  *is* the digest of the exact bytes sent, so replay reconstructs the answer without calling the
  provider (`episode_model_call.rb:107-122`). `RubyLLMModel` structurally can't offer that
  (`.ask(prompt).content` discards the message object) and has already grown a process-global
  workaround the frozen transport can't need (`Encoding.default_external`, D5).

The honest counter, kept in view: retiring the SDK adapter loses native anthropic/gemini and the
provider-level ergonomics ruby_llm gives for free. **So the gating question to answer before wave 3
is narrow and factual: is any real run using anthropic or gemini *natively* (not via openrouter)?**
If no → retire `RubyLLMModel`, adopt the transport contract everywhere, extraction becomes a
one-file move. If yes → keep it, but move it behind the same journaled-call interface into a small
`tamoz-model`/`tamoz-agent-ruby-llm` gem (the twice-deferred 04-E / audit-02 extraction), with its
consumers migrated in the same slice.

Either way, waves 1 and 2 are unblocked and worth doing first — they shrink the transport decision
to pure packaging, exactly as `03`§6 argues.

## Recommendation on the other four product calls

- **One-shot Runtime (port to graph vs just journal it):** just journal it (in-memory). Porting
  `Runtime` onto the graph engine is a large change for the same correctness win; the review's own
  steelman S2 shows a graph-owned seam wouldn't even reach the path that needs fixing.
- **`after_effect_started`:** delete it. No production implementor exists; reintroduce with an
  owner if provider-side cancellation ever ships. Don't carry a counterparty-less contract.
- **Extraction naming:** irrelevant until the transport decision picks "keep the adapter." If it
  does, `tamoz-model` — the seam is a model contract, not a ruby_llm detail.
- **AGENTS.md ephemeral carve-out sentence:** yes, add it. The absence of that one sentence is
  precisely what left the one-shot path looking like a violation to two of three lenses; a rule
  that needs three code comments to qualify it belongs in the rule text.

## Confidence and caveats

- **High confidence** on: uphold clause 11, reject option (d), do waves 1–2, D1 is false. These
  rest on anchors I re-verified directly.
- **Medium confidence** on the transport recommendation — it hinges on the one factual question
  above (native anthropic/gemini usage), which is the owner's to answer, not the code's.
- Not re-verified (planning-only, no tests): I read the conformance tests' intent but did not run
  them; the replay-semantics claims in `02` rest on reading the journal state machine, as the
  review itself states. Nothing in my assessment depends on a test result.
