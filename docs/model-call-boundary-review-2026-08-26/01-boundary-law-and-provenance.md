# Lens A — Boundary law & provenance: why `RubyLLMModel` lives where it lives, and whether the written law is right

Review date 2026-08-26. Target: `gems/tamoz-agent/lib/tamoz/agent/ruby_llm_model.rb` (113 lines).
Read-only review; every current-tree claim cites file:line, every history claim a git SHA.

## 1. Provenance — the file's biography

**Birth (9919639, 2026-07-31, "activate reviewed read-only Tamoz agent").**
`RubyLLMModel` landed as a 75-line file in the same commit that created the whole read-only
agent slice: `cli.rb`, `plan.rb`, `runtime.rb`, `toolbox.rb` inside
`gems/tamoz-agent/lib/tamoz/agent/`. At birth it was **the only model path in the repository**,
and it owned everything: an inline `ENV_KEYS` hash (nine providers), key resolution from ENV
with the ollama exception, the lazy `require "ruby_llm"` in the constructor, and a bare
`chat.with_instructions(system).ask(prompt).content` call
(`git show 9919639:gems/tamoz-agent/lib/tamoz/agent/ruby_llm_model.rb`). The original
`cli.rb` built it directly at its own lines 31–34. There was no alternative transport,
no kernel gem, no profile gem.

**Growth by accretion, not relocation.** The file has never moved; five commits modified it
in place:

- ab8fa78 (2026-08-11) added the `Encoding.default_external = UTF_8` mutation with the
  C-locale comment — today's lines 28–32.
- 4d05300 + 0a4f365 (2026-08-12) added the emitter protocol
  (`generate(stage:, system:, prompt:, emitter:)`) and usage/cost extraction — today's
  lines 44–101, including events emitted with nil namespace/run_id/task_id (lines 72–76).
- 175485a (2026-08-24) deleted the inline `ENV_KEYS` hash and replaced it with the alias
  `ENV_KEYS = Providers::ENV_KEYS` (line 6). The commit message is explicit about why:
  profile.rb evaluated `RubyLLMModel::ENV_KEYS` **at class-body time**, an upward edge from
  tamoz-agent-profile to the runtime cluster; the fix moved the *data* down into the kernel
  (`gems/tamoz-agent-kernel/lib/tamoz/agent/providers.rb:9-20`), leaving the adapter
  reading downward like every other consumer.

**The second transport appears 16 days later (61375a6, 2026-08-15).**
`episode_model_transport.rb` was born — notably *inside tamoz-agent itself*
(`gems/tamoz-agent/lib/tamoz/agent/episode_model_transport.rb`, 120 lines in that commit) —
as a deliberate bypass: "RubyLLM does not expose raw wire bytes, so the episode path does
not use RubyLLMModel" (`gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_transport.rb:10-17`,
header written then, moved verbatim by d05c454). d05c454 (2026-08-23, P1-A kernel extraction)
relocated it to tamoz-agent-kernel, where it now sits *below* the adapter in the dependency
order.

**So the answer to "was it ever the only model path": yes** — for the first 16 days of the
repo's agent life, and never again after 2026-08-15. Its center of gravity has been draining
ever since: credential vocabulary went down to the kernel (175485a), the durable episode path
routes around it entirely (`bin/tamoz-stream-worker:119` constructs the kernel transport
directly), and what remains is an SDK-shaped convenience wrapper consumed by the
legacy/interactive paths. The file is not misplaced residue of an earlier design; it is the
surviving half of a split the codebase already made and never finished reconciling.

## 2. The written-law inventory — every rule governing where model calls may live

