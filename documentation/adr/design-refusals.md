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
| `Marshal` as the default serializer | `Marshal.load` on a durable artifact is remote code execution waiting for a bad day | [ADR-020](./adr-020-secrets-are-refused-by-type-or-explicitly-protected-never-scrubbed-by-name.md) |
| An async/await API beside the sync one | One synchronous API; a fiber pool waits until it passes the pool conformance tests | [ADR-008](./adr-008-threads-is-the-default-pool-inline-in-tests.md) |
| Config-dict behaviour dispatch (`config["configurable"]["llm"]`) | Stringly-typed action at a distance; use keyword arguments | [ADR-006](./adr-006-plain-hash-state-with-an-explicit-reducer-registry.md) |
| A plugin API / plugin marketplace | Third-party code would hold the process's credentials and egress; extensions are first-party adapter gems | [ADR-014](./adr-014-extensions-are-first-party-adapter-gems-not-plugins.md) |
| Regex-based secret scrubbing | Lossy and incomplete | [ADR-020](./adr-020-secrets-are-refused-by-type-or-explicitly-protected-never-scrubbed-by-name.md) |
| Blind retry after an ambiguous side effect | Can duplicate irreversible work | [ADR-016](./adr-016-every-external-effect-is-journaled-and-ambiguity-stops-as-unknown.md) |
| A prompt-only "always plan" instruction | Cannot enforce an action gate or prove which plan authorized execution | [ADR-022](./adr-022-reviewed-plan-gate.md) |
| A live self-rewriting agent | Can change its own evaluator or permissions and hide regressions | [ADR-023](./adr-023-self-improvement-promotion.md) |
| A second SDK / provider adapter | Two credential, failure, and projection paths; cannot expose exact wire bytes | [ADR-048](./adr-048-tamoz-owns-the-model-boundary-one-digest-bound-openai-compatible-transport.md) |
| A threshold-action engine in observability | An authority path outside reviewed plans and bounded remediation | [ADR-050](./adr-050-automated-response-durable-evidence.md) (proposed) |
| Compatibility shims and legacy-row readers before 1.0 | Code that exists only to preserve past shapes, inside safety arguments | [ADR-059](./adr-059-no-backward-compatibility-before-1-0.md) |
| Building the framework without building the agent | The agent is the only honest specification | GOAL |

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`../../docs/design-v0.1/GOAL.md`](../../docs/design-v0.1/GOAL.md) — the goal and the non-goals list
