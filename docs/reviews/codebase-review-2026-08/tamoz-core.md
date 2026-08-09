# Codebase Review — gems/tamoz-core

*12-agent codebase review, 2026-08. See [INDEX.md](INDEX.md).*

## Overall assessment

The gem is in good shape — heavy validation at boundaries, immutable values, domain digests, and well-reasoned "why" comments. Verified clean: the `rescue Exception` uses (`pool.rb:255`, `instrumentation.rb:45,53`) match the §7-sanctioned pattern with inline disables; no secrets/credentials in durable paths (`Secret` is screened in `StateCodec`, `Immutable`, and `Circuit.digestable`); the gemspec depends only on stdlib + Zeitwerk with no cross-gem requires; capability registry closed-world checks (prefix, descriptor-source consistency, sealed `register`) are consistent with P18 C3/C4/C6. The main risks are untested circuit `rate`/`run` conditions and an immutability leak in `Record#load`.

## High

### H1 — The DR-2 circuit engine's `rate` and `run` condition kinds are untested

`gems/tamoz-core/lib/tamoz/circuit/record.rb:314-375` (`with_failure` rate/run branches) and `record.rb:556-564` (`condition_met?` rate branch). The only tests touching `Record` are via `test/sqlite_circuit_store_test.rb` (11 tests, all consecutive/window/immediate). Yet `Registry::RULE_TARGET` and `Registry::SCHEDULE` (`circuit/registry.rb:205,241`) ship production `rate` conditions and a `run` condition — a broken rate predicate would silently never open a budget circuit.

**Fix:** add a dedicated `test/circuit_record_test.rb` covering rate min-samples/ratio math, run fingerprint scoping/reset on run change, and `bound_counts` eviction.

### H2 — `Record#load` does not freeze or copy the payload, contradicting the class's immutability contract

`circuit/record.rb:74` stores the caller's hash by reference; the header comment (`record.rb:5`) claims "Immutable: every transition returns a NEW record", but `owners` (`record.rb:225`) returns the live mutable hash, so any holder of the loaded payload can mutate "durable" circuit state in place.

**Fix:** `Tamoz::Core.deep_freeze(payload)` (or deep-copy) in `initialize`, matching the `to_payload` deep-copy discipline.

### H3 — `Tamoz::Circuit::MemoryStore` documented but does not exist

`circuit.rb:13` advertises it as one of the two persistence adapters; no such constant exists anywhere in `gems/`. Direct violation of CODING_STANDARD §11 ("A doc describing a surface the repository does not have is worse than no doc").

**Fix:** remove the line or implement the store.

### H4 — `Record#with_retired_owner`, `#healed`, `#in_flight_disposition` have no callers and no tests

`record.rb:277,302,428` — grep shows zero production or test usage. `healed` is the documented self-heal append (DR-2 C1 read-time rule); `in_flight_disposition` encodes the §7 non-idempotent-effect policy. Dead-or-dormant policy code in a safety-critical engine is worse than absent code.

**Fix:** either wire them into `Tamoz::SQLite::CircuitStore`/MCP supervisor, or delete until a consumer lands (§6.2: no abstraction without a consumer).

## Medium

### M1 — Boolean parameters violate §4 / Reek `BooleanParameter`

- `immutable.rb:13` `copy(value, reject_sensitive: true, ...)` — two behaviors (sensitive-screening copier vs. permissive copier).
- `state_codec.rb:33` `Registration.new(..., encode: true)` — encode/decode-only split hidden in a flag.
- `record.rb:302` `in_flight_disposition(dispatched:, idempotent: false)`.

**Fix:** split into named methods (`copy_sensitive_safe` / `copy`, or separate Registration factories).

### M2 — `Record#with_failure` is a ~60-line, 5-branch case mixing policy, accumulation, and state transition

`record.rb:314-375`. It is exactly the "long method containing policy + persistence-shape + orchestration" shape §6 warns about, and the file is in `.rubocop_todo.yml` for method length/complexity (lines 393, 951, 1153, 1252, 1361, 1476, 1722, 1812).

**Fix:** extract per-kind accumulator objects (a `ConditionAccumulator` per `condition.kind`) so `with_failure` is a dispatch + replace.

### M3 — `Circuit::Record` is 632 lines with three distinct responsibilities

`circuit/record.rb`: payload validation (`validate!`, `validate_owners!`, `validate_sub_state!`, … lines 83-211), transition engine, and predicate evaluation. A file past ~250 lines is the standard's own signal (§2).

