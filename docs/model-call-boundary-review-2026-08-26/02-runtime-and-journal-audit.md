# Runtime & journal audit — does every model call cross the effect journal, and is the "one door" real?

Lens B of the model-call boundary review (2026-08-26). Question under audit: the owner asked
how `gems/tamoz-agent/lib/tamoz/agent/ruby_llm_model.rb` "breaks our design boundaries" given
the AGENTS.md rule (AGENTS.md:41-46): *"Non-deterministic and external calls go through the
durable effect journal. A model or tool call is non-deterministic and a durable graph replays
its nodes. Never call one raw inside a node and let downstream state depend on the result —
route it through `EffectDispatcher.run` (see `SessionEffects#model_call`) so a replay returns
the recorded receipt, not a fresh, different answer. Key identity and dedup on the request,
never on the answer."*

**Verdict up front.** The house rule holds on every path that writes durable state. The only
raw model caller that feeds an agent answer is `Runtime` (runtime.rb:599-606), and it is the
one-shot/ephemeral runtime by construction — but that exemption is written down in three code
comments and one plan, and nowhere in the rule itself. Two real defects sit adjacent to the
boundary, not inside it: (1) the emitter machinery in `RubyLLMModel#generate`
(ruby_llm_model.rb:51-60) is dead on every production path, and its only strict consumer would
reject its events as forged; (2) provider failures on journaled calls are never completed into
the journal — they leave attempts `running`, so failure classification is deferred to the
stale-attempt sweep and depends entirely on the safety class. The owner's concern is best
answered by closing those two leaks plus naming the ephemeral exception, not by moving code.

---

## 1. Live-path map: which runtime executes each entry point

Three execution engines exist:

- **`Tamoz::Agent::Runtime`** (`gems/tamoz-agent/lib/tamoz/agent/runtime.rb`) — one-shot,
  in-process, no checkpointer. Routing values `:legacy | :shadow | :experimental`
  (runtime.rb:45-46); `dispatch_task` runs shadow as legacy-plus-route-probe (runtime.rb:70-72,
  163-170) and experimental as route-first with legacy fallback (runtime.rb:73-76).
- **`Tamoz::Agent::Session`** (`gems/tamoz-agent-session/lib/tamoz/agent/session.rb`) —
  "durable-only by construction" (session.rb:49-52); refuses a non-durable checkpointer at
  session.rb:99-103. Routing values `:legacy | :experimental | :adaptive`
  (session.rb:57) select graph versions (session.rb:58-62, 119). All model calls cross
  `SessionEffects#model_call` → `EffectDispatcher.run` (session_effects.rb:18-35).
- **The kernel episode graph** — `EpisodeNodes` + `EpisodeGraph`, run only by the stream worker
  launcher `bin/tamoz-stream-worker`, which composes `EpisodeModelCall` over
  `EpisodeModelTransport` (bin/tamoz-stream-worker, `model_call_factory:` block) and serves it
  behind a UDS/TCP worker server.

Edges per production entry point:

| Entry point | Engine | Edge citations |
|---|---|---|
| `bin/tamoz --root . "TASK"` quick start (README.md:83; exe at gems/tamoz-agent-cli/exe/tamoz:3-5) | **Runtime** (one-shot) | cli.rb:156-182 `run_one_shot` → `Tamoz::Agent.build(...)` cli.rb:171-178 → `Runtime.new` agent.rb:66 |
| Same, with `--experimental-routing` / `--shadow-routing` | Runtime, routing variant | one_shot_routing cli.rb:197-205; dispatch runtime.rb:69-82 |
| Session subcommands (`--session` ask/continue/resume/show, interactive) | **Session** over graph phases | cli.rb:159-163 delegates to `cmd_ask`; `run_durable` builds SQLite adapter + Session cli.rb:571-592; `build_durable_session` cli.rb:614-629 with `routing: durable_routing(options)` cli.rb:633-641 (`:adaptive`/`:experimental`/`:legacy`) |
| Worker foreground process (`tamoz worker`) | **Session** per thread/profile | cmd_worker cli_worker_commands.rb:275-300 (`session_builder: ->(thread_id) { runtime.session_for(thread_id) }`); `WorkerRuntime.open` cli_worker_commands.rb:650-668; sessions built at worker_runtime.rb:1006-1011 (metadata) and 1020-1037 (profile), both `Session.new` with `DeferredModel` |
| Deferred construction inside the worker | still RubyLLMModel underneath | `DeferredModel#generate(...)` forwards to the factory-built model (worker_runtime/deferred_model.rb:16-24); factory is `build_model` → `RubyLLMModel.new` (cli.rb:859-867) |
| Scheduler-driven work | Session (via request inbox) | scheduler delivery targets the request inbox — "delivery is not execution success" and the inbox "commits ONE logical turn" (occurrence.rb:12-19); the enqueued turn is executed by whichever process drives that runtime directory, i.e. the worker's Session |
| Comms / telegram inbound | Session (via request inbox) | comms CLI "NEVER constructs a Session, loads a model credential" (cli_comms_commands.rb:10); inbound turns are admitted and enqueued through `Gateway#admit_and_enqueue` → `@store.admit_and_enqueue` (gateway.rb:385-389), which enqueues into checkpoints (gateway.rb:699); the worker's Session consumes them |
| Stream episode worker (`bin/tamoz-stream-worker`) | **Kernel episode graph** | launcher builds `EpisodeNodes` with `model_call_factory` returning `EpisodeModelCall.new(transport: EpisodeModelTransport.new(...))`; `EpisodeGraph.build(checkpointer:, nodes:)`; served via `WorkerServer` |

