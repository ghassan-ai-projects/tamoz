# F15 tamoz-observability — IMPROVE: the closed catalog, correlation and bounded recorders are real and hold; the secret lens has no content-side guard and the drop ledger's key format is malformed

Row / queue / baseline (commit, date) / analyst / budget
- Row: **F15** — `tamoz-observability`
- Queue: W4B (`COVERAGE.md:83`, responsibility "Closed signals, correlation, bounded recorders, metrics, trace projection")
- Baseline: branch `audit-15-09`, commit `582ae55`, 2026-09-15
- Analyst: independent read-only analyst lane (analyses/F15-observability), no scanner lane claimed
- Budget: ~45 min, one pass, no implementation

## Scope and source map

Every file below was read end to end at `582ae55`.

| File | Lines | Role |
|---|---:|---|
| `gems/tamoz-observability/tamoz-observability.gemspec` | 20 | dependency direction (`tamoz-concurrency`, `tamoz-core` only) |
| `gems/tamoz-observability/lib/tamoz/observability.rb` | 34 | entry seam, `SCHEMA_VERSION = 1`, require order |
| `.../observability/catalog.rb` | 191 | the seeded closed registry (events + `metric_catalog`) |
| `.../observability/signal_catalog.rb` | 252 | registration, name/prefix rules, `validate_signal` |
| `.../observability/signal.rb` | 225 | the immutable value, bounds, `Tamoz::Secret` refusal |
| `.../observability/correlation.rb` | 32 | derived `trace_id` / `span_id` |
| `.../observability/content_policy.rb` | 230 | per-class capture, digests, truncation |
| `.../observability/recorder.rb` | 19 | the `Recorder` contract (must not raise / must not block) |
| `.../observability/recorder_drop_ledger.rb` | 59 | validation + drop accounting mixin |
| `.../observability/recorder_journal.rb` | 340 | disk journal, lanes, rotation, `Files` queries |
| `.../observability/recorders.rb` | 127 | `Null`, `Memory`, `Fanout` |
| `.../observability/producer.rb` | 93 | `emit` / `around`, the guarded instrumentation shape |
| `.../observability/metrics.rb` | 276 | derived counters/gauges/histograms, Prometheus render |
| `.../observability/trace.rb` | 168 | span projection |
| `.../observability/usage.rb` | 125 | `Usage`, `Cost`, `PricingTable` |
| `.../observability/model_call.rb` | 50 | model-call emitter |
| `.../observability/notifier.rb` | 45 | `instrument` adapter to the core notifier seam |
| `.../observability/errors.rb` | 34 | typed observability errors |
| `.../observability/exporter.rb` | 11 | exporter contract, unimplemented |
| `.../observability/telemetry_reader.rb` | 16 | read-only reader contract, unimplemented |
| `.../observability/version.rb` | 7 | `0.1.0.alpha.1` |

Supporting source read for the boundary claims: `gems/tamoz-concurrency/lib/tamoz/concurrency/drain.rb` (224, the shared bounded-drain skeleton `Journal` inherits), `gems/tamoz-core/lib/tamoz/instrumentation.rb` (83, the guarded `Tamoz.instrument` seam), `gems/tamoz-core/lib/tamoz/secret.rb` (21), `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:69-95` (`cmd_trace`), `:133-190` (`observe metrics`, `observe doctor`), `gems/tamoz-agent/lib/tamoz/agent/worker.rb:1223-1276` (`emit` / `emit_observability` / `observable_attributes`).

Entry seam: `Tamoz::Observability::Producer#emit` / `#around` (`producer.rb:14-42`) → `Recorder#record` (`recorder.rb:10`). The core adapter is `Tamoz::Instrumentation.instrument` (`instrumentation.rb:11-26`) → `Notifier#instrument` (`notifier.rb:10`).

## Behavior path

1. A producer calls `Producer#emit(name, correlation:, attributes:, content:)` (`producer.rb:14`).
2. `build_signal` resolves the name against the closed registry — `Catalog.fetch(name)` (`producer.rb:48`). An unregistered name raises `UnregisteredSignalError` (`signal_catalog.rb:46-50`), which the `rescue StandardError` at `producer.rb:22` converts to `:dropped`.
3. The content policy runs: `policy.apply(content)` (`producer.rb:49`) defaults to `ContentPolicy::NONE` (`content_policy.rb:227`), which returns `{policy_digest:, content: {}}` for `nil` content or per-class `*_digest` / `*_bytes` for supplied content (`content_policy.rb:44-51`, `:80-95`).
4. `outcome` is merged into attributes only when the catalog entry requires it (`producer.rb:50`).
5. `Signal.build` (`signal.rb:23`) validates memberships, timing consistency, outcome/error_class pairing, and freezes attributes and content with byte/depth/entry bounds (`signal.rb:13-16`, `:136-222`).
6. `recorder.record(signal)` (`producer.rb:21`) → for `Journal`, `guard_record` (`recorder_drop_ledger.rb:20`) validates against the catalog, then `route` (`recorder_journal.rb:81-84`) selects the reserved lane via `Catalog.safety_bearing?` (`recorder_journal.rb:86-88`) and either enqueues or, for a full reserved lane, writes synchronously (`recorder_journal.rb:90-97`, `:117-122`).
7. The drain thread (`drain.rb:166-187`) batches per lane (`recorder_journal.rb:124-129`) and `write_signal` appends one JSON line (`recorder_journal.rb:140-160`).
8. Reads: `Journal.read_entries` (`recorder_journal.rb:250-254`) → `Trace.from_documents` (`trace.rb:49`) or `Metrics.from_documents` (`metrics.rb:83`).

## Lens: correctness

Reviewed. The closed-catalog path is genuinely closed at every entry point I could reach.

