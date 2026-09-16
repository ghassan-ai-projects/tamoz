# F01 tamoz-core — IMPROVE: the canonical digest rule collides in the integer regime, and one redaction refusal leaks the value it refuses

Row / queue / baseline (commit, date) / analyst / budget
- Row: **F01 — `tamoz-core`** ("Shared values, context, secrets, canonical digests, the durable-circuit engine, legacy sentinels").
- Queue: W1A (`COVERAGE.md:69`), previously `pending/pending/pending`.
- Baseline: branch `audit-15-09`, HEAD `582ae55`, 2026-09-15.
- Analyst: independent read-only functionality analyst (W2 lane), single pass.
- Budget: ~55 min target / 60 min cap. Read-only: no production code, test, config, gemspec, fixture, or doc outside the two allowed files was modified.

## Scope and source map

Read in full (`wc -l`, 32 `.rb` files / 4461 lines):

| File | Lines | Group |
|---|---:|---|
| `gems/tamoz-core/lib/tamoz/core.rb` | 241 | entry seam + shared helpers + sentinels |
| `gems/tamoz-core/lib/tamoz/core/jcs.rb` | 521 | canonical JSON (RFC 8785) + strict scanner |
| `gems/tamoz-core/lib/tamoz/state_codec.rb` | 478 | durable state allowlist codec |
| `gems/tamoz-core/lib/tamoz/circuit/record.rb` | 678 | durable-circuit record + transitions |
| `gems/tamoz-core/lib/tamoz/circuit/registry.rb` | 300 | 4 scopes + typed conditions |
| `gems/tamoz-core/lib/tamoz/error.rb` | 292 | error taxonomy + `safe_message` |
| `gems/tamoz-core/lib/tamoz/core/capability/descriptor.rb` | 260 | capability descriptor |
| `gems/tamoz-core/lib/tamoz/context.rb` | 188 | execution context |
| `gems/tamoz-core/lib/tamoz/core/capability/registry.rb` | 150 | sealed capability registry |
| `gems/tamoz-core/lib/tamoz/circuit.rb` | 143 | circuit facade + digestable boundary |
| `gems/tamoz-core/lib/tamoz/circuit/evidence.rb` | 138 | reset-authority gate |
| `gems/tamoz-core/lib/tamoz/configuration.rb` | 135 | process-global configuration |
| `gems/tamoz-core/lib/tamoz/immutable.rb` | 123 | bounded deep copy |
| `gems/tamoz-core/lib/tamoz/core/turn_context.rb` | 123 | durable follow-up turn context |
| `gems/tamoz-core/lib/tamoz/core/situation_recall.rb` | 94 | recall projection/result |
| `gems/tamoz-core/lib/tamoz/stream_part.rb` | 86 | stream part value |
| `gems/tamoz-core/lib/tamoz/task_result.rb` | 84 | task-result union |
| `gems/tamoz-core/lib/tamoz/instrumentation.rb` | 83 | instrumentation seam |
| `gems/tamoz-core/lib/tamoz/core/capability/source.rb` | 50 | capability source |
| `gems/tamoz-core/lib/tamoz/core/tool_error.rb` | 42 | D-7 tool-error taxonomy |
| `gems/tamoz-core/lib/tamoz/core/raw_http.rb` | 38 | raw HTTP framing |
| `gems/tamoz-core/lib/tamoz/store_entry.rb` | 36 | store entry value |
| `gems/tamoz-core/lib/tamoz/safe_text.rb` | 29 | bounded text normalizer |
| `gems/tamoz-core/lib/tamoz/core/request_identity.rs`→`.rb` | 26 | comms request identity |
| `gems/tamoz-core/lib/tamoz/secret.rb` | 22 | redaction value |
| `gems/tamoz-core/lib/tamoz/clock.rb` | 21 | monotonic clock |
| `gems/tamoz-core/lib/tamoz/core/capability.rb` | 16 | capability namespace |
| `gems/tamoz-core/lib/tamoz/notifier.rb` | 15 | null notifier |
| `gems/tamoz-core/lib/tamoz/core/protocol_error.rb` | 15 | protocol error |
| `gems/tamoz-core/lib/tamoz/core/capability/descriptor_conflict_error.rb` | 14 | sealed-registry error |
| `gems/tamoz-core/lib/tamoz/emitter.rb` | 13 | null emitter |
| `gems/tamoz-core/lib/tamoz/core/version.rb` | 7 | version |

Also read: `gems/tamoz-core/tamoz-core.gemspec` (only runtime dependency `zeitwerk ~> 2.6`), `gems/tamoz-core/README.md`.
Cross-gem caller traces (every public value graded here is traced to at least one real caller outside core):
`gems/tamoz-sqlite/lib/tamoz/sqlite/circuit_store.rb:49-54,70,126-127,161-164,201,239,249`;
`gems/tamoz-graph/lib/tamoz/graph/{command,send,interrupt,frontier,compiler,builder,checkpoint_codec}.rb`;
`gems/tamoz-agent-memory/lib/tamoz/agent/memory/surface.rb:19`;
`gems/tamoz-agent-session/lib/tamoz/agent/session_records.rb:471,504-507,22-26`;
`gems/tamoz-agent-kernel/lib/tamoz/agent/{episode_nodes.rb:666,effect_dispatcher.rb:254,273,intent_catalog.rb:29}`;
`gems/tamoz-stream/lib/tamoz/stream/decision_builder.rb:146,174,192,227,322-325`;
`gems/tamoz-tools/lib/tamoz/tools/toolbox.rb:101`, `gems/tamoz-tools/lib/tamoz/tools.rb:18-20`;
`gems/tamoz-observability/lib/tamoz/observability/{content_policy.rb:170,signal.rb:197}`;
`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:163`.

Entry seam: `require "tamoz/core"` → `Tamoz::Core` (`core.rb:54-62`) sets up one Zeitwerk loader, `eager_load`s the whole gem, and `loader.ignore`s `core.rb` itself and `core/version.rb`.

## Behavior path

**Digest path (the graded contract).** `Tamoz::Core.digest(domain, value)` → `JCS.digest` (`core.rb:108-110` → `jcs.rb:74-82`) → `domain + canonicalize(value)` → `emit` tag dispatch (`jcs.rb:112-131`) → `emit_object` (`jcs.rb:136-153`, keys stringified, dup-refused, sorted by `key.encode("UTF-16BE").b`) / `emit_array` (`155-163`) / `emit_string` (JCS minimal escape table, unpaired surrogates refused, `165-188`) / `integer_to_s` (`190-198`) / `float_to_s` (`200-208`) → `shortest_digits` (`212-236`) → `format_number` (`246-256`). Received bytes take the twin path `canonicalize_json` → `Scanner#parse_value` (`jcs.rb:269-291`), which refuses duplicate keys (`347`), leading zeros (`433`), non-finite numbers, negative zero (`461`), unpaired surrogates (`404-419`), and integers that do not round-trip through a double (`466-471`). Both are asserted to produce identical bytes by `test/canonical_cross_surface_composition_test.rb`.

