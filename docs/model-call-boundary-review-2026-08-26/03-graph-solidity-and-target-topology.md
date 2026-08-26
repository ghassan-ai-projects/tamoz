# Lens C — tamoz-graph solidity & target topology

Review date: 2026-08-26 · Scope: `gems/tamoz-graph` execution spine, the effect seam it exposes,
and where the model-call boundary should live. Owner question taken both ways: is the engine worth
its shape, and would owning model calls inside the graph gem strengthen or weaken the system.

Method note: every claim below cites the current tree. One correction to the review brief's
grounding: tamoz-graph does **not** depend "only on tamoz-core" — its gemspec declares
tamoz-cancellation, tamoz-concurrency, tamoz-core, and zeitwerk
(`gems/tamoz-graph/tamoz-graph.gemspec:11-16`). This does not weaken clause 11 (all three are
below-graph substrate gems, proven by `test/dependency_isolation_test.rb:81-107`), but the README's
dependency story should say "core + cancellation + concurrency", not "core only".

---

## 1. The execution spine, read end to end

One loop owns execution. `Builder` collects channels/nodes/edges/branches with capacity caps
(`builder.rb:39-106`) → `Compiler` validates references, routing modes, reachability from START and
reverse-reachability to END, then digests a canonical descriptor into `definition_digest`
(`compiler.rb:26-36,40-92,193-208`) → `Compiled` freezes planners, state manager, pools, codec, and
checkpointer (`compiled.rb:11-35`). Every entry path funnels into the same spine:

| Entry | Path to the loop |
|---|---|
| `Compiled.invoke/stream/resume/retry_failed/continue` (`compiled.rb:42-130`) | `LifecycleExecutor` |
| timed variants `invoke_at/resume_at/...` (`compiled.rb:200-203`) | `RunCoordinator` |
| durable request runs (`DurableRunner#run_next/recover`, `durable_runner.rb:56-153`) | claim → `DurableRequestExecutor.dispatch` over `:turn/:resume/:retry/:continue/:fork/:redirect` (`durable_request_executor.rb:30-42`) → `*WithWriter` |
| fork requests (`compiled.rb:219-222`) | `ForkExecutor`, which delegates non-fork states back through the same writer paths (`fork_executor.rb:33-50`) |
| subgraphs | `SubgraphRuntime#call` re-enters via `invoke_at/resume_at/retry_failed_at/continue_at` (`subgraph_runtime.rb:25-76`), sharing the parent checkpointer |

All of them end at `WriterRunExecutor#run_checkpoint`, which binds effects/store onto the context
and calls the one loop (`writer_run_executor.rb:187-191`). The loop itself is a single
super-step cycle: fence-check writer, plan tasks, execute pool, classify results, append exactly one
checkpoint per step with `expected_base_id` CAS (`executor.rb:22-168`; CAS surfaced at
`state_operations.rb:86-111`). Terminal transitions for durable requests are emitted through the
same commit call via `request_transition` (`executor.rb:134-162,359-380`), so request state and
checkpoint state move in one append — no second journal.

**Coherence verdict: solid.** There are five executor classes but one commit discipline and one
loop; the extra classes are adapters over distinct protocols (lifecycle entry, request dispatch,
fork lineage, subgraph nesting), not divergent engines. This matches GAUNTLET's standing
"no second engine" gate (`docs/GAUNTLET_PROGRESS.md:584-585`).

## 2. Solidity audit — four dimensions

### 2.1 Internal coherence — SOLID

Evidence as above, plus: interrupts, failures, and pauses all commit through
`append_noncommitting` → the same `append_checkpoint` (`executor.rb:326-357`); pending-outcome bytes
are limit-enforced before commit (`executor.rb:463-471`); stale results are rejected by task/
attempt/base identity before they can touch state (`executor.rb:315-324`). The one wrinkle is
cosmetic: `Executor` reaches `Compiled` internals through `__send__` in the adapters
(`writer_run_executor.rb:151,155,173-185`), a deliberate narrow-boundary choice documented at
`durable_request_executor.rb:6-12`. Strain, not breakage.