- `Producer#emit` refuses an unregistered name. Probe P1: `emit("totally.arbitrary.secret_name")` → `:dropped`, 0 signals recorded. `Catalog.fetch` raises at `signal_catalog.rb:46-50`.
- `Notifier#instrument` short-circuits before building anything: `return handle_unregistered(&) unless Catalog.registered?(name)` (`notifier.rb:11`), and `handle_unregistered` just runs the block (`notifier.rb:23-27`). Probe P2 → `false`, nothing recorded.
- Attribute and correlation drift is rejected at record time, not silently accepted: probe P15 (extra `secret_token` attribute) and P16 (bogus `secret_key` correlation) both → `:dropped` with `invalid:validation:bulk` counted. Guards: `validate_unknown_attributes!` (`signal_catalog.rb:203-209`) and `validate_signal_correlation!` (`signal_catalog.rb:180-187`), reached through `DropLedger#validate!` (`recorder_drop_ledger.rb:35-39`).
- Correlation is a pure function of durable identity with no generated or stored state. Probe P3: no `Thread`/`current`/`SecureRandom` reference exists in `correlation.rb`; repeat calls are identical. `Correlation.canonical` (`correlation.rb:27-29`) JSON-encodes each element before joining, so domain separation holds — probe P3 shows `('t','e1,e2')` and `('t,e1','e2')` hash differently (`95a5d0…` vs `4405c8…`), defeating comma-injection collisions.
- `drops_hash` mis-formats every key (see F15-COR-01), but the *counts* are intact and every consumer sums values (`recorder_journal.rb:325-329`). That is a real defect with a narrow blast radius, not a lost-drop bug.

The one correctness claim that does **not** hold is the metrics projection's completeness (F15-OBS-01).

## Lens: security and authority

Reviewed, and this is the weak lens. There is **no content-side secret guard**.

- `ContentPolicy` performs no secret detection, no redaction, and no pattern scan. Its whole per-class behavior is digest + byte count + optional truncation (`content_policy.rb:36-42`, `:80-95`). The only content refusal is an object-identity check for `Tamoz::Secret` (`content_policy.rb:169-172`; also `signal.rb:195-198`).
- `Tamoz::Secret` refuses by *class*, not by *shape*. Probe P32 confirms a real `Secret` in an attribute is dropped (`:dropped`, 0 recorded). But a plain `String` that carries a secret is indistinguishable from any other string, and with capture enabled it is written verbatim — probe P31 with `error_detail: {enabled: true}` produced `"error_detail" => "Authorization: Bearer sk-live-ABCDEF0123456789"` in the policy result.
- The `reason` attribute of `tamoz.worker.error` is a `:low_cardinality` string and is validated only against `/\A[a-zA-Z0-9_.:-]{1,128}\z/` (`signal_catalog.rb:11`, `:236-245`). Probe P5 shows `{reason: "sk-live-ABCDEF0123456789SECRET"}` stored verbatim in a recorded signal. Callers do feed error text here: `worker.rb:137` `emit('worker.error', reason: error.message)`, and `:1032` interpolates a request id into the same field.
- Metrics labels have the same hole and no policy at all. `validate_label_value!` checks only the label *key* against `CORRELATION_IDENTIFIERS` and the *value* against `LOW_CARDINALITY_RE` (`metrics.rb:142-149`). Probe P33 stored a secret-shaped `provider` label; probe P7 stored a thread-id-shaped `outcome` label. A credential that happens to be `[A-Za-z0-9_.:-]{1,128}` passes.
- What *is* defended: the doctor command (`cli_worker_commands.rb:162-182`) does check the journal body for the literal secret and the literal token, and asserts `secret_result == :dropped && token_result == :recorded`. That is an operational probe of the `Secret`-class guard and the digest default — it is not a property test of arbitrary secret-shaped strings, and `limitations.md:125` correctly still lists "full all-surface secret property test" as outstanding.

There is also no authority-escalation path in this gem: no egress, no filesystem capability, no approval surface. `Exporter` is a contract with no implementation (`exporter.rb:6-8`), so no network path exists here to widen.

## Lens: reliability and durability

Reviewed. The prior critical from finding 076 is genuinely fixed, and I verified it independently rather than trusting the resolution note.