| # | Rule (quote, file:line) | Who it binds |
|---|---|---|
| L1 | "**Requiring core/graph loads no RubyLLM, HTTP client, provider, or adapter**" — `docs/design-v0.1/INVARIANTS.md:32` (clause 11, authoritative); summarized at `documentation/architecture/invariants.md:15` | The load surface of tamoz-core/tamoz-graph. A restriction on the *engine*, not an assignment of model code to any gem |
| L2 | "`tamoz-graph` never references RubyLLM, an HTTP client, a provider SDK, or an adapter — a clean process requiring `tamoz/graph` loads none of them and opens no socket." — `documentation/architecture/gems.md:114`; graph row "Never loads an LLM client (invariant 11)" at gems.md:87 | tamoz-graph source and dependencies |
| L3 | "**`tamoz-agent` is the only layer that knows RubyLLM** (`ruby_llm ~> 1.16.0`). It accepts a `RubyLLM::Agent`, `RubyLLM::Chat`, or a callable" — `documentation/architecture/gems.md:77` | Prose knowledge-claim about the whole stack; enforced in practice only via gemspec declarations |
| L4 | Gemspec declarations: `gems/tamoz-agent/tamoz-agent.gemspec` lists `["ruby_llm", "~> 1.16.0"]` among runtime deps; `gems/tamoz-graph/tamoz-graph.gemspec` declares only tamoz-cancellation, tamoz-concurrency, tamoz-core, zeitwerk | Installation truth: who may ship the SDK dependency |
| L5 | tamoz-agent row owns "capability and model wiring (`RubyLLMModel`)" — `documentation/architecture/gems.md:107`; layer ownership "recipes over the graph: the durable model↔tools loop, **RubyLLM binding**…" — `documentation/architecture/overview.md:131`; rationale ("testable offline… reusable for durable workflows that have nothing to do with language models") — `overview.md:105` | Documentation of intent; binds tamoz-agent as the binding home |
| L6 | README gem table: `tamoz-graph` row (README.md:23, deps `tamoz-core`), `tamoz-agent` row listing RubyLLM (README.md:43) | Public packaging statement |
| L7 | Public API: `"Tamoz::Agent::RubyLLMModel": {}` under tamoz-agent (`docs/public-api.json:35`); live `EffectDispatcher` under tamoz-agent-kernel (`docs/public-api.json:98`) plus a deprecated stale alias under tamoz-agent (`docs/public-api.json:13`); mirrored at `test/public_api_test.rb:28`, `:20`, `:77` and `documentation/reference/public-api.md:56`, `:48` | The class is committed public surface of exactly one gem |
| L8 | Requirement `API-tamoz-agent-Tamoz::Agent::RubyLLMModel` — release_blocking, named test `test/public_api_test.rb#test_documented_inventory_matches_loaded_public_surface` (`docs/requirements-manifest.json:935`; pass recorded at `docs/REQUIREMENTS_AUDIT.md:122`) | Release gate: moving or renaming the class is a manifest-visible event |
| L9 | Owner directive (AGENTS.md): non-deterministic calls route through the durable effect journal — "`EffectDispatcher.run` (see `SessionEffects#model_call`)"; key identity on request, never answer | **Every caller in every gem**, wherever the client class lives |
| L10 | "No mutable process-global runtime state: boot-time registries freeze after configuration; per-run state travels through `Context`" — `documentation/architecture/gems.md:117` | All gems, including adapters |

What no rule says: **nothing in the tree assigns model calls to the graph gem.** Clause 11
forbids the engine knowing models; L5 assigns the *binding* to tamoz-agent; L9 governs how
calls are journaled regardless of home. The owner's premise is tested against this inventory
in §4d.

## 3. Compliance verdicts