**Fix:** extract `Circuit::RecordValidator` (module with the `validate_*` family) and keep `Record` as transitions + predicates.

### M4 — Emit-time sequence gap race in `StreamSink`

`stream_sink.rb:52-73`: `reserve_sequence!` (state mutex) and `@queue.push` are not atomic with `close`/`finish`; a close landing between them consumes a sequence number and then raises `StreamClosedError`, leaving a hole in the per-namespace sequence consumers may treat as loss.

**Fix:** reserve the sequence only after a successful non-blocking push, or hold one mutex across reserve+push.

### M5 — Duplicated codec/copy machinery between `StateCodec` and `Immutable`

`state_codec.rb:228-238` vs `immutable.rb:81-90` (cycle detection), `state_codec.rb:386-396` vs `immutable.rb:92-102` (UTF-8 + byte-limit), `state_codec.rb:413-426` vs `immutable.rb:105-112` (item counting, two near-identical variants differing only in error class).

**Fix:** extract a shared internal traversal/guard helper (or have `StateCodec` reuse `Immutable` primitives with an error-class parameter).

### M6 — Namespace/identity is validated twice per emit

`stream_sink.rb:166-180` normalizes each namespace part, then `StreamPart#initialize` (`stream_part.rb:35-39`) re-normalizes the same parts and ids — double `SafeText.normalize` cost on every event.

**Fix:** trust the contract object (build `StreamPart` once, derive the sequence via `with`) or mark the sink's normalization as the only one.

## Low

- **L1 — Dead pool mode.** `pool.rb:35-36`: the `:fibers` branch always raises. Either implement it or drop the branch until the conformance suite exists (§6.2).
- **L2 — Core knows agent-layer spellings.** `core.rb:23-27` `TOOL_ERROR_CLASS_NAMES` maps core classes to `"Tamoz::Agent::Tool*"` strings, and `core.rb:15` `LEGACY_SKILL_EPOCH` encodes a P9/P16 session concern. Documented as deliberate wire-compat, so acceptable — but it's a downward leak of agent naming into the bottom gem; a comment-only coupling a rename in tamoz-agent could silently invalidate. **Fix:** pin the mapping with a test in the dependency-isolation suite asserting the agent aliases still resolve.
- **L3 — Ambient global configuration read in defaults.** `pool.rb:26` (`Tamoz.configuration.pool_size`), `context.rb:32`, `stream_sink.rb:12` read the module-global `@configuration` (`configuration.rb:82-126`) in default arguments. It is the sanctioned config object, but §5 prefers explicit collaborators; defaults evaluated at call time also make the effective value order-dependent on `Tamoz.configure`. **Fix:** pass resolved values from the composing layer; keep `Tamoz.configuration` reads at the outermost entry points only.
- **L4 — Most error classes lack the one-line "when raised" doc required by §7.** `error.rb:75-203` — `TimeoutError`, `CancelledError`, `CheckpointError`, `CheckpointConflictError`, `CheckpointVersionError`, `CheckpointCorruptionError`, `LeaseLostError`, `EffectUnknownError`, `StoreError`, `PoolCircuitOpenError`, etc. carry no comment; only `StaleRequestError`, `CircuitPolicyError`, and the markers do. **Fix:** one line per class.
- **L5 — Misleading generic error message.** `core.rb:78` raises `"unsupported plan argument #{value.class}"` from `deep_freeze`, which is used by the skills compiler, capability descriptors, and durable records — not just plans. **Fix:** `"value cannot cross the durable boundary: #{value.class}"`.
- **L6 — `Secret` freezes only String values.** `secret.rb:6`: a non-String payload is stored mutable and returned live from `reveal`. **Fix:** freeze or document the non-String case.
- **L7 — One-class-per-file (§2) is stretched in three places.** `pool.rb` (`Base`/`Inline`/`Threads`), `task_result.rb` (six `Data` classes), `error.rb` (~20 classes). They're namespaced and `private_constant` where applicable, and this is a common Ruby idiom for error/result families — flagged only because the standard states the rule absolutely; either split or record the exception in the standard.
- **L8 — `.rubocop_todo.yml` debt is concentrated in this gem.** `circuit/record.rb`, `state_codec.rb`, `pool.rb`, `immutable.rb`, `context.rb`, `stream_sink.rb`, and the capability files appear under Metrics, Style, and Lint excludes (e.g. lines 61-68, 393-396, 951-962, 1812-1823). Legacy debt is permitted, but `record.rb` alone appears in ~8 cop excludes — it should be first in line when the ratchet shrinks.