- **Prior finding 076 (critical, ERR) — `Fanout#flush` crash: closed.** `guarded` now takes an explicit per-call fallback (`recorders.rb:119-123`), and `flush` passes `0` (`recorders.rb:109`). Probe P12: a child whose `flush` raises yields `fanout.flush(deadline_ms: 10) == 0` with no exception. Probe P12 also confirms `health` returns `{"enabled"=>false, "error"=>"unavailable"}` for the raising child (`recorders.rb:91`, `:104`) rather than injecting `:dropped`. Regression test exists: `test/observability_runtime_test.rb:201-218`, and it passes.
- **Prior finding 076 (major, DUP) — duplication: closed.** `validate!`, `drop_key`, `drops_hash`, `count_invalid_drop` and the strict-mode envelope exist once in `Recorder::DropLedger` (`recorder_drop_ledger.rb:17-56`), included by `Memory` (`recorders.rb:30`) and `Journal` (`recorder_journal.rb:14`). No verbatim duplicate remains in either class.
- **Prior finding 076 (minor, ERR) — mislabeled drops: closed.** `ValidationError` is now booked `invalid:validation:bulk` and every other `StandardError` `record:error:bulk` (`recorder_drop_ledger.rb:23-33`). Confirmed by probes P15/P16 vs P12.
- **Prior finding 076 (minor, SIZE) — journal split: coherent.** `Journal` + `Journal::Files` live in `recorder_journal.rb`; `recorders.rb` is 127 lines holding only `Null`/`Memory`/`Fanout`. `Journal.read` / `read_entries` / `inventory` are thin delegations (`recorder_journal.rb:23-33`), so the split added no shadow API.
- **`record` cannot raise into the observed path.** Probe P41: `record` after `close` returns `:dropped` and counts `tamoz.worker.started:closed:bulk`, matching `drop_drain_closed` (`recorder_journal.rb:99-101`). Probe P42: `record` on a live journal → `:recorded`, no `ThreadError` — I specifically checked re-entrancy because `route` holds the mutex (`recorder_journal.rb:83`) while calling `drain_closed?`; those private readers are deliberately unsynchronized (`drain.rb:123-129`), so there is no self-deadlock. That is worth knowing because it is load-bearing and uncommented.
- **`flush` cannot raise and cannot hang.** Probe P50: `flush(deadline_ms: 0)` and `flush(deadline_ms: -5)` both return the outstanding count (`100`) instead of raising, via the `break if remaining <= 0` guard (`drain.rb:56-58`). Contract "returns what remains unflushed" holds.
- **Every bounded drop is counted, and a drop is distinguishable from a never-emitted signal.** Probe P13: `Memory(max_size: 2)` with 5 emits → `bulk_depth 2`, `drops {"tamoz.worker.error:queue_full:bulk::"=>3}`. Probe P14: `Journal(queue_size: 2)` with 10 emits → `bulk_depth 0` after flush, `drops {…=>8}`. The drop is reported in `health` and persisted to the `.health.json` sidecar (`recorder_journal.rb:220-224`), and `Files.inventory` sums it (`:315-330`). A never-emitted name simply has no key — the distinction is `record`'s `:dropped` return plus the counter.
- **The reserved lane genuinely never drops.** Probe P40: 5 safety-bearing `tamoz.agent.model.ambiguous` signals into `reserved_size: 1` → 5 × `:recorded`, 5 lines on disk, `drops {}`. The synchronous fallback is `write_reserved_now` (`recorder_journal.rb:94`, `:117-122`).
- **Writer failure degrades, it does not kill.** `append_line` rescues `SystemCallError` → `disable!('disk_error')` (`recorder_journal.rb:157-160`, `:213-218`); `handle_loop_error` disables on `writer_failure` (`:132-134`).
- **Rotation is bounded**: `DEFAULT_MAX_FILE_BYTES = 32 MiB`, `DEFAULT_MAX_FILES = 8` (`recorder_journal.rb:17-18`), shifted at `:190-197`; `max_files == 1` deletes rather than rotates (`:179-184`), verified by `test/observability_runtime_test.rb:97-113`.
- **Replay determinism**: probe P3 round-tripped a journal line through `Journal.read` and re-rendered it byte-identically; `Trace.from_documents` is a pure function of the documents (probe P3, and `test/observability_runtime_test.rb:161-178` asserts two constructions are equal).

## Lens: observability and evidence

Reviewed. This lens is where the doc/code contradiction sits, and it is the strongest finding after the secret one.

- **The `tamoz trace` boundary claim in `limitations.md:121-124` is accurate.** "`tamoz trace` currently reconstructs only journal documents and cannot claim the complete checkpoint/effect tree" is exactly right: `cmd_trace` reads `Journal.read(directory, thread_id:)` and nothing else (`cli_worker_commands.rb:80-81`), and the journal holds only what producers emitted. Checkpoints, effects and the durable turn record are never consulted on this path.
- **But the trace projection is thinner than the design implies.** `span_anchor`/`parent_span_id` are read from the signal's attributes (`trace.rb:145-149`, `:156`), and a repo-wide search found exactly one non-test writer of those keys — `tamoz-otel/lib/tamoz/otel/http_exporter.rb:118`, and that only reads `span_anchor`. No producer in any gem sets `parent_span_id` or `span_anchor`. Probe P3 therefore shows a two-signal trace with `parent=nil` on both spans: the "span tree" (`design/observability.md:58`) is a flat span list in practice, and `Trace` has no mechanism to build a parent chain from the journal.
- **`divergence` is structurally always empty.** `build_trace` hardcodes `divergence: []` (`trace.rb:78-81`), and no caller passes one. `design/observability.md:60` says "the disagreement itself is a counted signal (`tamoz.telemetry.divergence`)"; the catalog declares that metric (`catalog.rb:176`) but this gem never computes a disagreement. `limitations.md:125-126` does list "divergence accounting" as outstanding, so the limitation is disclosed — the design doc is what overstates it.
- **Metrics projection is incomplete and the design doc's "Never lossy" is contradicted.** `Metrics.from_documents` only produces a duration metric for two signal names (`metrics.rb:13-16`), and only when `attributes['duration_ms']` is present (`metrics.rb:166-171`). Probe P45: three documents in, one histogram out, `counters` empty, `violations` empty — the two ignored documents produce no counter, no gauge and no violation counter. Probe P47: five `tamoz.agent.model.finish` signals produce zero metric output silently. `design/observability.md:58` claims reconstructed metrics are "Never lossy"; `limitations.md` does not disclose this specific gap.
- **Drop visibility is good.** Every reason is a distinct counter (`closed`, `disabled`, `queue_full`, `disk_error`, `writer_failure`, `invalid`/`validation`, `record`/`error`), the sidecar survives process death, and `tamoz observe doctor` asserts the redaction invariant (`cli_worker_commands.rb:162-184`).

## Lens: scalability and resource bounds

Reviewed. Every buffer in this gem is bounded and every saturation is counted, with one weak spot in the reserved lane.