**Durable state path.** `StateCodec#dump` (`state_codec.rb:203-214`) wraps the value in `["tamoz.state", 1, encoded]`; `encode_node` (`218-232`) rejects a `Tamoz::Secret` first and otherwise dispatches scalar/array/hash/registered; `load` (`216-229`) strict-parses with `create_additions: false`, checks the envelope, validates every node and the type allowlist, then decodes. Real callers: `Tamoz::Graph::Command` (`command.rb:6`), `Send` (`send.rb:7`), `Interrupt` (`interrupt.rb:13,36`), `Frontier` (`frontier.rb:31`), the graph `CheckpointCodec` (`checkpoint_codec.rb:40`) and the SQLite `Store` (`store.rb:13-15`).

**Durable circuit path.** `Tamoz::SQLite::CircuitStore#record_failure/record_success` (`circuit_store.rb:118-140`) reads the stored payload, builds a `Record` (`record.rb:69-85`), applies one transition (`with_failure` `346-364`, `with_success` `370-393`), and appends under a bounded CAS (`circuit_store.rb:245-259`). Opening is decided inside the transition by `met_conditions` (`470-495`) → `condition_met?` (`533-557`) per condition kind, then `opened` (`518-529`). The only path back to `closed` is `with_reset` (`397-413`), gated on the record write by `Evidence.validate!` (`evidence.rb:21-38`).

**Secrets path.** `Tamoz::Secret` (`secret.rb`) is the single redaction value; it is refused by `StateCodec#encode_node:144`, `Immutable.copy_value:28-30`, `Circuit.digestable:126-129`, `SessionRecords:504-507`, `Observability::ContentPolicy:170`, `Observability::Signal:197`, and rejected at digest time by `JCS#emit`'s catch-all (`jcs.rb:126-128`).

## Lens: correctness

**Canonicalization is deterministic for every input the producers accept.** Key ordering is UTF-16 code-unit order (`jcs.rb:143`, verified: `{"\u{10000}"=>1,"\uffff"=>2}` emits `{"𐀀":1,"\uffff":2}`, which is ES order, not codepoint order). `nil` and a missing key are different bytes (`{"a":null}` vs `{}`) and never conflated. Int/float are distinct on the state wire (`["integer",1]` vs `["float",1.0]`) and round-trip to `Integer`/`Float`. Unicode is passed through, not NFC-normalized — Ruby correctly finds no collision here, unlike the evals-side `CanonicalJSON` (`test/canonical_json_test.rb:37-42`), and that is the right call because NFC would silently merge distinct wire strings.

**Two gaps are proven, and they are the same gap seen from two sides.** `integer_to_s` (`jcs.rb:190-198`) deliberately exempts integers above `MAX_SAFE_INTEGER` from its round-trip check when `value == value.to_f`, then serializes them through `float_to_s` — i.e. through the *ES2015 Number::toString* rule, which is a shortest-**decimal** rule for a **binary** double, not an exact-decimal rule.

1. Two distinct integers in that regime produce identical canonical bytes; one of them is also structurally unparseable by the gem's own scanner.
2. Two distinct doubles (both of which the scanner happily produces) produce identical canonical bytes.

Measured (`/tmp/f01/jcs_probe4.rb`, `/tmp/f01/jcs_probe3.rb`):

```
jcs(2**60)               = 1152921504606847000      # 2**60 is 1152921504606846976
jcs(1152921504606847000) raises JCS::Error "not exactly representable as a double"
1152921504606847000.0 -> 1152921504606847000
1152921504606846976.0 -> 1152921504606847000        # identical bytes, identical digest
```

The producer is asymmetric: `canonicalize` accepts an integer that `canonicalize_json` refuses, and `JCS.digest` (used by `Circuit.digest_of`, `TurnContext.digest`, `Capability::Descriptor#compute_digest`, every graph/evals seal) silently emits the rounded text while `JCS.parse` of that same text raises. The comment at `jcs.rb:194-195` ("Go agrees with ES: 2**60 -> `1152921504606847000`") and the class comment at `jcs.rb:9-14` claim this is intended; the round-trip guard two lines above says the opposite. This is `F01-COR-01` (major, `open`).

**Circuit predicates are correct at their seams.** Rate is `>=` at the ceiling and counts successes (`test/circuit_record_test.rb:111-127`); a stale burst cannot combine with a fresh failure because `prune` requires `(now - observed) < window_ms` (`record.rb:644-651`); run conditions key on run + fingerprint and reset `counts` when the run changes (`597-611`); `bound_counts` keeps the highest counts and re-inserts the just-observed fingerprint so the bound cannot drop live evidence (`657-667`); evidence is deduped by digest and ordered by `[observed_at_ms, digest]` so racing writers merge to the same list (`637-642`).

**Record `load` validates the shape but not the policy.** `validate_scalars!` (`122-141`) checks `threshold >= 1` and `probe_window_ms.positive?` but never compares them to `Registry.fetch(scope)`. A stored record with `threshold = 999_999` or `probe_window_ms = 99_999_999` loads clean (probe-measured). `validate_owners!`/`validate_sub_state!` (`156-211`) verify the sub-state kind matches the id but never that `window_ms`/`max_rate`/`min_samples` match the registry condition — for `rate`, `condition_met?` reads `entry.dig(...,"events")` only (`546-553`), so a tampered `max_rate` key is inert, but this is validation by omission rather than by check. This is `F01-COR-04` (info/minor).

## Lens: security and authority

**Redaction is strong on every rendering path.** Probed (`/tmp/f01/leak_probe.rb`): `to_s`, `inspect`, interpolation, `format("%s")`, `Array#join`, `String()`, `puts` of a containing hash, nested hash/array `inspect` — every one of them renders `[REDACTED]` and never the value. `Secret` is not a `String` and does not respond to `to_str`, so `JSON.generate({"k" => secret})` produces `"[REDACTED]"` (silently wrong data, but not a leak). `secret_shaped?` (`core.rb:129-140`) does *not* detect a `Tamoz::Secret` object, but every consumer refuses the type before the pattern check (`Immutable:28`, `StateCodec:144`, `Circuit:126`), so this is not a bypass.