### 2.2 Seam cleanliness — SOLID

A node author injects a `NodeSpec`: name, callable, routing mode, routes, and a digest-stable
identity (`implementation_name` + `version`; anonymous procs are forced to declare both,
`node_spec.rb:42-50`). Nodes receive `(state, context)` (`node_spec.rb:55-61`,
`executor.rb:238-251`). Everything environmental arrives on the context: cancellation, emitter,
interrupt cursor, subgraph runtime (`executor.rb:203-216`) — and the effect journal, bound at run
time from the injected writer (`execution_support.rb:65-77`), which also rejects a context already
carrying an unbound journal (`execution_support.rb:67-74`). The graph never constructs an effect
journal, a store, or a transport. That is exactly the shape that lets episode nodes, session nodes,
healing, and memory consolidation share one engine.

### 2.3 Enforcement of clause 11 — PRESENT (load-time only)

The conformance test exists and is subprocess-based with a cleaned environment:
`test_graph_loads_no_model_eval_or_adapter_package` requires `tamoz/graph` in a fresh Ruby process
and refutes any `ruby_llm`, `tamoz/evals`, `tamoz/sqlite`, or `tamoz/agent` feature
(`test/dependency_isolation_test.rb:8-17`; harness `loaded_features_after` at :339-359). Sibling
tests pin core/tools/kernel/cancellation/concurrency boundaries the same way (:19-107). This is
real enforcement, not aspiration.

**Precise statement the docs still owe:** clause 11 (`documentation/architecture/invariants.md:15`;
`docs/design-v0.1/INVARIANTS.md` §11; rationale `documentation/architecture/overview.md:104-108`)
is a **load-time** invariant. At **run time**, graph execution absolutely can invoke a model object
— any object the embedding placed inside a node callable or the context, including one holding API
keys and an HTTP client. Nothing in graph code reaches for one (`grep effects` in the gem hits only
the two writer-binding sites above), so the *engine* stays provider-blind, but a reader of clause 11
who takes "no adapter loaded" as "no adapter can execute under the graph" will be wrong. The
invariant doc should say: clean-process load independence, enforced by
`dependency_isolation_test.rb:8`; run-time capability injection via node callables and
`context.effects`, by design.

### 2.4 Dead weight — MOSTLY NONE; two vocabulary/consumer splits

Checked by grep across gems/apps/bin plus intra-gem usage: `Marker` is the START/END sentinel used
by builder/compiler (`marker.rb:20-22`); `StreamEmitter`, `ForkExecutor`, `RunCoordinator`,
`LifecycleExecutor`, `SubgraphRuntime` all have live callers (§1 table). No orphan file found.

Two real splits, neither dead but both load-bearing for this review:

1. **Effect vocabulary lives in the graph; effect decisions live in SQLite.**
   `effect_record.rb:5-39` defines `EffectAttempt/EffectRecord/EffectDecision` as pure data.
   The decision (`EffectDecision.new`) is computed in tamoz-sqlite —
   `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_preparation.rb:255` and
   `effect_reconciler.rb:163` — driven by kernel `EffectDispatcher`
   (`gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:52-66` calls
   `effects.prepare/start/complete/reconcile`). The graph contributes the *context identity*
   (execution_id, task_id) the key is built from, and nothing else.
2. **`after_effect_started` is production-dead plumbing.** The suspicious inversion traces fully:
   `Executor` → node callable → `SessionEffects#dispatch` → `EffectDispatcher.run(after_start:)` →
   `effects.start(...)` then `after_start&.call` (`effect_dispatcher.rb:176-177`) →
   `SessionEffects#after_effect_started` (`session_effects.rb:100,154-157`) →
   `DeferredModel#after_effect_started` (`worker_runtime/deferred_model.rb:24-26`) → underlying
   model. But **no production model implements the hook**: `RubyLLMModel` has no such method, and
   the only implementor in the tree is the test fake `test/support/autonomy_case.rb:71`. So graph
   execution reaches the model object mid-effect only for tests. Either delete the hook chain or
   document who is supposed to implement it — today it reads like a contract with no counterparty.

