# `tamoz-chain` — deferred composition proposal

Status: designed, not in the v0.1 build.

The reference agent does not require a general chain package. Ordinary Ruby functions cover
simple pipelines and `tamoz-graph` covers branch, loop, pause, concurrency, and durability.
This package is promoted only after two shipped consumers demonstrate repeated plumbing
that the proposal removes.

Promotion requires:

1. two concrete application recipes;
2. a benchmark against plain Ruby composition;
3. streaming and cancellation conformance;
4. no dependency on RubyLLM or `tamoz-graph`;
5. no new public concept without an ADR.

## 1. Execution protocol

```ruby
step.call(input, context)
```

`Tamoz.step` adapts a two-argument callable:

```ruby
parse = Tamoz.step { |message, context| JSON.parse(message.content) }
chain = Tamoz.seq(prompt, model, parse)
```

`Tamoz.seq` is canonical. Native `Proc#>>` is deliberately unsupported because Ruby calls
the right-hand Proc with only the left-hand result; it cannot preserve the required
`context` argument:

```ruby
->(input, context) { ... } >> ->(input, context) { ... } # broken by Ruby semantics
```

A framework-defined `Step#>>` could work for wrapped steps, but an operator that appears to
accept bare Procs and then loses context is worse than one explicit method. v0.1 does not
ship it.

## 2. Proposed combinators

| Combinator | Contract |
|---|---|
| `Tamoz.seq(*steps)` | pass value left to right, same child Context lineage |
| `Tamoz.parallel(**steps)` | one input to N steps; result Hash follows declaration order |
| `Tamoz.branch(cases:, otherwise:)` | select one declared step |
| `Tamoz.map(step, concurrency:)` | bounded execution; results preserve input order |
| `Tamoz.tap(step)` | run step, return original input |
| `Tamoz.passthrough` | identity |

Callables are validated at construction. Parallel/map use the same ordered pool and
cancellation semantics as core. They do not add hidden retries.

## 3. Decorators

Decorators are small Steps:

```ruby
Tamoz.retry(step, attempts: 3, on: [TransientError], backoff: :jitter)
Tamoz.fallback(step, alternatives: [secondary], on: [OverloadedError])
Tamoz.deadline(step, seconds: 30)
Tamoz.around(step) { |inner, input, context| ... }
```

Rules:

- retry requires explicit error classes and idempotency from the wrapped step;
- fallback does not run after partial output unless the step declares a safe resume policy;
- deadline is cooperative through Context; it does not use `Timeout.timeout` around
  arbitrary code and cannot roll back effects;
- decorator order is visible in `inspect` and trace attributes.

## 4. Streaming

A step may implement `#stream(input, context)`. The default emits one final value.

Sequence streaming requires an explicit transform capability. If the next step cannot
consume deltas, the sequence buffers to the prior step's final value. Buffering is bounded
by a configured byte limit; overflow fails rather than growing without bound.

Parallel streams use the core bounded sink. Live chunks may interleave, with each part
namespaced by branch. Final values preserve declaration/input order. Closing the enumerator
cancels and joins owned work.

`call` and fully consumed `stream` must produce the same final value.

## 5. Prompts

Prompts remain pure ERB-based transformations:

```ruby
prompt = Tamoz::Prompt.messages do
  system "You are <%= role %>."
  history :messages
  user "<%= question %>"
end
```

The prompt object validates required variables, supports explicit partial binding, escapes
according to output type, and never reads time/global state implicitly.

Prompt-cache epochs are **not** memoized inside a prompt. They are session/durability
concerns owned by `tamoz-agent`, which persists canonical system content and schema digests.
Applications pass dynamic time or environment facts as turn content.

## 6. Structured output

```ruby
Tamoz::Result = Data.define(:parsed, :raw, :error)
```

Provider-native structured output is preferred when invoked through RubyLLM. Prompt/parse is
the fallback. Validation happens at the trust boundary, not on every intermediate step.

A repair decorator is a separate model call with its own effect identity, usage event, and
budget. It cannot silently hide the original invalid response.

## 7. Retrieval

Potential protocols:

```text
Embedder    #embed_documents / #embed_query
VectorStore #add / #search / #to_retriever
Retriever   #call(query, context) -> Array<Document>
```

RAG is a recipe:

```ruby
Tamoz.seq(
  Tamoz.parallel(context: retriever, question: Tamoz.passthrough),
  prompt,
  model,
  parser
)
```

Adapters, document loaders, and text splitters do not belong in core. Retrieval remains out
of the package until a real Tamoz Agent or application consumer establishes the minimal useful
contract.

## 8. Refusals

- no memory abstraction;
- no agent executor;
- no fixed-topology chain subclasses;
- no automatic Hash-to-behavior coercion;
- no sync/async twin APIs;
- no native `Proc#>>` claim;
- no retries or timeout semantics that imply unsafe effects were undone.
