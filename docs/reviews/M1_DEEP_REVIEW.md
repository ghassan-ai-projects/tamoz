# M1 deep review

Review target: uncommitted M1 implementation on top of `a897eb3`

Scope: core value boundaries, concurrency and lifecycle semantics, resource containment,
error and secret safety, instrumentation equivalence, package isolation, evaluation
credibility, and portability. Graph and persistence behavior were explicitly excluded
because they begin in M2 and M3.

## Method

The review traced every public contract from `M1_PLAN.md` to implementation and tests, then
used adversarial inputs, deterministic schedule variation, static forbidden-primitive
searches, installed-gem execution, fixture regeneration, and the complete M0+M1 gate.

## Findings

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| High | A codec registration could omit its immutability predicate, and encoded values were not checked against it. | A convenient `frozen?` default was weaker than the reviewed adapter contract. | Require the predicate, enforce it on encode and decode, reject core/Secret class overrides, and test shallow-freeze failure. |
| High | A bounded stream queue retained an unbounded per-namespace sequence map. | Backpressure bounded pending output but not lifetime cardinality. | Add a hard-bounded `max_namespaces`, validate before reservation, and prove invalid events do not consume namespace capacity. |
| High | Cancellation subscriptions were unbounded. | Removable callbacks addressed lifecycle but not adversarial fan-out. | Add configurable and hard callback caps with concurrent cancellation/subscription tests. |
| High | The conformance result claimed denied network access while using only a subprocess. | Process isolation had been confused with network isolation. | Run fixed selections under macOS Seatbelt with `deny network*`; unsupported hosts refuse the evidence run rather than overstate it. |
| Medium | Operational identifiers and reasons accepted control characters. | UTF-8 and byte limits did not address log/event injection. | Centralize safe-text validation, reject C0/DEL controls, and constrain instrumentation names to stable event identifiers. |
| Medium | Error category, retryability, visibility, and safe message could be overridden per instance. | Metadata customization weakened the promise of stable typed errors. | Derive operational metadata only from class constants; callers may customize only the raw diagnostic message. |
| Medium | Normal thread-pool completion used the cancellation grace timeout. | Worker joining did not distinguish completed user work from cancellation/stuck containment. | Fully join workers after all real results; retain bounded joins only for fatal, cancelled, or stuck paths. |
| Medium | Failed stream-part validation could reserve a namespace sequence. | Sequence allocation preceded full payload and identity validation. | Construct and validate the immutable candidate before reserving its accepted sequence. |
| Medium | Ordering and codec determinism had examples but insufficient persistent schedule/input variation. | Stress checks were initially ad hoc. | Commit deterministic multi-seed properties for pool ordering and state encoding. |
| High | Evidence children inherited ambient Ruby/Bundler injection variables and did not enforce the case time budget. | A fixed command was treated as sufficient isolation. | Sanitize Ruby/Bundler inputs, load the locked bundle explicitly, pin the test seed, enforce each declared deadline, and terminate only the owned child process group on expiry. |

## Static and lifecycle conclusions

- Core contains no `Marshal`, YAML revival, `eval`, dynamic network dependency, global type
  registry, fiber/thread-local tenant context, `Thread#kill`, `Thread#raise`, or
  `Timeout.timeout`.
- `Thread.current` is used only for owned-worker naming and accounting.
- No M1 object starts background work at require time.
- Every queue and retained runtime collection introduced by M1 has a configured and hard
  bound, except the explicit stuck Ruby thread described below.
- Stream payloads and Context metadata structurally reject `Tamoz::Secret`; no heuristic
  key-name scrubber is used.

## Residual release checks

Ruby cannot safely reclaim an uncooperative in-process thread. Tamoz reports it as `Stuck`,
opens the configured circuit, and documents process restart as the hard containment
boundary. A supervised process pool is a later adapter, not an implicit claim in M1.

The network sandbox adapter is currently macOS-specific. Linux CI can still run all runtime,
packaging, schema, and fixture checks, but skips the OS-network-isolated evidence execution
until a separately reviewed Linux sandbox adapter exists. Hosted Ruby 3.3/3.4/4.0 results
remain unproven until push. Package versions remain pre-release and are not a release claim.
