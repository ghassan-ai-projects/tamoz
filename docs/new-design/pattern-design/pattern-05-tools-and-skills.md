# Pattern 05 — Tool Use & Skill Registry

Handbook: chapter-05-tool-use-skill-registry.md. Verdict: **Strong — the
load-bearing requirements (resolve-first-execute-second, request-digest idempotency,
permission-first filtering, effect classes, result bounds, sealed registry) all
conform. Missing: per-tool schemas/versioning, structured error classes with retry
guidance, circuit breakers, skill governance metadata.** Builds on: README substrate
(catalog digest discipline); pattern-01 (tool contract in the frame). **Autonomy:
L1 tool surface** — discovery phase is read-only (`:read_only` effect class);
mutation requires approval.

## Handbook definition (owner's)

- The model proposes; the runtime disposes: expose → select → validate (exact
  schema version) → authorize → approve (policy) → execute (timeout/retry/
  idempotency/circuit-breaker) → return bounded result + trace. Only step 2 belongs
  to the model.
- Tool definitions are executable prompts: name, description, parameters, return
  contract, scope, side effects, empty-state semantics, error codes, idempotency,
  output limits. A schema guides generation; it is NOT an authorization boundary.
- Skill registry = control plane: schemas, versions, risk/effect class, permissions,
  execution policy, ownership, deprecation; runtimes cache signed last-known-good
  snapshots.
- Resolve first, execute second: permission filtering before relevance ranking;
  execution re-authorizes against concrete arguments. `ApprovalRequired` is a
  durable state transition, not a prompt response.
- Effect classes + idempotency + sagas: every tool declares read/draft/write/
  external/destructive; every retryable write needs an idempotency key bound to one
  logical user-authorized action; multi-tool pipelines are sagas.
- Structured errors + circuit breakers + untrusted output: seven error classes with
  distinct agent-visible guidance; breakers keyed by failure domain; tool results
  are untrusted input (prompt-injection surface).

## How tamoz implements it (HEAD)

| Handbook req | tamoz mechanism | Ref |
|---|---|---|
| Tool definitions | Frozen description hashes (prose + JSON argument example), imperative per-tool validators | `tool_catalog.rb:13,18,23`; `tool_argument_validator.rb:12-18,33-169` |
| Approval-required | `DEFAULT_APPROVAL_REQUIRED = ACTION_DESCRIPTIONS.keys` (`apply_patch, run_check, create_file`); normalized as subset of allowed_tools | `tool_catalog.rb:28`; `tool_policy_normalizer.rb:96-113` |
| Authorize + approve + execute | Approval gate + observation-budget preflight; deny → `approval_denied` terminal | `session_steps.rb:57-73,96-110` |
| Effect classes | `:reconcilable` (patch/create), operator-declared check safety (default `:unsafe`), else `:read_only` | `local_dispatcher.rb:62-67` |
| Result bounds | Per-tool max effect output bytes (6 KiB), workspace caps (64 KiB check output) | `toolbox.rb:26-33,108-113` |
| Idempotency | Effect journal keyed `LogicalCallKey` + `request_digest` — replay reuses the receipt, never re-executes | `episode_tool_call.rb:41,51,88-111` |
| Registry (control plane) | Sealed closed-world `Capability::Registry`: admission-set intersection, register always raises | `capability/registry.rb:22,72-76,101,126-134` |
| Permission-first | `CapabilityBinding#names(phase)`: discovery sees only `:read_only`; MCP `:unsafe` unless declared read-only | `capability_binding.rb:86-94,271-275`; `mcp_capability_source.rb:126` |
| Pre-execution validation | Plan-time `structural_issues` validates args; execution-time `verify_intent_before_state!` refuses if on-disk state no longer matches approved `before_state` | `deliberation.rb:186,202-227`; `session_effects.rb:48-55` |
| Evidence-tools boundary | Fixed 6 read-only tools, context scrubbed, result caps, bounded rows/bytes | `tamoz-stream/lib/tamoz/stream/capability_host.rb:32-44,117-172` |
| Wire-side verify | `verify!` refuses on identity or digest mismatch under shared domain | `evidence_client.rb:33,94,166-208` |
| Catalog pinning | `toolbox.catalog_digest` verified against profile-pinned `tool_catalog_digest` at session start | `session.rb:158-176`; `profile.rb:90-93` |

## Skills

- `SkillSet` = ordered wire refs `[{name, tree_sha256}]`, digest-pinned; text
  resolved only from the operator-approved source map; SHA-256 must equal the wire
  digest (fail closed before any model call) — `skill_set.rb:20-34,57-85`.
