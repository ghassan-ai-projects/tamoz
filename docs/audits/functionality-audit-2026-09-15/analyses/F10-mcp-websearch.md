# F10 `tamoz-mcp-websearch` — the in-process egress boundary is strong; the operator-side adapter it ships has an uncontrolled POST target, an unbounded `max_results`, and a declaration that is never wired to it

Row: F10 · Queue: W1B gem row · Baseline: branch `audit-15-09`, HEAD `582ae55`, 2026-09-15 ·
Analyst: independent read-only analyst (F10) · Budget: ~40 min, hard cap 60.

## Scope and source map

Real files read end to end (line counts are `wc -l`):

| File | Lines | Role |
|---|---|---|
| `gems/tamoz-mcp-websearch/lib/tamoz/mcp/websearch.rb` | 99 | gem entry: `egress_budgets`, `credential_shaped_query?`, `sanitize_result` |
| `gems/tamoz-mcp-websearch/lib/tamoz/mcp/websearch/egress_policy.rb` | 340 | `EgressPolicy`: fail-closed declaration validation, host/range classification |
| `gems/tamoz-mcp-websearch/lib/tamoz/mcp/websearch/egress_client.rb` | 292 | `EgressClient`: per-hop resolve → classify → pin → dial, redirect handling |
| `gems/tamoz-mcp-websearch/lib/tamoz/mcp/websearch/egress_circuit.rb` | 210 | `EgressCircuit`: the `CircuitStore` duck-type for the egress scope |
| `gems/tamoz-mcp-websearch/tamoz-mcp-websearch.gemspec` | 16 | declared deps |

The file named in the brief, `gems/tamoz-mcp-websearch/lib/tamoz/mcp_websearch.rb`,
does not exist; the entry point is `lib/tamoz/mcp/websearch.rb` (verified by
`find gems/tamoz-mcp-websearch -type f`).

Seams read because the egress boundary is only meaningful through them:

- `script/websearch_adapter` (207 lines) — the operator-side MCP server the
  gem ships; the only caller of `EgressClient#fetch` in the repository.
- `gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb` (462);
  `.../mcp_source_builder.rb` (299); `.../mcp_capability_source.rb`.
- `gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb` (the response admission point);
  `.../server_config.rb` (budget + env-allowlist + credential-ref validation);
  `.../supervisor.rb` (`circuit_store` seam, `self.build`).
- `gems/tamoz-agent-profile/lib/tamoz/agent/profile/egress_validator.rb` (228)
  plus the `EGRESS_*` constants in `.../profile.rb`; `gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb`
  (`KNOWN_SOURCES`, `source_settings`, `enabled_sources`) and `worker_runtime.rb`
  (`mcp_source`, `build_session`).
- `gems/tamoz-agent-session/lib/tamoz/agent/session.rb` (`verify_egress_binding!`,
  `guard_state!`), `session_bindings.rb`, `session_steps.rb`, `session_effects.rb`.
- `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_preparation.rb` (safety→action table),
  `.../circuit_store.rb`; `gems/tamoz-core/lib/tamoz/circuit/registry.rb`
  (`EGRESS` scope).

Entry seam for this row: `Tamoz::Mcp::Websearch.egress_budgets` (`websearch.rb:37`)
is the one production call site that pulls this gem's code into the agent's own
process; `WebsearchAdapter.search_response` (`script/websearch_adapter:99`) is the
one production egress path.

## Behavior path

Two distinct processes, and conflating them is where the risk lives.