Construction sites for `RubyLLMModel` itself: cli.rb:859-867 (`build_provider_model`, used by
both one-shot and every durable path), script/agent_latency_smoke:283-289,
openclaw_durable_cli_adapter.rb:904-908 (evals benchmark adapter).

## 2. Journal classification table

Replay semantics verified against the journal state machine, not comments: a record terminal
`succeeded` yields decision `:return` with `reused: true` (effect_preparation.rb:145-146;
effect_dispatcher.rb:91-95). An attempt left `running`/`prepared` past its fence/deadline is
classified by safety class at next prepare: `read_only`/`idempotent` → grant-next and **re-execute
fresh** (effect_preparation.rb:206-216); `transactional`/`reconcilable` → force reconcile
(:218-228); `unsafe` → force the attempt terminal `unknown` (:224-238).

| # | Call site | Runtime | Trigger | Wrapped-by | Journaled? | Logical-key basis | Replay behavior | Verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | Session stages `:route`, `:route_review` (session_routing.rb:18,134), `:verify` (session_lifecycle.rb:138), `:plan`, `:review` (session_plan_attempt.rb:51,158), `:context_compact` (session_planning_context.rb:73), `:adaptive_decide` (session_adaptive.rb:43) | Session | each graph-node deliberation step | `SessionEffects#model_call` → EffectDispatcher.run (session_effects.rb:18-35) | **Yes**, default safety `:idempotent` (session.rb:79) | structured logical identity: request_id+execution_id+operation+canonical arguments+authority/catalog revisions+iteration (session_effects.rb:24-31, 105-117) | succeeded receipt reused verbatim; crash-mid-call re-executed fresh (different answer possible) because `:idempotent` grants a new attempt (effect_preparation.rb:206-216) | **Compliant**, with the caveat in §4a |
| 2 | Memory consolidation `bounded_model_call` (consolidation.rb:194-210) | memory engine inside durable sessions | consolidation pass | EffectDispatcher.run, safety `:unsafe` | **Yes** | deterministic key `memory.consolidate:{owner}:{scopes_digest}:{candidate.digest}:{prompt_digest}` (consolidation.rb:216-220) | receipt reused across drives; crashed attempt stops-as-unknown, never blind-retried | **Compliant** — the P1 from docs/repo-quality-audit-2026-08-20/REPORT.md:42 ("Memory consolidation calls the model outside `EffectDispatcher`") is fixed in the current tree; the fix held |
| 3 | Episode reason call (episode_model_call.rb:48-83) | kernel episode graph | the single `reason` node | EffectDispatcher.run, safety `:unsafe`, operation `episode.model.reason` (episode_model_call.rb:67-83) | **Yes** | `ModelCall::LogicalCallKey(episode_id, stage, slot, request_digest)` — keyed on exact JCS wire bytes (episode_model_call.rb:49-53) | replay rebuilds the identical receipt from stored `{request_digest, content, response_digest, usage}` projection without calling the provider (episode_model_call.rb:107-122) | **Compliant**, strongest form |
| 4 | Situation-memory recall node (episode_nodes.rb:70-79) | kernel episode graph | recall before frame build | EffectDispatcher.run, safety `:unsafe` | **Yes** | deterministic recall logical key (episode_nodes.rb:69-79) | same stop-as-unknown discipline | **Compliant** (external call, not a provider call, but same door) |
| 5 | One-shot Runtime all stages — route probe (runtime.rb:204-219), plans/reviews via PlanReview, verify (runtime.rb:560-581) | Runtime | every step of `tamoz TASK` | observability span only: `@observability.around("tamoz.model.call", ...)` (runtime.rb:599-606) | **No** | none | n/a — process dies with the answer | **Sanctioned ephemeral exception** (§3.1); nothing durable depends on it |
| 6 | Evals harness decorator (memory_envelope.rb:63) | evals corpus runner | scripted-model turn | wraps inner scripted model; no journal | No | n/a | n/a — test evidence, never a real provider (AGENTS.md "Real model for real runs") | Compliant-by-scope: harness measures injection, not durability |
| 7 | Evals benchmark adapter `build_model` (openclaw_durable_cli_adapter.rb:904-908) | drives the real CLI | benchmark turn | the CLI's own Session journals the calls downstream | Yes (indirectly) | as row 1 | as row 1 | **Compliant** |
| 8 | Latency smoke probe (script/agent_latency_smoke:283-289) | standalone script | operator timing run | none — raw `.generate` | No | none | n/a | Operator-facing-only; no agent state exists to corrupt. Fine, but undocumented anywhere as exempt |
| 9 | Inspection dummy model (cli.rb:581-582, `generate(**) = "{}"`) | list/show commands | session listing | n/a — never calls a provider | No | n/a | n/a | Correct: keeps inspection working without credentials |

