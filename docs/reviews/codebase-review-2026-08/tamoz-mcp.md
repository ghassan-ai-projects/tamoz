# Codebase Review — gems/tamoz-mcp

*12-agent codebase review, 2026-08. See [INDEX.md](INDEX.md). Scope: ~3,100 LOC, 13 lib files.*

## Overall assessment

The gem is in good shape — typed errors, fail-closed validation, deliberate-duplication comments, and solid docs discipline. The most serious finding is a broken live HTTP provider path in the websearch egress client that no test exercises. Structural debt concentrates in the `Invocation` god-module and several verbatim-duplicated security-policy helpers.

## High

### H1 — `EgressClient` drops the request path — the real HTTP provider path is broken

`gems/tamoz-mcp/lib/tamoz/mcp/websearch/egress_client.rb:80-88` calls `@connector.call(pinned_ip:, host:, port:, timeout:, headers:, body:)` — **no `path`**. `request_path(uri)` is computed and stored in every target (lines 119, 148) but never reaches the connector; `default_connector` hardcodes `Net::HTTP::Get.new("/")` (line 266). Additionally a body on a `Net::HTTP::Get` is silently not sent (`request_body_permitted?` false), so the query from `script/websearch_adapter:159-163` never reaches the provider. The bug survives because every test injects a connector spy and CI only exercises the `fixture` provider — the live HTTP path is an untested critical path ("never CI", per the script's own header).

**Fix:** add `path:` to the connector contract, use `Net::HTTP::Get.new(path)` (or a POST class when `body` is present), and add a contract test asserting the connector receives the URL's path/query.

### H2 — Constants defined inside `Data.define(...) do … end` blocks leak onto `Tamoz::Mcp`, and other files silently depend on the leak

In `catalog.rb:21-24` (`DIGEST_DOMAIN`, `ENTRY_DIGEST_DOMAIN`, `TOOL_NAME_PATTERN`, `CLIENT_INFO`) and `server_config.rb:21-52` — constant assignment inside a block binds to the lexical scope (`Tamoz::Mcp`), not the Data class. `server_config.rb:337-339` documents this and patches `ServerConfig::Budgets = Budgets`, but `invocation.rb:300` references bare `CLIENT_INFO`, and `invocation.rb:675`, `elicitation.rb:257`, `supervisor.rb:317` reference bare `CONTROL_CHARACTER_PATTERN` — all resolving through the leaked `Tamoz::Mcp` namespace rather than an explicit home. Two files both defining the same constant name in such a block would collide module-wide with no warning at the site.

**Fix:** define constants explicitly under their owning class (`Catalog::CLIENT_INFO`, `ServerConfig::CONTROL_CHARACTER_PATTERN`) and reference them qualified; or hoist shared ones (e.g. `CONTROL_CHARACTER_PATTERN`) deliberately into `Tamoz::Mcp` with a comment.

## Medium

### M1 — Circuit logic duplicated ~120 lines between `MemoryCircuitStore` and `EgressCircuit`

`supervisor.rb:26-107` vs `websearch/egress_circuit.rb:31-137`: identical mutex-guarded `record_failure`/`record_success`/`open?`/`failures`/`reset`/`reset_evidence`/`last_failure_*` and a near-identical `conditions_digest` (same `CONDITIONS_DOMAIN` string duplicated). They differ only in the budget-breach predicate and reset-authority gate. Two real consumers exist, so the extraction bar is met.

**Fix:** extract a shared circuit-core (module or small value object) with the open-predicate and reset-validation as the two seams.

### M2 — `strict_schema` / `deep_strictify` / `strictable_object?` duplicated verbatim

`invocation.rb:220-251` and `elicitation.rb:201-228` are character-for-character copies (the "default-deny additionalProperties" rule). A security-policy copy that can drift is worse than ordinary duplication.

**Fix:** extract one `Tamoz::Mcp::StrictSchema` module function used by both.

### M3 — Deep-freeze duplicated three times

`catalog.rb:229-239`, `elicitation.rb:264-274`, `invocation.rb:682-692` (`deep_freeze_json`). Same shape, trivial drift risk.

**Fix:** move one `deep_freeze` next to `CanonicalJSON` and reuse.

### M4 — UTF-8-scrub + control-strip pattern repeated five times with subtly different bounds

`catalog.rb:178-187` (`bounded_description`), `elicitation.rb:254-262` (`bounded_message`), `invocation.rb:672-676` (`scrub_text`), `supervisor.rb:313-320` (`stderr_tail`), `websearch.rb:64-72` (`sanitize_result`). The adapter script adds a sixth, divergent copy of credential-shape detection (`script/websearch_adapter:175-179` vs `websearch.rb:46-52` — different regexes, e.g. `sk-` minimum length 8 vs 7+1).

**Fix:** one `Tamoz::Mcp` text-sanitizer function parameterized by byte cap; make the adapter call `Websearch.credential_shaped_query?` instead of re-implementing it.

### M5 — Tight coupling to MCP SDK private internals across several seams

`invocation.rb:383` calls `client.send(:request, …)` (private API, acknowledged in comment); `supervisor.rb:119` subclasses `MCP::Client::Stdio` and overrides `read_line`, `send_request`, `start`; `errors.rb:128` subclasses `MCP::Client::RequestHandlerError` with a guessed positional `{}` argument. The gemspec allows `mcp ~> 1.1`, so any 1.x bump can break these silently. Individually justified (comments are good), collectively the gem's largest fragility.

**Fix:** pin tighter (`~> 1.1.0`-style patch band) or add an SDK-upgrade smoke test covering the three seams; at minimum list the private-API touchpoints in the README.

### M6 — `Invocation` module is a 600-line `class << self` holding six responsibilities

`invocation.rb:81-693`: descriptor validation, schema strictification, digest gate, supervision/connect, wire round-trip + retry policy, elicitation handoff, and output bounding/attribution. RuboCop ceilings are dodged only because each method is small; the module itself is the god-object. `attribute_blocks` (`invocation.rb:581-641`, ~60 lines, three near-identical truncate/remaining blocks) and `round_trip`'s 4-clause rescue (`invocation.rb:331-366`) are the densest parts.

**Fix:** extract `ArgumentValidation` (with M2) and an `ObservationBuilder` (blocks + structured + attribution) as separate module functions; `attribute_blocks` per-type handling can collapse around one `truncate_to_budget(text, remaining)` helper.

### M7 — `Catalog` mixes a frozen value object with a compile service

`catalog.rb:20-241` — a `Data.define` snapshot plus 200 lines of `class << self` compilation machinery (handshake, collection, digests). `handshake` (lines 59-80) also duplicates most of `Invocation.ensure_connected!` (`invocation.rb:293-327`) with divergent error classification.

**Fix:** move compilation into a `CatalogCompiler` module function returning the `Catalog` value; share the connect/handshake path with Invocation.

## Low

- **L1 — Dead/misnamed method: `EgressPolicy#operator_authority?`** — `egress_policy.rb:174` is a predicate-named method returning the string `"owner"`; no callers anywhere in the repo. Violates §3 (predicates end in `?` and return booleans). **Fix:** delete it (authority already lives in `EgressCircuit::OPERATOR_AUTHORITY`).
- **L2 — Frozen `EgressClient` exposes a mutable `@dials` array** — `egress_client.rb:52,68`: object is frozen but `attr_reader :dials` hands out the unfrozen array; any caller can mutate the audit trail. §5 ("freeze values handed out"). **Fix:** return `@dials.dup.freeze` or freeze at construction and rebuild.
- **L3 — `ServerConfig#describe` returns a shallow-frozen hash** — `server_config.rb:143-166`: outer hash frozen, inner `"budgets"` hash and `.dup`'d arrays mutable. Minor §5 leak. **Fix:** freeze nested structures.
- **L4 — FD leak on failed spawn** — `supervisor.rb:337-355`: if `Process.spawn` raises, the parent ends (`stdin_r/stdout_w/stderr_w`) are closed in `ensure` but the child-side pipes (`stdin_w/stdout_r/stderr_r`) are never closed. **Fix:** close all six IOs in the rescue path.
- **L5 — `Supervisor#close` conflates teardown with retirement** — `supervisor.rb:374-405`: `close` unconditionally sets `@retired = true`, yet `restart` (line 281-286) works only because `start` happens to reset the flag. The documented contract ("a closed supervisor is never auto-started again") and the retry path disagree; a future caller invoking `close` then reading `state` mid-restart sees `:retired`. **Fix:** separate `teardown` (process) from `retire!` (lifecycle), or have `restart` use a non-retiring close.
- **L6 — Error-identity overlap: `ToolPolicyError::CATEGORY` == `ProtocolError::CATEGORY`** (`errors.rb:35,78`, both `"mcp_protocol"`). §7 pins error identity; two public classes sharing a category string weakens the taxonomy. **Fix:** confirm intentional and comment, or give `ToolPolicyError` its own category.
- **L7 — Broad `rescue StandardError` in schema validation** — `catalog.rb:126-133` rescues `StandardError` from the SDK validator (fail-closed, re-raised typed — defensible, but it would also swallow e.g. `NoMemoryError`-adjacent SDK bugs into a misleading "invalid schema"). `supervisor.rb:436-439` swallows `StandardError` from `close` silently. **Fix:** narrow to the SDK's `ArgumentError`/validation classes where known.
- **L8 — Redundant condition in retry guard** — `invocation.rb:332-343`: `max_attempts` already encodes read-only-ness (`1 + (read_only? ? budget : 0)`), making `&& descriptor.read_only?` dead weight. **Fix:** drop the redundant clause.

## Gem-boundary notes (no action required, flagged for awareness)

- The deliberate cross-boundary duplications (credential-env pattern from `tamoz-agent`, egress declaration shape from `Tamoz::Agent::Profile`) are each commented with their reason, satisfying §6.1's spirit — but the *egress declaration validation* now exists twice (`egress_policy.rb` + agent profile) as executable policy, not just patterns. If a third consumer appears, the shared shape belongs in `tamoz-core`.
- `Websearch::*` (net/http, resolv, IPAddr) is a socket-capable egress stack living in the MCP gem, kept off the default load path by convention (`websearch.rb:3-6`) rather than by the dependency-isolation test. It fits §6.2's "adapter" clause, but it is the strongest candidate for its own gem (`tamoz-egress`) if it grows beyond the one websearch consumer.