## 3. Who executes effects today — the precise answer

The side-effect block is **caller-supplied, executed inside node callables running under the graph
loop**. `EffectDispatcher.run` takes `&perform` from its caller; the journal transitions happen in
kernel code; the decision logic happens in sqlite; the graph provides only the bound context and the
checkpoint barrier around the whole thing. Concretely for models:

- Session path: `SessionEffects#model_call` wraps `@configuration.model.generate` in
  `EffectDispatcher.run` with operation `model.generate.<stage>` and a logical identity
  (`session_effects.rb:18-35`).
- Episode path: `EpisodeModelCall#call` builds canonical request bytes via the transport, derives
  the logical call key from (episode, stage, slot, request_digest), and journals through the same
  door (`episode_model_call.rb:48-83`).
- Memory consolidation and healing remediation use the same dispatcher
  (`memory/consolidation.rb:194`; `healing/remediation/effect_execution.rb:34`).

So the answer to the orchestrator's key question: **the graph is already structurally capable of
running a journaled model call** — the journaled-model-call machinery exists and works — but none
of it is *inside* graph code. The owner's instinct ("model calls belong in the graph") is
architecturally cheap to satisfy in behavior terms because the hard part (journal, keys, replay,
reconciliation) already exists behind `context.effects`. What remains outside the graph is only the
transport objects and the discipline of calling them through the door.

## 4. Which runtimes are live (this decides the recommendation)

Three model-call regimes exist in the tree **today**, all reachable from production entry points:

| Regime | Entry point | Model transport | Journaled? | Digest-bound receipt? |
|---|---|---|---|---|
| Episode worker | `bin/tamoz-stream-worker:102-129` composes `EpisodeGraph.build` + `EpisodeNodes` | `EpisodeModelTransport` (net/http, JCS canonical bytes, frozen temperature-0 settings, `episode_model_transport.rb:14-31`) | Yes — `EpisodeModelCall` → `EffectDispatcher.run` (`episode_model_call.rb:67`) | Yes — request digest IS the digest of sent bytes |
| Durable session worker | `Worker#claim_and_run` drives `session.app.durable_runner.run_next` (`worker.rb:485-495`); session compiles graphs at `session.rb:146-148` | `RubyLLMModel` via injected configuration | Yes — `SessionEffects#model_call` | No — request is raw `{stage, system, prompt}` strings |
| One-shot CLI Runtime | `cli.rb:171` → `Tamoz::Agent.build` → `Runtime.new` (`agent.rb:66-68`) | `RubyLLMModel` direct | **No** — `Runtime#model_generate` calls `model.generate` raw (`runtime.rb:599-606`) | No |

This settles the orchestrator's question about P1: the new-design episode architecture is **live in
production wiring** — `bin/tamoz-stream-worker` has no `--graph FILE` route and composes exactly
`EpisodeGraph`+`EpisodeNodes`+`EpisodeModelCall` (launcher header comments at `bin/tamoz-stream-worker:3-7`)
with the model factory composed *outside* the graph and injected in. It is aspirational only for the
session/CLI worlds. Meanwhile the one-shot CLI Runtime doesn't use the graph engine at all — it is a
separate deliberation loop with an unjournaled model call, the last surviving violation of the
AGENTS.md working rule ("non-deterministic external calls go through the durable effect journal")
among model paths.

## 5. Steelman: the strongest case FOR model calls inside the graph gem

**S1 — The graph already owns effect records and reconciliation, so a model call is just another
effect; giving the graph the model makes the journal automatic.**
Conceded half-way. The vocabulary (`effect_record.rb`) and the barrier semantics are graph-owned;
decisions and attempts are sqlite-owned (§2.4). For the graph to make model journaling "automatic,"
it would need to own `prepare/start/complete/reconcile` semantics too — i.e., absorb the journal
contract that today lives in tamoz-sqlite behind the injected writer. That is a large dependency
inversion bought to save one wrapper method (`SessionEffects#model_call`, 17 lines).

