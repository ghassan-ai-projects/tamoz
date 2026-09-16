# F16 `tamoz-otel` — a well-built egress boundary that nothing can reach; its governability is therefore unproven, and its attribute path has no content policy and no OTLP/JSON typing

Row / queue / baseline (commit, date) / analyst / budget
- Row: **F16**, queue **W4B**, responsibility "Optional governed OTLP/HTTP exporter".
- Repo: `/Users/ghassan/my-projects/tamoz`, branch `audit-15-09`, HEAD `582ae55`.
- Analyst: independent functionality analyst (lane B). Budget ~35 min, hard cap 60.
- Read-only. No production code, test, config, gemspec, fixture, or doc was modified.

## Scope and source map

Real files read, end to end, with line counts.

Source surface (the row, 403 lines including gemspec/version):

| File | Lines | Role |
|---|---|---|
| `gems/tamoz-otel/lib/tamoz/otel.rb` | 13 | entry point; requires observability + concurrency + 3 local files |
| `gems/tamoz-otel/lib/tamoz/otel/egress_policy.rb` | 85 | endpoint/credential/bounds validation |
| `gems/tamoz-otel/lib/tamoz/otel/http_exporter.rb` | 170 | OTLP/JSON body construction and the synchronous POST |
| `gems/tamoz-otel/lib/tamoz/otel/async_exporter.rb` | 113 | bounded queue, backoff, failure-limit disable |
| `gems/tamoz-otel/lib/tamoz/otel/version.rb` | 7 | `0.1.0.alpha.1` |
| `gems/tamoz-otel/tamoz-otel.gemspec` | 15 | dependency declaration |

Seam consumed (`tamoz-observability`): `exporter.rb` (11), `correlation.rb` (32),
`content_policy.rb` (230), `signal.rb` (225), `recorder_journal.rb` (340),
`recorders.rb` (127), `recorder.rb` (19), `catalog.rb:176-177` (signal names).
Substrate: `gems/tamoz-concurrency/lib/tamoz/concurrency/drain.rb` (224).

Entry seam: `Tamoz::Observability::Exporter` (`exporter.rb:5-9`) — `open`/`export`/`close`.
`HTTPExporter` includes it (`http_exporter.rb:11`) and **no other implementer exists**.

Caller sweep (`grep -rn "Otel\|OTLP\|otel" gems/*/lib apps/ bin/ script/`):
the only non-`tamoz-otel` hits are the words "remotely" inside two comments
(`tamoz-comms/lib/tamoz/comms/transport.rb:35`,
`tamoz-telegram/lib/tamoz/telegram/transport.rb:9`) and a manifest string
(`script/generate_requirements_manifest:592`). Nothing requires, constructs, or
configures this gem. The gemspec's only dependents are `Gemfile:35` (a dev
`path:` line) — see lens: maintenance.

## Behavior path

1. **Construction / gating.** `EgressPolicy#initialize` (`egress_policy.rb:14-24`)
   parses the endpoint URI, coerces `allow_local`, bounds `timeout_ms` to
   `1..30_000` (`:17`, `MAX_TIMEOUT_MS` `:10`), bounds `max_batch` to `1..10_000`
   (`:18`), normalizes `credential_ref` to an env-var name (`:19`, `:51-62`),
   runs `validate_endpoint!` (`:20`, `:64-75`) and **freezes** the value (`:21`).
   `validate_endpoint!` requires `scheme == 'https'` (`:65`), a host (`:66`), no
   `userinfo` (`:67`), no query/fragment (`:68`), and — unless `allow_local` —
   refuses `localhost`/`localhost.localdomain` and private/loopback/link-local IP
   literals (`:69-74`, `private_ip?` `:77-82`).
2. **Open.** `HTTPExporter#open` (`http_exporter.rb:24-34`) resolves the credential
   to an `Authorization` header via `credential_headers` (`:92-102`): the value is
   fetched from `@env` by name (`:95`), empty is refused (`:96`), **any `\r`/`\n`
   is refused** (`:97`) — a header-injection guard. Any failure resets `@opened`,
   `@headers` and `@descriptor` (`:29-33`) and returns `:rejected`. The `descriptor`
   becomes the OTLP `resource.attributes` (`:26`, used at `:134`).
3. **Export.** `HTTPExporter#export` (`:36-83`) refuses unless opened (`:37`),
   refuses a non-Array or an oversized batch (`:38`), refuses when **any** proxy
   env var is set (`:39`, `proxy_configured?` `:104-108`), builds the body
   (`:41`), refuses a body over 16 MiB (`:42`), resolves the host (`:44`,
   `egress_policy.rb:30-33`) and re-validates the **resolved** addresses against
   the private-IP rule (`:45`, `egress_policy.rb:35-41`) — this is the DNS-rebinding
   guard. It then builds a `Net::HTTP::Post` (`:47-50`), constructs the connection
   with `use_ssl = true` (`:52`), **pins** `http.ipaddr` to the first validated
   address (`:53`), sets `VERIFY_PEER` (`:54`), clamps the timeout to
   `min(caller deadline, policy timeout)` (`:55`), rejects a non-positive timeout
   (`:56`), and sets **both** `open_timeout` (`:58`) and `read_timeout` (`:59`).
   The response body is streamed with a 16 MiB cap (`:62-70`, `MAX_RESPONSE_BODY_BYTES` `:12`).
   Status mapping: `2xx → :delivered`, `429 → :throttled`, `3xx → :rejected`
   (redirects never followed), everything else `→ :unknown` (`:73-78`).
