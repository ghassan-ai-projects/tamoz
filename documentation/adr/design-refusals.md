# Standing design refusals

A cross-cutting digest of what Tamoz deliberately does **not** build — the size-discipline
refusals that keep the framework small (GOAL.md's bet: "a quarter of the size with the same
guarantees"). This is an index, not a second source of truth: each refusal points to the ADR
(or GOAL.md) that owns the reasoning, where the full rejected-alternatives analysis lives.

| Refused | Why | Owned by |
|---|---|---|
| Port LangChain's `Runnable` faithfully | Sixteen methods and async twins to express what duck typing gives free | GOAL non-goals |
| A `Memory` abstraction class family | State must be explicit and injected, not hidden in a memory object | [ADR-006](./adr-006-plain-hash-state-with-an-explicit-reducer-registry.md) |
| Supervisor / swarm / hierarchy classes | Recipes over the engine; shipping topology classes means the engine has started guessing what agents are | GOAL non-goals |
| Document loaders in core | LangChain's largest dependency-bloat source; Ruby has good per-format gems | GOAL non-goals |
| `Marshal` as the default serializer | `Marshal.load` on a durable artifact is remote code execution waiting for a bad day | [ADR-020](./adr-020-sensitive-data-policy-is-explicit-and-lossless.md) |
| An async/await API beside the sync one | One API with ordered pool selection; fibers stay optional | [ADR-008](./adr-008-threads-is-the-default-pool-inline-in-tests.md) |
| Config-dict behaviour dispatch (`config["configurable"]["llm"]`) | Stringly-typed action at a distance; use keyword arguments | [ADR-006](./adr-006-plain-hash-state-with-an-explicit-reducer-registry.md) |
| A plugin API / plugin marketplace | Compatibility commitment before the core stops moving; sources are a closed set | [ADR-014](./adr-014-no-plugin-api-in-v0-1.md) |
| Regex-based secret scrubbing | Lossy and incomplete | [ADR-020](./adr-020-sensitive-data-policy-is-explicit-and-lossless.md) |
| Blind retry after an ambiguous side effect | Can duplicate irreversible work | [ADR-016](./adr-016-external-effects-are-at-least-once-unless-proven-otherwise.md) |
| A prompt-only "always plan" instruction | Cannot enforce an action gate or prove which plan authorized execution | [ADR-022](./adr-022-reviewed-plan-gate.md) |
| A live self-rewriting agent | Can change its own evaluator or permissions and hide regressions | [ADR-023](./adr-023-self-improvement-promotion.md) |
| A second SDK / provider adapter | Two credential, failure, and projection paths; cannot expose exact wire bytes | [ADR-048](./adr-048-one-digest-bound-openai-compatible-model-transport.md) |
| Building the framework without building the agent | The agent is the only honest specification | GOAL |

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`../../docs/design-v0.1/GOAL.md`](../../docs/design-v0.1/GOAL.md) — the goal and the non-goals list