**S2 — A first-class `model_call` node type would eliminate the unjournaled Runtime path by
construction.**
The problem is real (`runtime.rb:599-606`), but the construction wouldn't fix it: the one-shot CLI
Runtime never enters the graph engine, so a graph-owned model seam is unreachable from the very path
that needs it. Fixing the hole means either porting Runtime onto graphs or wrapping its generate in
an EffectDispatcher-compatible journal — both are Runtime-side changes, not graph-side.

**S3 — Provider binding could become graph config, like checkpoint backends.**
Rebutted. The checkpointer is durability infrastructure the engine must validate to guarantee its
own correctness contract (protocol version, open_writer/latest/find/history —
`compiler.rb:101-121`). Provider choice affects payload policy, not engine correctness; there is no
graph-level invariant a provider could violate. Configuring providers in the graph adds coupling
without adding a guarantee.

**S4 — Two transports (RubyLLMModel vs EpisodeModelTransport) is accidental duplication; one graph
seam would unify them.**
True observation, wrong layer. The duplication closes by standardizing the *call object*
(`EpisodeModelCall` semantics) and retiring or demoting one transport — no engine change required
(§6, option c).

**S5 — "Offline-testable / reusable for non-LLM workflows" (the clause-11 rationale,
`overview.md:105-108`) is sentimental; everything real calls models anyway.**
Rebutted by the tree: `MemoryCheckpointer` exists precisely so graph tests run without stores
(`compiler.rb:11` default), the clause-11 test proves offline load (`dependency_isolation_test.rb:8`),
and the engine's consumers include healing rules and memory consolidation whose value is the
barrier/journal semantics, not LLMs. Making the engine require a model adapter would tax every
future durable workflow to slightly shorten two wrapper files.

**Verdict on the premise:** literalizing it (option d) destroys clause 11's mechanism while buying
almost nothing the tree doesn't already have — the journaled model call exists; it is just composed
from outside. What the premise is really pointing at is a missing **contract**, not a missing
dependency: today nothing forces a node author to route a model call through the journal (the CLI
Runtime proves it), and there are two transports with different receipt strength. Adopting the
middle design — a **graph-owned MODEL-CALL NODE CONTRACT with injected transport** — captures the
premise's benefit (journal-by-construction for every graph-executed model call) at zero dependency
cost. Concretely: generalize what `episode_nodes.rb` already does (its header states `reason` calls
models only through `EpisodeModelCall`/`EffectDispatcher`) into the stated rule for all graph
nodes, enforced by a conformance test that fails any node whose callable reaches `.generate` except
through a journaled call object.

## 6. Target topology

Ranked options. Primary: **(c)**, with **(b)** as a cheap follow-on once (c) lands.

