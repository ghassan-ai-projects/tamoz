# M4 plan — RubyLLM vertical slice

Status: conditionally accepted; implementation blocked on released upstream seam

Depends on: reviewed M3 commit `ae27b96`

Milestone outcome: one durable, single-generation RubyLLM graph with one governed
read-only/idempotent tool, using public upstream APIs only.

M4 proves the provider boundary before Tamoz Agent adds planning, approval, compaction, or
general tool policy. It is deliberately a vertical slice, not a partial hidden agent.

## 1. Entry gate: the upstream seam

Tamoz must control the model/tool loop one durable move at a time. The required upstream
contract is:

```ruby
chat.ask_later(user_message)
assistant = chat.generate { |chunk| ... } # exactly one provider generation
chat.run_tools                              # never called by Tamoz
chat.step                                  # never called by Tamoz
chat.complete                              # never called by Tamoz
```

The public contract must state that `generate` appends one assistant response but does not
execute requested tools. Tamoz invokes tools itself, persists their receipts, appends
tool-result messages, and schedules the next generation through its graph.

As of the M4 planning review:

- released RubyLLM 1.16.0 exposes `Chat#complete`, whose implementation recursively executes
  tool calls; it has no public one-generation method;
- RubyLLM 2.0 development documentation and public `main` source expose `ask_later`,
  `generate`, `run_tools`, `step`, and `complete` as separate public verbs.

Sources:

- [RubyLLM 1.16.0 `Chat`](https://github.com/crmne/ruby_llm/blob/1.16.0/lib/ruby_llm/chat.rb)
- [RubyLLM 2.0 development agentic workflow](https://rubyllm.com/next/agentic-workflows/)
- [RubyLLM current `Chat` source](https://github.com/crmne/ruby_llm/blob/main/lib/ruby_llm/chat.rb)

Implementation does not start against an unreleased commit. It starts when a released
RubyLLM version provides the seam and passes a source-independent compatibility contract.
The dependency will then be constrained to the smallest compatible released minor range.
Tamoz does not use `send`, `instance_variable_get`, `prepend`, monkey patches, provider
classes, protocol renderers, or RubyLLM private methods.

If the released seam changes materially, revise and review this plan. Do not emulate it over
1.16 by temporarily removing tools, intercepting callbacks, or calling provider internals:
those approaches cannot prove that hidden tool execution, message mutation, or recursive
generation did not occur.

## 2. Outcome and non-goals

M4 delivers:

- a direct `ruby_llm` dependency owned only by `tamoz-agent`;
- a versioned compatibility protocol checked at load/compile time;
- a lossless durable envelope for the supported public RubyLLM message/tool-call surface;
- one model-generation node that reconstructs a fresh chat and calls `generate` once;
- one tool-execution node that invokes only Tamoz-registered RubyLLM tools;
- model and tool operations routed through the M3 effect journal;
- deterministic tool-result ordering;
- bounded provisional model streaming;
- recorded-provider and fake-tool conformance with network denied;
- one opt-in live smoke profile, excluded from default CI;
- public M4 evaluation cases and clean-revision evidence.

M4 does not deliver:

- `Tamoz::Agent.react`;
- plan/review/replan/verification policy;
- approvals, filesystem/shell tools, general resource locks, or arbitrary user tools;
- model routing, fallbacks, compaction, subagents, memory, MCP, scheduling, or skills;
- Rails persistence or RubyLLM `acts_as_*`;
- provider-managed files, remote attachments, raw provider blocks, structured output, or
  extended-thinking configuration;
- semantic claims about model quality;
- exactly-once provider billing or exactly-once external effects.

Those exclusions keep M4 capable of proving the seam rather than hiding M5a policy inside an
adapter.

## 3. Package and dependency boundary

Only `tamoz-agent` depends on RubyLLM:

```text
tamoz-core   ─┐
tamoz-graph  ├─ no RubyLLM, Faraday, provider SDK, HTTP, or agent dependency
tamoz-sqlite ┘

tamoz-agent → tamoz-graph
            → ruby_llm (reviewed released range)
```

Requiring `tamoz/core`, `tamoz/graph`, or `tamoz/sqlite` in a clean process must still leave
RubyLLM, Faraday, Net::HTTP, and provider SDK features unloaded. Requiring `tamoz/agent`
loads RubyLLM but does not configure credentials, refresh a model registry, start a network
request, or mutate global RubyLLM configuration.

`tamoz-agent` supports plain RubyLLM chats and agents. Rails-backed agent/chat records are
rejected in M4 because they introduce a second persistence authority. A factory is the
production contract:

```ruby
factory.call(session) # => a new RubyLLM::Chat or RubyLLM::Agent
```

M4 accepts only a dedicated construction factory owned by trusted application code. It does
not accept a pre-existing Chat/Agent instance. A class may be normalized into that factory
only when the selected RubyLLM release documents that construction returns a fresh plain
chat. Every result must expose the reviewed public protocol and be new, empty, and unshared.

RubyLLM does not expose callback enumeration/reset as a public contract. Tamoz therefore
cannot prove that an arbitrary preconfigured chat has no callbacks. M4 documents the
factory as a trusted configuration boundary and rejects instance injection; M5a must not
treat application callbacks as authorized task actions. The transcript invariant detects
message mutation, but Tamoz does not claim it can detect arbitrary side effects performed
inside trusted factory code or RubyLLM callbacks.

## 4. Public M4 surface

The intended alpha surface is narrow:

```ruby
adapter = Tamoz::Agent::RubyLLMAdapter.new(
  llm: ->(session) { MyAgent.new(inputs: session.inputs) },
  tools: [
    Tamoz::Agent::ToolBinding.new(
      tool: LookupDocumentation,
      operation: "docs.lookup",
      safety: :read_only,
      timeout: 10
    )
  ],
  limits: Tamoz::Agent::ModelLimits.new(...)
)

app = Tamoz::Agent.vertical_slice(
  adapter:,
  checkpointer: sqlite
)

result = app.durable_runner.deliver(
  {"message" => "Find the documented answer"},
  thread: "session-1",
  request_id: "input-1"
)
```

Names remain alpha until M4 API review. `vertical_slice` intentionally signals that this is
not the final `react` recipe.

The adapter itself provides only:

```ruby
materialize(session:, messages:)
generate(session:, messages:, task:, context:)
execute_tools(session:, assistant:, task:, context:)
```

The graph recipe, not the adapter, owns looping and durable state transitions.

## 5. Durable values

M4 adds immutable values:

```ruby
RubyLLMMessage = Data.define(
  :format_version,
  :role,
  :content,
  :model_id,
  :tool_calls,
  :tool_call_id,
  :tokens,
  :thinking,
  :citations,
  :extensions
)

RubyLLMToolCall = Data.define(
  :id,
  :name,
  :arguments,
  :provider_metadata,
  :extensions
)

ModelReceipt = Data.define(
  :request_digest,
  :provider,
  :model_id,
  :message,
  :usage,
  :finish_reason,
  :stream_digest,
  :accepted_at_ms,
  :completed_at_ms
)

ToolReceipt = Data.define(
  :tool_call_id,
  :tool_name,
  :argument_digest,
  :effect_key,
  :status,
  :content,
  :error
)
```

Values are framework records, not replacements for RubyLLM runtime objects. The adapter
reconstructs public `RubyLLM::Message` values when materializing a chat.

### 5.1 Codec envelope

The codec is canonical JSON with fixed array envelopes:

```text
["tamoz.ruby_llm.message", 1, ruby_llm_version, public_attributes, extensions]
["tamoz.ruby_llm.tool_call", 1, public_attributes, extensions]
```

The codec:

- bounds total bytes, depth, messages, tool calls, argument size, content size, citations,
  extension keys, and token counters;
- accepts only fixed roles (`system`, `user`, `assistant`, `tool`) and never interns
  unvalidated persisted text;
- preserves tool-call ids and original call order exactly;
- preserves every key returned by the reviewed public `to_h` contract, including unknown
  keys, in the durable envelope;
- constructs runtime messages using only constructor/public conversion APIs;
- re-encodes and compares every supported reconstructed field; opaque extension fields stay
  in the durable record and are not falsely attributed to a RubyLLM object that ignored
  them;
- excludes `raw` HTTP responses, connections, callbacks, Procs, IO objects, credentials,
  and RubyLLM context objects;
- rejects unsupported `Content`, attachment, citation, thinking, or tool-call shapes rather
  than flattening them to strings;
- never calls `Marshal`, YAML object loading, JSON additions, or arbitrary constant lookup;
- has explicit forward migrations and rejects future versions.

“Lossless” means lossless for the declared supported public surface. M4 does not claim that
an arbitrary provider-native raw payload is portable or safe to checkpoint.

Golden fixtures are generated from the supported RubyLLM release, then reviewed and pinned.
Fixtures cover text, nil assistant content with tool calls, multiple ordered calls, tool
results, every token counter, UTF-8, structured Hash/Array tool results, unknown public
`to_h` keys, and rejection of unsupported attachments/raw objects.

## 6. Deterministic graph state

The vertical slice uses:

| State | Reducer | Contract |
|---|---|---|
| `messages` | append | durable `RubyLLMMessage` events in conversation order |
| `model_receipts` | append/id by generation key | one receipt per logical model move |
| `tool_receipts` | append/id by effect key | one receipt per logical tool call |
| `generation_index` | max | stable next model-call index |
| `remaining_model_calls` | managed | bounded provider budget |
| `remaining_tool_calls` | managed | bounded tool budget |
| `terminal_reason` | one write | completed, budget, unknown, or failure |

Graph:

```text
START
  → stage_user
  → generate
      ├─ final response → END
      └─ tool calls → execute_tools → generate
```

`stage_user` validates and encodes the caller message without I/O. `generate` performs
exactly one provider call. `execute_tools` performs the assistant response's exact ordered
call batch. Both nodes return updates only; the M2 barrier remains the sole graph-state
commit point.

No chat object enters graph state. Every generation creates a fresh chat from the trusted
factory, checks it is empty/unshared, replaces the tool registry through public methods,
installs only registered tool schemas, reconstructs the durable transcript, calls
`generate` once, captures the returned message, and discards the chat.

The graph compares the materialized chat transcript before and after generation:

- before: exactly the durable messages;
- after: exactly the durable messages plus one assistant message;
- any hidden tool result, extra generation, callback mutation, or reordered message is a
  fatal compatibility error.

## 7. Identity and model request digest

A logical model move is identified by:

```text
thread
namespace
execution_id
stable task_id
generation_index
adapter protocol version
resolved provider/model
canonical request digest
```

The request digest covers:

- ordered durable messages;
- ordered tool definitions and normalized schemas;
- model/provider identity;
- supported generation parameters;
- cache epoch (fixed to `m4` in this milestone);
- RubyLLM adapter protocol and codec versions.

It excludes attempt id, lease fence, wall time, stream chunk boundaries, callback identity,
and secret credentials.

Changing any semantic input creates a new request digest and cannot reuse a receipt.

## 8. Model call effect semantics

Model calls use the M3 effect journal. Preparation occurs after chat materialization and
request digest calculation but before provider I/O. `start` occurs immediately before
`chat.generate`.

Safety is explicit:

- `:idempotent` only when the selected provider path accepts a stable idempotency key and
  the adapter has a tested result-lookup/replay contract;
- otherwise `:reconcilable`, the M4 default.

M4 does not infer safety from provider name. A provider request id returned after completion
is recorded as `external_id` but does not retroactively make dispatch idempotent.

Outcomes:

| Boundary | Durable result |
|---|---|
| failure before journal start | no dispatch; normal retry may prepare |
| explicit provider rejection proving no accepted work | failed receipt; retry by policy |
| full response and receipt commit | succeeded; replay returns receipt |
| process loss after start and before receipt | `reconcile`; no automatic new provider call |
| stream begins then errors/cancels | ambiguous/reconcile unless provider proves cancellation |
| malformed response | failed receipt plus fatal compatibility error; never model-visible raw data |

RubyLLM error class alone is not proof that the provider did not accept a request. The
adapter maintains a small, reviewed classifier of only provable pre-dispatch/local failures.
Everything else after `start` is ambiguous.

Human resolution is available through the M3 journal. Automated provider reconciliation is
out of M4 unless the provider exposes a public lookup by stable request identity.

## 9. Tool boundary

M4 supports one or more instances only of one reviewed demonstration tool class, exercised
in two declared modes:

- `read_only`: deterministic lookup from immutable injected data;
- `idempotent`: write to a fake target that enforces the Tamoz effect key.

The released example uses `read_only`. The idempotent fake exists to prove crash semantics.
No filesystem, subprocess, shell, network, database, credential, or arbitrary application
tool is accepted in M4.

`ToolBinding` freezes:

- canonical explicit tool name;
- RubyLLM tool instance/class identity;
- canonical public JSON schema digest;
- operation name and safety;
- timeout and output limits;
- M4 fixed resource descriptor.

The tool schema is obtained through a reviewed public RubyLLM method. If RubyLLM does not
publish a stable schema accessor in the selected release, M4 accepts an explicit
application-supplied schema and verifies it matches the provider-rendered request fixture.
It never scrapes instance variables.

The node first preflights the entire assistant tool-call batch:

1. validate every id/name/argument and total batch bounds;
2. reject duplicate ids and unsupported shapes for the whole batch;
3. look up each exact registered binding; unknown tools become precomputed bounded typed
   tool errors without application dispatch;
4. canonicalize and validate all arguments against public schemas;
5. compute every stable effect key from task id and original call index.

Only after complete preflight does it process calls in original order:

6. materialize a precomputed unknown-tool error, or prepare/start through the journal;
7. call the public RubyLLM tool invocation API with normalized arguments;
8. bound/encode result;
9. commit exact receipt;
10. create one durable tool-result message bound to the original call id.

Validation and unknown-tool errors do not dispatch an effect. Exceptions are sanitized.
Only declared recoverable errors become tool-result content. Storage, lease, codec,
configuration, policy, and effect-unknown failures remain fatal or pause the workflow; they
never become model text.

Results are appended in the assistant's original tool-call order regardless of execution
completion order. M4 executes sequentially. Parallel resource scheduling belongs to M5a.

Tamoz never calls `chat.run_tools`, `chat.step`, `chat.complete`, or `chat.ask`.

## 10. Streaming

M4 model streaming is observational:

- `chat.generate` receives a block;
- chunks are converted to bounded Tamoz `StreamPart` values;
- the existing bounded sink applies backpressure and cancellation;
- chunk order is provider arrival order and never determines durable state;
- the accumulated final RubyLLM message is the only durable assistant message;
- a domain-separated digest of emitted normalized chunks is recorded for diagnostics;
- content is not logged by default.

Tool-call arguments may arrive in partial chunks. Tamoz does not execute them until the
final assistant message has passed codec and bound checks.

If a consumer stops reading, Tamoz requests cooperative cancellation. Unless RubyLLM and the
provider prove the request was cancelled before acceptance, the model effect remains
ambiguous. No partial assistant message is committed.

## 11. Limits

`ModelLimits` is immutable and validates bounded:

- messages per request;
- message, transcript, and attachment bytes (attachments remain zero in M4);
- tool definitions and calls per response;
- argument and tool-result bytes;
- model calls and tool calls per durable request;
- input/output/total reported tokens;
- estimated cost and provider calls;
- model and tool wall time;
- stream chunks and bytes;
- codec depth/items/extensions;
- error and metadata bytes.

Every loop decrements durable budgets before scheduling the effect. Provider-reported usage
is recorded after receipt. Missing usage is marked unknown/estimated, not zero. Exceeding a
post-call budget prevents another generation and produces a bounded terminal result.

Timeouts use the caller's monotonic deadline intersected with the M4 limit. A timeout never
changes an ambiguous started effect into an ordinary retryable error.

## 12. Failure and security model

Threats:

| Threat | Response |
|---|---|
| prompt asks for unavailable tool | exact registry lookup; bounded tool error |
| forged/duplicate tool-call id | codec rejects before effect preparation |
| RubyLLM silently runs tool | before/after transcript invariant fails fatally |
| RubyLLM recursively generates | transcript delta exceeds one assistant message; fail |
| changed model/tool schema on resume | request/definition digest incompatibility |
| chat reused across sessions | factory freshness fingerprint and single-owner guard |
| callback mutates messages | transcript invariant and digest fail |
| provider response contains secret/raw HTTP object | raw excluded; public projection only |
| streamed partial arguments | never executed before final message |
| error leaks provider body | safe category/message only |
| repeated ambiguous model call | journal stops at reconcile |
| repeated idempotent tool | same effect key and target idempotency key |
| tool returns huge/cyclic/secret object | bounded codec fails before model-visible message |
| model returns excessive calls | whole response rejected; no prefix execution |
| cancellation after dispatch | effect ambiguity retained; no graph commit |

The adapter accepts no runtime callback injection in M4. Trusted application factories may
configure instructions and model selection. Tamoz uses public methods to disable RubyLLM
tool concurrency and replace the tool registry with exact reviewed bindings. A factory
result that is nonempty, reused, Rails-backed, or cannot be normalized through public
methods is rejected. Factory construction itself remains trusted application code, not a
sandbox.

## 13. Observability

Tamoz emits metadata-only events:

```text
tamoz.agent.model.prepare
tamoz.agent.model.start
tamoz.agent.model.finish
tamoz.agent.model.ambiguous
tamoz.agent.tool.prepare
tamoz.agent.tool.finish
tamoz.agent.compatibility.failure
```

Payloads include run/request/execution/task identity, effect key, provider/model, tool name,
argument/result digests, counts, durations, usage, and safe status. They exclude message
content, arguments, results, instructions, raw responses, headers, credentials, and full
errors unless an application explicitly installs a protected content recorder.

RubyLLM instrumentation is not the durability boundary. Tamoz may subscribe for diagnostic
correlation, but journal state and graph checkpoints remain authoritative.

## 14. Implementation slices

1. **Dependency gate**
   - released RubyLLM range and checksums;
   - public-protocol compatibility test;
   - clean-process dependency isolation.
2. **Durable codec**
   - StateCodec registrations for all M4 durable values;
   - canonical envelope, limits, golden fixtures, corrupt/future rejection;
   - exact reconstruction tests across the supported RubyLLM range.
3. **Adapter/materializer**
   - factory normalization and freshness;
   - message/tool installation through public APIs;
   - before/after transcript invariant.
4. **Single generation**
   - request digest and model effect wrapper;
   - exactly one `generate`, bounded stream, usage/receipt mapping.
5. **Tool batch**
   - binding/validation, read-only and idempotent fake tools;
   - sequential ordered effect execution and result message construction.
6. **Durable graph**
   - stage/generate/tool route;
   - budgets, resume, unknown/reconcile, MemoryCheckpointer equivalence.
7. **Adversarial evidence**
   - recorded provider, process kills, compatibility matrix, policy attacks, public evals.

Every slice keeps M0–M3 green. M4 implementation is committed only after its deep review
and clean-revision evidence. M5a planning does not begin before that commit.

## 15. Test and evaluation matrix

### 15.1 Upstream compatibility

For every supported RubyLLM minor:

- public methods exist and are public;
- `ask_later` makes no provider call;
- `generate` makes exactly one provider call and zero tool calls;
- `generate` appends exactly one assistant message;
- tool calls and ids survive reconstruction;
- `run_tools` exists only as a negative control and is never referenced by Tamoz production
  source;
- Agent delegates or yields a Chat through documented APIs;
- supported `Message#to_h`, token, thinking, citation, and tool-call fixtures round trip;
- unsupported public shape fails with an actionable compatibility error.

Tests exercise behavior through a recorded/fake public provider, not source-line matching.
An additional source scan forbids private-method names and reflection escape hatches.

### 15.2 Model effects

Kill a subprocess:

- before prepare;
- after prepare/before start;
- after start/before provider acceptance;
- after first chunk;
- after complete response/before receipt;
- after receipt/before task write;
- after task write/before checkpoint.

For default reconcilable calls, every post-start ambiguous boundary stops without another
provider call. For the fake idempotent provider, recovery uses the same key and returns the
same response. Both retain exact attempts and usage evidence.

### 15.3 Tools

For read-only and idempotent demonstration tools:

- zero, one, and many tool calls;
- duplicate ids, unknown name, malformed/extra/deep/large arguments;
- recoverable result versus exception versus timeout/unknown;
- kill at all M3 effect boundaries;
- idempotent target sees one logical key;
- results remain original-call ordered under injected completion permutations;
- secret, cyclic, unsupported, and oversized results never reach model context;
- a model-requested unregistered mutating tool executes zero application code.

### 15.4 Determinism and restart

- inline/threaded logical histories match;
- MemoryCheckpointer and SQLite projections match excluding durability metadata;
- restart at every graph barrier converges;
- request duplicate/recovery/fork/redirect preserve model and tool identities;
- changed RubyLLM version, model, schema, tool definition, adapter protocol, or codec fails
  before provider/tool I/O;
- random chunk boundaries produce one identical durable message and graph history.

### 15.5 Security and resources

- network is OS-denied in default CI;
- prompt/tool-output injection cannot alter registry, safety, or budgets;
- provider error bodies and credentials are absent from errors/events/inspect;
- factory returns shared/mutated chat or Rails-backed chat and is rejected;
- the documented trusted-factory boundary is tested; no test claims arbitrary callbacks are
  discoverable through RubyLLM's public API;
- early stream close returns threads, connections, and sink capacity;
- 10,000 materialize/generate fixture cycles return RSS, FDs, threads, and objects to bounded
  baselines;
- gem package contains no credentials, recordings with content, or provider cache.

### 15.6 Public M4 evaluations

`tamoz.m4.ruby_llm` publishes at least:

1. `m4.single-generation` — one public generation, zero hidden tools;
2. `m4.message-fidelity` — supported public values round trip exactly;
3. `m4.model-ambiguity` — post-dispatch crash stops without duplicate;
4. `m4.tool-effects` — read-only/idempotent calls preserve identity and order;
5. `m4.resume-compatibility` — durable restart and changed-definition rejection;
6. `m4.stream-equivalence` — chunking/early-close cannot change durable state.

Default results use a deterministic recorded provider under OS-denied network. The opt-in
live profile records provider/model/version, pricing metadata, tokens, cost, and sanitized
digests, but it is not a release correctness oracle.

## 16. Review gate

Implementation may begin only when every answer is yes:

- Is there a released RubyLLM version with a documented public one-generation seam?
- Can `generate` be proven to execute zero tools and append exactly one response?
- Does production source avoid all RubyLLM private/provider/protocol APIs and reflection?
- Is RubyLLM loaded only by `tamoz-agent`?
- Can every supported message/tool-call field survive durable round trip?
- Are unsupported content and unknown future formats rejected instead of flattened?
- Is every provider call effect-journaled before I/O?
- Does any ambiguous non-idempotent model call stop without automatic redispatch?
- Can a tool run only through Tamoz validation and the effect journal?
- Is whole-batch tool validation complete before the first tool executes?
- Are tool results ordered by original call index?
- Are streaming chunks provisional and bounded?
- Can shared chat state, callbacks, or hidden RubyLLM persistence become authoritative?
- Do fatal storage/policy/codec failures stay out of model-visible tool results?
- Are budgets durable and checked before each provider/tool effect?
- Are M0–M3 behavior, isolation, packaging, and evidence unchanged?

Any “no” blocks implementation and revises this plan. The current answer to the first item
remains **no until RubyLLM releases the reviewed 2.0 seam**. That is an upstream release
gate, not permission to weaken Tamoz's boundary.

## 17. Plan review result

Conditionally accepted. [M4_PLAN_REVIEW.md](reviews/M4_PLAN_REVIEW.md) records the upstream
audit, thirteen resolved critical/high/medium findings, two Five Whys analyses, conditional
entry gate, and residual risks.

The review corrected four foundational errors before code: it rejected RubyLLM 1.16's
opaque tool loop, removed an unverifiable hidden-callback claim, required whole-batch tool
preflight before any dispatch, and distinguished durable preservation of extension fields
from RubyLLM runtime reconstruction. No M4 implementation or dependency change is authorized
until the released upstream seam passes the recorded behavioral contract.