No sixth family exists: grepping the tree for `.generate(stage:` finds exactly the four
production/harness sites above plus the definition itself.

## 3. Violation hunt

### 3.1 The unjournaled one-shot path — sanctioned, and here is where it is (and isn't) written down

`Runtime#model_generate` wraps calls only in a telemetry span (runtime.rb:599-606). If this
runtime wrote durable state, every one of its calls would violate AGENTS.md:41-46. It does not:

- Its approval engine is explicitly in-memory: "The one-shot runtime is ephemeral: its grants
  live and die with this process" (agent.rb:62-65, engine built at agent.rb:72-83 over
  MemoryGrantStore/MemoryDecisionLog).
- Its tool executions carry telemetry-only effect keys spelled `"ephemeral:#{execution_id}:"`
  (step_execution.rb:261-271) — no journal is opened.
- `Session` refuses ephemeral checkpointers precisely to keep this split honest:
  "Ephemeral and read-only work stays on `Tamoz::Agent::Runtime`; PERSISTENCE_DESIGN §9 forbids
  using the in-memory adapter to claim crash durability" (session.rb:49-52, enforced at
  session.rb:99-103).
- P6_DURABLE_SESSION_RECOVERY_PLAN.md commits to leaving `Runtime` "byte-for-byte
  behaviour-compatible" as an explicit non-goal boundary.

So the classification is **ephemeral-by-design**, not a violation. What complicates the clean
narrative: the exemption lives in comments and plan documents, but the house rule in AGENTS.md
itself has no carved-out sentence, and nothing at the `RubyLLMModel` seam distinguishes an
ephemeral caller from a durable one. A future contributor who wires `RubyLLMModel` into any new
stateful component gets zero friction and zero signal. Also note shadow routing
(cli.rb:200-201) makes the one-shot path issue *extra* provider calls purely for telemetry —
acceptable ephemerally, but it means "the raw path" is also the least cost-controlled one.

### 3.2 The nil-namespace emitter events are dead code — and their only strict consumer rejects them

`RubyLLMModel#generate` emits `:model_started/:model_delta/:model_completed` with nil
namespace/run_id/task_id when passed an emitter (ruby_llm_model.rb:51-60, 72-76). **No
production caller passes one.** All four `.generate(stage:` sites omit the parameter
(session_effects.rb:32; runtime.rb:605; consolidation.rb:203; memory_envelope.rb:63). The only
adapter that could receive such events, the stream's `EpisodeStreamAdapter#emit`, raises a typed
error on exactly these types — "graph node attempted to emit forbidden model event"
(episode_stream.rb:184-194) — because the wire's model events must come solely from
journal-verified receipts (situation_request.rb:661-683 verifies each receipt against the
journal and refuses forged or missing providers before emitting). Consequences:

- These events can never reach a durable stream; they are at most process-local telemetry, and
  today they are nothing at all.
- The orchestrator's framing ("emits ... with NIL namespace — who consumes them?") resolves to:
  nobody, by design. The B4 invariant ("graph nodes never hold any wire channel",
  episode_model_call.rb:41-43 comment) is enforced *against* this exact emission path.