| Rank | Option | Verdict | Kill reason / cost |
|---|---|---|---|
| 1 | **(c) Consolidate on one digest-bound journaled call contract for ALL paths** (EpisodeModelCall semantics everywhere; EpisodeModelTransport as reference transport; retire RubyLLMModel or demote it behind the same interface) | **Recommended** | Cost: provider breadth narrows unless adapters are added — `Providers::ENV_KEYS` lists nine providers (`providers.rb:10-20`) while EpisodeModelTransport speaks OpenAI-compatible endpoints only (`episode_model_transport.rb:21-23`). ollama/openrouter cover most of that list; anthropic/gemini native need either an adapter or acceptance of gateway access. |
| 2 | **(b) Extract `tamoz-agent-ruby-llm` / `tamoz-model` below profile+CLI** (04-E revived) | Good follow-on, not the fix | The 2026-08-23 deferral blockers **still exist**: cli.rb:837-869 resolves ENV keys and constructs `RubyLLMModel` (`cli.rb:837,863`), and the evals adapter still fetches `ENV_KEYS` and constructs it (`openclaw_durable_cli_adapter.rb:906-907`); `ruby_llm ~> 1.16.0` is still on the agent gemspec (`tamoz-agent.gemspec:27`). Extraction alone leaves two transports and the unjournaled path untouched. After (c), extraction becomes trivial (one file moves). |
| 3 | **(a) Status quo** (kernel EffectDispatcher + SDK adapter, written law upheld) | Rejected | Preserves the actual defect: unjournaled CLI model calls (`runtime.rb:599-606`), weak receipts on the session worker, two transports drifting (`ruby_llm_model.rb` mutates `Encoding.default_external` globally at :31-32 — a process-wide side effect the digest-bound transport cannot have). |
| 4 | **(d) Owner's premise literalized** (graph-owned model seam/provider config) | Rejected | Destroys clause 11's load-time mechanism for zero behavioral gain (§5); contradicts the settled B3 direction that nodes call models through the ONE effect door, not that the engine grows one (`AUDIT_FINDINGS.md:28`). |

### What option (c) answers, and what it costs

Owner questions answered: "should all model calls be inside the graph gem?" — answered precisely:
calls should be inside **graph execution** under the journal contract, with transports outside the
engine; "do we have solid design for the graph gem?" — yes (§2), and it is exactly the right place
to enforce the contract. Costs: (i) losing native multi-provider breadth or writing thin adapters;
(ii) migrating `SessionEffects#model_call` receipts to digest-bound projections (a schema-visible
change — acceptable under the no-backwards-compatibility directive); (iii) rewriting or wrapping
`RubyLLMModel`'s usage/cost extraction and emitter events (`ruby_llm_model.rb:81-102`) onto the
transport's usage projection (`episode_model_call.rb:124-132`).

### Migration sketch (small, ordered, each step independently shippable)

1. **Close the unjournaled hole.** Wrap `Runtime#model_generate` (`runtime.rb:599-606`) in
   `EffectDispatcher.run` with a logical identity, mirroring `SessionEffects#model_call`. The
   one-shot runtime has an ephemeral journal available via its approval-engine-style memory stores;
   even an in-memory journal converts "invisible non-determinism" into recorded receipts.
2. **Codify the model-call node contract.** Write down what `episode_nodes.rb` already practices:
   a graph node that needs a model receives a journaled call object (constructed by the embedding,
   injected like `model_call_factory` at `bin/tamoz-stream-worker:110-123`); it never touches a
   transport. Add a conformance test: no node callable may reference a transport class; model
   events stay runner-emitted (B4, already enforced by the context emitter rejecting model event
   types — `episode_model_call.rb:26-28`).
3. **Upgrade the session path's receipts.** Change `SessionEffects#model_call` to build canonical
   request bytes and record `{request_digest, content, response_digest, usage}` like
   `EpisodeModelCall#perform_call` (`episode_model_call.rb:112-122`), keeping the operation name and
   logical identity scheme.
4. **Decide the transport question explicitly.** Either (i) accept OpenAI-compatible endpoints as
   the supported surface (ollama/openrouter/gateway cover nine-provider reality), retiring
   `RubyLLMModel`; or (ii) keep `RubyLLMModel` as a *provider adapter implementing the same call
   interface*, moved into `tamoz-agent-ruby-llm` per option (b), with digest receipts computed over
   the adapter's serialized request. Do both steps 1–3 before deciding — they shrink the question
   to pure packaging.
5. **Then extract (b)** if step 4 chose (ii): move the adapter + `Providers::ENV_KEYS` consumers'
   wiring in one slice, updating `cli.rb:863` and the evals adapters in the same change, per the
   2026-08-25 audit's own condition (`02-candidate-assessments.md:131-139`).
6. **Cleanup:** resolve the `after_effect_started` chain (§2.4) — delete it or give it an owner;
   correct the graph README dependency sentence; add the load-time/run-time wording to clause 11's
   documentation (§2.3).