4. **Body construction.** `resource_spans` (`:110-135`) `filter_map`s each item:
   it reads `correlation`, `attributes`, `observed_at_ms`, `name` (`:113-116`),
   derives `trace_id` from `correlation.trace_id` or `Correlation.trace_id`
   (`:117`, `:141-147`), derives `span_id` from `attributes.span_id` (note: from
   **attributes**, not correlation) or `Correlation.span_id` keyed on
   `span_anchor || effect_key || observed_at_ms` (`:118-119`, `:149-153`), skips
   the item unless both ids exist (`:120`), maps `started_at_ms`/`ended_at_ms` to
   nanoseconds (`:129-130`), and emits the OTLP/JSON envelope
   `resourceSpans[0].scopeSpans[0].spans` with `kind = SPAN_KIND_INTERNAL` (`:124-134`).
   Ids are normalized to lowercase hex 32/16 chars, otherwise re-hashed (`:155-167`).
5. **Async wrapper.** `AsyncExporter` (`async_exporter.rb:9`) extends
   `Concurrency::Drain`. `initialize` (`:10-24`) validates `max_queue`,
   `batch_size`, `failure_limit` as positive integers (`:12-14`) and `interval_ms`
   in `1..60_000` (`:15-18`), then calls `super(lanes: { export: max_queue }, ...)`
   (`:23`) — a single bounded lane, created as a real frozen queue plus one
   background thread (`drain.rb:14-27`). `record` (`:34-47`) counts and drops on
   closed/disabled/queue-full. `deliver_batch` (`:74-76`) calls
   `@exporter.export(batch, deadline_ms: 2_000)`. `delivery_result` (`:80-83`)
   accounts under the mutex, then disables the drain once failures reach the limit.

## Lens: correctness

**Reviewed.** The pure functions are correct and the boundary refusals are real;
the body-building path is where correctness fails.

- Endpoint, credential, batch, size, deadline, proxy and address guards all behave
  as documented; verified by probe (P9/P9b/P10/P15/P17) and by the shipped test
  file (`test/otel_test.rb`, 6 runs).
- Identity derivation is deterministic and idempotent: already-hex ids pass
  through unchanged (`:157`, `:164`), otherwise a namespaced SHA-256 prefix is
  used (`:159`, `:166`). Probe P2/P11 produced 32/16-char ids matching the test's
  assertion (`test/otel_test.rb:50-51`).
- **The emitted span is not valid OTLP/JSON.** `resource_spans` copies the
  document's `attributes` straight into the span (`:131`) and the `descriptor`
  straight into `resource.attributes` (`:134`). The `Signal` contract permits
  `Symbol` attribute values (`signal.rb:159` — `when Integer, Symbol, TrueClass,
  FalseClass, NilClass then value`) and unbounded `Integer` values. OTLP/JSON
  `KeyValue.value` is a typed `AnyValue` (string/bool/int/double/array/kvlist);
  a Ruby `Symbol` serializes through `JSON.generate` as a bare JSON **string**
  (accidentally acceptable by luck), and any integer outside int64 serializes as
  an unquoted literal. Probe P13 emitted exactly
  `"attributes":{"ok":1,"sym":"a_symbol"}`; probe P3 emitted
  `"big":1000000000000000000000000000000` for `10**30`. The former is unreconciled
  against the contract but survivable; the latter is outside the OTLP int64 range
  and a strict collector rejects the batch. Either way the exporter never
  validates that its own output conforms to the protocol it names. See **F16-COR-01**.
- The declared `gen_ai` attribute mapping
  (`documentation/design/observability.md:12`, `docs/OBSERVABILITY_DESIGN.md:33`,
  `docs/OBSERVABILITY_PLAN.md:226`) **does not exist in the code**: `grep -rn "gen_ai"`
  returns no hit under `gems/`. Attributes pass through verbatim; no mapping,
  rename, or semantic-convention translation is performed. See **F16-COR-02**.

## Lens: security and authority

**Reviewed — and this is the row's headline.** The gem is off by default in the
strongest possible sense, and that is precisely why its governance is unproven.