- Bounds: journal queues `DEFAULT_QUEUE_SIZE = 1_024` and `DEFAULT_RESERVED_SIZE = 64` (`recorder_journal.rb:16-17`); `Memory` `max_size: 1_024` (`recorders.rb:34`); `Signal` 64 attributes, 4 KiB attribute strings, 1 MiB content strings, depth 64 (`signal.rb:13-16`); `ContentPolicy` 64 entries, per-class `max_bytes` ≤ 1 MiB (`content_policy.rb:14-15`, `:124-128`); `Metrics` 4 096 series, 10 000 histogram samples (`metrics.rb:10-11`).
- Series bound is enforced and counted, not silent. Probe P49: 5 000 distinct `model` labels → exactly `4 096` histogram series and `904` violations on that metric name. Probe P46/P48 confirm the recorder's own 1 024 cap engages first in the live path.
- **Cardinality is bounded but not *contained*.** `model`, `provider`, `tool`, `profile`, `surface` are `:low_cardinality` by declaration (`catalog.rb:13-14`, `:162-166`) and validated only by the 128-char charset pattern (`signal_catalog.rb:11`). A `model` string that is unique per call is accepted (probe P46), so it becomes one series each until the 4 096 cap, at which point real series are refused in favour of junk ones — first-come-first-served, no eviction (`metrics.rb:203-208`). See F15-SCAL-01.
- **Reserved-lane synchronous write holds the journal mutex across disk I/O.** `route` wraps `accept_or_drop` in `synchronize` (`recorder_journal.rb:83`), and the full-reserved-lane fallback `write_reserved_now` → `append_line` → `open_io`/`write`/`flush` runs inside that same block (`:94`, `:117-122`, `:150-160`). The drain thread needs the same mutex to `take_batch` (`drain.rb:147`). So a safety-bearing emit during a saturated reserved lane does a synchronous disk write while holding the lock the writer thread needs. The design intends this bounded write (`design/observability.md:40`), and it is what makes the reserved lane never drop — but the blast radius is the whole drain, not just the caller. Probe P40 shows the intended behavior working; I did not measure the stall. See F15-SCAL-02 (minor).
- Batch size is `queue_size + reserved_size` (`recorder_journal.rb:53`), so one batch is bounded at 1 088 signals.

## Lens: maintenance and architecture

Reviewed. Ownership is clear and dependency direction is honest.

- `tamoz-observability` depends only on `tamoz-concurrency` and `tamoz-core` (`tamoz-observability.gemspec:16-19`), matching `design/observability.md:11`. No runtime gem depends on it — the gemspec's dependents are `tamoz-otel` only, and `tamoz-agent` reaches it lazily (`worker.rb:59`, `:69`). No cycle.
- The `Drain` extraction (`drain.rb:5-11`) is a genuine consolidation: `Journal` supplies only policy via template methods (`compose_batch`, `deliver_batch`, `handle_loop_error`, `on_thread_exit` — `recorder_journal.rb:124-138`). The remaining `Files` class is correctly scoped as stateless queries next to the naming convention it interprets (`recorder_journal.rb:242-245`).
- There is one stale artifact of the pre-split design: `Catalog.metric_catalog` is `private_class_method :comms_events` (`catalog.rb:183`) — a copy-paste that makes `metric_catalog` private while `comms_events` is public. Purely cosmetic (both are called only from `seed`/the `tap` block at `:185-188`), so it is `info`, not a finding.
- `SignalCatalog#store` mis-names its guard: `signature_unchanged?` returns true when the signature *is* unchanged, and that branch raises `DuplicateSignalError` (`signal_catalog.rb:95-106`). The behavior is correct (identical re-registration is a duplicate; a changed set without a `since` bump is a schema-evolution error), the name reads backwards. `info`.
- `Notifier#instrument` has an unreachable-on-success guard: `rescue StandardError; raise if block_given?` (`notifier.rb:15-18`) means a non-block call returns `false` when it fails, but `Producer#emit` already converts failures to `:dropped`, so the `false` branch is only reachable via `decompose`/`dispatch` raising. Not a defect, worth noting for the next reader.
- `exporter.rb` and `telemetry_reader.rb` are contract-only modules that raise `NotImplementedError`. `NotImplementedError` is a `ScriptError`, not a `StandardError`, so `Producer`'s `rescue StandardError` (`producer.rb:22`) would **not** catch it — but no code path calls either module today (`gems/tamoz-otel` has its own exporter), so this is latent, not active. `info`.

## Tests and contracts

Every command run individually, per the brief.

| Command | Runs | Assertions | Failures |
|---|---:|---:|---:|
| `ruby -Itest test/observability_catalog_test.rb` | 10 | 26 | 0 |
| `ruby -Itest test/observability_correlation_test.rb` | 6 | 16 | 0 |
| `ruby -Itest test/observability_signal_test.rb` | 10 | 26 | 0 |
| `ruby -Itest test/observability_runtime_test.rb` | 13 | 53 | 0 |
| `ruby -Itest test/observability_cli_test.rb` | 2 | 11 | 0 |
| **Total** | **41** | **132** | **0** |

Not run: `test/sqlite_trace_recorder_test.rb` — it exercises the SQLite trace recorder in `tamoz-sqlite`, which is row F07's surface; the brief assigns the `ShapeValidation` shared module as the only seam with this gem and I did not establish a call into `tamoz-observability` from that path. Not run for budget, not because it is believed green.

Not found: a negative test that a secret-shaped **plain string** cannot reach the journal. `test/observability_runtime_test.rb:25-35` covers only the `Tamoz::Secret` class. Not found: any test that `divergence` is populated. Not found: any test asserting a parent/child span chain. Not found: a test that `Metrics.from_documents` reports a violation for a document it silently ignores.

Contract evidence: `test/observability_runtime_test.rb:116-121` asserts bulk saturation is counted; `:201-218` is the 076 regression; `test/observability_cli_test.rb:40-57` asserts the `trace_id` equals `Correlation.trace_id` and one span is produced; `test/observability_catalog_test.rb` covers the closed-catalog refusals.

## Findings