**A. In-process (Tamoz's own process, no socket).**
`RuntimeDirectory#enabled_sources` reads `sources.websearch.enabled` from
`config.yaml` and refuses any name outside the closed set
`%w[skills memory mcp websearch]` (`runtime_directory.rb:45,117-128`).
`WorkerRuntime#mcp_source` → `McpSourceBuilder#build` (`mcp_source_builder.rb:50`)
→ `websearch_server` (`:282`) builds a `ServerConfig` with
`server_id: "websearch"` and **no `budgets:` argument** (`:286` → `config_for` `:289`),
so the child gets `ServerConfig::Budgets` defaults: `max_output_bytes 64 KiB`,
`connect_timeout 10.0` (`server_config.rb:66-72`). `Catalog.compile` pins the tool
list; `Supervisor.build(config)` (`supervisor.rb:131`) is called with no
`circuit_store:`, so it falls back to `MemoryCircuitStore` (`:258-259`) — an
in-memory, process-local circuit, not the durable `CircuitStore`.
`CapabilityBinding#mcp_descriptor` (`capability_binding.rb:222-248`) mints the host
descriptor under source id `websearch:websearch`, `kind: :websearch`,
`effect_class` from `closed_effect_class` (`:206-209`), `trust: :operator`,
`egress_policy_ref "websearch:websearch"`, `output_budget 64 KiB`, `secret_handling: :reject_values`.
`McpDispatcher#safety` (`:451-453`) returns `:read_only` iff `source.read_only?`.
`SessionEffects#build_intent` writes that into the intent's `safety`
(`session_effects.rb:287`); `dispatch` (`:75-86`) routes through
`EffectDispatcher.run` with a `logical_identity` built from
request/execution/operation/capability/arguments/authority/catalog revisions
(`:135-147`) — the effect key is over the REQUEST, never the answer, per the FX rule.

**B. Operator-side (the egress process the gem ships).**
`WebsearchAdapter.search_response` (`script/websearch_adapter:99`): `load_policy`
parses `TAMOZ_WEBSEARCH_EGRESS` into `EgressPolicy` (`:123-133`); grant check
`ENV[GRANT_ENV] == "1"` (`:104`); `load_provider` parses `TAMOZ_WEBSEARCH_PROVIDER`
(`:135-151`); query hygiene (`:110-111`); then either `fixture_result` (`:153`) or
`http_result` (`:170-188`). Only `http_result` touches `EgressClient#fetch`
(`egress_client.rb:81`), which per hop does `validate_scheme!` → `validate_host!`
→ `validate_port!` → `pin_address` (resolve → `private_range?` → pin) → connector
(`:84-109`, `:116-128`, `:211-232`).

Query construction line by line, because the query IS the egress: the adapter
never turns file content into a query. It receives `query:` as an MCP tool
argument (`:90`), stringifies it (`:109`), and on the HTTP path wraps it as
`JSON.generate("query" => query, "max_results" => max_results)` into the request
BODY (`:177`). A probe confirmed the dialer receives
`body={"query":"find the secret","max_results":3}` at `path=/search`,
`host=api.search.example` (/tmp probe, below). There is no filesystem read, no
workspace walk, and no prompt/observation text on this path, so no file body or
path can reach the query by construction — the only query source is the model's
`query` argument.

## Lens: correctness

Reviewed, with the key behaviors source-grounded and probe-verified.

- Per-hop validation runs on every connection and every redirect target
  (`egress_client.rb:84-109`); the validated address is the one handed to the
  connector (`:85-96`), and the default connector dials it via `http.ipaddr=`
  while keeping the allowlisted hostname for TLS SNI/verification (`:266-288`).
  Probe: a 302 to `cdn.search.example` produced two dials, each with its own
  pinned IP; an off-allowlist 302 was refused with exactly one dial (the
  refusal precedes the hop).
- Redirect bound is enforced after the counter increment (`:101-106`), so N
  redirects with `redirect_max_hops: 3` raise `RedirectHopLimitError`.
- Credential headers are dropped on host change
  (`:151-154`, `CREDENTIAL_HEADER_NAMES` `:45`).
- Response body is cut at `max_response_bytes` and flagged `truncated`
  (`:241-251`).
- `EgressPolicy` refuses unclassifiable address spellings fail-closed
  (`egress_policy.rb:91-98`), which is the correct direction; `classification`
  of `127.1`, `0x7f.0.0.1`, `2130706433` all land in the refusal set.

One correctness defect found: the `budget_breach: false` declaration is not
honored by `EgressCircuit` — see F10-REL-01.

## Lens: security and authority

Reviewed. This is the lens with the material findings.

**What authorizes a websearch.** Three independent gates: `sources.websearch.enabled`
(operator `config.yaml`, closed source set), the profile's `egress:` section
(validated by `EgressValidator`, pinned into the session record as `egress_pin`
and compared on resume by `enforce_egress_binding!` → `guard_state!`,
`session.rb:251-264,437-447`), and the adapter's own `TAMOZ_WEBSEARCH_GRANT=1`
(`script/websearch_adapter:104`). `EgressPolicy#operator_authority?` returns
`"owner"` (`:132`) and the circuit reset requires `authority: "owner"` plus a
`sha256:` command digest (`egress_circuit.rb:175-206`), so no in-process caller
can self-reset — probe-verified in `websearch_circuit_test.rb`.

**Can the model widen it?** For the `/tmp`-visible surface: the model controls
`query`, `max_results`, and nothing else — the endpoint, scheme, port, host, and
headers are all server-side. The transport is fixed to https/443
(`:168-173`, `:196-200`). Off-allowlist and IP-literal targets are refused
(probe-verified). But `max_results` has **no upper bound anywhere** and is
forwarded verbatim into the outbound request body (F10-SEC-02), and the
operator-side endpoint is an unchecked string (F10-SEC-01).

**The profile-to-adapter gap.** I traced every reader of `profile.egress`:
`session.rb:293-298` and `session_bindings.rb:44-48` — both only PIN the
declaration. `McpSourceBuilder` (`mcp_source_builder.rb`) has zero `egress`
references (verified by grep over `gems/tamoz-agent-capabilities/lib/tamoz/agent/`),
`WorkerRuntime` has zero, and no production file passes the profile's declaration
to the adapter's `TAMOZ_WEBSEARCH_EGRESS`. The operator guide states the
intended contract explicitly — "put the same egress declaration under the
profile's `egress:` section" (`documentation/guides/agent-operator.md:246-249`)
and `env_allowlist` must list `TAMOZ_WEBSEARCH_EGRESS` (`:210-217`) — which is
exactly a **self-reported, operator-maintained duplication with no comparison
point**. `egress_policy.rb:16-22` already admits this in prose ("Any 'runtime
comparison' a caller surfaces is a SELF-REPORTED, `author_claimed` check with no
enforcement value"). The consequence: a profile that narrows egress (one host,
64 KiB) can be pinned, recorded, and resume-verified while the adapter runs under
an entirely different declaration. This is the P17-side analogue of CF05-SEC-01
and is recorded as F10-SEC-03.

**Response handling.** The admission point is `Invocation.build_observation`
(`invocation.rb:614-627`): every content block is attributed
(`"remote content from server websearch"`), text is control-stripped
(`scrub_text` `:753-758`), and fit to `budgets.max_output_bytes` (`:716-720`),
marking `truncated`. Structured content is control-stripped deep and bounded
(`:726-735`). On top of that the gem's own `sanitize_result`
(`websearch.rb:68-73`) strips credential assignments and `SECRET_VALUE_PATTERNS`
tokens before the text is journalled. Injection text is NOT stripped — correctly,
since sanitizing is not the containment mechanism; the containment is the
structural review + approval gate, and `agent_smoke_corpus.rb:1686-1695` drives
that scenario with a literal injection payload whose `shell` step is refused.
Probe: `sanitize_result` passes the injection payload through unchanged and
strips both `OPENAI_API_KEY=` and a bare `sk-` token — the intended division.

## Lens: reliability and durability

Reviewed. The FX rule is satisfied on the in-process path: `SessionEffects#dispatch`
(`session_effects.rb:75-86`) is the only execution door and it calls
`EffectDispatcher.run`; `McpCapabilitySource#execute` (`:138-140`) is a plain
call reached FROM inside that block, so a timeout raises out of the journaled
operation and the journal resolves it by safety class. I read the table at
`effect_preparation.rb:203-235`: `read_only`/`idempotent` → `:execute` (fresh
attempt); `transactional`/`reconcilable` → `:reconcile`; `unsafe` → the attempt
is marked `unknown` and the effect stops. With websearch admitted as `:read_only`
by `McpDispatcher#safety` (`capability_binding.rb:451-453`), a timed-out search
grants a fresh attempt rather than returning the recorded receipt. That is the
declared semantics for an idempotent read and the query is the request key
(`session_effects.rb:135-147`), so it is not a broken-durability finding — but it
does mean a timeout on `mcp:websearch/search` re-queries the provider. Recorded
as F10-REL-02 (info/minor), because the brief asks the question directly.

The duck-typed safety question from the brief is answered in F10-MNT-01.

`EgressCircuit` is thread-safe (`Mutex` around every read-modify-write,
`egress_circuit.rb:63-105`) and both DR-2 open conditions are implemented. The
`budget_breach: false` path is wrong (F10-REL-01), and the connector claims are
truthful about their own limitation.

## Lens: observability and evidence

Reviewed, partly `not evidenced` for the live path.

Present: dial audit trail (`EgressClient#dials`, `:55`, frozen copy), typed
refusals with `CATEGORY`/`SAFE_MESSAGE` (`:13-26`) so a policy violation never
leaks the target into a user-visible message, `truncated` on both the client
`Result` (`:50`) and the invocation `Observation` (`observation.truncated`), and
`attribution` on every content block (`invocation.rb:663-665`).

Not evidenced: no metric, counter, or log line records that a query LEFT the
machine. `@dials` is written but never read by any production caller (grep over
`gems/` and `script/` finds no `dials` reader outside the test file), and the
adapter emits nothing on stderr on the HTTP path. What would prove it: an
operator-visible per-turn egress receipt (server id, host, byte counts,
truncated flag) recorded where the effect receipt already is — the journal
records the request digest, not the egress destination.

## Lens: scalability and resource bounds

Reviewed, with one gap.

Bounded: request body (`initial_target` `:121-125` against `max_request_bytes`),
response body (`:246-249`), redirect hops (`:102`), connect/read timeout
(`:272-273`), redirect Location bytes (`MAX_REDIRECT_LOCATION_BYTES` `:44`,
`:139`), in-process output (`budgets.max_output_bytes`, `invocation.rb:616`).
Every `EgressPolicy` numeric is range-checked (`:60-63`, `:295-301`).

Unbounded: `max_results` (F10-SEC-02). Its only constraint is that it must be a
positive Integer to be honored (`script/websearch_adapter:113`), which is an
accept-any-value rule, not a bound. The upstream provider, not Tamoz, decides how
much work `max_results: 2**40` means; the first-party fixture ignores it
entirely, so no test can observe the effect.

Also unbounded and worth one line: the HTTP provider path has no total-fetch
deadline beyond `connect_timeout_s` applied to both open and read
(`:272-273`), so `connect_timeout_s: 300` (the permitted maximum,
`egress_policy.rb:28`) is a 300-second read timeout per hop across up to 10 hops.

## Lens: maintenance and architecture

Reviewed. Dependency direction is honest and narrow: the gemspec declares only
`tamoz-mcp` and `tamoz-core` (`tamoz-mcp-websearch.gemspec:13-14`), no provider
SDK, and no production gem depends on `tamoz-mcp-websearch` (verified: no
`.gemspec` references it, and the only requires of `tamoz/mcp/websearch` are
`script/websearch_adapter:57` and tests). `websearch.rb:3-6` states the
non-requirement and `test/packaging_test.rb:392-411` proves the parent MCP gem
does NOT pull `net/http` or `resolv` into a closure. The selftest at
`packaging_test.rb:198-220` asserts `%w[tamoz-core tamoz-mcp]` is the full
dependency set. That is the strongest part of this gem.

The duplication of the egress schema across `EgressValidator`
(`gems/tamoz-agent-profile`, `EGRESS_*` constants) and `EgressPolicy`
(`gems/tamoz-mcp-websearch`) is deliberate and documented
(`egress_policy.rb:9-14`): tamoz-mcp must not depend on tamoz-agent. But the two
copies have already drifted — `EgressPolicy::SCHEMES`/`MAX_RESPONSE_BYTES`
(`:24-31`) versus the profile's constants — and nothing compares them
(F10-MNT-02).

Sharper problem found here: `Websearch.credential_shaped_query?` and
`Websearch.sanitize_result` have **zero production call sites**. Every caller
found by grep is a test or a test support file
(`test/websearch_invocation_test.rb:325,411,444`,
`test/support/agent_smoke_corpus.rb:1846,1877,2008`). The production validator is
`McpSourceBuilder#build_validator` (`mcp_source_builder.rb:182-189`), which only
runs `Invocation.validate_arguments` (JSON-schema shape), and the production
executor is `build_executor` (`:108-123`) → `Invocation.call` — neither calls
into the websearch gem. See F10-SEC-04.

## Tests and contracts

Commands run one file per command, `ruby -Itest <file>`:

| Command | Runs | Assertions | Failures | Errors |
|---|---|---|---|---|
| `ruby -Itest test/websearch_contract_test.rb` | 4 | 52 | 0 | 0 |
| `ruby -Itest test/websearch_egress_test.rb` | 10 | 74 | 0 | 0 |
| `ruby -Itest test/websearch_invocation_test.rb` | 11 | 61 | 0 | 0 |
| `ruby -Itest test/websearch_circuit_test.rb` | 8 | 33 | 0 | 0 |
| `ruby -Itest test/websearch_adapter_test.rb` | 14 | 58 | 0 | 0 |
| `ruby -Itest test/websearch_connector_contract_test.rb` | 3 | 5 | 0 | 0 |
| `ruby -Itest test/packaging_test.rb -n "/websearch/"` | 3 | 60 | 0 | 0 |
| `ruby -Itest test/public_api_test.rb` | 3 | 1051 | 0 | 0 |

Total websearch-specific: 53 runs / 283 assertions / 0 failures / 0 errors.
Suite named in the brief `test/websearch_invocation_test.rb` (459 lines) ran
green; `test/websearch_egress_test.rb` exists (284 lines) and ran green. No test
file was skipped. `test/websearch_egress_test.rb` is the only file that
exercises `verify_egress_binding!`.

`not run`: `test/agent_smoke_corpus.rb` case 18 (`websearch-governed`) — it is a
harness support file driven by the benchmark runner, not a `test/*_test.rb`
suite, so it is out of scope for one-file-per-command execution. The brief
permits a bounded set only.

The tests are the reason the connector contract is honest today:
`websearch_connector_contract_test.rb:7-14` records that the `path` was dropped
and the GET body silently swallowed, and both bugs survived because every other
adapter test injects a connector spy. That is a live statement about the
fixture-only coverage of the HTTP path.

## Findings

### F10-SEC-01 — the served HTTP endpoint is an unchecked string, so the adapter's `websearch` server POSTs to any allowlisted host chosen by a third party

- **Severity**: major
- **Confidence**: high
- **Status**: open
- **Source evidence**: `script/websearch_adapter:143-146` accepts any `endpoint`
  that is a String starting with `https://` (the only check is
  `endpoint.is_a?(String) && endpoint.start_with?("https://")`); `:171` does
  `endpoint = provider.fetch("endpoint")` and `:174-178` passes it straight to
  `client.fetch(endpoint, ..., body: JSON.generate("query" => query, "max_results" => max_results))`.
  `EgressClient` then validates it only against the egress declaration:
  scheme (`egress_client.rb:168-173`), host allowlist (`:175-194`), port
  (`:196-200`). The **path** is unvalidated: `request_path` returns
  `uri.request_uri` verbatim (`:202-207`) and the connector sends it as-is
  (`:278`). Probe (`/tmp/f10probe/p2_endpoint.rb`): with
  `allowlisted_hosts: ["api.search.example", "internal.example"]`, an endpoint of
  `https://internal.example/collect` dialed `internal.example` at `/collect` with
  the query in the body.
- **Test/contract evidence**: `test/websearch_adapter_test.rb:184-193` proves the
  allowlist refuses an off-allowlist redirect, and `test/websearch_connector_contract_test.rb:52-60`
  pins that the path reaches the dialer — neither test constrains where the
  initial endpoint may point. The grant test
  (`test/packaging_test.rb:418-448`) uses the fixture provider only. The live
  provider is the recorded deferral (`script/websearch_adapter:22-25`).
- **Scanner signal**: none; found by tracing `http_result` line by line.
- **Independent judgment**: confirmed. The per-hop allowlist is genuinely
  enforced and `deny_private_ranges` genuinely refuses a metadata address even
  when its hostname is allowlisted (probe: `metadata.example` → `169.254.169.254`
  refused). So this is not an SSRF-to-169.254 bypass. It is a boundary
  violation of the operator's own declaration: "which provider" stops being a
  Tamoz-side fact and becomes whatever the process environment says, and the
  only in-process anchor that could have compared it (the profile's `egress:`
  section) is never consulted. I could not prove a concrete attacker in this
  read-only audit — hence `major`, not `critical` — but the contract asserted in
  `egress_policy.rb:16-22` ("Tamoz's own copy is what it pins and validates") is
  not what the shipped adapter does.
- **Root cause (five whys)**:
  1. Why can a search be POSTed to an arbitrary allowlisted host/path? Because
     `http_result` uses `provider["endpoint"]` verbatim as the request target.
  2. Why is it used verbatim? Because the endpoint is treated as operator
     configuration, not as policy-controlled data.
  3. Why is it not policy-controlled? Because the operator describes targets in
     two places — `config.yaml`/env for the adapter and the profile `egress:`
     section for Tamoz — and no code joins them.
  4. Why is there no join? Because `McpSourceBuilder` forwards only the command,
     argv, `env_allowlist`, and `credential_refs` to the child
     (`mcp_source_builder.rb:239-254`) and never the profile's egress section
     (zero `egress` references in that directory).
  5. Why did the design leave the join out? Because `egress_policy.rb:16-22`
     accepted "the operator-side process enforces it" as sufficient and recorded
     the duplication as intentional, so no evidence-based admission check was
     ever assigned an owner. The contract that would prevent recurrence: the
     session's pinned `egress_pin` must be the value the adapter actually dials
     under, or the adapter must refuse to start when its declaration is not the
     pinned one.
- **Recommendation**: the smallest credible action at the existing seam — in
  `WebsearchAdapter.load_provider` (`script/websearch_adapter:135-151`), require
  the resolved endpoint's host to be the first entry of
  `policy.allowlisted_hosts` (the declaration already carries the ordered list,
  `egress_policy.rb:57,71-73`), refusing with a named reason otherwise. That
  turns "allowlisted hosts" from a set of permitted redirect targets into the
  declared provider identity, with no new class and no new config key. Optionally
  strengthen with the profile-comparison the finding names, but the one-line
  host pin is what closes the widening.
- **Disposition**: left open. Read-only audit; the coordinator decides whether to
  fold this into CF05-SEC-01's contract decision or track it separately.

### F10-SEC-02 — `max_results` is model-controlled and unbounded, and is forwarded into the outbound request body

- **Severity**: minor
- **Confidence**: high
- **Status**: open
- **Source evidence**: the tool schema declares `"max_results" => {"type" => "integer"}`
  with no `maximum` (`script/websearch_adapter:86`); the handler accepts any
  positive Integer (`:113`, `max = max_results.is_a?(Integer) && max_results.positive? ? max_results : 3`);
  it is serialized straight into the request body (`:177`). The in-process
  fixture server has the identical schema and no bound
  (`script/mcp_test_server:171`). No constant in `EgressPolicy` bounds it
  (compare `MAX_REQUEST_BYTES`, `MAX_RESPONSE_BYTES`, `MAX_REDIRECT_HOPS`,
  `MAX_CIRCUIT_THRESHOLD` at `egress_policy.rb:26-31` — `max_results` has no
  counterpart).
- **Test/contract evidence**: `test/websearch_invocation_test.rb` never passes
  `max_results` (all calls use the default 3,
  `call_search` at `:144-149`); the adapter test never passes it either. `not
  found`: no test asserts any upper bound on `max_results`.
- **Scanner signal**: none; found by reading the schema against the policy
  constant list.
- **Independent judgment**: confirmed as a real unbounded model-controlled
  parameter, but bounded in impact: it cannot widen the target, scheme, or
  method, and the response is still capped at `max_response_bytes`. Its cost is
  provider-side work and rate-limit consumption, plus a larger `max_request_bytes`
  risk if a provider echoes the parameter. Downgraded from the brief's
  "unvalidated parameter reaching the transport" framing to `minor` because the
  transport itself is fully validated — only an integer's magnitude is free.
- **Root cause**: the egress declaration bounds bytes/hops/timeouts but has no
  vocabulary for result count, so the one query parameter that controls
  provider-side work was never given a policy field.
- **Recommendation**: add a `maximum` to the `max_results` property in the tool
  schema at `script/websearch_adapter:86` and clamp at `:113` — one schema line,
  no new machinery.
- **Disposition**: left open.

### F10-SEC-03 — websearch admission states the profile-to-MCP contract it does not enforce; the profile `egress:` section never reaches the adapter

- **Severity**: major
- **Confidence**: high for behavior, medium for the intent
- **Status**: open
- **Source evidence**: every reader of `profile.egress` is a pin, never an
  enforcement input — `gems/tamoz-agent-session/lib/tamoz/agent/session.rb:293-298`
  (`current_egress_pin` → `Deliberation.canonical`) and
  `session_bindings.rb:44-48` (`{ egress_pin: ... }`). `grep -rn "egress"`
  over `gems/tamoz-agent/lib/tamoz/agent/` returns exactly one hit that is not
  the closed source list: none in `McpSourceBuilder` or `WorkerRuntime`.
  `McpSourceBuilder#config_arguments_for` (`mcp_source_builder.rb:239-254`)
  forwards `env_allowlist` and `credential_refs` but not the egress section.
  The intended contract is written down at
  `documentation/guides/agent-operator.md:246-249` and `:204-217` (the operator
  must list `TAMOZ_WEBSEARCH_EGRESS` in `env_allowlist`), and the gem itself
  labels any runtime comparison a "SELF-REPORTED, `author_claimed` check with no
  enforcement value" (`egress_policy.rb:16-22`). The resume guard
  (`session.rb:251-264`) does compare the pin — but against the profile, not
  against the adapter's env, so a narrowed profile and a wide adapter env coexist
  without a stop.
- **Test/contract evidence**: `test/websearch_egress_test.rb` (10 runs / 74
  assertions, 0F) proves the pin is recorded, changes to it stop typed, and an
  identical one resumes — all profile-vs-profile.
  `test/websearch_adapter_test.rb` proves the adapter enforces whatever env it
  is given. `not found`: no test compares the two.
- **Scanner signal**: row flag CF05-SEC-01 (`FINDINGS.md:15`,
  `analyses/mcp-profile-admission.md`); this finding is the egress-side instance
  of the same unsettled admission contract, not a duplicate — CF05-SEC-01 is
  about which MCP NAMES reach the model, this is about which EGRESS DECLARATION
  governs the call.
- **Independent judgment**: confirmed the behavior with high confidence
  (the pin-only readers and the absent wiring are direct source facts). The
  intent is `medium`: `egress_policy.rb:16-22` may mean the operator-side process
  is deliberately outside Tamoz's authority, in which case the defect is the
  documentation asserting a pin-and-validate relationship that no code performs.
  Either way the observable at risk is the same: a session can report and
  re-verify an egress declaration that is not the one its searches run under.
- **Root cause (five whys)**:
  1. Why can a pinned declaration differ from the enforced one? Because they are
     two independent operator-maintained copies with no comparison.
  2. Why are there two copies? Because tamoz-mcp must not depend on tamoz-agent
     (`egress_policy.rb:9-14`), so the schema was duplicated across the boundary.
  3. Why was duplication accepted? Because the enforcement point is outside
     Tamoz by design (correction 2), which made "enforced outside" read as
     "verified outside".
  4. Why does nothing verify it? Because admission authority for the `websearch`
     source id was never assigned — the same gap CF05-SEC-01 records, where the
     profile-to-MCP admission contract is unsettled.
  5. Why is it unsettled? Because no invariant names who owns MCP/websearch
     admission versus profile narrowing; the repo instead documents a manual
     operator procedure. The contract that would prevent recurrence: the
     `egress_pin` the session records must be derived from, or checked against,
     the declaration the adapter process runs under.
- **Recommendation**: at the existing seam — `McpSourceBuilder#config_arguments_for`
  (`mcp_source_builder.rb:239-254`) already builds the child's `env_allowlist`;
  it should pass the profile's validated egress declaration to the adapter as a
  declared value (an explicit config field or an `env_allowlist`-carried
  declaration) so `WebsearchAdapter.load_policy` can refuse when its own
  declaration is not the pinned one. Smallest version: refuse at
  `load_policy` when the declaration digest does not match a
  `TAMOZ_WEBSEARCH_EGRESS_DIGEST` the builder supplies. No new class, and the
  refusal is a named message like the existing gate refusals
  (`script/websearch_adapter:68-73`).
- **Disposition**: left open, flagged for the coordinator to co-dispose with
  CF05-SEC-01.

### F10-SEC-04 — the query-hygiene and result-sanitization functions are test-only; the production path applies neither

- **Severity**: major
- **Confidence**: medium
- **Status**: open
- **Source evidence**: `Websearch.credential_shaped_query?` (`websearch.rb:52-56`)
  and `Websearch.sanitize_result` (`:68-73`) have zero production callers —
  `grep -rn "sanitize_result\|credential_shaped_query?"` over the repo returns
  only `websearch.rb` itself plus `test/websearch_invocation_test.rb:325,411,444`,
  `test/support/agent_smoke_corpus.rb:1846,1877,2008`, and the public-API
  manifest `test/public_api_test.rb:295-297`. The production validator is
  `McpSourceBuilder#build_validator` (`mcp_source_builder.rb:182-189`): it calls
  `database_policies[...]&.validate` and `Invocation.validate_arguments`, nothing
  else. The production executor is `build_executor` (`:108-123`) →
  `Invocation.call`, whose observation building control-strips and bounds
  (`invocation.rb:614-627, 753-758`) but does not run
  `SECRET_VALUE_PATTERNS`/`CREDENTIAL_ASSIGNMENT_PATTERN` stripping
  (`websearch.rb:87-93`).
- **Test/contract evidence**: the two W6 tests
  (`test/websearch_invocation_test.rb:306-342`, `:347-362`, `:368-437`) each
  construct their own `Source.new(..., validator: lambda { ... credential_shaped_query? ... },
  executor: lambda { ... sanitize_result ... })` inline — they prove the
  functions work, and prove the session honors a caller-supplied validator and
  executor, but the closure they test is written by the test.
  `test/support/agent_smoke_corpus.rb:1868-1888` does the same inside the
  benchmark harness. `not found`: no production wiring.
- **Scanner signal**: none; found by grepping call sites after reading the
  docstring at `websearch.rb:46-51` ("Such a query is rejected at invocation
  (fail closed, no call is issued)").
- **Independent judgment**: the *function* claims are true and well-tested; the
  *system* claim is not proven for the production builder. I could not prove an
  actual leak end to end, which is why this is `medium` rather than `high`:
  a credential-shaped query still has to pass the JSON-schema validator, and the
  response still passes `Invocation`'s control-strip and byte bound. What I can
  prove is that the guard the gem documents as the invariant-24 control is
  absent from the only production construction path, and that its absence is
  invisible because every test supplies it by hand. This is the same shape as
  the CF05-SEC-01 family: a documented control whose production wiring is a
  caller obligation nobody owns.
- **Root cause (five whys)**:
  1. Why does production not apply the query hygiene? Because
     `build_validator` (`mcp_source_builder.rb:182-189`) has no websearch-aware
     branch — it is generic over all MCP servers.
  2. Why is it generic? Because websearch is modeled as "an MCP server whose id
     is `websearch`" (`mcp_source_builder.rb:5-10`), so the builder treats it as
     an ordinary MCP server.
  3. Why does that lose the hygiene? Because the hygiene lives in a SEPARATE gem
     (`tamoz-mcp-websearch`) that the builder must not require — tamoz-agent-capabilities
     depends on the source shape, not the egress gem.
  4. Why is the function there and not where it is needed? Because it was
     authored alongside the egress adapter and validated against fixtures and
     deliberately-wired smoke sessions.
  5. Why did no gate catch the missing wiring? Because coverage is measured on
     the function (called by tests) and on the session (given a hand-written
     validator), never on the production builder's descriptor set. The contract
     that would prevent recurrence: a source-id-keyed control must be applied by
     the code that BUILDS the source, and a test must assert it on
     `McpSourceBuilder#build`, not on a hand-composed `Source.new`.
- **Recommendation**: at the existing seam, add the websearch branch to
  `McpSourceBuilder#build_validator` and `#build_executor`
  (`mcp_source_builder.rb:182-189`, `:108-123`) keyed on
  `config.server_id == WEBSEARCH_SERVER_ID` (the constant already exists at
  `:31`), and add one assertion to `test/agent_mcp_capability_source_test.rb`
  that the built source wires them. If the honest answer is that the adapter
  already does the hygiene server-side, then the smallest correct action is the
  opposite: delete the docstring claim at `websearch.rb:46-51` and move the
  functions behind the adapter, so the repository stops asserting a control that
  no production path performs.
- **Disposition**: left open; needs an independent challenge before any closure,
  because the two readings (missing wiring vs. misleading documentation) have
  different fixes and the sources support both.

### F10-REL-01 — `EgressCircuit` ignores `budget_breach: false` and opens anyway after `threshold` breaches

- **Severity**: minor
- **Confidence**: high
- **Status**: open
- **Source evidence**: `egress_circuit.rb:152-160` (`transition_on_failure`):
  the immediate-open branch is guarded by `@budget_breach && kind == :budget_breach`;
  when the guard is false, control falls through to `@failures += 1` and
  `@state = @failures >= @threshold ? :open : :degraded`. So a budget breach
  with `budget_breach: false` is counted as an ordinary consecutive failure and
  still opens the circuit at the threshold. The declaration models this as a
  dropped condition, not a counting change: `Tamoz::Circuit::Registry::EGRESS`
  declares `budget_breach` as `kind: "immediate", failure_kinds: %w[budget_breach]`
  (`gems/tamoz-core/lib/tamoz/circuit/registry.rb:259-262`) and the registry's
  own comment names `circuit.budget_breach: false` as "the case" for
  `without_condition(id)` (`:135-142`). `EgressCircuit` has no equivalent of
  dropping the condition.
- **Test/contract evidence**: probe `/tmp/f10probe/p1_circuit_budget.rb` —
  `EgressCircuit.new(threshold: 3, budget_breach: false)` then three
  `record_failure(kind: :budget_breach)` reports
  `open?=true failures=3 kind=budget_breach`; the
  `budget_breach: true` control with `threshold: 2` opens on the first breach.
  `test/websearch_circuit_test.rb` (8 runs / 33 assertions, 0F) exercises the
  reset authority and the open predicates; `not found`: any test with
  `budget_breach: false`.
- **Scanner signal**: none; found by probing the declaration semantics.
- **Independent judgment**: confirmed by direct probe. Impact is bounded and
  points the safe way (it over-refuses rather than under-refuses), so it is
  `minor`, not major: an operator who deliberately disabled the non-consecutive
  condition still gets a circuit that opens, just later and through the
  consecutive counter. It is nonetheless a real contract divergence between the
  registry vocabulary and the class that implements the egress scope.
- **Root cause**: the class was written to implement "both DR-2 open conditions"
  (`egress_circuit.rb:13-23`) as a two-branch predicate, so `budget_breach: false`
  had nowhere to go but the consecutive counter; the registry's
  drop-the-condition model was never mirrored.
- **Recommendation**: in `transition_on_failure` (`egress_circuit.rb:152-160`),
  return early — without incrementing `@failures` — when the kind is
  `BUDGET_BREACH_KIND` and `@budget_breach` is false. One guard, matching the
  registry's own semantics.
- **Disposition**: left open.

### F10-REL-02 — a timed-out search is re-attempted, not receipt-replayed, because the admitted safety is `:read_only`

- **Severity**: info
- **Confidence**: high
- **Status**: open (verified design fact, not a defect)
- **Source evidence**: `McpDispatcher#safety` returns
  `source.read_only?(descriptor.id) ? :read_only : :unsafe`
  (`capability_binding.rb:451-453`); `SessionEffects#build_intent` stores it as
  the intent's `safety` (`session_effects.rb:287`); `SessionEffects#dispatch`
  hands it to `EffectDispatcher.run` (`:78-85`); the journal's table maps
  `read_only`/`idempotent` to a fresh `:execute` grant on an unanswered attempt
  (`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_preparation.rb:203-214`), while
  `unsafe` marks the attempt `unknown` (`:229-235`). The chain from the graph
  node to the journal is correct — `McpCapabilitySource#execute` (`:138-140`) is
  invoked inside the `EffectDispatcher.run` block, so there is no raw call in a
  node.
- **Test/contract evidence**: `test/websearch_invocation_test.rb:279-301` shows
  the budget-breach recording path; `not run`: no test drives a *timeout* on
  `mcp:websearch/search` through replay.
- **Scanner signal**: the brief's failure/ambiguity question.
- **Independent judgment**: the FX rule is satisfied — the call is journaled and
  keyed on the request (`session_effects.rb:135-147`, `Invocation.effect_key`
  over id+arguments). The residual behavior worth recording is that a replay
  after a timeout issues a NEW provider query rather than returning a receipt,
  because `:read_only` grants a fresh attempt by design. Given a search is a
  read, this is the right classification; it is recorded so no one later reads
  "durable effect journal" as "a search never leaves twice."
- **Recommendation**: none. The simple path already delivers the required
  property; the only addition worth considering is the observability item in the
  lens above, which is not a change to this behavior.
- **Disposition**: accept as `info`.

### F10-MNT-01 — the MCP descriptor duck-type has no mismatch guard, and websearch's own descriptor is consistent

- **Severity**: info
- **Confidence**: high
- **Status**: open
- **Source evidence**: the scanner lead from the brief is `CapabilityBinding#closed_effect_class`
  (`capability_binding.rb:206-209`) reading `optional(descriptor, :effect_class)`
  (`:250-252`) while `McpDispatcher#safety` (`:451-453`) independently calls
  `source.read_only?(descriptor.id)` — for a custom descriptor with
  `effect_class: :bounded` and `read_only? == true`, the host descriptor carries
  `:bounded` but the dispatch safety is `:read_only`. Websearch's own descriptor
  comes from `McpSourceBuilder#append_descriptors` (`:80-89`) →
  `Invocation.descriptor_for(entry, snapshot:, effect_class: effect_class_for(entry, read_only))`
  with `effect_class_for` = `read_only_tools.include?(entry.name) ? :read_only : :unknown_effects`
  (`:202-204`), and `McpCapabilitySource#read_only_descriptor?`
  (`:163-167`) derives `read_only?` from the same `effect_class`. So for
  websearch the two agree by construction; `closed_effect_class` maps
  `:unknown_effects` → `:bounded` (`:206-209`) and `mcp_approval_policy`/`mcp_retry_policy`
  key off that same closed class (`:362-368`), so the production builder is
  internally consistent. The mismatch is reachable only by a caller that
  supplies a hand-written source whose `read_only?` disagrees with its
  `effect_class` — which is exactly what `test/websearch_invocation_test.rb:399-413`
  and `test/support/agent_smoke_corpus.rb:1663-1675` do.
- **Test/contract evidence**: `not found`: no test asserts the two agree; the
  hand-composed `Source.new` in the W6 test declares `effect_class: :read_only`
  (`test/websearch_invocation_test.rb:136-142`) so it does not expose it either.
- **Scanner signal**: supplied in the brief (duck-typed contract, no mismatch guard).
- **Independent judgment**: confirmed as a real gap in the duck-typed contract,
  and confirmed that websearch's own descriptor and source are consistent, so
  the row does not inherit it. It is `info` here rather than a finding against
  this gem because the owning seam is `CapabilityBinding`/`McpDispatcher`, not
  `tamoz-mcp-websearch`.
- **Recommendation**: none from this row. If the coordinator wants it closed,
  the seam is `McpDispatcher#safety` (`capability_binding.rb:451-453`), which
  could take the host descriptor's `effect_class` instead of asking the source.
- **Disposition**: accept as `info`, cross-referenced to CF05-SEC-01's contract
  decision.

## Blind spots

- **The live HTTP provider was never executed.** Every probe used an injected
  resolver and connector. `EgressClient`'s real `default_resolver`/`default_connector`
  (`egress_client.rb:253-288`) were read but not run end to end; the brief
  forbids live network calls and the repository records the live path as a
  deferral (`script/websearch_adapter:22-25`). `test/websearch_connector_contract_test.rb:64-76`
  stubs `Net::HTTP` to prove the verb, which is the closest available evidence.
  A real TLS exchange with a pinned `ipaddr` and SNI verification is unproven.
- **`gems/tamoz-agent-session/lib/tamoz/agent/session_nodes.rb` and
  `session_graph.rb`** were grepped for the egress/effect seam but not read end
  to end; the FX-rule conclusion rests on `session_steps.rb:37-48`,
  `session_effects.rb:75-86`, and the journal's safety table. A node that calls
  the capability outside `EffectDispatcher.run` would falsify F10-REL-02.
- **`test/support/agent_smoke_corpus.rb` case 18** (the websearch-governed
  end-to-end scenario) was read at the wiring level (`:1619-1723`, `:1750-1766`,
  `:1776-1900`) but not executed, because it is a benchmark-harness support file
  rather than a `test/*_test.rb` suite. It is the only end-to-end websearch
  evidence in the repository and it composes its own validator and executor, so
  it cannot resolve F10-SEC-04.
- **`gems/tamoz-mcp/lib/tamoz/mcp/supervisor.rb`** was read for the
  `circuit_store` seam and the retry budget but not line by line; a transport
  failure on the in-process MCP channel is not fully traced.
- **`gems/tamoz-evals/suites/agent/smoke/18_websearch_governed.case.json`** was
  located but not read. It governs the case above and may pin expectations this
  report does not know about.

## Verdict

**IMPROVE** — 0 critical, 2 major, 2 minor, 2 info.

The gem's in-process half is the strongest part of this row and is genuinely
well-built: fail-closed declaration validation, fail-closed address
classification, per-hop resolve→classify→pin with a rebinding-proof pin, a
credential-dropping redirect rule, an authority-gated circuit reset, a narrow
and honest gemspec, and a packaging test that proves the parent MCP gem stays
free of `net/http` and `resolv`. All 53 websearch-specific test runs pass.

The majors are all the same shape and all live at the **operator-side adapter
boundary and its wiring**, never in the in-process policy engine: the served
endpoint is unchecked (F10-SEC-01), the profile's pinned egress declaration
never reaches the process that dials (F10-SEC-03), and the query-hygiene and
result-sanitization controls the gem documents are only invoked by tests
(F10-SEC-04). That pattern is the P17-side instance of CF05-SEC-01's unsettled
profile-to-MCP admission contract, and F10-SEC-03 should be co-disposed with it
rather than counted twice.