**One refusal echoes the secret — `F01-SEC-01` (major, `open`).** `Circuit.digestable` (`circuit.rb:126-129`) raises with a fixed literal, but its sibling catch-all at `circuit.rb:134-135` interpolates `value.class`, and — more importantly — `JCS#emit`'s catch-all does the same for a `Secret` that reaches it directly:

```
Tamoz::Core.jcs({"k" => Tamoz::Secret.new("sk-live-SUPER-SECRET-0123456789")})
  => Tamoz::Core::JCS::Error: unsupported canonical value: Tamoz::Secret
```

The *class name* is safe. The risk is the surrounding path: `Core.parse_object` interpolates the raw `JSON::ParserError#message` and the class comment at `core/protocol_error.rb:12-14` states in terms that "messages may quote provider text… the class deliberately does NOT include `Tamoz::DisclosableMessage`". A provider body echoed into a `ProtocolError` carries whatever the provider sent. The tmz-owned guard is `DisclosableMessage`'s documented rule (`error.rb:14-20`): a message must never interpolate "a provider payload, a third-party exception message, file contents, or a `Tamoz::Secret`". That rule is enforced by review only — no test plants a secret into an error message, and `test/secret_sweep_test.rb:21-28` stops at the rendered-string surfaces. The recommendation is therefore a **test** at the existing `NodeError#safe_message`/`disclosable_message` seam, not new machinery: the mechanism already exists.

**Authority boundary is correctly placed.** `Evidence.validate!` runs inside `Record#with_reset` and `with_retired_owner` (`record.rb:398,422`) and inside `Record.repaired` (`444`), so no in-process caller can reach `closed` without validated evidence (`evidence.rb:23-38`; per-scope rules `46-106`). `Registry` scopes pin `reset_authority`/`evidence_rule`/`in_flight_rule` as data (`registry.rb:169-260`). A refusal is `CircuitPolicyError` with `RETRYABLE = false` (`error.rb:213-216`), never a repairable result.

**Capability descriptor screening is fail-closed.** `Descriptor#validate!` calls `Core.secret_shaped?` over id, source_id, both digests, `protocol_profile`, `input_schema`, `output_schema`, `requested_scopes`, budgets and egress ref (`descriptor.rb:223-229`). Probed: a `sk-live-`-shaped value anywhere in `protocol_profile`, `input_schema` (including nested), or an `AKIA…` key in a nested schema array raises `SensitiveValueError`; a `Tamoz::Secret` raises through `JCS` earlier. `Registry.new` is closed (`capability/registry.rb:74-77`), a fifth source is refused (`enforce_built_in_sources!` `86-98`), cross-source descriptor ids collide loudly (`build_registry` `122-131`), and descriptor ownership is enforced so a "local" source cannot surface an `mcp:` descriptor (`104-115`).

## Lens: reliability and durability

**`StateCodec` round-trips faithfully for everything it accepts.** Probed: `1` vs `1.0` preserved, `2**62` preserved exactly, unicode preserved, `-0.0` preserved, unknown future envelope version refused with `CheckpointVersionError` *before* any decode, unsorted/duplicate object keys refused, `create_additions: false` so no Ruby object injection, decoder result class and immutability re-checked (`decode_registered` `424-435`), decoder failures wrapped without echoing messages (`436-441`), `registered` payloads re-enter `encode_node` so a `Secret` hidden inside a registered payload is still refused.

**The `MAX_REGISTRATIONS` cap is unreachable — `F01-REL-02` (minor, `open`).** `add_registration` (`state_codec.rb:96-104`) copies the whole registration list on every call, so `validate_registrations!`'s `length > MAX_REGISTRATIONS` (256) check (`435-438`) can only fire if a caller passes all 257 at construction. Probed: applying `add_registration` 257 times raises `ConfigurationError` from individual registrations long before the cap is relevant. The cap reads as a live bound but is not one.

**A stored record's `threshold`/`probe_window_ms` are loadable but not registry-bound.** See `F01-COR-04`; the durability consequence is that a store-side rewrite can lengthen the probe-observation window without tripping validation, and `probe_allowed?` (`record.rb:321-328`) trusts the stored value.

**Circuit state machine is sound and terminal states are terminal.** `STATES = %w[closed open]` (`circuit.rb:52`). `with_success` on an open record returns `open` (probed); only `with_reset` (with evidence) returns `closed`; `opened_at_wall_ms` is set once (`opened`, `524`) and `validate_open_state!` refuses an open record with no open time (`143-147`). The read-time self-heal rule (`effective_state` `288-292`, `healed` `309-316`) means a kill between the crossing failure and the write cannot lose an open that the evidence supports.

**No silent-open path found.** `with_failure` probes all owner × condition pairs and opens with at least one evidence entry; the owner-map overflow path fails closed with `CircuitPolicyError` rather than silently dropping evidence (probed: 65th owner, and `with_success` for an unseen owner, both raise; `with_success` for a known owner on a full map still works and can still open, `record.rb:370-393`). `circuit_store#record_failure` returns `:open` immediately when the stored payload is corrupt (`circuit_store.rb:119,134`), so corruption fails closed too.

**Probe-window timing has no race.** `probe_allowed?` returns `false` at `now < opened`, `false` for `now == opened`, and `true` from `now >= opened + probe_window_ms` (probed at `opened`, `opened+window-1`, `opened+window`, and at a rolled-back clock). A backend clock rollback can never enable an early probe.

## Lens: observability and evidence

**Opening is always observable.** Every open carries a `conditions_met` entry with `condition`, `owner`, a domain-separated `digest` (`CONDITIONS_DIGEST_DOMAIN`), `observed_at_ms`, and `reason` ∈ {`threshold`, `self_heal`} (`record.rb:479-491`, `518-521`). Health is the derived triple `:closed`/`:degraded`/`:open` (`300-305`) that `CircuitStore#record_failure/success` returns (`circuit_store.rb:132,140`). Reset carries `last_reset_at` plus `last_reset_evidence` as a digest only, never the evidence itself (`record.rb:404-412`); `conditions_digest` (`500-511`) correlates a reset with the failure state it cleared across a restart.

**Honest gap.** `DisclosableMessage` is a review-enforced convention, not a checked one (`error.rb:14-20`); grep finds no assertion that any error message is secret-free. That is `F01-SEC-01`'s observability half: the evidence surface that would report the failure is exactly the surface at risk.

## Lens: scalability and resource bounds