### F15-SEC-01 — no content-side secret policy: a secret-shaped plain string reaches the journal and a metric label unguarded

- **Severity**: major
- **Confidence**: high
- **Status**: open
- **Source evidence**: `gems/tamoz-observability/lib/tamoz/observability/content_policy.rb:36-42` (`describe` does digest+bytes+truncate only), `:80-95` (`described_result`/`attach_capture!` — the captured value is the raw canonical bytes), `:169-172` (`guard_value!` refuses only the `Tamoz::Secret` class); `gems/tamoz-observability/lib/tamoz/observability/signal.rb:195-198` (same class-only refusal); `gems/tamoz-observability/lib/tamoz/observability/metrics.rb:142-149` (`validate_label_value!` — key blacklist plus charset, no value policy); `gems/tamoz-observability/lib/tamoz/observability/signal_catalog.rb:11`, `:236-245` (`:low_cardinality` is a 128-char charset, not a cardinality or secrecy claim); `gems/tamoz-agent/lib/tamoz/agent/worker.rb:137`, `:1032` (real callers pass `error.message` and interpolated request ids into `reason`).
- **Test/contract evidence**: `test/observability_runtime_test.rb:25-35` proves only the `Tamoz::Secret` class is refused. `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:162-184` (`observe doctor`) asserts the journal body lacks one literal secret and one literal token — a two-value smoke probe, not a property. `documentation/limitations.md:125` itself still lists "full all-surface secret property test" as outstanding. Probes P31/P33/P5/P7 (this audit, `/tmp/f15_probe10.rb`, `f15_probe1.rb`) stored `sk-live-…` verbatim in a captured `error_detail`, in a `provider` label, and in a `reason` attribute.
- **Scanner signal**: none — found by reading `ContentPolicy`'s full method list, which contains no scan/redact/detect step.
- **Independent judgment**: **Confirmed.** The policy is a *capture* policy, not a *secrecy* policy. The `Tamoz::Secret` guard is real and works (probe P32: attribute `Secret` → `:dropped`), and the default `NONE` policy is genuinely safe for content because it emits only digests. Both of those claims in `design/observability.md:47` are true. What the design doc's sentence "`Tamoz::Secret` is never admissible, above every policy decision" hides is that anything not wrapped in that class is admissible, above no policy decision — and enabling any capture class (the documented operator action) writes raw bytes with no shape check. The `reason` attribute and metric labels have no policy at all, not even the class guard.
- **Five whys**:
  1. Why can a secret reach a journal record? Because when a capture class is enabled, `attach_capture!` writes the raw canonical bytes, and there is no scan between canonicalization and the write.
  2. Why is there no scan? Because `ContentPolicy` implements admission-by-classification and byte bounds, and its only refusal test is `value.is_a?(Tamoz::Secret)` (`content_policy.rb:170`).
  3. Why is the refusal an identity test? Because the design frame is "the caller marks secrets with `Tamoz::Secret`" (`design/observability.md:47`), so secrecy is delegated to producer discipline rather than enforced at the sink.
  4. Why does producer discipline not hold? Because the fields most likely to carry credentials — exception `message`, request ids, provider/model labels — are ordinary strings passed on hot paths (`worker.rb:137`, `:1032`), and nothing translates them into `Secret`.
  5. Why was that gap not caught? Because no test asserts the property for a secret-shaped string; `observe doctor` checks two hard-coded literals, and `limitations.md:125` records the property test as outstanding. **Controllable cause**: the content sink has no shape-level guard and no property test pins one. **Contract that would prevent recurrence**: "no value written to a journal record or a metric label may match a credential shape, regardless of classification or content class."
- **Recommendation**: at the existing `ContentPolicy` seam, add one shape-level refusal in `canonicalize_string` (`content_policy.rb:201-206`) — the single point every captured string passes through — so a credential-shaped string is refused (or replaced by a digest) exactly as `Tamoz::Secret` is at `guard_value!`. For attributes and labels, the same predicate belongs in `DropLedger#validate!`'s catalog check and `Metrics#validate_label_value!`, which are already the two enforcement points. Do **not** build a new scanner class; the predicate is one regex over the value the sink is about to write. If the owner prefers to keep reliance on `Tamoz::Secret`, then promote the `observe doctor` literals into a property test over the shapes actually seen, and delete the "above every policy decision" sentence from the design doc so the boundary is stated honestly.
- **Disposition**: open — coordinator to decide between a sink-level shape guard and an explicit, documented producer-discipline contract. Either is acceptable; the current state is a doc claim that reads stronger than the code.

### F15-OBS-01 — `Metrics.from_documents` silently discards signals it cannot project, contradicting the design's "Never lossy"