| Check | Verdict | Evidence |
|---|---|---|
| C1 file vs clause 11 / L2 | **Complies** | File lives above the engine; grep over `gems/tamoz-graph/lib` and `gems/tamoz-core/lib` finds zero `ruby_llm`/`Net::HTTP` references; clean-load is executable law: `test/dependency_isolation_test.rb:8-14` refutes ruby_llm, evals, sqlite, agent features after requiring `tamoz/graph`, and the graph suites (`test/graph_execution_test.rb:1-20` et al.) run provider-free |
| C2 gemspecs vs reality | **Complies** | Only tamoz-agent declares ruby_llm (L4); zero `RubyLLM::` constant references exist outside `gems/tamoz-agent` (grep across all gems) |
| C3 gems.md:77 "only layer that knows RubyLLM" | **Strains (prose defect, not code defect)** | Three sibling gems name the constant: `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:837` (`RubyLLMModel::ENV_KEYS[...]`) and `:863` (`RubyLLMModel.new(...)`); `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb:273`, `:906-907`; `environment_loader.rb:55`. But each declares tamoz-agent as a runtime dep (`gems/tamoz-agent-cli/tamoz-agent-cli.gemspec:14`; `gems/tamoz-evals-runner/tamoz-evals-runner.gemspec:25`), so the SDK monopoly holds under the only reading the dependency law can enforce |
| C4 public-API registration | **Complies** | Single-homed registration matches physical home (L7). Contrast the EffectDispatcher dual-listing — live in kernel (:98), deprecated ghost in agent (:13) — which is what real mis-registration looks like; RubyLLMModel has no ghost |
| C5 AGENTS.md effect-journal directive (L9) | **Complies at both transports** | Session path journals through `EffectDispatcher.run` wrapping `model.generate` (`gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:18-33`); episode path journals through the same dispatcher (`gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_call.rb:67-76`); memory consolidation too (`gems/tamoz-agent-memory/lib/tamoz/agent/memory/consolidation.rb:193-201`) |
| C6 ARCH-2 double key resolution (001-agent-cli-rb-audit.md:97) | **Strains — still open** | CLI resolves the ENV key itself (`cli.rb:837-839`), then the constructor re-resolves with its own fallback (`ruby_llm_model.rb:20-25`). Two layers own one policy; demand for a resolver seam exists in the wild (evals adapters reimplement lookup at :273, :906, environment_loader.rb:55) |
| C7 COUP-8 Encoding mutation (001-agent-cli-rb-audit.md:189) | **Violates the letter of gems.md:117** | Lines 31–32 mutate `Encoding.default_external` process-globally at construction time — mutable process-global state set mid-run, exactly what gems.md:117 forbids. Mitigation: the comment documents a real RubyLLM bug (bundled registry `File.read` fails under C locale), so it is a justified violation awaiting an upstream fix or explicit configuration — but COUP-8's remedy (explicit arg) stands |
| C8 nil-namespace model events (lines 72–76) | **Strains** | Events emit `namespace: nil, run_id: nil, task_id: nil`, so legacy-path model events carry no correlation identity while episode-path receipts are digest-bound. Not a boundary breach; flagged for the observability lens |

On C3, the distinction to get exactly right: the law binds *gem-level SDK knowledge*
(declaring ruby_llm, referencing `RubyLLM::*` constants), not awareness of Tamoz's own
public class. Sibling gems constructing a registered API class they legitimately depend on
is legal under every enforced rule; the gems.md:77 sentence overstates what is actually
enforced and should be rewritten as "the only gem that declares the ruby_llm SDK."

## 4. The strongest case against our current boundary law

**(a) Is clause 11 earning its keep?** Reverse gemspec dependencies of tamoz-graph are
exactly three: tamoz-sqlite (`gems/tamoz-sqlite/tamoz-sqlite.gemspec:13` — persistence
adapter for checkpoint/journal contracts, executes nothing), tamoz-agent
(`gems/tamoz-agent/tamoz-agent.gemspec:20`), and tamoz-evals-runner
(`gems/tamoz-evals-runner/tamoz-evals-runner.gemspec:37`). Actual workflow *executors* —
code that builds or runs graphs — are all agent-family:
`gems/tamoz-agent-session/lib/tamoz/agent/session.rb:440`,
`gems/tamoz-agent/lib/tamoz/agent/worker.rb`,
`gems/tamoz-agent/lib/tamoz/agent/episode_graph.rb`,
`gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_shared.rb`. No app (`apps/` contains only
tamoz-agent) and no bin entry runs a graph without models. So "reusable for durable
workflows that have nothing to do with language models" (`overview.md:105`) is **today
insurance, not usage** — speculative generality if sold as realized value.