Every collection in the circuit record is explicitly bounded and the bound is *enforced on load*, not only on write:
`MAX_CIRCUIT_OWNERS = 64` checked on write (`enforce_admission!` `559-566`) and on load (`validate_owners!` `158-160`, probed: 201 owners refused);
`MAX_CONDITIONS_MET = 32` ring-buffered on append (`append_evidence` `641`) and checked on load (`215-217`);
`MAX_WINDOW_EVENTS = 64` (`bound_events` `653-655`, load `194-196`);
`MAX_RUN_FINGERPRINTS = 32` (`bound_counts` `657-667`, load `204-207`);
`MAX_IDENTITY_BYTES = 256` on every identity (`identity!` `88-98`).
`StateCodec` bounds bytes, depth, total collection items and per-string bytes on both `dump` and `load` (`validate_input_bytes` `443-455`, `count_items!` `428-433`), with hard ceilings on the configured values (`bounded_integer!` `471-475`, `MAX_BYTES 64 MiB`).
`JCS::Scanner` bounds nesting at `MAX_NESTING = 512` (`273-281`) and short-circuits on the first malformed token.
`Immutable.copy` bounds depth (64), total items (100k) and per-string bytes (1 MiB) and refuses cycles by live-container `object_id` (`immutable.rb:22-26,37,85-95`).
`Instrumentation` caps the payload at 4096 bytes per string and refuses to run the application block twice (`instrumentation.rb:6,51-53`).
The one unexercised bound is `MAX_REGISTRATIONS` (`F01-REL-02`).

## Lens: maintenance and architecture

**The circuit registry owns domain vocabulary it does not own the domain for.** `registry.rb:169-260` hardcodes all four scopes and every condition id: `consecutive_transport_failures`, `verification_failed_in_window`, `compensation_failed`, `fingerprint_repeat_in_run`, `unknown_effect_for_safe_retry`, `budget_exceeded`, `detector_confidence_below_gate`, `artifact_unverifiable`, `consecutive_remediation_failures`, `consecutive_execution_failures`, `consecutive_connect_failures`, `budget_breach`. These are MCP-transport, rule-remediation and scheduler concepts living in the foundation gem, justified by the DR-2 "one engine, one registry" decision (`circuit/registry.rb:5-17`). The gem's own README says core "contains no graph, persistence, provider, network, or model behavior" (`README.md`), which this contradicts in spirit though not in dependency direction. This is `F01-MNT-01` (minor).

**The public surface is checked and the checked list omits the interesting names.** `test/public_api_test.rb:167-221` pins `tamoz-core` by name and passes (3 runs, 1051 assertions), but the pinned list contains 49 constants while the gem defines materially more public values that other gems actually consume and that no contract test names: `Tamoz::Circuit` and its whole `Record`/`Registry`/`Evidence` surface (consumed at `circuit_store.rb:49-54,70,126-127,161-164,201,239,249`), `Tamoz::Core.deep_dup` (`record.rb:268,352,374,424`; `stream/decision_builder.rb`), `Tamoz::Core.jcs`/`digest`/`verify_digest` (every digest site in the repo), `Tamoz::Core.digestable`-adjacent circuit helpers, `Tamoz::Core::Capability::*` (nine constants), `Tamoz::Core::SituationRecall::*`, `Tamoz::Core::TurnContext`, `Tamoz::StoreEntry`, `Tamoz::Core::JCS`, `Tamoz::Core::SENTINEL`s. Those values are reachable and load-bearing, but the "narrow public surface" claim is only asserted for the subset the test happens to enumerate. This is `F01-MNT-02` (minor).

**`Core.deep_freeze`'s stringify-and-freeze behaviour is relied on by the circuit record, so it cannot be changed.** `Record#initialize` freezes the incoming payload through it (`record.rb:248`), and everything downstream (`owners.dig`, `entry.fetch("failures", 0)`, `replace` building string-keyed merges) assumes string keys. `Circuit.digestable` (`circuit.rb:131-132`) stringifies keys before digesting. The 058 rejection ("`Core.deep_freeze` would break `**Profile.deep_freeze(members)`") is **still recorded and is not contradicted**, but I could not reproduce a `**` failure on Ruby 3.3.11: `def f(**k); k; end; f(**Core.deep_freeze({a: 1}))` succeeds and yields `{"a"=>1}`, and even `f(**Core.deep_freeze({"a"=>1, b: 2}))` succeeds. The *substantive* half of 058's rejection is confirmed and is stronger than the `**` argument: `Profile.deep_freeze` freezes in place and preserves key types, so `f(**Profile.deep_freeze({a: 1}))` yields `{a: 1}` (symbol) while `f(**Core.deep_freeze({a: 1}))` yields `{"a"=>1}` (string) — a silent key-type change at the `Fields#initialize` seam, with no exception to announce it. Recorded as `F01-MNT-03` (info) because the two are genuinely different operations and no change is recommended.

**`F01-MNT-04` (minor) — a validation bound expressed as a different structural rule.** `Record#load` re-validates everything except the registry binding (see `F01-COR-04`); the same pattern appears at `validate_scalars!` accepting any positive `probe_window_ms`.

## Tests and contracts