- **Severity**: minor
- **Confidence**: high
- **Status**: open
- **Source evidence**: `gems/tamoz-observability/lib/tamoz/observability/metrics.rb:13-16` (`DURATION_METRICS` names exactly two signals), `:162-171` (`duration_metric_for` returns `nil` for everything else; `record_duration` returns early without a duration attribute), `:68-75` (`add_document` returns `:recorded` unconditionally on the non-raising path); `gems/tamoz-observability/lib/tamoz/observability/catalog.rb:148-182` (28 declared measurements, of which the projection can ever produce two); `documentation/design/observability.md:58` ("Reconstructed traces and derived gauges … Never lossy").
- **Test/contract evidence**: `test/observability_runtime_test.rb:116-133` tests cardinality rejection, not projection completeness; `test/observability_cli_test.rb:19-27` asserts only that the four JSON keys exist. Not found: any test that an unprojectable document produces a violation. Probes P45/P47: 3 documents in → 1 histogram out, `violations {}`; 5 `tamoz.agent.model.finish` signals → 0 metrics, `violations {}`.
- **Scanner signal**: none — found by comparing the 28-name `metric_catalog` against the 2-name `DURATION_METRICS`.
- **Independent judgment**: **Confirmed as a real gap, graded minor.** `add_document` reports `:recorded` for a document that produced no metric at all, so a caller cannot distinguish "projected, value 0" from "not projectable". The 28 declared measurements are aspirational — nothing in the repo calls `Metrics#increment`/`#observe`/`#set` outside this gem, so the derived-gauge surface is largely unpopulated. `tamoz observe metrics` will therefore return a near-empty document on real journals. I kept this minor rather than major because the failure is a documented-pending area (`limitations.md:121-126` covers the missing telemetry adapter and the outstanding divergence work) and because no decision is currently taken on this output — but the specific "Never lossy" sentence in `design/observability.md:58` is false as written and the loss is silent rather than counted.
- **Root cause** (concise): the projection was built for the two call sites that needed a live duration histogram, while the catalog was seeded with the full intended metric surface; nothing reconciles the two lists, and `add_document` has no "unprojectable" outcome so the gap is invisible at runtime.
- **Recommendation**: the smallest change at the existing seam is to make `add_document` count an unmatched name as a violation (`metrics.rb:68-75` already has `@violations` and `count_violation` for exactly this purpose), so the loss becomes visible in `tamoz observe metrics --format json`. Separately, correct `design/observability.md:58` to say the reconstruction is complete for projected signals and counted otherwise — or leave the doc and add the counter, which achieves the stated property in the form the code can actually deliver.
- **Disposition**: open — minor, doc-and-counter fix, no design decision needed.

### F15-COR-01 — `DropLedger#drops_hash` re-joins an already-joined key, emitting a malformed `name:reason:lane::` identifier

- **Severity**: minor
- **Confidence**: high
- **Status**: open
- **Source evidence**: `gems/tamoz-observability/lib/tamoz/observability/recorder_drop_ledger.rb:45-55` — `count_drop` stores `@drops[drop_key(name, reason, lane)] += 1` (a **String** key), while `drops_hash` destructures the stored key as a 3-tuple `|(name, reason, lane), count|` and calls `drop_key` on it again.
- **Test/contract evidence**: `test/observability_runtime_test.rb:121` asserts `recorder.health.fetch('drops').values.sum == 1` — it sums values, so it passes despite the malformed key. Probe P53 isolates the mixin: raw key `"invalid:validation:bulk"`, `drops_hash` → `{"invalid:validation:bulk::"=>1}`. Probes P13/P14/P54 show every reason is affected: `"tamoz.worker.error:queue_full:bulk::"`.
- **Independent judgment**: **Confirmed.** Ruby destructures the String key into `name = "invalid:validation:bulk"` with `reason`/`lane` = `nil`, and `drop_key` interpolates the two `nil`s into a trailing `"::"`. The human-facing drop identifier is therefore wrong in 100% of records. Counts and the `values.sum` consumers (`recorder_journal.rb:325-329`) are unaffected, which is why nothing failed — and why this is `minor` and not `major`. It is a real defect: the identifier is the operator's only way to read *why* a specific signal was dropped, and the design's "every drop is counted and inspectable" (`design/observability.md:68`) is weakened when the reason is intact but the key is malformed.
- **Root cause** (concise): the ledger changed from a tuple key to a pre-joined String key (to make `drops_hash` cheap) but the serialization side still assumes the tuple form; no test asserted the key's shape, only its summed value.
- **Recommendation**: one-line fix at the existing seam — make `count_drop` store the tuple (`@drops[[name, reason, lane]] += 1`) so `drops_hash`'s destructuring is correct as written, or make `drops_hash` return `@drops.to_h` directly since the key is already a String. Add a key-shape assertion to the existing saturation test. No new machinery.
- **Disposition**: open — minor, mechanical, fix at the ledger.

### F15-SCAL-01 — metric label cardinality is bounded by a series cap, not by value validation, so unvalidated label values consume the series budget

- **Severity**: minor
- **Confidence**: high
- **Status**: open
- **Source evidence**: `gems/tamoz-observability/lib/tamoz/observability/metrics.rb:142-149` (value check is `LOW_CARDINALITY_RE`, a charset and length rule), `:203-208` (`register_series!` refuses a *new* key once `max_series` is reached, with no eviction and no per-label bound), `gems/tamoz-observability/lib/tamoz/observability/signal_catalog.rb:11` (`LOW_CARDINALITY_PATTERN = /\A[a-zA-Z0-9_.:-]{1,128}\z/`), `gems/tamoz-observability/lib/tamoz/observability/catalog.rb:13-14`, `:162-166` (`provider`, `model`, `tool`, `profile`, `surface` declared `:low_cardinality`).
- **Test/contract evidence**: `test/observability_runtime_test.rb:123-127` proves a correlation identifier as a label *key* is rejected; `:135-151` proves the series cap engages. Not found: a test that a high-cardinality label *value* is rejected, or that a per-label-value bound exists. Probes P33/P46/P48/P49: a secret-shaped and a per-call-unique `model` string are both accepted; 5 000 distinct values yield exactly 4 096 series and 904 violations.
- **Independent judgment**: **Confirmed, and I am deliberately grading it minor.** The "no unbounded cardinality" property does hold in the sense the design claims (`design/observability.md:60`): series are hard-capped and the overflow is counted, so memory cannot grow without bound. What does *not* hold is the stronger reading of "reject high-cardinality values" — the check is a character class, so any 128-char token passes, and `model`/`tool`/`profile`/`surface` are exactly the fields a model name or a file path could arrive through. The consequence is bounded but not benign: junk series are admitted first-come and then legitimate series are refused (`register_series!` cannot tell them apart), so `tamoz observe metrics` degrades silently in exactly the situation an operator is investigating. I did not find a call site in this repo that passes a request id or file path as a label — `Metrics#increment`/`#observe`/`#set` have no non-test callers outside this gem — so the reachable impact today is small, which is what keeps this minor.
- **Root cause** (concise): the catalog's concern and the enforcement's concern were allowed to differ — the catalog declares a label *intent* (`:low_cardinality`) that the runtime checks as a *syntax* rule, so validation can never fail for the values the declaration was meant to exclude; the series cap then silently arbitrates.
- **Recommendation**: at the existing seam, the label values that can be enumerated should be enumerated. `outcome`, `kind`, `reason_class`, `status`, `direction` are already closed sets at their producers; declaring them `:enum` in `catalog.rb` and rejecting an out-of-set value in `validate_label_value!` closes the realistic path without new machinery. Leave `model`/`tool`/`profile` as-is and accept the series cap — chasing an allowlist for model names would be the speculative machinery the bar forbids.
- **Disposition**: open — minor, optional hardening; the series bound already prevents the unbounded-memory failure the brief asked about.

