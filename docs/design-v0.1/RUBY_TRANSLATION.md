# Ruby translation

What each Python idiom becomes, what we refuse to port, and what Ruby lets us delete.

This is the synthesis chapter the research never wrote (planned Ch 5). Its thesis, from
`research/…/architecture_insight.md` insight 2: **LangChain's documented failures are
precisely where Ruby's idioms win.** Over-abstraction, forty concepts, sync/async duality,
Pydantic-everywhere, hidden control flow — Ruby dissolves each one, not by being clever but
by already having the feature LangChain had to build.

## 1. The translation table

| Python / LangChain / LangGraph | Ruby answer | Why |
|---|---|---|
| `Runnable` ABC, 16 methods, only `invoke` abstract | duck type `#call(input, context)`; `include Tamoz::Step` for combinators | Duck typing already gives substitutability; a base class adds nothing but a ceiling |
| `ainvoke` / `abatch` / `astream` twins | one method family; concurrency chosen by symbol (`:inline`, `:threads`, `:fibers`) | Function colouring is a Python problem. Fibers give concurrency without a parallel API |
| `chain = prompt \| model \| parser` | `Tamoz.seq(prompt, model, parser)` if `tamoz-chain` is promoted | Native `Proc#>>` forwards only the prior result and loses Tamoz's required `context`; explicit composition is correct |
| dict literal → `RunnableParallel` | `Tamoz.parallel(context: retriever, question: :itself)` | Explicit is better than coercing a Hash literal into behaviour |
| `RunnableConfig` TypedDict, `patch_config`, `merge_configs` | frozen `Tamoz::Context`, `#with(...)` returns a patched copy | Explicit typed capabilities flow down; no free-form dispatch bag |
| `@tool` decorator + type hints → `args_schema` | `class Weather < RubyLLM::Tool` with schema inferred from `execute`'s keyword signature | RubyLLM already owns this boundary; no parallel declaration drifts |
| Pydantic models everywhere | `Data.define` value objects; `dry-schema` **only** at trust boundaries (tool args, structured output) | Validate where untrusted data enters, nowhere else |
| `BaseCallbackHandler`, six mixins, `on_llm_*`/`on_chain_*`/`on_tool_*` | one notifier duck type: `#instrument(name, payload) { }` | `ruby_llm`'s pattern. ActiveSupport::Notifications-compatible, no hard dependency, one method to implement |
| `astream_events(version="v2")` | `Enumerator` of `Tamoz::StreamPart` | Ruby's `Enumerator` is the event stream. Lazy, composable, `.filter_map`-able |
| `AIMessageChunk.__add__` algebra | `Tamoz::Delta#merge`, folded by an accumulator into the same `Message` | `ruby_llm`'s `StreamAccumulator`. One message type, deltas are internal |
| `TypedDict` / Pydantic state schema | plain Hash with symbol keys + an explicit schema registry | Hashes are Ruby's record type; pattern matching reads them natively |
| `Annotated[list, add_messages]` | `state :message_events, reduce: Tamoz::Reducers.message_events` | An explicit append-only event reducer preserves audit history |
| `LastValue` default channel | absence of `reduce:` | Same semantics, no vocabulary |
| `interrupt(value)` raising `GraphInterrupt` | worker-local `catch(:tamoz_interrupt)` around a `throw` | `rescue => e` cannot swallow it, and the catch stays on the executing thread's stack |
| `Command(update=…, goto=…, resume=…)` | `Tamoz::Command = Data.define(:update, :goto, :resume, :graph)`; a bare Hash still means update-only | Value object, pattern-matchable, no generics |
| `Send("node", state)` | `Tamoz::Send = Data.define(:node, :input)`; `Tamoz.send_to(:node, input)` | Same |
| `should_continue` returning `Literal["tools","end"]` | conditional edge returning a Symbol; `case … in` in the router | Pattern matching is the idiomatic dispatch |
| `BaseCheckpointSaver` | load + idempotent task writes + atomic compare-and-append + fenced lease | Correct state transitions matter more than matching a method count |
| `SerializerProtocol` / `JsonPlusSerializer` | allowlisted, versioned JSON codecs | Durable data never revives arbitrary Ruby objects |
| `BaseChatMessageHistory`, `ConversationBufferMemory`, `RunnableWithMessageHistory` | **nothing** — history is a channel in graph state, persisted by the checkpointer | Three LangChain rewrites all concluded "state must be explicit and injected". Start there |
| `AgentExecutor` | durable graph recipe accepting `RubyLLM::Agent`/`Chat` | RubyLLM owns reusable agent configuration; Tamoz adds durable execution |
| `LLMChain`, `SequentialChain`, `RetrievalQA`, the chain subclass zoo | ordinary Ruby functions; deferred `Tamoz.seq` only if repeated need appears | Fixed topologies do not justify classes or an unconsumed package |
| `RunnableBindingBase` + retry/fallback/each wrappers | deferred small Steps if two consumers justify `tamoz-chain` | Do not publish an unused composition package |
| `configurable_fields` / `configurable_alternatives`, `config["configurable"]["llm"]` | constructor/compile keywords and typed policy objects | Stringly typed dispatch-at-a-distance is removed entirely |
| `create_model_v2` dynamic schema generation per Runnable | **nothing** | Schemas for components nobody introspects |
| thread-local / contextvar ambient state | `context:` as a constructor or call argument | `ruby_llm`'s `RubyLLM.context` precedent: explicit scope objects, no `Thread.current`. Materially safer for a many-tenant graph process |

## 2. What Ruby lets us delete outright

Nine things exist in LangChain/LangGraph only because Python lacks a Ruby feature:

1. **The `a*` method family.** One API with an ordered pool; fibers are an optional engine.
2. **`Runnable` as a base class.** Duck typing.
3. **The chunk class hierarchy** (`AIMessageChunk`, `AddableDict`, …). One message type plus
   an accumulator, as `ruby_llm` proves.
4. **The callback-handler mixin tree.** One `#instrument` method.
5. **`coerce_to_runnable`.** `Tamoz.step` adapts a callable explicitly; native `Proc#>>`
   is not used because it drops Context.
6. **Pydantic schema generation for internal components.** Reflection on the method
   signature at the one boundary that needs it.
7. **`Annotated[...]` metaprogramming.** A lambda in a schema declaration.
8. **`try/except GraphInterrupt` discipline.** Worker-local `throw`/`catch`.
9. **The memory class family.** State is a channel; persistence is a checkpointer.

Concept count remains a usability budget, not a correctness constraint.

## 3. The twelve concepts

The whole framework a user must hold in their head:

| # | Concept | One line |
|---|---|---|
| 1 | **Message** | the currency — role, content, tool calls |
| 2 | **Tool** | a class with `description` and `execute`; the signature is the schema |
| 3 | **Step** | anything adapted to `#call(input, context)` |
| 4 | **Context** | explicit run/execution/request ids, cancellation, emitter, Store, effects |
| 5 | **State** | a Hash whose keys have reducers |
| 6 | **Node** | a Step over state, returning a partial update or a `Command` |
| 7 | **Edge** | static, conditional, or dynamic (`Command#goto`) |
| 8 | **Graph** | nodes + edges + a state schema; `compile` makes it runnable |
| 9 | **Checkpoint** | an immutable snapshot per super-step, keyed by thread |
| 10 | **Interrupt** | pause from inside a node, resume with a value |
| 11 | **StreamPart** | the uniform `{type, namespace, data}` streaming envelope |
| 12 | **Store** | cross-thread durable key-value memory |

`Command` and `Send` are routing vocabulary. Channels/reducers are state vocabulary.
Lease, effect receipt, graph version, and request id are operational vocabulary users meet
only when they need the corresponding durability feature. No concept-count target may hide
a necessary correctness boundary.

## 4. Style rules inherited from `ruby_llm`

Non-negotiable, because the point is that Tamoz feels like a sibling of `ruby_llm`, not a
Python transplant. Each is pattern-numbered against the catalogue in
`research/…_sec02.md` §2.6.

| Rule | Pattern |
|---|---|
| Module-level facade with `...` forwarding; one-line entry points that add no wrappers | 1 |
| `option` DSL for configuration with lazy lambda defaults and normalising writers | 2 |
| Open registries with self-registration; new backends never edit core files | 3 |
| Two-axis splits: many small declarations, few large strategies | 4 |
| `abstract :name` seam macro raising a `NotImplementedError` that names class and method | 5 |
| Classes composed of one-concern-per-file `module_function` mixins | 6 |
| Fluent configuration only where objects are not shared; graph/runtime values use copy-on-write | 7 |
| Public, decomposed state machines — every move callable, the loop drivable by hand | 8 |
| Class-level macro DSLs (`description`, `parameter`, `state`, `node`) | 9 |
| Schema inferred from method signature, never declared twice | 10 |
| Only declared recoverable/model-actionable tool failures become typed values; fatal failures propagate | 11 |
| Callbacks over inheritance; persistence and tracing hang off public hooks | 12 |
| Blocks for streaming; streamed and non-streamed return the same type | 13 |
| Duck-typed conversion protocol (`respond_to?(:to_llm)`) instead of shared base classes | 14 |
| Conditional integration and lazily required optional dependencies | 15 |

Plus four Tamoz additions:

- `# frozen_string_literal: true` everywhere; `Data.define` for every value object.
- Pattern matching (`case … in`) is the preferred dispatch in routers and reducers.
- No `Thread.current`, no global mutable registry after boot, no `$` globals.
- Public API carries RDoc with runnable examples; internals marked `:nodoc:`.

## 5. Where we deliberately diverge from `ruby_llm`

Two places, both justified:

- **Immutable over fluent-mutable.** `ruby_llm`'s `Chat` mutates and returns `self`, which
  is right for an interactively driven conversation object. Graph state, `Context`, and
  chain steps are frozen and copy-on-write, because they are shared across parallel tasks
  at a barrier. Mutation there is a data race with a friendly syntax. The `Tamoz::Agent`
  surface still offers `with_*` fluency — it just returns a new object.
- **Composition.** Tamoz does not use native `Proc#>>`: it cannot thread the second Context
  argument. If `tamoz-chain` is promoted, `Tamoz.seq(a, b, c)` is the only canonical form.

## 6. Concurrency, honestly

Three modes, selected by symbol, following `ruby_llm`'s `ToolConcurrency`:

| Mode | Mechanism | When |
|---|---|---|
| `:inline` | sequential, same thread | default in tests; deterministic; the debugging mode |
| `:threads` | fixed-size pool | **default in production** — agent work is I/O-bound, so the GVL is released during HTTP waits |
| `:fibers` | `async` gem, lazily required | many hundreds of concurrent branches; opt-in dependency |

The GVL is not a problem here and pretending otherwise would be dishonest in the other
direction: LLM agent workloads are network-bound almost end to end. Where it *does* bite is
local tool work — parsing large files, embedding computation in-process — and the answer
there is a subprocess or a native extension, not a different concurrency model.

The barrier makes committed results equivalent across modes: writes are buffered per task
and merged in deterministic path order. Each worker captures `throw` on its own stack.
Live progress timing may differ; final checkpoints may not. That equivalence is a
conformance test, not an aspiration.
