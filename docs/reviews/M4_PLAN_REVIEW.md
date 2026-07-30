# M4 plan review — RubyLLM vertical slice

Review target: [M4_PLAN.md](../M4_PLAN.md)

Review status: conditionally accepted for implementation preparation; implementation is
blocked until RubyLLM releases the required public seam.

## Method

The review compared the plan against:

- M3 fencing, request, effect, codec, and fatal-error behavior;
- clauses 11, 25–27, 52–55 and the M4 roadmap exit criterion;
- RubyLLM 1.16.0 public source and documentation;
- RubyLLM 2.0 development documentation and public `main` source;
- crash boundaries before dispatch, during streaming, after receipt, and before graph
  checkpoint;
- hostile tool-call batches, shared mutable chats, callbacks, unknown fields, and budgets;
- the later M5a plan/review/action-policy boundary.

The review treats upstream documentation as capability evidence, not release evidence. A
method on development `main` cannot satisfy a released dependency gate.

## Findings resolved

| Severity | Finding | Five-Whys root | Resolution |
|---|---|---|---|
| Critical | Stable RubyLLM 1.16 cannot provide one public generation without owning the tool loop. | M4's design was written against a desired seam while `complete` still recursively executes tools. | Hard-gate implementation on a released version with public `ask_later`/`generate`; never reach into 1.16 private `complete_once`/provider APIs. |
| Critical | An arbitrary preconfigured Chat can contain callbacks that Tamoz cannot enumerate or reset publicly. | “Fresh chat” had been treated as proof of “no hidden behavior,” but callbacks are private mutable state. | M4 rejects instance injection, accepts only a documented trusted construction factory, exposes no runtime callback injection, and narrows the claim: transcript mutation is detected; arbitrary trusted-code side effects are not sandboxed. |
| Critical | The first tool could execute before a later call in the same model response failed validation. | Validation and execution were described in one per-call loop. | Split whole-batch preflight from execution; no effect starts until every id, shape, binding, schema, argument, limit, and effect key is resolved. |
| Critical | Calling RubyLLM `ask`/`complete`/`run_tools` would bypass graph barriers and the M3 journal. | RubyLLM's convenience loop and Tamoz's durable loop have different authorities. | Production source may call only the reviewed construction/message APIs and exactly one `generate`; negative source/API tests forbid the other loop verbs. |
| High | “Lossless reconstruction” overclaimed unknown extension fields that RubyLLM constructors may ignore. | Durable preservation and runtime object reconstruction were conflated. | Preserve unknown public `to_h` keys in the Tamoz durable record, compare all supported reconstructed fields, and do not claim ignored extensions exist on the RubyLLM object. |
| High | A model error after journal start was at risk of ordinary retry based only on exception class. | Network/provider exceptions do not prove whether work was accepted or billed. | Default model safety is reconcilable; only a reviewed proof of pre-dispatch rejection or provider idempotency/lookup permits retry. |
| High | Stream cancellation could have committed a partial assistant message. | UI progress and durable response had not been explicitly separated. | Chunks are bounded provisional observations; only the final returned Message may enter the receipt and graph update. Post-start cancellation is ambiguous without provider proof. |
| High | Tool schemas could be scraped from RubyLLM internals. | RubyLLM tools own schemas, but stable public access was not yet verified for the target release. | Require a public schema accessor or an explicit application schema verified against public rendered-request fixtures; no instance-variable access. |
| High | A model could request many calls and execute a valid prefix before the limit was noticed. | Per-call limit checking was insufficient. | Validate whole-response count/bytes/duplicate ids and every call before any dispatch. |
| High | RubyLLM runtime values could enter M3 receipts without a registered durable codec. | M3 StateCodec rejects arbitrary mutable classes by design. | M4 registers immutable Tamoz message/receipt values with explicit versions and uses those values in graph/effect state. |
| Medium | A shared mutable chat could leak transcript/tools across sessions. | Accepting instances optimized for ergonomics before proving ownership. | No instances in M4; factory freshness, empty transcript, distinct object identity, and single-session tests are mandatory. |
| Medium | Tool completion permutations were irrelevant while M4 execution is sequential. | A future parallel policy had leaked into the vertical slice. | Keep original-order assertions but do not claim M4 parallel execution; resource-safe parallelism remains M5a. |
| Medium | Provider raw responses and headers could leak through codec, errors, or telemetry. | RubyLLM exposes `raw` for diagnostics, but it is unsuitable durable state. | Exclude raw HTTP objects/headers; emit only bounded safe metadata and domain-separated digests. |

## Five Whys: why RubyLLM 1.16 is not sufficient

1. Why can Tamoz not call `Chat#complete`? It recursively executes every tool call and may
   issue more provider generations.
2. Why can callbacks not make that safe? They observe or wrap the hidden loop; they do not
   move ownership of tool dispatch and graph barriers to Tamoz.
3. Why not call private `complete_once`? Its name, behavior, provider coupling, and callback
   semantics are not a compatibility contract.
4. Why not temporarily remove tools? Then the provider does not receive the actual tool
   schemas and the result no longer represents the intended request.
5. Why wait for `generate`? Its documented contract is exactly one provider move, appending
   one response while leaving tool execution separate—the unit Tamoz can journal and place
   between durable graph barriers.

Therefore waiting is a correctness decision, not schedule conservatism.

## Five Whys: why model calls are effects

1. Why journal a model call if it does not mutate the user's filesystem? It consumes money,
   can create provider-side state, and returns nondeterministic output.
2. Why not simply retry a failed call? A network failure may occur after the provider
   accepted or completed it.
3. Why is request digest alone insufficient? Most providers do not guarantee lookup or
   idempotency by a client digest.
4. Why default to reconcilable? It prevents hidden duplicate billing/output while allowing
   a human or provider-specific reconciler to establish truth.
5. Why can some calls become idempotent? Only a tested provider contract that accepts the
   stable key and returns the same logical receipt justifies that stronger class.

## Conditional acceptance gate

The plan is accepted as the implementation contract when these preconditions are met:

1. RubyLLM publishes a release containing the documented public single-generation seam.
2. Its released API/reference confirms `generate` executes zero tools.
3. Behavioral compatibility tests against the release prove one request/one appended
   assistant response.
4. The public Tool invocation and schema surfaces needed by the demonstration tool are
   confirmed or the explicit-schema fallback is reviewed.
5. The exact dependency range and checksums are recorded.

Until then:

- do not add `ruby_llm` to the lockfile;
- do not implement an adapter against development `main`;
- do not start M5a;
- do not weaken M3 or the design to simulate the missing seam.

## Residual risks

- RubyLLM 2.0 may change before release. Re-run the API audit against the released gem.
- Provider-specific accepted/ambiguous classification is intentionally conservative and may
  require human resolution more often than an application prefers.
- Trusted factory code remains normal application Ruby code. M4 is not a code sandbox.
- M4 supports a deliberately narrow content/tool surface. Multimodal files, raw blocks,
  citations, structured output, and thinking must each earn codec and security support.
- Live-provider smoke evidence cannot prove crash correctness; recorded deterministic
  providers and process-kill tests remain authoritative.

No residual permits hidden RubyLLM tool execution or private API access.