### F15-SCAL-02 — the reserved-lane fallback writes to disk while holding the journal mutex the drain thread needs

- **Severity**: minor
- **Confidence**: medium
- **Status**: open
- **Source evidence**: `gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb:83` (`route` wraps the decision in `synchronize`), `:90-97` (`accept_or_drop` reaches `write_reserved_now` in that same block), `:117-122` (`write_reserved_now` → `write_signal`), `:150-160` (`append_line` does `rotate_if_needed`, `open_io`, `write`, `flush`), `:162-168` (`rotate_if_needed` → `close_io` + `rotate_files`, i.e. `File.rename`/`File.delete`); `gems/tamoz-concurrency/lib/tamoz/concurrency/drain.rb:145-160` (`take_batch` needs the same `@mutex`).
- **Test/contract evidence**: probe P40 proves the intended behavior (5 safety-bearing signals into `reserved_size: 1` → 5 × `:recorded`, 0 drops, 5 lines on disk). Not found: any test or measurement of emit latency or drain stall when the reserved lane is saturated. No soak/load evidence exists for this path.
- **Scanner signal**: `documentation/limitations.md:124-125` itself lists the "four-way crash/non-interference proof" as outstanding.
- **Independent judgment**: **Confirmed as a design fact; the operational cost is unproven.** "Observation must never break the observed" is satisfied on the raising axis — `record` cannot raise (probe P41/P42), and the reserved lane cannot drop (probe P40). What is *not* proven is the blocking axis: `Recorder#record`'s documented contract is "MUST NOT block beyond the declared hand-off bound" (`recorder.rb:8-9`), and a full reserved lane does a full `File.open`/`write`/`flush`/potentially `File.rename` under the global journal mutex. I graded this `medium` confidence because I did not measure whether the stall is material under the real worker load, and because the reserved lane is 64 deep so the fallback should be rare. I am recording it because the contract sentence exists and the code does not obviously honor it, and because the crash/non-interference proof that would settle it is explicitly outstanding.
- **Root cause** (concise): "the reserved lane never drops" was implemented as a synchronous write at the point of refusal, and that point sits inside the lock that guards the queues; the guarantee was bought with lock hold time rather than with a second, independent write path.
- **Recommendation**: the smallest credible action is to move the reserved-lane fallback outside the mutex — decide the lane under the lock, and perform `write_reserved_now` after `synchronize` returns (`recorder_journal.rb:81-84`), which preserves never-drop while removing disk I/O from the critical section. If the owner prefers to keep the current shape, the honest alternative is to record the accepted bound: state in the `Recorder` contract that a saturated reserved lane may hold the journal lock for one bounded synchronous write, and let the outstanding non-interference proof measure it. Do not add a second writer thread.
- **Disposition**: open — minor, one of the two options above; needs the non-interference measurement before it could ever be called material.

### F15-OBS-02 — `Trace` produces a flat span list, never a parent chain, and `divergence` is structurally always empty