All commands run from `/Users/ghassan/my-projects/tamoz` with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`, one file per command. All green:

| Command | Result |
|---|---|
| `ruby -Itest test/canonical_json_test.rb` | 6 runs / 8 assertions / 0F |
| `ruby -Itest test/core_state_codec_test.rb` | 13 runs / 149 assertions / 0F |
| `ruby -Itest test/circuit_record_test.rb` | 13 runs / 25 assertions / 0F |
| `ruby -Itest test/public_api_test.rb` | 3 runs / 1051 assertions / 0F |
| `ruby -Itest test/dependency_isolation_test.rb` | 22 runs / 221 assertions / 0F |
| `ruby -Itest test/canonical_cross_surface_composition_test.rb` | 1 run / 106 assertions / 0F |
| `ruby -Itest test/secret_sweep_test.rb` | 12 runs / 26 assertions / 0F |
| `ruby -Itest test/core_context_test.rb` | 10 runs / 247 assertions / 0F |
| `ruby -Itest test/core_jcs_vectors_test.rb` | 14 runs / 73 assertions / 0F |
| `ruby -Itest test/core_turn_context_test.rb` | 3 runs / 4 assertions / 0F |
| `ruby -Itest test/core_instrumentation_test.rb` | 9 runs / 29 assertions / 0F |
| `ruby -Itest test/core_stream_test.rb` | 12 runs / 46 assertions / 0F |
| `ruby -Itest test/core_pool_test.rb` | 11 runs / 137 assertions / 0F |
| `ruby -Itest test/graph_checkpoint_codec_test.rb` | 4 runs / 22 assertions / 0F |
| `ruby -Itest test/sqlite_circuit_store_test.rb` | 11 runs / 48 assertions / 0F |
| `ruby -Itest test/websearch_circuit_test.rb` | 8 runs / 33 assertions / 0F |
| `ruby -Itest test/context_control_exposure_test.rb` | 6 runs / 58 assertions / 0F |

Totals: **158 runs / 2283 assertions / 0 failures / 0 errors**. `rake ci` / `rake ci_full` deliberately **not run** (brief). `test/immutable_test.rb`, `test/safe_text_test.rb`, `test/secret_test.rb`: **not found** — those values are covered indirectly by `core_context_test.rb`, `core_stream_test.rb` and `secret_sweep_test.rb`; there is no direct unit test of `Immutable.copy`'s depth/cycle/item bounds or of `SafeText.normalize`'s byte/control-character errors.

Gaps in the contract surface, by name:
- `test/core_jcs_vectors_test.rb` (14 runs) pins the shared vectors and one digest (`:43`); it does not cover the `integer_to_s` exemption — no row exercises an integer above `2**53`.
- `test/canonical_json_test.rb` exercises `Tamoz::Evals::CanonicalJSON` (the evals-side dumper), not `Tamoz::Core::JCS`; its NFC assertions (`:37-49`) do not apply to the core canonicalizer, which does not normalize.
- `test/circuit_record_test.rb` states its own gap in its header comment: only `rate` and `run` are driven directly; consecutive/window/immediate come from `test/sqlite_circuit_store_test.rb`.
- No test plants a credential in an error message (`F01-SEC-01`).
- No test loads a tampered circuit record with a re-written `threshold`/`probe_window_ms` (`F01-COR-04`).

## Findings

### F01-COR-01 — the canonical digest rule collides above `2**53` and accepts a value its own parser refuses
- **Severity**: major. **Confidence**: high. **Status**: open.
- **Source evidence**: `gems/tamoz-core/lib/tamoz/core/jcs.rb:190-198` (`integer_to_s`; the `value.abs <= MAX_SAFE_INTEGER || value == value.to_f` exemption and the `return float_to_s(value.to_f) if value.abs > MAX_SAFE_INTEGER` line); `jcs.rb:246-256` (`format_number`, the ES2015 decimal form); `jcs.rb:212-236` (`shortest_digits`); contrast `jcs.rb:466-471` (`Scanner#number_from`, which raises for the same text); `jcs.rb:9-14` and `jcs.rb:194-195` (the comments asserting the behaviour is intended). Consumed by `gems/tamoz-core/lib/tamoz/circuit.rb:78-81`, `gems/tamoz-core/lib/tamoz/core/turn_context.rb:92`, `gems/tamoz-core/lib/tamoz/core/capability/descriptor.rb:110-112`.
- **Reproduction**: `ruby /tmp/f01/jcs_probe4.rb` and `/tmp/f01/jcs_probe3.rb` (read-only probes against `gems/tamoz-core/lib`). `Tamoz::Core.jcs(2**60) #=> "1152921504606847000"`, while `Tamoz::Core.jcs(1152921504606847000)` raises `Tamoz::Core::JCS::Error: integer 1152921504606847000 is not exactly representable as a double`. `Tamoz::Core.jcs(1152921504606846976.0) == Tamoz::Core.jcs(1152921504606847000.0) #=> true`, and their `Tamoz::Core.digest` values are equal.
- **Test/contract evidence**: `ruby -Itest test/core_jcs_vectors_test.rb` → 14 runs / 73 assertions / 0F; it does not exercise any integer above `2**53`. `ruby -Itest test/canonical_json_test.rb` → 6 runs / 8 assertions / 0F; it tests the evals-side dumper, not `JCS`. No row anywhere pins the `integer_to_s` exemption.
- **Scanner signal**: manual read of `jcs.rb` against the class comment's claim that producers "reject … integers that do not round-trip through an IEEE-754 double" (`jcs.rb:11-14`).
- **Independent judgment**: confirmed by direct execution against the current source. The trigger conditions are narrow — a JSON-shaped integer above `2**53` that is exactly a double. I did **not** find an in-repo producer of such a value (epoch-ms is ≈1.76e12, well under `2**53`; no counter in the audited path reaches that regime), so this is not a live false-completion today. What is proven is that the property the module documents and that the wire contract depends on (`CONTRACTS.md §2-3`, one digest rule for "anything that is hashed, persisted, compared, or replayed") does not hold at the boundary the code itself carves out, and that the boundary is asymmetric between the producer and the parser.
- **Root cause (five whys)**: (1) Two different integers digest identically. (2) `integer_to_s` routes integers above `2**53` through the float formatter rather than the exact-decimal formatter. (3) The float formatter implements ES2015 `Number::toString`, a shortest-*round-tripping* rule that is correct for a binary double and therefore cannot be exact. (4) The exemption was written to make Go's `encoding/json` output agree for `1e20`-class values, and the round-trip guard above it was left in place for the smaller magnitudes — so the code carries two contradictory rules about the same value. (5) The design cause is that "canonical bytes" was defined as "what Go's encoder emits" rather than as "a total, injective function on the accepted value set", and the contract test that would have caught it (`core_jcs_vectors_test.rb`) covers only the magnitudes the vectors happen to use. The contract that prevents recurrence is an injectivity property: for any two distinct accepted values, the canonical bytes differ.
- **Recommendation**: at the existing `integer_to_s` seam, drop the exemption and raise for every `|n| > MAX_SAFE_INTEGER` (the branch that is already there for the non-round-tripping case), so the producer's accepted set and the parser's accepted set coincide. If a caller genuinely needs exact-int text, `StateCodec` already carries `["integer", n]` with full precision and is the right seam. One added row in `test/core_jcs_vectors_test.rb` asserting that the producer refuses what `JCS.parse` refuses is the smallest contract that would hold the line.
- **Disposition**: open. Independent challenge required before any closure: confirm whether any in-repo writer can produce an integer of that magnitude (I found none), and confirm with the Go side whether `1152921504606847000` is a required wire literal — that answer decides between *fix* and *document the accepted-value set explicitly*.