But the insurance is absurdly cheap and its failure mode (L1's "vendor coupling and
offline-test failure") is real and already priced: one sentence of prose plus one executable
test that passes for free precisely because the law exists. By the repo's own
simple-solution directive, the simple solution here *is* clause 11; deleting it saves
nothing and would recouple the deepest, most stable layer to the most volatile one.
**Verdict: uphold clause 11; rewrite its sales pitch** — it guarantees a clean,
provider-free test substrate for the durability core, and any future non-LLM consumer is
upside, not justification.

**CORRECTION (2026-08-26 re-review): the adversarial find below was a false positive and is
retracted.** The original text claimed `tamoz-agent-session` calls `Tamoz.graph(...)`
(session.rb:440) yet does not declare `tamoz-graph` in its gemspec. It does:
`gems/tamoz-agent-session/tamoz-agent-session.gemspec:21` lists
`["tamoz-graph", "= #{...VERSION}"]`, and `gems/gemspec_helper.rb:56-57` turns every entry
of that `dependencies:` array into a real `spec.add_runtime_dependency`. The edge is declared;
there is no load-order-luck defect. The error came from grepping the gemspec for
`add_runtime_dependency`/`add_dependency` (which this repo's `TamozGemspec.build` helper hides)
and concluding "undeclared." This tracked as review defect **D1**, rated High and called the
review's one genuinely new finding; it is withdrawn. Lesson worth keeping: gemspec-declaration
claims in this repo must be checked against `gemspec_helper.rb`, not against raw
`add_*_dependency` greps.

**(b) Dual transport: principled or drift?** Principled at birth, drift-prone in operation.
The split was created deliberately with a written reason — exact wire bytes for digest-bound
witness/replay (`episode_model_transport.rb:10-22`) — and both transports honor the same
journaling discipline (C5), so this is two clients over one effect contract, not two
execution philosophies. But the law nowhere says which path is primary; credential policies
have diverged (Providers::ENV_KEYS + `{PROVIDER}_API_BASE` derivation versus
endpoint+api_key); response shapes differ (raw usage hash mapping versus
`ModelCall::Usage`); nothing reconciles them. The drift risk is concrete: RubyLLMModel
already grew a workaround (C7) that the frozen transport structurally cannot need, and each
new SDK concern widens the gap silently.

**(c) Is eager-requiring the file while lazy-requiring the SDK a half-measure?** No at the
file level, yes at the gemspec level. Requiring `ruby_llm_model.rb` eagerly (`agent.rb:14`)
is side-effect-free — the SDK require sits in the constructor (line 33) — so
`require "tamoz/agent"` loads the *class*, which it must: the class is registered public
surface (L7), and `WorkerRuntime::DeferredModel`
(`gems/tamoz-agent/lib/tamoz/agent/worker_runtime/deferred_model.rb:14`, used at
worker_runtime.rb:1007,1023) defers even *construction* until a profile resolves. That
chain — eager class, lazy SDK, deferred instance — is coherent boot discipline, not
indecision. The genuine half-measure is `tamoz-agent.gemspec` declaring
`ruby_llm ~> 1.16.0` unconditionally: every install of tamoz-agent pays for the SDK whether
or not any caller supplies a callable model, which is exactly the untruthfulness the
optional-gem split targets.

**(d) Was the owner's premise right?** **Wrong per the written law, right about the smell.**
Moving model calls *into* the graph gem would invert the single clause in the sixty-one that
is both conformance-tested (`dependency_isolation_test.rb:8-14`) and ADR-anchored
(`docs/design-v0.1/DECISIONS.md:47-48`: "`tamoz-graph` remains LLM-independent
(invariant 11)"), and would forfeit the offline durability-test substrate for zero
compensating gain — the effect journal already makes replay deterministic regardless of
which gem houses the HTTP client. But the instinct that *something* is architecturally wrong
is confirmed: the model seam is smeared across four gems — adapter in tamoz-agent, credential
vocabulary in kernel `Providers`, resolution policy in the CLI (`cli.rb:837-869`, ARCH-2),
consumers in evals-runner — with no single owner below profile/CLI. The premise fails because
it names the wrong destination; the discomfort is real because the current location is the
residue of a split nobody finished.

## 5. Prior settled decisions, engaged by name

- **04-non-obvious-moves.md §E + priority table :141 (extract `tamoz-model`, Med-High)** —
  **Upheld, strengthened.** New evidence since 2026-08-23: (i) the 175485a incident proves
  the adapter already functioned as a de-facto provider catalog strong enough to create a
  real upward layering inversion from tamoz-agent-profile. (The original second leg here — an
  "undeclared session→graph edge" — was retracted; see the §4a correction. The extraction case
  stands on the 175485a inversion alone, which is real.)
- **08-remaining-work.md:82 (deferral: "load-bearing in worker model_factory, evals
  benchmark adapter, Profile::KNOWN_PROVIDERS")** — **Recommend overturning the deferral.**
  Two of its three legs have since been cut: profile now reads `Providers::ENV_KEYS`
  downward (`gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:66`), and the worker takes
  a callable factory deferred behind `DeferredModel`, which never touches the class.
  Remaining consumers are finite and enumerated — cli.rb:837,863, three evals-runner sites,
  one public-API/manifest entry (L7/L8) — precisely the migration list audit-02 already
  wrote.
- **gem-boundary-audit-2026-08-25/02-candidate-assessments.md §"tamoz-agent-ruby-llm —
  technically clean, explicitly deferred" (~:106-147)** — **Upheld; its precondition is now
  partially satisfied.** "Untangle those composition paths first": profile untangled
  (175485a), worker untangled (DeferredModel). CLI/evals/public-API remain, and the doc's
  own rule — move consumers in the same slice, no compatibility alias — applies directly.
- **001-agent-cli-rb-audit.md ARCH-2 (:97) and COUP-8 (:189)** — **Both still open**
  (C6, C7). ARCH-2's fix — a resolver beside the model seam — lands naturally wherever the
  adapter ends up.
- **repo-quality-audit-2026-08-20/REPORT.md P1** — **Verified fixed**: consolidation routes
  through `EffectDispatcher.run` under a deterministic logical key
  (`consolidation.rb:193-201`), matching the AGENTS.md directive.

## 6. Verdict summary

**Recommend:** execute the twice-deferred extraction (04-E / audit-02) of the adapter into a
small gem below profile and CLI, moving consumers in the same slice; reword gems.md:77 to
bind SDK-declaration rather than "knowledge"; resolve ARCH-2 by giving the seam one credential
resolver; retire the C7 global mutation via explicit encoding configuration. **Reject:** relocating
model calls into tamoz-graph — it contradicts the tested core of the written contract and
buys nothing the effect journal doesn't already provide.

## Self-check against the bar

1. **Citations** — every factual claim carries file:line or SHA; ≥10 spot-checkable pairs
   listed in my report (target file lines, both gemspecs, both transport headers,
   session_effects, consolidation, dependency_isolation_test, session.rb:440,
   public-api.json entries, manifest entry).
2. **Explicit verdicts** — verdict table in §3 (complies ×4, strains ×3, violates ×1) plus
   recommend/reject in §6; no neutral description where a ruling was owed.
3. **Prior decisions engaged by name** — all five, each upheld/overturned with new evidence
   (§5); none silently ignored.
4. **Adversarial honesty** — the concession that clause 11's headline rationale is currently
   insurance rather than usage, argued against my own inclination to defend it (§4a). (A second
   adversarial finding — an undeclared session→graph gemspec dependency — was claimed here but
   proved false on re-review and is retracted in §4a; the retraction is left visible rather than
   deleted.)
5. **Format** — dense prose within the 150–350 line band, no restatement of the brief;
   house style followed (real files, seams, plain terms).
