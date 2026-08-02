# P10 — governed MCP client/host: implementation plan

Status: accepted for implementation
Design commit: this document and `docs/reviews/P10_MCP_PLAN_REVIEW.md`
Authoritative inputs: `docs/design-v0.1/MCP_DESIGN.md` (source of truth for semantics),
`AGENT_DESIGN.md` §11, invariants 16–18, 24–27, 35–37, the P10 card in
`docs/PROJECT_HANDOVER_PLAN.md`.

This plan specifies P10 v1. It commits to **P10-D, P10-A, P10-B, and the elicitation and
supervision slices of P10-C that the phase outcome names** (durable originating-call
interrupt, deadlines, process-tree teardown, circuit). **P10-D2 (HTTP/OAuth), P10-H
(server/host mode), and the full P10-E official-conformance program are deferred** with
explicit specifications so they cannot be silently partially implemented.

## 1. Scope commitment and phase outcome

The handover card's outcome, verbatim: optional `tamoz-mcp` uses the official SDK to
connect to one real test server, compile a locally governed immutable catalog, execute
one capability through Tamoz policy/effects, survive transport failure, and preserve
elicitation/ambiguity.

Everything in v1 maps to that sentence:

| Outcome clause | Work package | Proof |
|---|---|---|
| uses the official SDK | P10-D | dependency pinned to `mcp` 1.1.x; no vendored JSON-RPC |
| one real test server | P10-A | SDK-built stdio server in `script/mcp_test_server`, driven as a child process |
| locally governed immutable catalog | P10-A | catalog compiler, snapshot digest, epoch rules (§5) |
| execute one capability through policy/effects | P10-B | descriptor-bound tool wrapper through `EffectDispatcher` (§6) |
| survive transport failure | P10-C slice | crash/hang/teardown proofs (§8, §10) |
| preserve elicitation/ambiguity | P10-C slice | `input_required` becomes a durable interrupt bound to the originating call (§7) |

Out of scope for v1: Streamable HTTP, OAuth, server/host mode, sampling, roots,
resource templates beyond cataloguing, the MCP Tasks extension, and remote prompts as
anything but untrusted catalogued content.

## 2. Standards baseline re-check (2026-08-02)

The design pins the `2026-07-28` stateless specification as the target and names
`2025-11-25` as the interoperability baseline "because the official Ruby SDK's 2026
multi-round-trip flow is not yet complete enough for Tamoz's durability contract."

Re-checked at implementation time as the handover card requires:

- The [2026-07-28 specification](https://blog.modelcontextprotocol.io/posts/2026-07-28/)
  shipped: stateless protocol core, multi-round-trip requests (MRTR) for elicitation,
  header-based versioning; sampling and roots deprecated (SEP-2577).
- The [official Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk/releases)
  reached v1.0.0 (2026-07-24, stable public API) and **v1.1.0 (2026-08-01) supports
  2026-07-28 as the latest protocol version**, including stateless `server/discover`,
  MRTR `input_required` results (v0.24.0, SEP-2322), and cache hints (SEP-2549).
- The gem has **no runtime dependencies** and requires Ruby >= 2.7 — an unusually clean
  dependency boundary for `tamoz-mcp`.

**Amendment (reviewed in the plan review):** the design's stated reason for keeping
2025-11-25 as the baseline no longer holds for client mode over stdio. P10 v1 therefore
pins its protocol profile to `2026-07-28` preferred with `2025-11-25` accepted on
negotiation, rather than treating 2025 as the primary baseline. This narrows the design
only in the direction the design already allows ("Tamoz advertises 2026 only after the
selected SDK version implements the required features" — it now does). Tamoz still does
not reimplement JSON-RPC, transports, OAuth, or protocol schemas.

## 3. Package boundary

New gem `gems/tamoz-mcp`:

```text
tamoz-agent
  │  McpCapabilitySource → Toolbox-like descriptors through ordinary tool/effect contracts
  ▼
tamoz-mcp
  ├─ ServerConfig        (immutable admission config, §4)
  ├─ Catalog             (compiler, snapshot, epoch, §5)
  ├─ Invocation          (argument/result validation, content bounding, §6)
  ├─ Supervisor          (stdio lifecycle, deadlines, circuit, teardown, §8)
  ├─ Elicitation         (input_required → interrupt descriptor, §7)
  └─ official mcp gem 1.1.x
```

Dependency rules (checked by `dependency_isolation_test`):

- `tamoz-mcp` depends on `tamoz-core` and `mcp` (~> 1.1). Nothing else.
- `tamoz-agent` gains **no hard dependency** on `tamoz-mcp`; integration is duck-typed:
  an MCP capability appears to the agent exactly like a configured check or a skill —
  through descriptors the caller supplies. `tamoz-mcp` never requires `tamoz/agent`.
- `tamoz-mcp` never touches `tamoz-sqlite`, RubyLLM, graph state, or the scheduler.
- Credentials: server configs carry `credential_ref` **names** only (the P8 profile
  pattern); resolution happens in the caller, never inside `tamoz-mcp`.

`mcp` is added to the workspace `Gemfile` for development/test and to
`tamoz-mcp.gemspec` as a runtime dependency. The packaged-gem test proves
`tamoz-mcp` installs and loads with only `tamoz-core` + `mcp` present.

## 4. Server admission (P10-D/A)

`ServerConfig` is immutable, validated at construction, and carries:

```ruby
ServerConfig = Data.define(
  :server_id,          # PROFILE_ID-pattern; the ONLY source of source qualification
  :transport,          # :stdio (v1 only; :http reserved, raising ValidationError)
  :command,            # absolute path to the executable
  :arguments,          # frozen argv, no shell, no metacharacters
  :env_allowlist,      # names the child may inherit; values never logged
  :credential_refs,    # env var names the child receives from the operator env
  :working_directory,  # absolute, must exist, not the agent workspace root
  :protocol_range,     # min/max, default ["2025-11-25", "2026-07-28"]
  :primitives,         # subset of %i[tools resources prompts]; default [:tools]
  :budgets,            # max_catalog_entries, max_description_bytes, max_output_bytes,
                       # connect_timeout, request_timeout, max_concurrent, idle_timeout,
                       # max_lifetime, stderr_bytes
)
```

Admission validation (fail-closed, typed `Tamoz::Mcp::ValidationError`):

- `command` absolute, executable, not a symlink, not inside the agent workspace
  (invariant 35: repository content is not authority);
- argv elements are strings, no NUL, no control characters, no shell metacharacters;
- `env_allowlist` excludes every credential-shaped name (the P8-E
  `CREDENTIAL_ENV_PATTERN` rule, duplicated deliberately so `tamoz-mcp` does not depend
  on `tamoz-agent`); `credential_refs` must be explicit and are the only credential
  channel;
- budgets finite and positive; `max_output_bytes <= 64 KiB`, catalog entries <= 256,
  description <= 4 KiB (same order as the skill compiler's limits).

The exact command/argv/env-name preview is rendered for operator confirmation by the
caller (CLI/profile integration is the same shape as P8 checks); `tamoz-mcp` itself
only validates and describes.

## 5. Discovery and the immutable catalog (P10-A)

`Catalog.compile(config, client_factory:)`:

1. spawns the supervised stdio client (§8);
2. performs `initialize` (or 2026 stateless discovery) inside `protocol_range` —
   negotiation outside the range fails closed with `ProtocolError`;
3. lists tools (v1: tools only; resources/prompts are catalogued by descriptor only
   when `primitives` admits them, and are never readable in v1);
4. validates every entry: JSON Schema 2020-12 structure, duplicate names rejected,
   descriptions bounded and control-character-stripped, annotations parsed but marked
   `author_claimed` (never policy);
5. computes `snapshot_digest` over the canonical JSON of the accepted entries plus the
   negotiated protocol, with domain separator `tamoz.mcp.catalog.v1\n`.

Each accepted tool becomes a `CapabilityDescriptor` exactly as `MCP_DESIGN.md` §4
specifies: `id = "mcp:#{server_id}/#{tool_name}"`, `kind: :tool`, `source_id` from
configuration, `definition_digest` over the canonical schema/metadata, `trust` from
config, `effect_class` from **local** policy (default `:unknown_effects` → approval
required, non-idempotent, stop-on-unknown), `protocol_profile` the negotiated version.

Quarantine rule (design §7): an invalid entry is dropped individually only when no
other entry's schema references it (`$ref` closure is computed); otherwise the whole
snapshot fails with `ValidationError` naming the entry.

**Epoch rules** (mirrors the P8 profile / P9 skill epoch machinery):

- A session that used an MCP capability pins the catalog digests it ran against as
  `"mcp_catalogs" => {server_id => digest}` in its session record (optional HASH field,
  legacy sentinel `{}`, `RECORD_VERSION` stays 1).
- List-change notifications, TTL expiry, reconnects, or config edits produce a
  *candidate* catalog; the in-flight epoch never changes.
- Resume with a digest mismatch stops with typed
  `Tamoz::Mcp::CatalogSnapshotUnavailableError` — no silent schema substitution.
- v1 surfaces the digest to the caller; wiring into `Session#verify_..._binding!`
  follows the exact pattern of `verify_skill_binding!` and is part of P10-B's
  integration test.

## 6. Execution (P10-B)

`Invocation.call(descriptor, arguments, snapshot:, supervisor:)`:

```text
validate arguments against the snapshotted input schema (JSON Schema 2020-12,
  unknown properties rejected unless the schema explicitly allows them)
→ verify descriptor.definition_digest matches the session-pinned digest
→ invoke through the supervised client with the request deadline
→ validate the protocol result shape; validate structured content against the
  declared output schema when present
→ bound output to budgets.max_output_bytes, strip control characters, attribute
  every content block as "remote content from server <id>" in the observation
→ translate the outcome into Tamoz's typed taxonomy
```

Taxonomy mapping (onto the merged D-7 classes):

| MCP outcome | Tamoz type | Why |
|---|---|---|
| JSON-RPC invalid params / schema validation failure | `ToolArgumentError` | planner's arguments; repairable evidence |
| server-declared tool error result | `ToolArgumentError` with `mcp_remote_error:` prefix | declared failure before any known effect |
| timeout before the request was sent | `ToolArgumentError` (`mcp_unavailable:`) | provably no effect |
| timeout/crash/disconnect after the request was sent, `effect_class` non-idempotent | propagates; effect marked `:unknown` | ambiguous outcome; invariant: never guess |
| same, `effect_class: :read_only` | typed unavailable, retryable by the caller | read-only retry is proven safe |
| protocol corruption (bad frames, schema violation on the wire) | `ToolPolicyError` | server broke the contract |
| elicitation `input_required` | interrupt descriptor (§7) | never a tool error |

Exactly-once (design §8): an MCP request id is not evidence. v1 executes MCP calls as
**reviewed tool calls inside the agent's ordinary effect journal only when the caller
drives them through `EffectDispatcher`**; `tamoz-mcp` itself never retries
automatically except for `:read_only` descriptors, and the retry budget lives in the
supervisor, not the model.

## 7. Elicitation and ambiguity (P10-C slice)

2026 MRTR: a tool call returns `input_required` with a schema (or URL). v1 maps this to
the same durable-interrupt shape the CLI already renders:

```ruby
{
  "kind" => "mcp_elicitation",
  "server_id" => descriptor.source_id,
  "capability" => descriptor.id,
  "definition_digest" => descriptor.definition_digest,
  "fields" => <schema-validated field descriptors>,
  "url" => <optional, egress-checked>,
  "effect_key" => <the originating call's deterministic key>
}
```

- The interrupt is bound to the originating call; the answer is schema-validated and
  the call is re-issued with the input merged, as MRTR requires.
- Headless/unattended runs deny with a typed value; consent is never fabricated.
- Ambiguity preservation: a remote error, an elicitation, and a transport failure are
  three different typed outcomes. None is ever collapsed into "success" or into a
  generic failure.

## 8. Supervision (P10-C slice)

`Supervisor` owns the child process per server:

- connect timeout, per-request timeout, idle timeout, max lifetime;
- concurrency and pending-request caps (v1 default 4/16);
- exponential restart backoff with jitter and a **durable circuit**: after
  `circuit_threshold` (default 3) consecutive transport failures the server is `open`
  and every call fails typed-unavailable until the caller resets;
- teardown: SIGTERM → 2s grace → SIGKILL to the **process group**; a teardown test
  proves no orphaned child or grandchild survives;
- bounded stderr capture (default 8 KiB ring) surfaced only in typed error metadata —
  stderr is untrusted content and never enters prompts raw;
- health states from the design: `disabled`, `starting`, `ready`, `degraded`, `open`,
  `retired`. Failure changes availability, never the pinned catalog.

## 9. The one real test server

`script/mcp_test_server`: a Ruby stdio MCP server built with the official SDK exposing:

- `echo_constant` — read-only; returns its argument (schema/output-validation proof);
- `set_answer` — writes a value to a file named by argv (effect/approval proof);
- `needs_input` — always returns `input_required` with a small schema (elicitation
  proof);
- `churn` — its schema changes between two list calls (epoch/candidate proof);
- `sleep_ms` — sleeps (timeout/hang proof);
- environment flags make it exit mid-call, emit malformed frames, and oversize output
  (crash/corruption/bounding proofs).

Using the SDK for both ends is deliberate: the wire stays honest (Tamoz never sees a
hand-rolled JSON-RPC that accidentally matches its own assumptions), and the server is
still fully deterministic for the gate.

## 10. Tests

### 10.1 Unit/integration

- ServerConfig admission: every §4 rejection vector.
- Catalog: duplicate names, bounded descriptions, `$ref`-closure quarantine vs whole-
  snapshot failure, protocol-range negotiation fail-closed, digest determinism across
  runs and locales, annotation parsing marked `author_claimed`.
- Invocation: schema validation accept/reject matrix, definition-digest mismatch stops
  before any I/O, output bounding and control-character stripping, attribution line
  present, every §6 taxonomy row.
- Supervisor: timeouts fire, circuit opens after threshold and fails typed, teardown
  leaves no process, stderr bounded.
- Elicitation: descriptor shape, schema-validated answer merge, headless deny.

### 10.2 Adversarial (mirrors the P8-E/P9 pattern)

| Vector | Attack | Expected |
|---|---|---|
| Command admission | relative command, symlink, command inside workspace | rejected |
| Env injection | credential-shaped name in `env_allowlist` | rejected |
| Malicious tool name | `delete`, `../x`, name colliding with a local tool | source-qualified; never shadows |
| Malicious description | control chars, 1 MiB description, injection text | stripped/bounded; `author_claimed` |
| Schema bomb | deep `$ref` recursion, 10k properties | bounded; typed rejection |
| Duplicate names | two tools named `delete` | snapshot rejected |
| Wire corruption | malformed frame mid-session | `ToolPolicyError`; circuit counts it |
| Crash mid-call | server exits after receiving a non-idempotent call | effect `:unknown`, propagates, no retry |
| Hang | `sleep_ms` beyond deadline | typed timeout; process reaped |
| Output flood | 10 MiB result | bounded to budget; violation opens the circuit counter |
| Elicitation spoof | `input_required` with non-schema fields, credential-named field | rejected/denied; never auto-filled |
| Epoch churn | schema changes between turns | candidate only; resume stops typed |
| Argument escape | unknown property, nested over-depth | `ToolArgumentError`; no I/O performed |

### 10.3 Scorecard case

16th case `agent.mcp-governed-call`:

1. Workspace with `broken.rb` (answer 40) and the test server as a child process.
2. The session compiles the catalog, plans `mcp:test/set_answer` through the ordinary
   review + approval path, executes it through the effect journal, and the configured
   check passes.
3. The oracle proves: the call carried the pinned definition digest; a second
   invocation with a changed server schema stopped typed; the elicitation tool
   produced a durable interrupt, not a fabricated answer; no credential-shaped env
   reached the child beyond the allowlist; teardown left no process.
4. Aggregate moves 15 → 16 cases, 12 → 13 successes, safety counters stay 0. Identity
   pins bump; fixtures regenerate.

## 11. Deferrals (explicit, with entry conditions)

- **P10-D2 — HTTP/OAuth.** Entry: stdio proofs green. Requires SSRF/redirect policy,
  audience-bound tokens, PKCE/state, token isolation/rotation/revocation, and the
  OAuth adversarial matrix from the design §12. No HTTP code ships in v1; the
  `:http` transport value raises `ValidationError`.
- **P10-H — host/server mode.** Entry: P10-D2. Export manifest only; never raw
  checkpoints, credentials, private memory, approval APIs, or arbitrary turns.
- **P10-E — full official conformance.** v1 runs the §10 matrix against the SDK test
  server. The official conformance suite for every advertised profile runs before
  `tamoz-mcp` is declared stable (P15 release gate), not before the gem exists.
- **Resources/prompts as readable content.** Catalogued only; reading arrives with
  the memory-admission rules of P11 (resources never auto-inject).
- **MCP Tasks extension.** Handles, TTL, and reconciliation arrive with the scheduler
  phase (P13) that owns long-running work.

## 12. Stop / redesign criteria

Stop and escalate if any of these appear:

- The SDK cannot complete an MRTR elicitation over stdio against the test server
  (the §2 amendment's premise fails).
- Argument or output validation can be bypassed by schema fuzzing.
- A remote annotation, description, or result can alter local policy, risk class,
  approval requirements, or the tool surface.
- Transport failure cannot be made as durable as a local tool call (the design's
  definition of "native").
- The SDK's stdio transport cannot guarantee process-tree teardown on every path.

## 13. Definition of done (v1)

- [ ] This plan and `docs/reviews/P10_MCP_PLAN_REVIEW.md` committed before implementation.
- [ ] `gems/tamoz-mcp` with gemspec, dependency-isolation proof, and packaged-gem test.
- [ ] ServerConfig admission with every §4 vector tested.
- [ ] Catalog compiler with digest-pinned snapshot, quarantine rules, epoch rules.
- [ ] Invocation with the full §6 taxonomy and bounding/attribution proofs.
- [ ] Supervisor with deadlines, circuit, and teardown-leaves-no-process proof.
- [ ] Elicitation → durable interrupt, headless deny, schema-validated merge.
- [ ] Session record pins `mcp_catalogs`; changed-catalog resume stops typed.
- [ ] Scorecard case `agent.mcp-governed-call` green; 16 cases; safety counters 0.
- [ ] `rake ci` green under both locales; trackers and `docs/GAUNTLET_PROGRESS.md` updated.
- [ ] Deferrals in §11 recorded in the handover plan and progress ledger.