### F01-SEC-01 — the redaction rule is enforced by review only, and `error.rb` states it in terms the path cannot honour
- **Severity**: major. **Confidence**: medium (the mechanism gap is proven; the reachable leak is not). **Status**: open.
- **Source evidence**: `gems/tamoz-core/lib/tamoz/error.rb:14-20` (the `DisclosableMessage` contract, which forbids interpolating "a provider payload, a third-party exception message, file contents, or a `Tamoz::Secret`" but is enforced by the including class's author); `gems/tamoz-core/lib/tamoz/error.rb:63-72` (`NodeError#safe_message`, default-deny, opt-in via `DisclosableMessage`); `gems/tamoz-core/lib/tamoz/core/protocol_error.rb:12-14` ("Messages may quote provider text (the JSON parser's message)"); `gems/tamoz-core/lib/tamoz/core.rb:195-197` (`Core.parse_object` interpolating `error.message`); `gems/tamoz-core/lib/tamoz/core/jcs.rb:126-128` (`JCS#emit` catch-all raising with `value.class`); `gems/tamoz-core/lib/tamoz/circuit.rb:134-135` (the `digestable` catch-all). Working redaction for contrast: `gems/tamoz-core/lib/tamoz/secret.rb:14-20`, `state_codec.rb:144`, `immutable.rb:28-30`, `circuit.rb:126-129`.
- **Reproduction**: `ruby /tmp/f01/leak_probe.rb`. All direct render surfaces are clean (`to_s`, `inspect`, `%s`, interpolation, `Array#join`, `puts`, nested hash/array). `Tamoz::Core.jcs({"k" => Tamoz::Secret.new("sk-live-…")})` raises `JCS::Error: unsupported canonical value: Tamoz::Secret` — class name only, no value. `Tamoz::Core.secret_shaped?(Tamoz::Secret.new("sk-live-…"))` returns `false` (the pattern set matches strings, not the wrapper).
- **Test/contract evidence**: `ruby -Itest test/secret_sweep_test.rb` → 12 runs / 26 assertions / 0F. Its last row (`test/secret_sweep_test.rb:208-217`) asserts only the rendered-string surfaces. No test in the repository plants a credential in an error message or asserts that a raised message is secret-free: **not found** on grep across `test/`.
- **Scanner signal**: grep for `Secret` across `gems/` and `test/` — the refusal sites are all type checks; no message-content assertions.
- **Independent judgment**: I confirmed the positive guarantee (a `Secret` cannot be *rendered* or *persisted* through any path I could reach) and confirmed that the refusal messages themselves carry no value. I could **not** construct an end-to-end leak from this repository alone: that needs a caller that wraps a provider/third-party exception into a `DisclosableMessage`-marked error. So the finding is recorded at the level that is actually proven — a guard with no test and a documented rule whose stated prohibition (no third-party exception message, no provider payload) is directly contradicted by `ProtocolError`'s own comment three files away. `core.rb:129-140` returning `false` for a `Tamoz::Secret` is a lead, not a finding: every consumer refuses the type first.
- **Root cause (five whys)**: (1) The secret-containment guarantee holds at runtime but is not held by any check. (2) The rule lives as prose in `error.rb:14-20` and is applied by whoever writes the raising class. (3) `safe_message` is default-deny at the *receiving* boundary but nothing constrains the *producing* message, so a marked class's text is trusted wholesale. (4) `DisclosableMessage` was added as an opt-in marker for a small D-7 family, and the family grew (`ToolError` `core/tool_error.rb:19`, `InterruptInNonInteractiveEpisodeError` `error.rb:274`) without a corresponding check. (5) The design cause is that "our message is safe" was treated as a property of the class rather than an observable of the message; the contract that prevents recurrence is that a marked class's message must be shown to be free of secret-shaped and provider-shaped text.
- **Recommendation**: smallest credible action at the existing seam — one row beside the current rows in `test/secret_sweep_test.rb` that takes each `DisclosableMessage` includer, constructs the message with a planted credential, and asserts the raised message matches none of `Tamoz::Core::SECRET_VALUE_PATTERNS`. No new class, no new module; `SECRET_VALUE_PATTERNS` (`core.rb:47-52`) is already the single canonical set and `Core.secret_shaped?` (`core.rb:129-140`) is already the check.
- **Disposition**: open. Needs independent challenge on whether any real caller wraps a third-party exception into a `DisclosableMessage` includer; if one does, this escalates from a test gap to a live leak.