- **Off by default: confirmed, and then some.** Nothing enables it. `grep -rn
  "AsyncExporter\|HTTPExporter\|EgressPolicy\|Observability::Exporter"` across the
  repo matches only `test/otel_test.rb` and the gem's own files. No production
  gem, app, `bin/`, or `script/` constructs an exporter. `Tamoz::OTel` is loaded
  only by `test/test_helper.rb:61`. The catalog declares
  `tamoz.telemetry.export` (`catalog.rb:177`) but **no code emits it** — grep for
  the name finds only the catalog and its test. The `tamoz-agent` calls that
  `documentation/design/observability.md:14` describes ("`tamoz-agent` loads it
  lazily when a runtime directory configures observability") do not exist in
  `gems/tamoz-agent/lib` or `gems/tamoz-agent-cli/lib`. There is no CLI command,
  flag, config key, or environment variable that turns export on. See **F16-SEC-01**.
- **No untrusted enable path.** Because there is no enable path at all, a config
  file in a workspace, a model reply, or an MCP server cannot enable or redirect
  export. This is a real, verified property, not a gap.
- **Redirect/SSRF controls are strong where they do run.** Non-https refused
  (`egress_policy.rb:65`), userinfo refused (`:67`), query/fragment refused (`:68`)
  — so a query string cannot smuggle a second destination; localhost and private
  literals refused (`:69-74`); resolved addresses re-checked (`:35-41`) and the
  connection pinned to a validated address (`http_exporter.rb:53`), which closes
  the check-then-connect race; redirects mapped to `:rejected` and never followed
  (`:76`); all six proxy variables checked (`:105`); `VERIFY_PEER` (`:54`);
  credential newline-injection refused (`:97`); credential stored by name only,
  never inlined (`egress_policy.rb:51-62`).
- **Two residual authority questions.** (a) `allow_local` (`egress_policy.rb:16`)
  is a plain boolean constructor argument with no policy-data binding; the
  repository's own convention is that authority lives in
  `gems/tamoz-approval/policy/*.yaml`. (b) The address re-validation
  (`http_exporter.rb:45`) is skipped entirely when `allow_local` is true
  (`egress_policy.rb:36`), so an opted-in sidecar config has no post-resolution
  guard. Both are contract/policy observations on a path no caller can currently
  reach; recorded as info, not findings.

## Lens: security and authority — content policy on export

**Reviewed — this lens fails.** The priority question was whether the exporter
applies the same redaction/content policy to exported spans as to the local
journal. **It does not, and it does not pass the governing digest either.**

- The journal merges a policy digest into every line it writes
  (`recorder_journal.rb:147`: `signal.to_h.merge('policy_digest' => signal.policy_digest
  || @policy_digest)`).
- The exporter's `resource_spans` reads exactly five keys — `correlation`,
  `attributes`, `observed_at_ms`, `name`, and the two timestamps
  (`http_exporter.rb:113-123`). Probe P12 enumerated what is dropped:
  `["kind", "schema_version", "timing", "duration_ms", "content", "policy_digest", "outcome"]`.
  **`policy_digest` never reaches the wire.**
- `ContentPolicy` (`content_policy.rb`) is never referenced anywhere in
  `gems/tamoz-otel/` — no require, no mention. The `attributes` value is copied
  by reference (`http_exporter.rb:131`). Probe P1 confirmed verbatim egress:
  `{"prompt"=>"SECRET-PROMPT-TEXT", "tool_arguments"=>"rm -rf /",
  "content"=>{"input_messages"=>"raw user text"}, "nested"=>{"deep"=>["a","b"]}}`
  appeared unchanged in the span.
- In practice today the local `ContentPolicy` already keeps prompt text out of
  `attributes` (content lives in the separate `content` field), so this is not a
  live leak — which is why this is **major, not critical**. But the design
  promise "two runs can be proven to have sent the same prompt without the prompt
  leaving the machine" (`documentation/operations/observability-ops.md:78-81`)
  is a claim about the *signal*, and the exporter has no independent guarantee:
  the instant anyone attaches content-bearing or oversized values to `attributes`,
  they leave the machine with no redaction, no truncation, and no policy digest
  to prove what policy applied. See **F16-SEC-02**.

## Lens: reliability and durability

**Reviewed.** Failure isolation is mostly good; the timeout policy has one
inconsistency.

- `export` rescues everything: `ResponseTooLarge → :rejected` (`:79-80`),
  `StandardError → :unknown` (`:81-82`). The seam contract "must not raise"
  (`documentation/design/observability.md:64`) holds. A hostile or broken
  collector cannot raise into a caller.
- Connect **and** read timeouts are both set (`:58`, `:59`), clamped to the
  minimum of the caller deadline and the policy timeout (`:55`), with a
  non-positive timeout rejected (`:56`). Response bodies are streamed and capped
  at 16 MiB (`:62-70`), so a hostile collector cannot exhaust memory by
  streaming an unbounded body — a genuinely good control.
- Retry is bounded and counted: `failure_limit` disables the drain permanently
  (`async_exporter.rb:82`, `:98-100`), backoff is exponential capped at 30 s
  (`:93`), and a success resets both (`:87-89`). Probe P8 confirmed
  `{"queue_depth"=>0, "drops"=>{"unknown"=>2, "disabled"=>18}, "failures"=>2, "disabled"=>true}`.
- **Timeout inconsistency.** `AsyncExporter#deliver_batch` hardcodes
  `deadline_ms: 2_000` (`async_exporter.rb:75`), discarding the policy's own
  `timeout_ms`. Probe P14: with `timeout_ms: 25_000`, the exporter still received
  `deadline_ms=2000`. Since `HTTPExporter` takes the *minimum* (`:55`), a
  deliberately configured long timeout can never take effect through the async
  path — the configured bound is silently overridden. See **F16-REL-01**.
- **Synchronous export blocks the caller.** `HTTPExporter#export` is a blocking
  `http.start` (`:60-72`). Probe P15 against a blackhole address returned
  `:unknown` after **1.51 s** with `timeout_ms: 1_500`, i.e. the calling thread
  was blocked for the full deadline. The async wrapper keeps this off the
  producer's thread, but `HTTPExporter` is a public API
  (`test/public_api_test.rb:330`) whose direct use is synchronous. Bounded by
  policy (`MAX_TIMEOUT_MS = 30_000`), so this is a documented-shape concern, not
  an unbounded stall.
- Durability: none claimed and none present, correctly — the plane is explicitly
  not durable (`documentation/design/observability.md:64`), and `on_thread_exit`
  calls `close(deadline_ms: 0)` (`async_exporter.rb:103`), i.e. it does not block
  process exit to flush. That matches the stated design.

## Lens: observability and evidence

**Reviewed — materially incomplete.** This is the row's other substantive gap.

- The async wrapper has real internal accounting: `health` (`async_exporter.rb:49-58`)
  reports `queue_depth`, `drops` by reason (`closed`/`disabled`/`queue_full`/result
  key), `failures`, and `disabled`. Probe P7 confirmed
  `{"queue_depth"=>3, "drops"=>{"queue_full"=>198}, "failures"=>0, "disabled"=>false}`.
- **But none of it is emitted as a signal.** `tamoz.telemetry.export` is declared
  in the closed catalog (`catalog.rb:177`) and never produced by any code. Export
  outcome (`:delivered`/`:throttled`/`:unknown`/`:rejected`) therefore exists only
  as a return value and an in-memory counter; after the process exits there is no
  evidence that a batch was ever attempted, delivered, or dropped. A reader
  inspecting the journal sees no trace of export at all.
- **Divergence accounting is absent.** `limitations.md:126` lists "divergence
  accounting" as outstanding, and this is confirmed: `tamoz.telemetry.divergence`
  is declared (`catalog.rb:176`) but nothing emits it, and `gems/tamoz-otel/`
  contains no divergence logic whatsoever (grep for `rate|sample|sampling|divergence`
  in the gem returns only the unrelated `JSON.generate` at `:41`).
- **The exported span drops the outcome.** `outcome` is in the `Signal` `to_h`
  (`signal.rb:70`) but is not read by `resource_spans` (P12). A failed or unknown
  span therefore arrives at the collector indistinguishable from an `:ok` one —
  the collector cannot tell a refused turn from a successful one. See **F16-OBS-01**.
- The `resource.attributes` descriptor (`:134`) is emitted exactly as the caller
  passed it, with no service-name default and no validation; probe P4 showed
  `{"service.name"=>"x", "host.name"=>:sym}` passing through with a `Symbol`
  value. A collector that requires a resolvable service identity gets none unless
  the caller supplied one.

## Lens: scalability and resource bounds

**Reviewed — the bounds are real and the buffering is bounded.**

- Queue: one lane bounded at `max_queue` (default `1_024`, `async_exporter.rb:10`),
  enforced by `accept` (`drain.rb:101-112`, `return false if queue.length >= @lanes.fetch(lane)`).
  Drop-newest on saturation, counted (`async_exporter.rb:42-45`).
- Batch: `batch_size` (default `256`, `:10`) bounds each `compose_batch`
  (`drain.rb:114-117`); `HTTPExporter` independently refuses any batch over
  `policy.max_batch` (`http_exporter.rb:38`, default `256`, `egress_policy.rb:14`,
  ceiling `10_000`).
- Body: 16 MiB cap before send (`http_exporter.rb:42`) and 16 MiB cap on the
  response stream (`:62-70`).
- Memory held while the collector is down: bounded by `max_queue` × average
  signal size. **Probe P8/P7 confirm no unbounded growth**: on persistent failure
  the drain disables entirely (`failure_limit`, `:82`) rather than accumulating,
  and once disabled every subsequent `record` is counted and dropped
  (`:36-39`) — probe P8 showed `disabled: true` with 18 counted `disabled` drops.
  This is the correct answer to "unbounded buffering": there is none.
- Time: no unbounded wait. `open_timeout`/`read_timeout` (`:58-59`) and the
  30 s `MAX_TIMEOUT_MS` ceiling (`egress_policy.rb:10`) bound each attempt, and
  backoff is capped at 30 s (`async_exporter.rb:93`).
- One scaling caveat: `Socket.getaddrinfo` (`egress_policy.rb:31`) is called
  **on every export** (`http_exporter.rb:44`), i.e. once per batch, rather than
  cached. Under a high batch rate this is a repeated blocking DNS resolution on
  the drain thread. Bounded by the batch interval, so a minor cost note, not a
  finding.

## Lens: maintenance and architecture

**Reviewed.** Dependency direction is honest and the API surface is narrow — the
strongest part of this row.

- **Dependency direction confirmed.** `tamoz-otel.gemspec:11-14` declares exactly
  `tamoz-concurrency` and `tamoz-observability`. Nothing else.
  `gems/tamoz-observability/tamoz-observability.gemspec` does **not** mention
  `tamoz-otel`. Sweeping every `*.gemspec` in the repo for `tamoz-otel` returns
  only its own file; the sole external reference is `Gemfile:35`, a development
  `path:` line, which does not create a runtime dependency. The gem stays
  optional. **This confirms the priority question as a verified pass.**
- ADR-044 (`adr-044-...md:11-14`) requires each exporter to pass "the contract
  gem's conformance suite". No conformance suite exists: `exporter.rb:5-9` is a
  bare module with three `NotImplementedError` methods and no assertions, and
  `test/otel_test.rb` tests `HTTPExporter` directly without ever exercising the
  seam. The adapter is structural (`include`) but unverified against a contract.
  See **F16-MNT-01**.
- Public surface is exactly three classes plus `VERSION`
  (`test/public_api_test.rb:327-332`, run: 3 runs / 1051 assertions / 0 failures).
- Vocabulary is consistent with the rest of the repo (`open`/`export`/`close`,
  `validate_*`, `EgressPolicy`), and the gem reuses `Concurrency::Drain` rather
  than reimplementing it (`async_exporter.rb:9`, per `drain.rb:5-6`) — the
  codebase's "extend, don't reinvent" convention is followed.
- **Dead surface.** Since nothing constructs these classes, all 403 lines are
  currently unreachable in production. That is the honest architectural fact
  behind F16-SEC-01: the boundary is built and tested but not wired, so
  `limitations.md:119`'s "hardened optional OTLP/HTTP adapter are implemented" is
  true only in the "code exists and its own guards pass" sense, not in the
  "operators can turn it on" sense. `documentation/operations/observability-ops.md:88-90`
  describes it as usable and states installations without it "report a typed
  missing-adapter error for export" — no such error class exists for OTLP
  (`MissingAdapterError` at `cli_comms_shared.rb:21` is comms-only).

## Tests and contracts

Commands run (one file per command, from the repo root with the rbenv prefix):

| Command | Result |
|---|---|
| `ruby -Itest test/otel_test.rb` | **6 runs, 17 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/public_api_test.rb` | **3 runs, 1051 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/observability_catalog_test.rb` | **10 runs, 26 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/concurrency_drain_test.rb` | **7 runs, 36 assertions, 0 failures, 0 errors, 0 skips** |

`test/otel_test.rb` covers: endpoint scheme/loopback refusal (`:6-13`), local
opt-in and credential-as-reference (`:15-24`), proxy-env refusal on export
(`:26-31`), OTLP span shape (`:33-53`), credential-failure state clearing
(`:55-65`), and resolved-address refusal (`:67-73`). All pass.

**Not found** (each is an evidence gap, not an implied pass):

- No test constructs `AsyncExporter` — `grep -rln "AsyncExporter" test/` matches
  only `test/public_api_test.rb` (an existence assertion at `:328`). So the queue
  bound, drop accounting, backoff, failure-limit disable, and close path are
  **untested**. Probes P6/P7/P8/P14 exercised them ad hoc for this audit only.
- No test asserts that a redaction or content policy is applied to an exported
  batch.
- No test asserts that the emitted body is valid OTLP/JSON, or round-trips it
  through any decoder.
- No test asserts the `Exporter` seam contract against `HTTPExporter`.
- No test asserts a timeout on connect or read, or a non-followed redirect.
- No test asserts sampling, the `tamoz.telemetry.export` signal, or divergence
  accounting — none of which exist.
- Not run: `rake ci`, `rake ci_full` (excluded by the brief).

## Findings

### F16-SEC-01 — The governed exporter has no enable path; its governance is unproven and its documented operational story is not implemented

- **Severity:** major
- **Confidence:** high
- **Status:** open
- **Source evidence:** `gems/tamoz-otel/lib/tamoz/otel/http_exporter.rb:11`
  (`include Tamoz::Observability::Exporter` — the only implementer);
  `gems/tamoz-observability/lib/tamoz/observability/exporter.rb:5-9` (bare seam,
  `NotImplementedError`); `gems/tamoz-observability/lib/tamoz/observability/catalog.rb:177`
  (`tamoz.telemetry.export` declared); `gems/tamoz-otel/tamoz-otel.gemspec:11-14`
  (dependencies). Absence evidence: repo-wide grep for
  `AsyncExporter|HTTPExporter|EgressPolicy|Observability::Exporter` outside the
  gem and `test/otel_test.rb` returns nothing; grep for `otel` across
  `gems/*/lib apps/ bin/ script/` returns only two "remotely" comment matches and
  one manifest string; `Tamoz::OTel` is required only at `test/test_helper.rb:61`.
- **Test/contract evidence:** `ruby -Itest test/public_api_test.rb` → 3 runs /
  1051 assertions / 0 failures (asserts the classes *exist*, nothing about
  wiring). `not found`: no test constructs `AsyncExporter` outside an existence
  assertion (`test/public_api_test.rb:328`).
- **Scanner signal:** caller sweep for `Otel|OTLP|otel` over `gems/*/lib apps/
  bin/ script/`; hit for `tamoz.telemetry.export` in `catalog.rb` with no producer.
- **Independent judgment:** the "off by default" half of the priority question is
  **confirmed and stronger than claimed** — not merely off, but unreachable, so an
  untrusted config file, model reply, or MCP server cannot enable or redirect
  export. The unproven half is real: nothing in the repository proves that the
  endpoint an operator would configure is validated against policy data, that
  enabling requires authorization, or that the documented
  missing-adapter path exists. I confirmed the docs describe a capability
  (`documentation/operations/observability-ops.md:88-90`,
  `documentation/design/observability.md:14`) that has no code behind it.
- **Root cause (five whys):**
  1. Why is governance unproven? Because no code path constructs the exporter.
  2. Why is there no construction path? Because the observability slice shipped
     the adapter gem and its seam but never the caller that would use it.
  3. Why was the caller not shipped? Because the wiring lives outside this gem —
     in `tamoz-agent`/`tamoz-agent-cli`, which per
     `documentation/design/observability.md:14` should "load it lazily when a
     runtime directory configures observability" and do not.
  4. Why did that not surface as a gap? Because `limitations.md:119` marks the
     adapter "implemented" based on code presence, and the only test
     (`test/otel_test.rb`) drives the class directly rather than through a boot.
  5. Why is that the controllable cause? Because there is no contract stating
     **who** may enable export and **what** proves a configured endpoint was
     authorized — the same policy-as-data rule the repo applies to approvals is
     not applied to the one path that carries data to a third party.
  The preventing contract: "enabling OTLP export requires an explicit,
  digest-bound authorization bound to the endpoint, and the code path that reads
  that authorization is tested end to end."
- **Recommendation:** the smallest credible action at the existing seam is to
  state the missing contract rather than build the caller: record in
  `documentation/limitations.md` §"Observability remains partial" that the
  adapter is present but **not wired**, and name the owner seam
  (`tamoz-agent` runtime-directory observability configuration) and the
  authorization input that must gate it. Do not build an enable path in this
  read-only package; do not add a plugin API (ADR-044 forbids it).
- **Disposition:** *(coordinator)* — open, pending coordinator acceptance.

### F16-SEC-02 — The exporter applies no content/redaction policy to exported attributes and does not carry the governing policy digest

- **Severity:** major
- **Confidence:** high
- **Status:** open
- **Source evidence:** `gems/tamoz-otel/lib/tamoz/otel/http_exporter.rb:131`
  (`'attributes' => attributes` — copied by reference, verbatim);
  `:113-123` (the only keys read: `correlation`, `attributes`, `observed_at_ms`,
  `name`, timestamps — `content` and `policy_digest` are never touched).
  Contrast the journal, which merges the digest on every line:
  `gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb:147`
  (`signal.to_h.merge('policy_digest' => signal.policy_digest || @policy_digest)`).
  `ContentPolicy` (`gems/tamoz-observability/lib/tamoz/observability/content_policy.rb`,
  230 lines) is never required or referenced anywhere under `gems/tamoz-otel/`.
  Same for the `resource.attributes` descriptor: `http_exporter.rb:26`, `:134`.
- **Test/contract evidence:** `ruby -Itest test/otel_test.rb` → 6 runs / 17
  assertions / 0 failures; the only body-shape test
  (`test/otel_test.rb:33-53`) passes `'attributes' => {}` — an empty hash — so it
  cannot detect verbatim egress. `not found`: no test asserts any redaction,
  truncation, size bound, or policy digest on an exported batch.
- **Scanner signal:** grep for `ContentPolicy|policy_digest` under `gems/tamoz-otel/`
  → zero hits.
- **Independent judgment:** I traced real attribute construction with a live
  probe rather than relying on the grep. Probe P1 built a document with
  `'prompt' => 'SECRET-PROMPT-TEXT'`, `'tool_arguments' => 'rm -rf /'`, a nested
  `content` hash and a nested array, and read back the produced span attributes:
  all four shipped unchanged. Probe P12 enumerated the dropped fields:
  `["kind", "schema_version", "timing", "duration_ms", "content", "policy_digest", "outcome"]`.
  I **reject** the critical grade: today the local `ContentPolicy` keeps prompt
  text in the separate `content` field (`signal.rb:129`) rather than in
  `attributes`, so no live leak occurs, and the exporter is unreachable anyway
  (F16-SEC-01). I **accept** the major grade because it is a genuine
  defence-in-depth and evidence failure on the one egress path — there is no
  bound on attribute size either, so an oversized attribute produces both a leak
  risk and a batch rejection with no accounting.
- **Root cause (five whys):**
  1. Why do raw attributes reach a third party? Because `resource_spans` copies
     `attributes` into the span without consulting any policy.
  2. Why does it not consult a policy? Because the exporter treats the exporter
     seam as transport-only and assumes the upstream signal is already safe.
  3. Why is that assumption unsafe? Because the `Signal` contract permits
     arbitrary bounded values in `attributes` (`signal.rb:155-170`) and bounds
     them only by count and per-string bytes, not by content class or
     classification.
  4. Why is there no check at the boundary? Because no contract says the exporter
     seam must re-assert the content policy — `documentation/design/observability.md:64`
     describes egress rules for *destination* only, never for *content*.
  5. Why does that matter for evidence? Because dropping `policy_digest` means an
     exported span cannot state which policy produced it, so an operator cannot
     later prove what left the machine — the exact property
     `documentation/operations/observability-ops.md:78-81` claims.
  The preventing contract: "every byte that leaves the process carries the
  governing content-policy digest, and export applies the same classification
  decision as the journal."
- **Recommendation:** at the existing `resource_spans` seam, carry the document's
  `policy_digest` into the span (as a span attribute or the resource block) so the
  exported evidence is self-describing. The redaction decision itself already
  lives correctly upstream in `ContentPolicy`; do not duplicate it in the
  exporter — record the digest, which is the minimum that makes export auditable.
- **Disposition:** *(coordinator)* — open; independent challenge recommended
  before closure.

### F16-REL-01 — `AsyncExporter` hardcodes a 2 s export deadline, silently overriding a longer configured `timeout_ms`

- **Severity:** minor
- **Confidence:** high
- **Status:** open
- **Source evidence:** `gems/tamoz-otel/lib/tamoz/otel/async_exporter.rb:75`
  (`@exporter.export(batch, deadline_ms: 2_000)`);
  `gems/tamoz-otel/lib/tamoz/otel/http_exporter.rb:55`
  (`timeout = [Float(deadline_ms) / 1_000, policy.timeout_ms / 1_000.0].min` —
  the minimum, so the smaller hardcoded value always wins);
  `gems/tamoz-otel/lib/tamoz/otel/egress_policy.rb:14`, `:10` (policy default
  2_000, ceiling `MAX_TIMEOUT_MS = 30_000`).
- **Test/contract evidence:** `ruby -Itest test/otel_test.rb` → 6 runs / 17
  assertions / 0 failures; no test asserts the deadline passed by the async path.
  `not found`: no test constructs `AsyncExporter`.
- **Scanner signal:** none (found by reading the delivery path; confirmed by probe P14).
- **Independent judgment:** probe P14 constructed a policy with `timeout_ms:
  25_000` and a capturing exporter, then recorded one signal through
  `AsyncExporter`: the exporter received `deadline_ms=2000`, not 25_000. So an
  operator who configures a longer timeout because their collector is slow gets
  2 s in practice, and the configured bound is unreachable through the only
  wrapper that exists. Severity is minor because the failure is fail-soft and
  counted (`:unknown` → drop accounting → failure limit), not data loss of
  durable state.
- **Root cause (causal):** the deadline was hardcoded at the drain seam instead of
  being derived from the same `EgressPolicy` the exporter already holds, so two
  places encode the same policy and one of them silently wins. The preventing
  contract: "the export deadline has exactly one source, the egress policy."
- **Recommendation:** pass the policy's own timeout (e.g. read it from the
  exporter's `policy`) at `async_exporter.rb:75` instead of the literal `2_000`.
  One-line change, no new machinery.
- **Disposition:** *(coordinator)* — open.

### F16-OBS-01 — Export outcome and divergence are unrecorded; the exported span loses `outcome`, making a failed turn indistinguishable from a successful one

- **Severity:** major
- **Confidence:** high
- **Status:** open
- **Source evidence:** `gems/tamoz-observability/lib/tamoz/observability/catalog.rb:176-177`
  declares `tamoz.telemetry.divergence` and `tamoz.telemetry.export`; no code
  emits either (repo-wide grep matches only the catalog and
  `test/observability_catalog_test.rb:36-37`). Export outcomes are produced at
  `gems/tamoz-otel/lib/tamoz/otel/http_exporter.rb:73-82`
  (`:delivered`/`:throttled`/`:rejected`/`:unknown`) and consumed only into
  in-memory counters at `gems/tamoz-otel/lib/tamoz/otel/async_exporter.rb:85-96`
  and the `health` hash at `:49-58`. `outcome` is present in the signal
  (`gems/tamoz-observability/lib/tamoz/observability/signal.rb:70`) but is not
  read by `resource_spans` (`http_exporter.rb:113-123`).
- **Test/contract evidence:** `ruby -Itest test/observability_catalog_test.rb` →
  10 runs / 26 assertions / 0 failures (asserts the *names are registered*, not
  that they are emitted). `not found`: no test asserts an export signal or a
  divergence signal is ever recorded.
- **Scanner signal:** grep for `tamoz.telemetry.export` / `tamoz.telemetry.divergence`
  across `gems/` and `test/`.
- **Independent judgment:** probe P12 confirmed `outcome` is among the fields the
  exporter drops. Combined with the absent export signal, the operational
  consequence is concrete and doubly misleading: (a) a collector receives a span
  for a *failed* turn with no error indicator, and (b) the local journal contains
  no record that export was attempted, delivered, dropped, or disabled, so an
  operator cannot tell a quiet plane from a broken one. I confirmed the
  `limitations.md:126` claim that "divergence accounting ... remain[s] outstanding" —
  it is accurate, and this finding states its cost. This also bears on the
  sampling question below: with no export signal there is no way for a reader to
  know whether a given span was subject to any retention decision.
- **Root cause (five whys):**
  1. Why is there no export evidence? Because the exporter returns a symbol and
     the wrapper counts it in memory, and nothing routes it to a recorder.
  2. Why does nothing route it? Because the exporter holds no recorder reference
     and the seam (`exporter.rb:5-9`) has no channel for one.
  3. Why does the seam have no channel? Because the design assigns backoff and
     self-disable to "the recorder" (`documentation/design/observability.md:64`)
     while implementing them inside `AsyncExporter` — the responsibility moved
     but the reporting did not follow.
  4. Why did that go unnoticed? Because the catalog declares the names, so a
     catalog-completeness test passes while nothing produces them.
  5. Why is that the controllable cause? Because "declared in the catalog" is
     treated as equivalent to "produced", when the two are separate claims.
  The preventing contract: "every declared catalog signal has a producer, and the
  audit gate fails on a declared-but-unproduced name."
- **Recommendation:** emit `tamoz.telemetry.export` with its `outcome` attribute
  from the existing `delivery_result` seam (`async_exporter.rb:80-83`), which
  already receives the result on every delivery attempt. Leave divergence
  accounting to the slice that owns the durable reader — do not build a second
  source of truth here.
- **Disposition:** *(coordinator)* — open.

### F16-COR-01 — Emitted span attributes are not OTLP/JSON-conformant; the exporter never validates its own wire body

- **Severity:** minor
- **Confidence:** high
- **Status:** open
- **Source evidence:** `gems/tamoz-otel/lib/tamoz/otel/http_exporter.rb:131`
  (`'attributes' => attributes`, untransformed) and `:134`
  (`'resource' => {'attributes' => @descriptor || {}}`, untransformed);
  `:41` (`body = JSON.generate(resource_spans(batch))` — serialized, never
  validated). Permitted value types: `gems/tamoz-observability/lib/tamoz/observability/signal.rb:155-170`
  allows `Integer` without a range bound and `Symbol` (`:159`).
- **Test/contract evidence:** `ruby -Itest test/otel_test.rb` → 6 runs / 17
  assertions / 0 failures. The shape test (`:33-53`) asserts only name lengths and
  `kind`, and passes an empty attributes hash, so no value typing is exercised.
  `not found`: no test round-trips the generated body through any OTLP decoder or
  asserts attribute value types.
- **Scanner signal:** none (found by reading `resource_spans` and confirmed by probes).
- **Independent judgment:** probe P3 emitted
  `"big":1000000000000000000000000000000` for an attribute value of `10**30` — an
  unquoted integer outside the OTLP int64 range, which a strict collector rejects
  at the batch level, discarding the *entire* batch rather than one span. Probe
  P13 emitted `"sym":"a_symbol"`, where a Ruby `Symbol` silently became a JSON
  string — survivable, but by accident rather than by mapping. Probe P4 showed the
  same for a `Symbol` in `resource.attributes`. I **reject** a higher severity:
  the Signal contract's practical attribute population is controlled by the
  catalog, no live producer emits out-of-range integers, and the gem is
  unreachable (F16-SEC-01). I **accept** minor: the failure mode is a whole-batch
  rejection with no local diagnostic, and the design explicitly promises OTLP
  conformance.
- **Root cause (causal):** the exporter treats attribute values as opaque and
  relies on `JSON.generate` to produce a valid body, but OTLP/JSON requires typed
  `AnyValue` encoding, so the Ruby value space and the protocol value space are
  never reconciled. The preventing contract: "the exporter validates its own
  output against the OTLP value model before sending."
- **Recommendation:** at `resource_spans`, map attribute values into OTLP's typed
  form (reject or stringify a non-finite/out-of-int64 integer, stringify symbols,
  skip an unsupported class) and drop the whole batch locally with an `:rejected`
  return if any value cannot be represented — a bounded loop at the existing
  seam, no new class.
- **Disposition:** *(coordinator)* — open.

### F16-COR-02 — The documented OpenTelemetry `gen_ai` attribute mapping does not exist in code

- **Severity:** info
- **Confidence:** high
- **Status:** open
- **Source evidence:** the claim is stated in three places —
  `documentation/design/observability.md:12`, `docs/OBSERVABILITY_DESIGN.md:33`,
  `docs/OBSERVABILITY_PLAN.md:226` ("`gen_ai` attribute mapping"). The code at
  `gems/tamoz-otel/lib/tamoz/otel/http_exporter.rb:110-135` performs no rename,
  translation, or semantic-convention mapping of any attribute.
- **Test/contract evidence:** `not found` — no test mentions `gen_ai`;
  `grep -rn "gen_ai"` over `gems/` returns nothing.
- **Scanner signal:** grep for `gen_ai` across the repository.
- **Independent judgment:** confirmed absent. Recorded as info rather than a
  finding-grade defect because the `gen_ai` mapping is a design-doc aspiration for
  a capability no caller currently exercises, and its absence changes no runtime
  behavior today. It is worth recording because the design doc presents it as a
  property of the shipped gem.
- **Root cause (causal):** the design document describes the intended end state of
  `tamoz-otel`, while the shipped slice implemented transport and egress only; the
  document was not narrowed when the slice landed.
- **Recommendation:** align the one-line table entry — either mark the `gen_ai`
  mapping as not-yet-implemented in `documentation/design/observability.md:12`, or
  leave it and let the coordinator track it as planned work. No code change.
- **Disposition:** *(coordinator)* — open.

### F16-MNT-01 — ADR-044 requires a conformance suite for the exporter adapter; no conformance suite exists

- **Severity:** minor
- **Confidence:** high
- **Status:** open
- **Source evidence:** the requirement is at
  `documentation/adr/adr-044-observability-is-a-contract-gem-plus-per-exporter-adapter-gems.md:11-14`
  ("each exporter is a separate adapter gem passing the contract gem's conformance
  suite"). The seam that would carry it is
  `gems/tamoz-observability/lib/tamoz/observability/exporter.rb:5-9` — a bare
  module defining three methods that raise `NotImplementedError`, with no shared
  assertions. The only adapter is `gems/tamoz-otel/lib/tamoz/otel/http_exporter.rb:11`.
- **Test/contract evidence:** `ruby -Itest test/otel_test.rb` → 6 runs / 17
  assertions / 0 failures — every test drives `HTTPExporter` directly; none
  exercises the `Exporter` module or asserts a shared contract. `not found`: no
  conformance suite, no shared example, no contract test file.
- **Scanner signal:** `exporter.rb` line count (11) versus the ADR's requirement.
- **Independent judgment:** the adapter declares conformance structurally
  (`include`) but nothing verifies it. The practical effect today is nil because
  the seam has one implementer and no caller; the effect in future is that the
  ADR's stated gate — the reason a plugin API was rejected — does not actually
  exist, so a second exporter could be added without the promised check. Minor,
  because the closed-set decision (ADR-044) still holds and adding an exporter is
  still a contract-gem release.
- **Root cause (causal):** the seam was defined as a signature-only module, so
  "passing the conformance suite" had nothing to bind to; the requirement was
  written for a gate that the seam does not physically support.
  The preventing contract: "the contract gem ships an assertion set that every
  adapter runs against its own instance."
- **Recommendation:** if a second adapter is ever planned, add the shared
  assertion set to `exporter.rb` and call it from `test/otel_test.rb`; until then
  record the ADR/code divergence in `documentation/limitations.md` rather than
  building a suite for a single adapter.
- **Disposition:** *(coordinator)* — open.

## Blind spots

- **Sampling and the operational consequence.** The brief asked whether a reader
  can mistake a sampled export for a complete trace. The answer is that sampling
  does not exist in either gem — `documentation/limitations.md:126` lists "export
  sampling" as outstanding, and `grep` for `rate|sample|sampling` in
  `gems/tamoz-otel/` returns nothing (only the unrelated `JSON.generate` at
  `http_exporter.rb:41`). The design at
  `documentation/design/observability.md:62-64` specifies tail sampling keyed on
  `trace_id` and `export_rate` with always-exported "interesting turns"; none of
  it is implemented. **Operational consequence, stated plainly:** because every
  batch the wrapper accepts is exported and every refusal is counted only in
  memory, the export stream today is *complete for whatever was enqueued* but
  **silently lossy at the queue** — a reader receiving the collector's view of a
  turn cannot distinguish a turn that was never recorded, one dropped at
  `queue_full`, and one lost after the failure limit disabled the drain. Since
  `tamoz.telemetry.export` is never emitted (F16-OBS-01), the collector-side trace
  is indistinguishable from a complete one. That is the concrete misreading risk,
  and it is worse than a sampled trace because a sampled trace at least has a
  declared rate.
- **I did not read** `gems/tamoz-observability/lib/tamoz/observability/metrics.rb`,
  `trace.rb`, `producer.rb`, or `usage.rb` end to end — the metrics/trace rows
  belong to F15. I read `signal.rb`, `content_policy.rb`, `recorder_journal.rb`,
  `recorders.rb`, `correlation.rb`, `recorder.rb`, `catalog.rb:176-177`, and
  `exporter.rb` because they are the seam this row consumes.
- **I did not construct a live TLS collector**, by instruction. All HTTP behavior
  was verified against a blackhole address (probe P15) and by reading the
  `Net::HTTP` configuration; no byte was sent to any real endpoint, and no
  `Net::HTTP` request reached a listening socket.
- **I could not verify** whether an operator-facing configuration key for OTLP
  exists outside the greps I ran (`*.rb`, `*.gemspec`, `*.yaml`, `*.yml`, `*.json`,
  `*.md`, `Gemfile`, `Rakefile`). If such a key is read by a non-Ruby entry point
  or an external deployment file, F16-SEC-01's "no enable path" conclusion would
  need revisiting; I found no candidate for one.
- **`allow_local` authority** (`egress_policy.rb:16`) and the skipped
  post-resolution guard when it is true (`:36`) are recorded as observations, not
  findings — I could not establish an authority contract for that flag in the
  repository, and the path is unreachable.

## Verdict

**IMPROVE** — per BAR.md, at least one accepted critical/major finding.

- Counts: **critical 0, major 3, minor 3, info 1.**
  - major: F16-SEC-01 (no enable path / unproven governance),
    F16-SEC-02 (no content policy or policy digest on exported attributes),
    F16-OBS-01 (export outcome + divergence unrecorded; `outcome` dropped from the span).
  - minor: F16-REL-01 (hardcoded deadline), F16-COR-01 (non-conformant attribute
    typing), F16-MNT-01 (no conformance suite).
  - info: F16-COR-02 (documented `gen_ai` mapping absent).
- Lens summary: correctness **reviewed**; security and authority **reviewed**;
  reliability and durability **reviewed**; observability and evidence **reviewed**;
  scalability and resource bounds **reviewed**; maintenance and architecture
  **reviewed**. No lens is `not evidenced`.
- Verified passes worth stating: the gem is off by default and has no untrusted
  enable path; buffering is bounded with counted drops and a failure-limit disable;
  both connect and read timeouts exist; TLS is verified, redirects are refused,
  proxy env is refused, and resolved addresses are re-validated and pinned against
  DNS rebinding; dependency direction is honest (`tamoz-observability` +
  `tamoz-concurrency` only) and **no production gem depends on `tamoz-otel`**,
  confirming the optional-gem requirement.