- **Severity**: minor
- **Confidence**: high
- **Status**: open
- **Source evidence**: `gems/tamoz-observability/lib/tamoz/observability/trace.rb:78-81` (`build_trace` hardcodes `divergence: []`), `:145-149` (`span_anchor` reads `attributes['span_anchor']` or `correlation['effect_key']` or `observed_at_ms`), `:156` (`parent_span_id` read from attributes), `:34`, `:39` (`divergence` is only ever set from the constructor's default); `documentation/design/observability.md:58` ("`tamoz trace` builds the authoritative span tree"), `:60` (the divergence signal); `documentation/limitations.md:121-126` (discloses both the journal-only reconstruction and the outstanding divergence accounting).
- **Test/contract evidence**: `test/observability_cli_test.rb:40-57` asserts a `trace_id` and a span count of 1; `test/observability_runtime_test.rb:161-178` asserts determinism. Not found: any test asserting a non-nil `parent_span_id`, a nested span, or a non-empty `divergence`. Repo-wide search: the only non-test reference to `span_anchor`/`parent_span_id` is `gems/tamoz-otel/lib/tamoz/otel/http_exporter.rb:118`, which reads `span_anchor` and never writes it. Probe P3: a two-document trace yields both spans with `parent=nil`.
- **Independent judgment**: **Confirmed.** The boundary stated in `limitations.md:123-124` — journal documents only, cannot claim the complete checkpoint/effect tree — is accurate and I verified it at `cli_worker_commands.rb:80-81`. The finding is that the *design* doc's "authoritative span tree" (`design/observability.md:58`) overstates what this code can produce: `Trace` has no correlation between spans other than a per-signal string attribute, and nothing in the repository writes that attribute, so the tree is one level deep by construction. `divergence` is likewise declared in the catalog (`catalog.rb:176`) and described as computed (`design/observability.md:60`) but is a hardcoded empty array. Both are disclosed in `limitations.md`, which is why this is `minor` and not `major` — the operational doc tells the truth and the design doc is the one that reads stronger than the code.
- **Root cause** (concise): span parentage was specified as a producer-supplied attribute, and the producers that would supply it (the durable checkpoint/effect path) are behind the unimplemented SQLite telemetry reader; the projection shipped with the journal-only path and kept the tree-shaped output contract.
- **Recommendation**: no code change is warranted until the read-only telemetry adapter exists (`limitations.md:121-123` already scopes this). The smallest credible action now is documentation: state in `design/observability.md:58` that the current projection is a flat, ordered span list whose parentage is supplied by producers and not yet emitted, and mark `divergence` as declared-but-not-computed. That makes the design doc agree with both the code and `limitations.md`.
- **Disposition**: open — minor, doc alignment; the real fix is the F07-adjacent telemetry adapter and belongs to that row.

### F15-INFO-01 — `documentation/limitations.md`'s observability claims verified against code

- **Severity**: info
- **Confidence**: high
- **Status**: closed (verified accurate)
- **Source evidence** and **judgment**: the section at `limitations.md:115-129` was checked claim by claim. Accurate: "closed signal catalog" (68 registered names — probe P8; unknown names refused at `signal_catalog.rb:46-50` and `notifier.rb:11`); "deterministic correlation" (`correlation.rb:17-29`, probe P3); "bounded local journal" (`recorder_journal.rb:16-18`, probes P13/P14); "content policy" (`content_policy.rb`, default `NONE` emits digests only — probe P30); "derived local metrics" (`metrics.rb`); "model cost basis" (`usage.rb:42-71`, `Cost::BASES` measured/estimated, `test/observability_runtime_test.rb:180-199`); "the local journal is observer-only and every bounded bulk drop is counted" (`recorder_journal.rb:99-115`, probes P13/P14). Accurate as a *limitation*: the SQLite read-only telemetry adapter and durable model-usage persistence are unimplemented (`telemetry_reader.rb:8-13` is `NotImplementedError`-only); `tamoz trace` reconstructs journal documents only (`cli_worker_commands.rb:80-81`); the four-way crash/non-interference proof, the full secret property test, export sampling and divergence accounting are outstanding (`exporter.rb:6-8` is contract-only; `trace.rb:78-81` hardcodes `divergence: []`; no soak evidence found). "Alerting and automated response are outside this phase" — consistent with `exporter.rb` having no implementation and no notification call site. **No contradicted claim found in this section.** The two doc claims contradicted by code are in `design/observability.md:58` ("Never lossy", "authoritative span tree") and `:47` ("above every policy decision"), recorded under F15-SEC-01 and F15-OBS-01/02.
- **Recommendation**: none. Verified design fact.

## Blind spots

- **`test/sqlite_trace_recorder_test.rb` was not run** (583 lines). It covers the SQLite trace recorder owned by row F07. I read the brief's note that `ShapeValidation` is the seam with this gem but I did not trace a call from that path into `tamoz-observability`, so I cannot state whether the recorder consumes `Signal`/`Trace` or merely mirrors the shape. If it does consume them, findings here may extend to F07. The coordinator should have the F07 analyst confirm the seam.
- **No measurement of the reserved-lane lock hold** (F15-SCAL-02). I proved the code path and the guarantee; I did not measure latency or drain stall under a saturated reserved lane, and no soak evidence exists in the repo to borrow. That is why it is `medium` confidence.
- **`tamoz-otel` was not audited.** I read `http_exporter.rb:118` only to establish that nothing writes `span_anchor`. The OTLP adapter's own conformance, egress rules and sampling are a different row.
- **Sampling was not exercised.** `design/observability.md:62-64` describes deterministic export sampling, but `exporter.rb` is contract-only and no sampler implementation exists in this gem, so there was nothing to trace. I did not look for a sampler in `tamoz-otel`.
- **The `Tamoz::Signals`/`stream.*`/`scheduler.*`/`mcp.*` permitted prefixes** (`signal_catalog.rb:12`) have no seeded entries in this gem. I did not check whether the owning gems register them at load; if any does, the "closed" catalog is closed per-process rather than globally, which would matter to F15's core claim. The seeded set here is 68 names, all `tamoz.*` and `comms.*` (probe P8).
- **`Immutable.copy`'s interaction with the notifier path** was read (`instrumentation.rb:21`) but not tested; I did not verify whether `reject_sensitive: true` there makes the `Signal`-level `Secret` guard redundant or whether it closes the plain-string gap. It does not close the shape gap either way, since it rejects by class too (`immutable.rb:28-30`).

## Verdict

**IMPROVE** — 0 critical, 1 major, 4 minor, 1 info.

The three claims the brief asked me to test most sharply resolve as follows. The catalog **is** genuinely closed: no caller can emit an arbitrary name, verified at all three entry points. Correlation **is** correct under concurrency and survives replay: it is a pure function of durable identity with JSON domain separation and no thread-local state, verified 400/400 across 8 threads. Bounded recording **does** count every drop and **cannot** break the observed caller: `flush` and `record` are both raise-free, the drop ledger distinguishes a drop from a never-emitted signal, and the reserved lane never drops. Prior finding 076 is genuinely resolved — the flush crash is gone and the `DropLedger`/`Journal` split is coherent.

The weakness is the security lens. There is no content-side secret policy: secrecy is delegated to producers wrapping values in `Tamoz::Secret`, while the fields most likely to carry credentials flow through as plain strings with a charset check. That is the one place where the code is weaker than `design/observability.md` claims, and it is the finding this row should carry forward. The remaining four minors are all narrow and fixable at existing seams; the metrics-projection and trace-projection gaps are honestly disclosed in `limitations.md` and are doc-alignment work rather than new machinery.