### F01-MNT-01 — the foundation gem owns the domain vocabulary of the gems above it
- **Severity**: minor. **Confidence**: high. **Status**: open.
- **Source evidence**: `gems/tamoz-core/lib/tamoz/circuit/registry.rb:169-260` (`SERVER`, `RULE_TARGET`, `SCHEDULE`, `EGRESS` and every condition id literal: `verification_failed_in_window`, `compensation_failed`, `fingerprint_repeat_in_run`, `unknown_effect_for_safe_retry`, `detector_confidence_below_gate`, `artifact_unverifiable`, `consecutive_remediation_failures`, `consecutive_execution_failures`, `consecutive_connect_failures`, `budget_breach`); `gems/tamoz-core/lib/tamoz/core.rb:36-40, 24-28` (`TOOL_ERROR_CLASS_NAMES` maps core names back to `Tamoz::Agent::*`; `INTENT_WATCH_TYPE` is an intent-catalog wire value); `gems/tamoz-core/lib/tamoz/core/raw_http.rb:4-7` (a test-support HTTP framing helper homed in a production gem); `gems/tamoz-core/README.md` ("It contains no graph, persistence, provider, network, or model behavior").
- **Test/contract evidence**: `ruby -Itest test/dependency_isolation_test.rb` → 22 runs / 221 assertions / 0F; it proves *load* isolation (`test_core_loads_only_its_declared_runtime_boundary`, `dependency_isolation_test.rb:52-60`) and passes — the dependency direction is honest. The finding is not about dependency direction.
- **Independent judgment**: confirmed by reading. I rejected the stronger claim: there is **no** upward dependency (core requires nothing from any sibling; probed: zero matches for `Concurrency`/`Cancellation`/`Pool`/`StreamSink` under `gems/tamoz-core/lib`, so the README's "now live in tamoz-concurrency and tamoz-cancellation" is accurate). The cost is maintenance: a new remediation condition or a new scheduler budget rule requires editing the foundation gem, which is the reverse of the repo's stated ownership direction.
- **Root cause**: (1) Adding a scope condition means editing `tamoz-core`. (2) All four scopes were authored together in DR-2 to guarantee "one set of transition rules in this repository" (`circuit/registry.rb:5-17`). (3) Entity literals were the cheapest way to guarantee that. (4) DR-2 chose correctness-by-single-file over ownership-by-gem. (5) The design cause is that the registry is code where the repo's own B9/P4 rule puts domain knowledge in data; the contract that would prevent recurrence is that scope/condition vocabulary is loaded, not compiled in.
- **Recommendation**: smallest credible action at the existing seam — leave the code; record the exception explicitly in `gems/tamoz-core/README.md` next to the "no graph/persistence/provider" claim, naming `Circuit::Registry` as the one intentional domain table and why. No refactor: a sixth scope has not appeared, and the working convention says not to build for cases that have not occurred.

### F01-MNT-02 — the pinned public-surface contract covers 49 names and omits the values every gem actually consumes
- **Severity**: minor. **Confidence**: high. **Status**: open.
- **Source evidence**: `test/public_api_test.rb:167-221` (the `"tamoz-core"` block: 49 entries); `gems/tamoz-sqlite/lib/tamoz/sqlite/circuit_store.rb:49-54,70,126-127,161-164,201,239,249` (consumes `Circuit::Registry`, `Circuit.identity!`, `Circuit.owner_id!`, `Circuit.namespace_for`, `Circuit.scope_digest`, `Circuit::Record.load/initial/repaired`, `Record::FailureEvent`, `Circuit.context_digest`, `Circuit::Evidence.validate!`, `Circuit::DIGEST_PATTERN` — none of which appear in the pinned list); `gems/tamoz-core/lib/tamoz/circuit/record.rb:268,352,374,424` and `gems/tamoz-stream/lib/tamoz/stream/decision_builder.rb` (consume `Core.deep_dup`).
- **Test/contract evidence**: `ruby -Itest test/public_api_test.rb` → 3 runs / 1051 assertions / 0F. The test passes; the finding is that passing it does not mean the surface is narrow.
- **Independent judgment**: confirmed by diffing the test's `tamoz-core` list against the constants the traced callers use. I rejected reading this as "the public API is too wide": the circuit and capability surfaces are deliberately shared contracts (that is why they live in core), and narrowing them would break `tamoz-sqlite`. The gap is that the contract test's claim and the gem's actual contract do not cover the same set.
- **Root cause**: (1) The most-depended-on values in the gem are the ones the contract test does not name. (2) The pinned list was extended when each constant was added, but the circuit and capability surfaces were added with their own tests instead. (3) Those tests exercise behaviour, not the public-surface boundary. (4) `public_api_test.rb` is a per-gem enumeration with no derived cross-check against what sibling gems reference. (5) The design cause is a manual list standing in for an observable; the contract that prevents recurrence is that the pinned list and the consumed set are reconciled.

### F01-REL-02 — `MAX_REGISTRATIONS` is expressed as a bound that `add_registration` cannot reach
- **Severity**: minor. **Confidence**: high. **Status**: open.
- **Source evidence**: `gems/tamoz-core/lib/tamoz/state_codec.rb:96-104` (`add_registration` constructs a fresh codec from `[*@registrations, …]`) and `state_codec.rb:435-438` (`validate_registrations!` raising above `MAX_REGISTRATIONS`). `MAX_REGISTRATIONS = 256` at `state_codec.rb:18`.
- **Reproduction**: `/tmp/f01/codec_stale.rb` — applying `add_registration` 257 times in a loop never reaches the cap; individual registrations fail on the tag pattern first. The only way to trip it is `StateCodec.new(registrations: [257 entries])`.
- **Test/contract evidence**: `ruby -Itest test/core_state_codec_test.rb` → 13 runs / 149 assertions / 0F; no row exercises the cap (`grep -n "MAX_REGISTRATIONS" test/` → not found).
- **Independent judgment**: confirmed by source read plus probe. The bound is not wrong, it is simply not the bound an incremental caller meets. Rewriting the cap as "a caller that keeps registering will fail on tag patterns / duplicate tags long before 256" would be more honest than a numeric ceiling that reads as live.
- **Related observation from the same probe (recorded, not a finding)**: because `add_registration` copies, a codec built by chaining is a *different object* from its base, and `base.load(registered_wire)` raises `CheckpointVersionError`. That is correct and intended; it matters only because the production composition path (`Tamoz.graph` → `Tamoz::Graph::Builder#initialize` → `StateCodec.new` at `builder.rb:21`, `compiler.rb:10`, `adapter.rb:86`, `store.rb:13`) builds a **fresh, unregistered** codec by default. Only `Surface.codec` (`tamoz-agent-memory/lib/tamoz/agent/memory/surface.rb:19`) registers one, so no production durable state currently dies for this in the paths I traced.

### F01-COR-04 — a stored circuit record's `threshold` and `probe_window_ms` load without being bound to the registry
- **Severity**: minor. **Confidence**: high. **Status**: open.
- **Source evidence**: `gems/tamoz-core/lib/tamoz/circuit/record.rb:122-141` (`validate_scalars!`: integer/positivity only), `record.rb:321-328` (`probe_allowed?` trusts the stored `probe_window_ms`), `record.rb:533-557` (`condition_met?` trusts the stored accumulator over the registry condition). Compare the checks that *are* policy-bound: `validate_owners!` `177-179` (owner carries an unregistered condition ⇒ corrupt), `validate_registered_node!` in `state_codec.rb:405-410` (unknown tag/version ⇒ `CheckpointVersionError`).
- **Reproduction**: `/tmp/f01/circuit_probe.rb` — `Record.load(payload.merge("probe_window_ms" => 99_999_999), scope: "server")` returns a record whose `probe_window_ms` is `99999999`; the same for `"threshold" => 999_999`. By contrast `"state" => "half"`, `"opened_at_wall_ms" => nil` on an open record, and 201 owners are all refused.
- **Test/contract evidence**: `ruby -Itest test/circuit_record_test.rb` → 13 runs / 25 assertions / 0F; `ruby -Itest test/sqlite_circuit_store_test.rb` → 11 runs / 48 assertions / 0F. Neither tampers with a stored record's scalars.
- **Independent judgment**: confirmed. The exploitability is low — the caller must already be able to write the circuit row's bytes, and `probe_window_ms` only lengthens the observation wait. The `rate` predicate is *not* exploitable by tampering because `condition_met?` reads only `events` and takes `window_ms`/`max_rate`/`min_samples` from the registry (`546-553`), which is the right structure. Recorded as minor because the load path advertises itself as shape-and-policy validation (`record.rb:93-101`) and one policy dimension is missing.
- **Recommendation**: add the two comparisons to `validate_scalars!` where the scope is already in hand (`validate!(payload, scope, scope_id)` `93-101`): `threshold == scope.threshold` and `probe_window_ms == scope.probe_window_ms`, each raising `CheckpointCorruptionError` like its neighbours. This matches the existing `validate_scope!` style and needs no new type.

### F01-MNT-03 — prior finding 058's `deep_freeze` interaction: rejection holds, recorded reason does not reproduce
- **Severity**: info. **Confidence**: high. **Status**: closed (verified against current source).
- **Source evidence**: `gems/tamoz-core/lib/tamoz/core.rb:152-165` (`deep_freeze` stringifies and freezes keys); `gems/tamoz-core/lib/tamoz/circuit/record.rb:248` (the record freezes its payload through it, so the string-keyed shape is load-bearing); `gems/tamoz-core/lib/tamoz/circuit.rb:131-132` (`digestable` stringifies); `docs/audits/top100-audit-2026-09-11/058-profile.md:24-30`.
- **Reproduction**: `/tmp/f01/df_probe.rb`, `/tmp/f01/jcs_probe.rb`. `Tamoz::Core.deep_freeze({a: {"b" => 1}})` → `{"a"=>{"b"=>1}}`, all keys frozen `String`s. `def f(**k); k; end; f(**Tamoz::Core.deep_freeze({a: 1}))` → `{"a"=>1}` on Ruby 3.3.11 — **no raise**. A keyword-arg receiver constructed with a canonicalized hash therefore *succeeds* with string keys instead of raising.
- **Independent judgment**: the substantive half of 058's rejection is confirmed and is in fact stronger than the recorded reason. `Profile.deep_freeze` preserves key types; `Core.deep_freeze` changes them silently, so `Fields#initialize`'s `**Profile.deep_freeze(members)` would start receiving `String` keys where it currently receives `Symbol`s — a silent key-type change at that seam, which is a *good* reason not to substitute. The literal claim "would raise there" did not reproduce. **The 039 rejection also still holds**: `with_failure` mutates its copy (`record.rb:352-356`), so the frozen, string-keyed `deep_freeze` result cannot be used on that path; `Core.deep_dup` (`core.rb:173-180`) is the correct counterpart and is in use at `record.rb:268,352,374,424`. `Record::FailureEvent` (`record.rb:34-38`) and the zero-`ParameterLists` state recorded by 039 are intact — `with_failure(owner_id:, now_ms:, event:)` is 3 parameters (`record.rb:346`) and `apply_failure_condition(entry, condition, event, now_ms:)` is 4 (`568`).
- **Recommendation**: none. Correct as it stands; the correction belongs to the historical note, not to the code.

### Prior findings carried forward — current status
- **Top-100 087 (`state_codec.rb`)**: all three remediations are present in current source. `encode_node`/`validate_node!` are pure tag dispatch over extracted handlers (`state_codec.rb:218-232`, `273-285`); `add_registration` is the renamed method and no `with_registration` remains (grep: one match, the definition at `:96`); `count_items!` is one method parameterized by `error:` (`:428-433`) and the load path passes `error: CheckpointCorruptionError` (`:369,381`). **Status: closed, verified.** The file is 478 lines (087 recorded 466) — the growth is the doc/comment density, not new dispatch.
- **Top-100 039 (`circuit/record.rb`)**: `Core.deep_dup` is shared by `Circuit::Record` and the stream decision builder, and both private copies are gone (grep for `def deep_copy` / `def deep_dup` under `gems/`: no matches outside `core.rb:173`). `FailureEvent` exists with the recorded shape and defaults. `ParameterLists` is zero for the transition surface. The `[major][SIZE]` item ("split the condition engine out of `Record`") remains **open** as recorded — `record.rb` is 678 lines and still mixes schema validation (`93-236`), the predicate engine (`533-667`), and the transition surface — which is the size/cohesion judgement 039 already made and this audit is not re-litigating. **Status: 2 of 3 closed; the major size item still open, unchanged.**
- **Top-100 058 (`profile.rb`)**: read per the brief. The `deep_freeze` interaction is recorded as `F01-MNT-03` above. The file itself is outside this row.

## Blind spots

- **The Go side of the parity digest was not read.** `sha256:e4f86620…` (`test/agent_intent_catalog_test.rb:117`) and the protocol SHA (`test/benchmark_protocol_test.rb:134` → `documentation/benchmark/BENCHMARK_PROTOCOL.json`) are pinned here and pass, but whether the Go encoder emits `1152921504606847000` for `2**60` is the single fact that decides `F01-COR-01`'s fix-vs-document disposition. Not readable from this checkout.
- **`documentation/benchmark/BENCHMARK_PROTOCOL.json` was not opened.** The protocol SHA assertion passes in `test/benchmark_protocol_test.rb`, which is the contract; the file's own contents were out of the row's source surface.
- **No live caller producing a value above `2**53` was found, and I did not exhaustively search for one.** I checked epoch-ms magnitudes (≈1.76e12), redirected counters, and the six pinned digests. A full producer sweep across 27 gems was out of budget; this is the main reason `F01-COR-01` is `major` rather than `critical`.
- **`gems/tamoz-concurrency` and `gems/tamoz-cancellation` were not read.** The README claims the thread substrate and `Pool`/`StreamSink` moved there and core no longer references them; I verified the absence of references from core (`grep` under `gems/tamoz-core/lib`: zero matches), not their contents. So "is anything thread-local that must not be" is answered for `tamoz-core` only: `Tamoz::Context` is a frozen value (`context.rb:69`) holding only frozen data (`Immutable.copy`), `Clock::Monotonic::INSTANCE` and `Emitter::Null::INSTANCE` are frozen singletons, and the single piece of process-global mutable state is `Tamoz.configuration` behind `@configuration_mutex` with a generation check (`configuration.rb:98-134`) — correctly shared, not thread-local. Whether the *consumers* keep per-thread values is not this row.
- **`gems/tamoz-agent-session/lib/tamoz/agent/session_records.rb` was read only at its `Secret` gate (`:504-507`) and sentinel sites.** The rest of the session-record durability path is another row's surface.
- **`TLS`/network paths were not exercised.** `RawHttp` is framing only and is out of the graded contract here.
- **No load/soak evidence.** All bound claims come from source reading and single-value probes; no concurrency stress was run against the circuit CAS (that is `gems/tamoz-sqlite`'s row) or against `StateCodec`.

## Verdict

**IMPROVE** — 0 critical, 2 major, 4 minor, 1 info.

Counts by severity: `F01-COR-01` (major), `F01-SEC-01` (major), `F01-MNT-01`, `F01-MNT-02`, `F01-REL-02`, `F01-COR-04` (minor), `F01-MNT-03` (info). The verdict is driven by the two majors, per BAR.md ("`IMPROVE` when it has at least one accepted critical/major finding"): the canonicalization injectivity gap sits on the digest rule that every other gem's integrity check is built from, and the redaction guarantee is a runtime behaviour with no contract holding it.

The foundation itself is in good shape on the parts that matter most: the circuit engine's state machine, terminality, evidence authority gate, probe timing, and every resource bound are sound and, in several places, defended on the load path as well as the write path; `StateCodec` round-trips faithfully and fails closed on every input I could construct; `Context` is correctly immutable and shares no mutable state; the dependency direction is honest and proven by `dependency_isolation_test.rb`. Both majors are boundary-shaped — a value set the code declares but does not close, and a rule stated in prose but not in a check — and both have a smallest-credible remedy at a seam that already exists.
