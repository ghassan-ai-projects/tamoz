# Codebase Review — gems/tamoz-stream

*12-agent codebase review, 2026-08. See [INDEX.md](INDEX.md). Scope: 991 LOC, 15 files — all of `lib/`, gemspec, related tests (`stream_*_test.rb`, `sqlite_stream_*`), `.rubocop_todo.yml` entries.*

## Overall assessment

The gem is small, well-documented, and contract-first; most debt is concentrated in the three `Data.define` value classes, which are also the files with the most `.rubocop_todo.yml` entries. Boundary direction is clean: `tamoz-stream` depends only on `tamoz-core`; `tamoz-sqlite` implements `StreamStore` and consumes `CognitionAdmission`/`EventEnvelope` — correct per §6.1. The headline finding is a real correctness bug: `ReplayClock`'s monotonicity guard is dead code.

## High

### H1 — `ReplayClock`'s regression guard is dead

`gems/tamoz-stream/lib/tamoz/stream/clock.rb:79-83`. `guard!` compares against `@last`, but `@last` is assigned only in `initialize` (line 57) and **never updated** by `now_processing`, `now_event`, or `advance`. `WallClock#now_processing` updates `@last` (line 31); `ReplayClock` doesn't. Consequence: `now_event(wm2)` with `start < wm2 < wm1_previous` does not raise `StreamClockError` — the monotonicity guarantee the class doc promises is not enforced, and `advance` only stays monotonic by the non-negative-delta check, not by the guard.

**Fix:** assign `@last = value` (or `@virtual`) after a successful `guard!`, mirroring `WallClock`.

### H2 — `WallClock#now_event` has no guard at all

`clock.rb:35-37`. It returns the watermark unconditionally, while `ReplayClock#now_event` guards. Two implementations of the same contract behave differently; a regressing watermark passes silently in live mode.

**Fix:** route both clocks through the same guarded implementation.

### H3 — `CognitionAdmission.evaluate` silently admits on empty scores

`cognition_admission.rb:71`. `trigger.fetch("scores").values.max.to_f` — if `"scores"` is `{}`, `max` is `nil`, `nil.to_f == 0.0`, and the confidence check passes, yielding `:admitted` on evidence-free input. For an admission gate this should fail closed.

**Fix:** `return :rejected if scores.empty?` (or validate the trigger shape up front).

## Medium

### M1 — `ReplayRuntime#run` ignores `@mode` and `@fixture_model`