### Risks

- **Provider regression risk** in step 4(i): any operator relying on native anthropic/gemini/mistral
  endpoints breaks; mitigate by shipping the gateway/adapter story in the same slice, not after.
- **Journal-size growth**: digest-bound receipts store more than `{output}` strings; bounded by the
  same attempt limits (`MAX_ATTEMPTS = 3`, `effect_dispatcher.rb:15`).
- **Scope creep into (d)**: steps 1–3 deliberately touch zero graph-gem files; if an implementation
  starts editing `tamoz-graph/lib` for this, it has left the plan.
- **Public API churn**: `Tamoz::Agent::RubyLLMModel` and `EffectDispatcher` are public-surface names
  (`test/public_api_test.rb:20,28`); removals must update the manifest in the same slice rather than
  deprecating forever (repo convention: no compatibility shims).

## 7. Engagement with prior settled decisions

- **04-E (`tamoz-model` extraction, Med-High)** — `agent-gem-decomposition-2026-08-23/04-non-obvious-moves.md:58-72,141`;
  deferral recorded at `08-remaining-work.md:82-84`. **Partially overturned with new evidence:** the
  deferral was justified by entangled composition (still true, verified at `cli.rb:837-869` and
  `openclaw_durable_cli_adapter.rb:906-907`), but the tree since gained a second, better transport
  making the SDK adapter's long-term role doubtful — sequencing now runs consolidation first,
  extraction second, which the original study did not anticipate.
- **2026-08-25 audit §"tamoz-agent-ruby-llm — technically clean, explicitly deferred"**
  (`02-candidate-assessments.md:106-139`). **Upheld** on mechanics (lazy require, sole ruby_llm
  consumer, gemspec still carrying the dep — reverified); its precondition "untangle composition
  first" becomes executable via the §6 sketch.
- **P1_PLAN reason-as-only-model-node + EpisodeModelCall** (`new-design/impl/P1_PLAN.md:64,73,89`)
  and **B3 "one effect door"** (`AUDIT_FINDINGS.md:28`). **Upheld and extended:** live in the
  episode worker (`bin/tamoz-stream-worker:102-129`), not yet binding on session/CLI paths; this
  review recommends making B3 the repo-wide model-call law (steps 1–3) rather than an episode-local
  property.
- **GRAPH_SURFACE_AUDIT** rows (`docs/GRAPH_SURFACE_AUDIT.md:10-38`): consistent with findings here
  — the graph's promoted surface is definition/runtime types, not any effect or model type, which is
  the correct shape under option (c).

## Self-check against the bar

1. **Citations**: every claim carries file:line from the current tree; ≥10 verifiable anchors
   appear in §1–§6 (spot-check suggestions: `executor.rb:143-162`, `execution_support.rb:65-77`,
   `dependency_isolation_test.rb:8-17`, `effect_dispatcher.rb:174-177`, `session_effects.rb:154-157`,
   `runtime.rb:599-606`, `bin/tamoz-stream-worker:119-129`, `episode_model_call.rb:112-122`,
   `tamoz-graph.gemspec:11-16`, `08-remaining-work.md:82-84`).
2. **Explicit verdicts**: dimension table implicit in §2 headings (coherence solid, seams solid,
   enforcement present-with-caveat, dead weight none/two splits) and ranked options table in §6.
3. **Prior decisions engaged by name**: §7 covers 04-E, the 2026-08-25 assessment, P1/B3, and the
   surface audit; one partial overturn justified by new evidence (second transport).
4. **Adversarial honesty**: §3 concedes the graph is already structurally capable of journaled model
   calls — the written law understates how cheap the owner's instinct is; §2.4 documents
   production-dead plumbing (`after_effect_started`) that superficially looks like a clause-11
   violation but isn't; §6 admits option (c)'s real cost is provider breadth, not engineering.
5. Ends with this section. Length ~230 lines, within 150–350.