- Tree digest = SHA-256 over the relative-path file listing
  `[[path, kind, digest, executable], …]` — `skills/compiler.rb:188-223`; set digest
  pins `{name, source_class, tree_digest, rendering_protocol_version}`, epoch pinned
  on resume (`enforce_skill_binding!`).
- Discovery = stage-1 progressive disclosure (names/descriptions/risk, byte-budgeted);
  `load_skill` grants no tool/root/credential/approval — `deliberation.rb:131-140`,
  `skills/catalog.rb:32,67,79-88`.
- Selection = **fixed ordered list**, not relevance retrieval — deliberate and
  handbook-endorsed for stable small catalogs.
- Frame injection = fenced, attributed `{id:"skill:<name>", tree_sha256, text}` with
  `skill:<name>` evidence ids — episode_frame_builder.rb:131-137.

## Divergence from the handbook

1. **No per-tool output schema or version/deprecation metadata** — descriptions are
   prose; contracts are imperative validators; the handbook's registry entry
   (input_schema, output_schema, version, deprecated_at, ownership, timeout) is
   absent per tool.
2. **No structured error classes with retry guidance** — results carry `is_error` +
   `error_code` only; the model cannot distinguish "wait and retry" from "never
   retry".
3. **No circuit breakers** on dispatchers or the evidence endpoint (fail-closed
   exists, breaker state machine does not).
4. **No long-running durable job contract** (`start → status → result`); everything
   is synchronous and bounded — acceptable at current scale, defer.
5. **No sagas/compensation** — but no multi-tool pipelines exist either, so
   compliant.
6. **Skill governance metadata missing** — owner, verified risk class (only the
   author-claimed `declared_risk`), deprecation/replacement.
7. **No zero-result/ambiguity logging** for skill discovery resolution.

## How it SHOULD be implemented (on existing seams)

1. **Upgrade catalog entries to data schemas.** Extend each frozen description in
   `tool_catalog.rb:13-28` with `arguments_schema`/`result_schema` (JSON-Schema-
   shaped) while `tool_argument_validator.rb` stays the enforcement layer (schema
   guides, validator refuses). `catalog_digest` already hashes the surfaces — adding
   schemas changes the digest, which is the point: the profile-pinned
   `tool_catalog_digest` (session.rb:158-176) version-locks schemas exactly as the
   handbook's stale-schema control. Add `version`/`deprecated_at`/`replacement`.
2. **Structured error classes.** Extend the tool result projection
   (episode_tool_call.rb:88-111) with a `class` field ∈ {validation, authorization,
   approval_required, not_found, rate_limited, transient, outcome_unknown,
   unavailable}, surfaced in the frame's `tool_results` so the next step is guided
   (retry vs wait vs escalate). Keep `result_sha256`/`result_bytes` unchanged —
   replay contract intact.
3. **Circuit breaker on the evidence endpoint** keyed by tenant (evidence_client.rb
   call path) — one tenant's failures must not open the circuit for all.
4. **Skill governance metadata** — owner + declared risk class + deprecation rendered
   as author claims (already the pattern at skills/catalog.rb:67); add
   ambiguity/truncation trace events at discovery (catalog.rb:32,79-88).
5. **Sagas + long-running jobs: defer** — no multi-tool pipelines exist; add the
   durable job contract only when a tool can exceed the model turn.

## Gap list (priority order)

| # | Gap | Landing spot |
|---|---|---|
| T1 | Per-tool schemas + version/deprecation | `tool_catalog.rb:13-28` surfaces → profile-pinned `catalog_digest` |
| T2 | Structured error classes | `episode_tool_call.rb:88-111` result projection |
| T3 | Circuit breaker keyed by failure domain | `evidence_client.rb` call path |
| T4 | Long-running job contract | New job store next to `ACTION_DESCRIPTIONS` — **defer-by-design** (no tool exceeds the model turn today) |
| T5 | Skill governance metadata | `skills/compiler.rb:188-208` + `skills/catalog.rb:67` |
| T6 | Log zero-result/ambiguous discovery queries | `skills/catalog.rb:32,79-88` |
| T7 | Aggregate-value checks against threshold gaming | `session_steps.rb:57-73` gate + profile threshold |

**Tests to update:** T1 changes `tool_catalog` surfaces → `catalog_digest`-pinning
tests and the session catalog tests; T2 changes the tool-result projection asserted
in the tool-loop tests.