`replay_runtime.rb:24-41`. `fixture_model` is accepted, stored, and never read; `run` behaves identically in all four modes. The class doc claims mode-specific credential behavior, but the only mode-dependent branch is `deliver_command`. Either dead state (remove the param) or a half-implemented contract (docs describe behavior the code doesn't have — a §11 violation: "A doc describing a surface the repository does not have is worse than no doc").

### M2 — `ActionBoundary.revalidate_and_check` fails closed only for `StreamError`

`action_boundary.rb:71-75`. A `RuntimeError`/bug inside the interlock reader propagates unhandled rather than becoming `InterlockUnavailableError`; the doc says "a read failure FAILS CLOSED".

**Fix:** rescue `StandardError` (not `Exception`) and re-raise as `InterlockUnavailableError`, keeping the cause.

### M3 — No direct tests for the clock pair or `CognitionAdmission` edge cases

`clock.rb` is exercised only indirectly via SQLite tests (`test/sqlite_stream_*`), and no test pins the `ReplayClock` regression guard (which is why H1 survives), `WallClock#advance` raising, or empty-scores admission (H3). §9 wants failure paths first-class at the narrowest boundary.

**Fix:** add `test/stream_clock_test.rb` with mutation-sensitive cases.

### M4 — `SituationSnapshot` is a mutable, unvalidated outlier

`situation_spec.rb:117-163`. Unlike the three `Data.define` values in the same gem, it's a plain class: `situation_id` string not frozen, no validation of `situation_version`/`risk_class`/`deadline`/`created_at` types, no `freeze` on the instance. Its digest feeds the invariant-49 binding check, so a garbage snapshot silently binds.

**Fix:** make it `Data.define` with the same validate-then-freeze pattern as `EventEnvelope`.

### M5 — Two classes per file (§2 violations)

`clock.rb` (`WallClock` + `ReplayClock`) and `situation_spec.rb` (`SituationSpec` + `SituationSnapshot`); `connector.rb` also defines `AuthenticationError` (an error class outside `errors.rb`).

**Fix:** `stream/wall_clock.rb`, `stream/replay_clock.rb`, `stream/situation_snapshot.rb`, move `AuthenticationError` to `errors.rb` (it's also a Zeitwerk path-mirroring break: `Tamoz::Stream::AuthenticationError` lives in `connector.rb`).

### M6 — `.rubocop_todo.yml` debt concentrated here

`event_envelope.rb` appears in ~10 todo sections, `channel_descriptor.rb`/`situation_spec.rb`/`cognition_admission.rb`/`action_boundary.rb` in ~7–8 each (Metrics/MethodLength, ParameterLists, AbcSize, etc.). Pre-existing debt, allowed, but the `validate!` methods (e.g. `channel_descriptor.rb:68-125`, 57 lines) are the top shrink candidates via L1 below.

## Low

- **L1 — Duplicated validate/compute_digest/to_h triad across three Data classes.** `event_envelope.rb:30-43,100-137`, `channel_descriptor.rb:61-125`, `situation_spec.rb:64-108`. Same skeleton: `validate!` → `compute_digest` via `DIGEST_DOMAIN + JSON.generate(Core.canonical(...))` → frozen field hash → `to_h`. The digest computation (`domain + canonical JSON → "sha256:..."`) is byte-identical logic four times (add `SituationSnapshot#compute_digest`, `situation_spec.rb:150-162`). **Fix:** extract a tiny shared `Stream.digest(domain, value)` module_function — one clearly isolated responsibility, four real consumers. (Keep `validate!` per-class; the rules differ.)
- **L2 — Comment/vocabulary drift.** `cognition_admission.rb:70`: "Confidence ceiling: the trigger exceeded the spec's **risk** ceiling" while checking `max_confidence` against a score — confidence and risk are conflated. Also `stream_clock.rb:11` mentions `advance(delta)` as "replay-mode stepper" on the interface, but `WallClock#advance` always raises — the interface advertises an operation one of two implementers forbids (mild LSP smell; acceptable if documented per-class, currently only implied).
- **L3 — `Errors` constants are shadowed per subclass but `RETRYABLE` isn't.** `errors.rb:8-40`: `StreamError::RETRYABLE = false` is inherited silently; subclasses override `CATEGORY` individually. Fine, but `InterlockUnavailableError` (fail-closed, transient reader failure) being non-retryable is a policy decision with no comment or test pinning it. **Fix:** pin `RETRYABLE` semantics in a comment/test, or set it explicitly on the retryable subclass.
- **L4 — `CognitionAdmission.evaluate` mixes 7 keyword params including two optional timestamps and a version.** `cognition_admission.rb:39-40` (in `.rubocop_todo.yml` for parameter lists). A small `AdmissionState` value (`debounced_at`, `last_admitted_at`, `current_version`) would halve it. Low priority; flagged as the natural shape if M6 is remediated.
- **L5 — `StreamStore` contract returns string-keyed outcome hashes.** `stream_store.rb:31-32` (`{"outcome" => ..., "identity" => ...}`). §5 says internal stable shapes are `Data.define`, hashes only at wire boundaries; this is an internal contract between `tamoz-stream` and `tamoz-sqlite`. Justifiable as a contract seam, but the same pattern in `ActionBoundary.revalidate_and_check`'s return (`action_boundary.rb:80`) is purely internal and could be a value object.

## Gem-boundary notes

- `QuarantineOverflowError` (`errors.rb:27-29`) is **never raised anywhere** (grep: only definitions, docs, and the public-API inventory test). Either the SQLite store is missing the overflow path, or the error is dead public API that the surface audit now pins forever. Worth confirming intent.
- `stream_clock.rb`'s doc references `process_partition`, which lives in `tamoz-sqlite` — harmless, but the clock contract's "why" is documented against an implementation in another gem; a one-line pointer would help.

## Reviewer's top recommendations (in order)

1. Fix the `ReplayClock` guard (H1) + add `stream_clock_test.rb` (M3) — a real correctness bug in a determinism-critical component.
2. Fail closed on empty scores in `CognitionAdmission` (H3).
3. Reconcile `ReplayRuntime`'s docs with its behavior (M1) — currently a documented surface that doesn't exist.
4. Convert `SituationSnapshot` to validated `Data.define` (M4) and split the multi-class files (M5).
5. Extract the shared digest helper (L1) as the first slice of the `.rubocop_todo.yml` debt (M6).