Verdict: hygiene defect, not a durability defect. The parameters and the two-line comment block
at ruby_llm_model.rb:72-76 advertise a channel that the architecture forbids. Delete them or
wire them deliberately; keeping dead machinery that a strict consumer treats as a forgery
attempt is the kind of thing that misleads the next auditor (it misled this review's premise).

### 3.3 Provider failures are never completed into the journal — ProtocolError mapping is the wrong fix surface

Two stacked facts, verified:

1. `RubyLLMModel#generate` rescues `StandardError` and converts **only** `RubyLLM::Error`
   subclasses into `ProtocolError` (ruby_llm_model.rb:62-67). In ruby_llm 1.16, HTTP-status
   failures do become `RubyLLM::Error` subclasses via `ErrorMiddleware`
   (ruby_llm/error_middleware.rb, `parse_error` raising `BadRequestError`,
   `RateLimitError`, `ServerError`, ...). But transport-level failures raised *before* any
   response — `Faraday::TimeoutError`, `Faraday::ConnectionFailed`, `Errno::ETIMEDOUT`,
   `Timeout::Error` (ruby_llm connection.rb retry_exceptions list, connection.rb:133-142) — are
   Faraday/stdlib classes, not `RubyLLM::Error`, so they escape `generate` **raw**.
2. Inside `EffectDispatcher#execute_outcome`, only `Tamoz::Tools::ToolError` (→ terminal
   `:failed`) and `Tamoz::EffectUnknownError` (→ terminal `:unknown`) are completed exceptionally
   (effect_dispatcher.rb:183-203). `ProtocolError` is `Tamoz::Core::ProtocolError < Tamoz::Error`
   (protocol_error.rb:12; aliased at errors.rb:14) — **not** a ToolError — so neither it nor any
   raw Faraday error completes the attempt. The attempt stays `running`.

Net effect on journaled paths (rows 1-3): a failed provider call leaves a running attempt whose
fate is decided later by the stale-attempt sweep, purely by safety class — fresh re-execution
under the session default `:idempotent` (effect_preparation.rb:206-216), terminal unknown under
`:unsafe` (effect_preparation.rb:224-238). Callers do catch `ProtocolError` after the fact and
degrade gracefully (session_routing.rb:35,165; session_adaptive.rb:75; episode_nodes.rb:371
repairs malformed-after-success exactly once), so behavior is safe; what is missing is the
*typed terminal journal record* the tool path gets for free. Severity: **real but latent** —
durability-relevant bookkeeping gap, not an answer-corruption hazard. It also means the
`ProtocolError` rescue in ruby_llm_model.rb is doing less work than it appears: half the failure
universe bypasses it.

### 3.4 Minor boundary smells (no severity)

- ENV-key fallback duplicated between the CLI (cli.rb:834-841) and the model class
  (ruby_llm_model.rb:20-25); two places to update when provider key names change.
- `Encoding.default_external` mutated process-wide at construction (ruby_llm_model.rb:31-32) —
  justified by the UTF-8 registry-read failure, but it is a global side effect hiding in a
  constructor.
- OBSERVABILITY_PLAN.md:147 already flags the discarded `RubyLLM::Message`
  (".ask(prompt).content") as the reason usage needs a protocol change; usage extraction at
  ruby_llm_model.rb:81-102 works off the response object but `generate` still returns bare text,
  so the journal stores `{output}` with no usage (session_effects.rb:32).

## 4. The strongest case against the one-door contract

**(a) Replay-same-text is right for temperature-0 JSON, overstated for everything else.**
The contract sentence promises "a replay returns the recorded receipt, not a fresh, different
answer." That is exactly true for the episode transport, which freezes
`temperature 0, stream false, response_format json_object` (episode_model_transport.rb:27-31)
and keys identity on the exact request bytes. For the Session path it is only true for records
that reached `succeeded`. Under the default `model_call_safety: :idempotent` (the allowed values
are `%i[idempotent unsafe]`, session.rb:56; default at session.rb:79), a crash mid-call
re-executes a *fresh* generation on recovery (effect_preparation.rb:206-216) — the recovery
answer can differ from the one nobody received. That is arguably correct design (there is no
receipt worth preserving for an unanswered call), but it means even the flagship journaled path
does not literally deliver the AGENTS.md promise; it delivers "no duplicate spend for answered
calls, no silent divergence for answered ones." The honest statement of the contract is:
*terminal receipts are immutable; unanswered calls are resolved by the safety class.*
`model_call_safety` exists precisely as that dial (P6_DURABLE_SESSION_RECOVERY_PLAN.md:68, row
12), yet nothing helps an operator choose per stage — it is one blanket constructor value.

**(b) What the journal buys for model calls vs plain observability receipts.** Three concrete
things an observability span cannot buy: (i) dedup — the request-keyed logical identity
(session_effects.rb:105-117) collapses retried deliveries into one provider spend, which the
comms/scheduler paths rely on since delivery repeats by design (occurrence.rb:12-19);
(ii) typed ambiguity — `:unsafe` calls stop-as-unknown instead of guessing
(effect_preparation.rb:224-238; surfaced as `provider_ambiguity` per the P6 plan);
(iii) verifiable streams — the wire layer refuses model events whose digests do not match the
journal (situation_request.rb:673-687), which is only possible because receipts live in the
same store as everything else. Against that: journaling creative output costs storage and
freezes answers that a human might prefer regenerated. On balance the door earns its keep —
but mostly for rows 2-3, where keys are deterministic and outputs are contracts, and least for
row 1's free-form stages.

**(c) Two transports: deliberate, written down, and still a standing divergence risk.** This is
not an accident. The episode transport's header states the reason: the episode path needs the
exact wire bytes so endpoint-side digests equal receipt digests, and "RubyLLM does not expose
raw wire bytes, so the episode path does not use RubyLLMModel"
(episode_model_transport.rb:10-22); P6_DURABLE_SESSION_RECOVERY_PLAN.md:31 pins the other side:
"No private RubyLLM API. The provider seam stays `Tamoz::Agent::RubyLLMModel#generate`."
OBSERVABILITY_PLAN.md:147 independently records RubyLLM discarding the message object. So: sound
engineering, documented at both seams. The residual risk is behavioral divergence the docs do
not manage: ruby_llm internally retries a whole class of exceptions (connection.rb:133-142) while
`EpisodeModelTransport` is single-shot net/http with a 120 s timeout and no retries
(episode_model_transport.rb:37-38, 84-90); error taxonomies differ (`ProtocolError` wrapping vs
raw transport errors, §3.3); and usage/cost extraction differs (ruby_llm_model.rb:81-102 vs the
transport's envelope digest). Nothing tests that the two transports agree on anything observable.
That is the actual price of two doors, and it should be named in a test or a doc line.

**(d) Verdict for the owner.** "How is it breaking our design boundaries?" — it isn't, structur-
ally. `RubyLLMModel` sits in tamoz-agent, the graph gem stays provider-blind (its effect
vocabulary at gems/tamoz-graph/lib/tamoz/graph/effect_record.rb:4+ defines
EffectAttempt/EffectRecord with zero provider knowledge), and every durable consumer reaches the
model through the one dispatcher. Note the door itself: `EffectDispatcher` is defined in
tamoz-agent-kernel but namespaced `Tamoz::Agent::EffectDispatcher` (effect_dispatcher.rb:11);
session/memory/episode code reach it unqualified because they share the namespace and depend on
tamoz-agent-kernel (tamoz-agent-session.gemspec dependency list). Contrary to the review brief's
grounding note, **no `deprecated: true` marker on EffectDispatcher exists anywhere in gems
code** (grep over gems/*/lib found none); there is no `Tamoz::Agent::Kernel` facade module beyond
a version namespace (kernel/version.rb:5). The migration story is carried by file location and
gemspecs alone — worth fixing if the move is meant to be communicated. Close these four leaks
instead of moving code: delete-or-wire the dead emitter events (§3.2); give model effects typed
failure completion like tools have, or accept and document the deferred-classification behavior
(§3.3); make the ephemeral exemption explicit in the AGENTS.md rule text (§3.1); pin the
two-transport divergence with one parity test (§4c).

## Self-check against the bar

1. **Citations:** every claim carries file:line from the current tree; the classification
   table's verdict column rests on runtime.rb:599-606, session_effects.rb:18-35,
   consolidation.rb:194-220, episode_model_call.rb:48-83, episode_nodes.rb:70-79,
   memory_envelope.rb:63, openclaw_durable_cli_adapter.rb:904-908,
   script/agent_latency_smoke:283-289, cli.rb:581-582.
2. **Explicit verdicts:** per-row verdicts in §2; graded severities in §3; a direct answer in
   §4d.
3. **Named engagement:** AGENTS.md:41-46 quoted; repo-quality-audit REPORT.md:42 P1 verified
   fixed; P6_DURABLE_SESSION_RECOVERY_PLAN.md:31 and :68 quoted; OBSERVABILITY_PLAN.md:147 used.
4. **Adversarial honesty:** findings that complicate the expected narrative — the emitter events
   assumed live are dead and forbidden (§3.2); the journaled path's own default does not deliver
   the literal replay promise (§4a); the `deprecated:true` grounding fact is wrong (§4d); the
   sanctioned status of the one-shot path rests on comments/plans, not on the rule itself (§3.1).
5. **Density:** ~200 lines within the 150-350 window.
