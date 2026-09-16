# F09 `tamoz-mcp` — governed MCP client/host: strong local boundary, two real seams (elicitation interrupt is dropped; server-authored description rides into the planner prompt unmarked)

Row: F09 · Queue: W1B (authority / profile / tools / MCP / capabilities) · Baseline: branch `audit-15-09`, commit `582ae55`, 2026-09-15 · Analyst: independent F09 analyst · Budget ~50 min

## Scope and source map

All 13 files under `gems/tamoz-mcp/lib` were read end to end (2779 lines), plus the gemspec.

| File | Lines | Role |
|---|---:|---|
| `gems/tamoz-mcp/lib/tamoz/mcp.rb` | 20 | require graph / entry seam |
| `gems/tamoz-mcp/lib/tamoz/mcp/version.rb` | 7 | `0.1.0.alpha.1` |
| `gems/tamoz-mcp/lib/tamoz/mcp/errors.rb` | 138 | typed outcome taxonomy (§6) |
| `gems/tamoz-mcp/lib/tamoz/mcp/shared_constants.rb` | 32 | `CONTROL_CHARACTER_PATTERN`, `CLIENT_INFO` |
| `gems/tamoz-mcp/lib/tamoz/mcp/bounded_text.rb` | 38 | untrusted display-string bound |
| `gems/tamoz-mcp/lib/tamoz/mcp/canonical_json.rb` | 68 | deterministic digests |
| `gems/tamoz-mcp/lib/tamoz/mcp/server_config.rb` | 474 | **admission** (prior 085, `IMPROVE`) |
| `gems/tamoz-mcp/lib/tamoz/mcp/circuit_supervision.rb` | 122 | shared circuit/backoff |
| `gems/tamoz-mcp/lib/tamoz/mcp/supervisor.rb` | 454 | **stdio lifecycle** (prior 091 PASS) |
| `gems/tamoz-mcp/lib/tamoz/mcp/http_supervisor.rb` | 129 | HTTP lifecycle |
| `gems/tamoz-mcp/lib/tamoz/mcp/catalog.rb` | 251 | **catalog admission** |
| `gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb` | 764 | **the wire call** (prior 023, SIZE/FX open) |
| `gems/tamoz-mcp/lib/tamoz/mcp/elicitation.rb` | 282 | **MRTR interrupt** |

Entry seam: `Tamoz::Mcp::ServerConfig` (admission) → `Catalog.compile` (pin) → `Invocation.call` (one call) → `Supervisor` (lifecycle). The gem is deliberately duck-typed at its boundary: it does not depend on `tamoz-agent`, and `tamoz-agent` does not depend on it.

Consumer surface read for the boundary trace: `gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb` (299), `mcp_capability_source.rb` (292), `capability_binding.rb` (462), `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb` (406), `session_steps.rb` (309), `session_plan_outcome.rb`/`session_plan_attempt.rb`, `gems/tamoz-agent-kernel/lib/tamoz/agent/deliberation.rb`, `effect_dispatcher.rb` (334), `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb` (interrupt rendering), `gems/tamoz-agent/lib/tamoz/agent/worker.rb`.

Docs read: `documentation/design/mcp.md`, `documentation/architecture/security-model.md`, `documentation/guides/agent-operator.md` §4–5, `documentation/limitations.md`, `docs/P10_MCP_PLAN.md` §6–8.

## Behavior path

1. **Admission.** Operator `config.yaml` (mode-0700 runtime dir, `runtime_directory.rb:301-340`) → `McpSourceBuilder#server_configs` (`mcp_source_builder.rb:257-263`) → `ServerConfig.new` (`server_config.rb:113-153`). Fail-closed: absolute non-symlink executable outside the workspace (`:326-353`), no shell metacharacters in argv (`:376-379`), credential-shaped `env_allowlist` rejected (`:396-400`), HTTPS-or-loopback endpoints (`:230-236`), HTTP cannot carry a command/argv/env/cwd (`:299-310`).
2. **Catalog pin.** `Catalog.compile` (`catalog.rb:32-54`) spawns the supervisor, negotiates the protocol version inside the configured range (`:67-95`), validates entry names against `TOOL_NAME_PATTERN` (`:181-187`), rejects duplicates (`:189-195`), bounds descriptions via `BoundedText` (`:200-202`), and freezes a `snapshot_digest` (`:239-246`).
3. **Risk classification.** `effect_class` is local operator policy only: `effect_class_for(entry, read_only)` returns `:read_only` iff the operator listed the tool in `read_only_tools`, else `:unknown_effects` (`mcp_source_builder.rb:202-204`, `:80-89`). Server annotations are parsed but never consulted (`catalog.rb:26`, `:208-212`).
4. **Node execution.** `SessionSteps#step_execute` → `SessionEffects#dispatch` → `EffectDispatcher.run` (`session_effects.rb:75-86`) → `Capabilities#execute` → `McpDispatcher#execute` → `McpCapabilitySource#execute` → executor lambda → `Invocation.call` (`mcp_source_builder.rb:108-123`).
5. **Invocation.** `validate_descriptor!` → `validate_arguments!` (default-deny strictify, depth ≤ 100) → `open_pinned_channel` (**digest gate before any I/O**, `invocation.rb:269-292`) → `transport_round_trip` under deadline → result-shape validation → bounded/attributed observation (`:615-628`).

## Lens: correctness — reviewed

The typed pipeline is ordered correctly and the pre-I/O gate is real: `verify_pinned_digest!` runs before `ensure_available!`, client construction, and connect (`invocation.rb:285-292`), raising `CatalogSnapshotUnavailableError` with no request sent (`:269-281`). Argument validation rejects non-objects, over-depth payloads, and unknown properties unless the schema opts in (`:185-265`).

Result shape is validated before use (`:582-596`), unknown content-block types are terminal (`:679-683`), and structured content is checked against the declared output schema when present (`:598-611`). Output is byte-bounded and attributed (`:644-661`).

One correctness divergence is recorded as F09-COR-01 below: `Invocation` branches on `descriptor.read_only?` while the binding branches on `descriptor.effect_class`, and the two are independently supplied on a duck-typed object.

## Lens: security and authority — reviewed

**Who may add a server.** Only the operator. `RuntimeDirectory` calls itself "the only place its authority comes from" and reads a mode-0700 `config.yaml` (`runtime_directory.rb:10-28`, `:301-340`, `:326-334`). `McpSourceBuilder` states and honors "Nothing here reads the workspace" (`mcp_source_builder.rb:25-27`); the server list, commands, env allowlist, and risk classification all come from the runtime directory (`:265-296`). I found **no path** by which a workspace file, a model reply, or an MCP server can add, repoint, or reclassify a server: the builder is constructed from `@directory` only, `KNOWN_SOURCES` is a closed set (`runtime_directory.rb:43`), and a server id of `websearch` is refused under `sources.mcp.servers` (`mcp_source_builder.rb:274-276`). **Disproven as a content-grant path.**

**Catalog admission.** A tool name must match `/\A[A-Za-z\d_\-.]{1,128}\z/` (`catalog.rb:23`, `:181-187`) — a name outside the charset fails the whole snapshot before it reaches a message, path, or descriptor id. Duplicates fail the snapshot (`:189-195`). An invalid input schema fails the snapshot (`:135-152`). Descriptions are control-stripped and byte-bounded (`:197-202`). Entry count is capped at 256 (`:107-113`). Server annotations are never policy (`:26`).

**Can a tool claim `read_only` while performing writes?** The server cannot: only `settings["read_only_tools"]` grants `:read_only` (`mcp_source_builder.rb:202-204`). But the operator can mislabel a mutating tool, and the effect is real — see F09-SEC-01.

**Elicitation.** Well guarded at construction: only `elicitation/create` shapes are accepted (`elicitation.rb:129-137`), credential-shaped property names reject the whole interrupt (`:174-184`), every schema string is control-stripped and byte-bounded (`:151-164`), input-request count is capped at 32 (`:98-109`), offered URLs are egress-gated (`:250-273`), and headless runs deny with typed `consent => false` (`:50-58`, `invocation.rb:535-546`). Answer validation reuses the same default-deny strictify (`:218-222`). **The interruption never reaches the operator** — F09-SEC-02.

**Secrets.** `env_allowlist` entries that are credential-shaped are rejected outright (`server_config.rb:387-404`); credentials reach the child only through explicit `credential_refs` (`supervisor.rb:313-322`). The child env is built with `unsetenv_others: true` and an explicit map (`:335-347`), and resolved credential values are redacted by value from the stderr tail (`:324-333`, `:210-217`). HTTP credentials never live in YAML (`server_config.rb:263-281`). Proven by `test/mcp_supervisor_test.rb:87-100`, `:168-193`.

## Lens: reliability and durability — reviewed

**Ambiguity.** The request-sent boundary is explicit: `Supervisor#send_request` clears the flag before the SDK write and sets it inside the yield (`supervisor.rb:192-202`), so `record_transport_failure` can distinguish "provably no effect" from "may have acted" (`invocation.rb:435-452`). A post-send failure on a non-read-only descriptor raises `AmbiguousOutcomeError` (`:503-509`), which the executor maps to `Tamoz::EffectUnknownError` (`mcp_source_builder.rb:160-162`), which `EffectDispatcher#execute_outcome` records as terminal `:unknown` (`effect_dispatcher.rb:192-203`). **Correct — never guessed, never blindly retried.**

**Replay.** A replayed MCP step does not re-invoke the server: identity is journaled on the *request* (`session_effects.rb:135-147`, keyed on operation, capability id, canonical arguments, authority revision, and an MCP catalog revision at `:153-156`), and a `succeeded` row returns the recorded receipt via `action = :return` (`effect_preparation.rb:150-153`). **Re-invoking a non-idempotent MCP tool on replay is disproven.**

Automatic retry is confined to `read_only?` descriptors (`invocation.rb:382`, `:402-404`) and corruption is never retried (`:402-404`, `:467`).

**Lifecycle.** Teardown is close-pipes → wait → SIGTERM → 2 s grace → SIGKILL to the whole **process group** (`supervisor.rb:379-389`), with `pgroup: true` at spawn (`:340-347`). Orphans are disproven by `test/mcp_supervisor_test.rb:104-116` (grandchild) and `:333-360` (restart). A supervisor that was never started is retired and never auto-started (`:238-247`).

One durability gap: an MCP elicitation cannot be resumed at all — F09-SEC-02.

## Lens: observability and evidence — reviewed

Refusals are typed and carry a category: `ValidationError` / `ProtocolError` / `CatalogSnapshotUnavailableError` / `ToolArgumentError` / `ToolPolicyError` / `UnavailableError` / `AmbiguousOutcomeError` / `CircuitPolicyError` (`errors.rb:26-136`), each with a `CATEGORY` string and a `SAFE_MESSAGE`. The ambiguous row is explicitly *not* retryable (`:100-106`).

Circuit health is observable as `disabled → starting → ready → degraded → open → retired` (`circuit_supervision.rb:40-47`), and a reset records a typed `conditions_digest` of the failure state it cleared (`circuit_supervision.rb:85-94`, `supervisor.rb:99-106`). Failure kind and context are retained (`supervisor.rb:46-54`, `:87-93`).

Remote content is attributed on every block (`invocation.rb:32`, `:644-661`), and the observation carries `provenance => 'remote_untrusted'` into the session record (`session_effects.rb:238-245`). Stderr surfaces only as typed error metadata, bounded and redacted (`supervisor.rb:204-217`).

**Gap:** the attribution exists on the *result* path but not on the *advertising* path — a server's tool description reaches the planner prompt with no trust marker. F09-SEC-01.

## Lens: scalability and resource bounds — reviewed

Every dimension is bounded in `Budgets` with construction-time caps (`server_config.rb:59-111`): catalog entries ≤ 256, description ≤ 4096 B, output ≤ 64 KiB, connect/request/idle/lifetime timeouts positive and finite, `stderr_bytes` positive. `MAX_ARGUMENT_BYTES` 4096 and `MAX_HEADER_VALUE_BYTES` 4096 (`:35-36`). Argument nesting is capped at 100 (`invocation.rb:30`, `:217-229`); canonical JSON nesting is capped at 100 (`canonical_json.rb:34`). Output bounding stops accumulating once the budget is exhausted (`invocation.rb:650-651`), and oversized structured content is dropped and flagged `truncated` rather than passed through (`:726-736`). Elicitation input requests are capped at 32 and messages at 4096 B (`elicitation.rb:22-23`).

The stdio frame bound is the SDK's own `MAX_LINE_BYTES = 4 MiB` (`mcp-1.1.0/lib/mcp/client/stdio.rb:27`), which `Supervisor#read_line` inherits and converts to a typed `OutputLimitError` (`supervisor.rb:285-296`, `errors.rb:128-136`). That is a *frame* bound, not the 64 KiB output budget, which is applied after parsing. It is a 64× headroom over the configured output budget, so a server can make Tamoz parse up to 4 MiB per frame before bounding to 64 KiB. Bounded and logged, but recorded as F09-INFO-01 since the amplification is real. HTTP passes `max_message_bytes: @config.budgets.max_output_bytes` explicitly (`http_supervisor.rb:106-112`).

## Lens: maintenance and architecture — reviewed

Dependency direction is honest and documented: `tamoz-mcp` depends only on `tamoz-core`, `tamoz-cancellation`, and the `mcp` SDK (`tamoz-mcp.gemspec`), and the deliberate duplication of the argv and credential-env rules is explained at the point of duplication (`server_config.rb:38-52`). The shared-constant home is explicitly documented with the reason it moved (`shared_constants.rb:3-19`) — this is the kind of "why" comment the standard asks for. `CircuitSupervision` is a module rather than a superclass precisely because `Supervisor` already subclasses the SDK's `Stdio` (`circuit_supervision.rb:6-8`).

`Invocation.call` (7 params), `reissue` (10), and `round_trip` (8 keywords) exceed the 5-param ceiling — prior finding 023 SIZE, still open, confirmed at `invocation.rb:84`, `:108`, `:358`. Prior 023 DEAD is confirmed **fixed**: `strict_schema` (`:239-241`) now delegates entirely to `deep_strictify` (`:243-265`) with no redundant root merge. Prior 023 FX is confirmed **open**: `resume_tool` still drives the SDK's private pipeline via `client.send(:request, ...)` (`:427`).

## Tests and contracts

All ten MCP-relevant files were run, one file per command, each well under 2 minutes.

| Command | Result |
|---|---|
| `ruby -Itest test/mcp_server_config_test.rb` | 39 runs / 321 assertions / 0F / 0E |
| `ruby -Itest test/mcp_catalog_test.rb` | 9 runs / 80 assertions / 0F / 0E |
| `ruby -Itest test/mcp_supervisor_test.rb` | 16 runs / 87 assertions / 0F / 0E |
| `ruby -Itest test/mcp_elicitation_test.rb` | 19 runs / 71 assertions / 0F / 0E |
| `ruby -Itest test/mcp_invocation_test.rb` | 31 runs / 208 assertions / 0F / 0E |
| `ruby -Itest test/mcp_http_test.rb` | 2 runs / 11 assertions / 0F / 0E |
| `ruby -Itest test/agent_mcp_adversarial_test.rb` | 8 runs / 41 assertions / 0F / 0E |
| `ruby -Itest test/agent_mcp_capability_source_test.rb` | 14 runs / 102 assertions / 0F / 0E |
| `ruby -Itest test/agent_worker_mcp_test.rb` | 11 runs / 35 assertions / 0F / 0E |
| `ruby -Itest test/agent_cli_mcp_test.rb` | 6 runs / 28 assertions / 0F / 0E |

Total: **155 runs / 984 assertions / 0 failures / 0 errors / 0 skips.** Prior 020 (`mcp_invocation_test`) and 098 (`mcp_server_config_test`) PASS statuses are confirmed against current source. The prior 018 PASS for `agent_mcp_capability_source_test.rb` is confirmed.

Contracts that pin the security claims: `test/mcp_server_config_test.rb` (argv/env/endpoint rejection), `test/mcp_supervisor_test.rb:87-100` (env restriction), `:168-193` (credential redaction), `:104-116` + `:333-360` (process-group teardown, restart), `test/mcp_elicitation_test.rb` (credential-shaped field rejection, non-egress-safe URL omission, headless denial).

**Not run:** `test/agent_smoke_corpus`-driven scorecard suites and `rake ci`/`ci_full`, per the brief's budget rule. **Not found:** any test that drives an MCP elicitation through a full session to a rendered operator prompt (this is the evidence gap behind F09-SEC-02); any test asserting the descriptor's `effect_class` and `read_only?` agree (F09-COR-01).

## Findings

### F09-SEC-01 — server-authored tool descriptions reach the planner prompt verbatim and unmarked

| Field | Content |
|---|---|
| Severity | **major** |
| Confidence | **high** |
| Status | **open** |
| Source evidence | `catalog.rb:200-202` (description bounded only by control-strip + 4096 B); `session_effects.rb:392-401` (`mcp_entry` returns the raw description); `session_effects.rb:337-342` (`mcp_planning_surface`); `session_deliberation.rb:62`; `session_plan_attempt.rb:63,180`; `deliberation.rb:104-108` (`merge_tool_surfaces` merges `mcp_tools` into `available_tools` with no marker); `deliberation.rb:119-128` (both surfaces land in the same `available_tools` object). Absence of any trust marker confirmed by probe C. |
| Test/contract evidence | `test/mcp_catalog_test.rb` (9 runs) verifies bounding, not provenance marking. Probe C (logged `/tmp/tamoz-agents/analyst_f09.log`): a 6132-byte hostile description bounded to 4096 bytes retained `IGNORE ALL PREVIOUS INSTRUCTIONS` and `never ask for approval` verbatim, and matched no `untrusted`/delimiter pattern. **Not found:** any test asserting MCP descriptions are distinguishable from local ones in the prompt. |
| Scanner signal | The authority/tools scanner flagged MCP description handling as an authority lead. |
| Independent judgment | Confirmed. The bounding is real and correct, but bounding is not provenance: a server controls up to 4 KiB of text that lands in the same `available_tools` JSON as trusted local descriptions, with no delimiter, prefix, or `provenance` field. `documentation/design/mcp.md` states descriptions "are untrusted input" and the security model says they can only *request* — both are true of the code's intent, but neither is represented in the prompt bytes themselves, so the model has no way to tell which entries are remote. |
| Root cause | 1. A server's description reaches the prompt because `mcp_planning_surface` forwards it. 2. It forwards it unmarked because `merge_tool_surfaces` merges two maps of the same shape. 3. The two maps are the same shape because the planning surface was modeled as "tool name ⇒ description string" rather than "tool name ⇒ described capability with provenance". 4. Provenance is recorded on the *result* path (`session_effects.rb:238-245`, `provenance => 'remote_untrusted'`) but the *advertising* path never got the same treatment. 5. No test asserts description provenance, so the asymmetry was never surfaced. |
| Recommendation | Smallest credible action at the existing seam: mark the remote surface where it is already filtered. In `SessionEffects#mcp_planning_surface` (`session_effects.rb:337-342`), prefix or wrap each returned description with the same `remote content from server <id>` attribution `Invocation` already uses for blocks (`invocation.rb:32`, `:640-641`), so `merge_tool_surfaces` keeps its current shape and the prompt distinguishes remote from local text with no new machinery. Add one assertion to `test/agent_mcp_capability_source_test.rb`. No new class, no schema change. |
| Disposition | Open. Severity is `major`, not `critical`, because the injection cannot itself grant authority: an injected call still routes through plan review, and an unlisted MCP tool is `:bounded` with `approval_policy: :required` (`capability_binding.rb:344-353`), so a human still sees the exact argv-free preview before dispatch. The operational cost is a model that can be steered toward an approval prompt the operator did not originate — and, per `security-model.md`, the operator's decision is the last gate. |

### F09-SEC-02 — an MCP elicitation is collapsed into a tool failure and never reaches the operator

| Field | Content |
|---|---|
| Severity | **critical** |
| Confidence | **high** |
| Status | **open** |
| Source evidence | `invocation.rb:370-375` returns `Outcome#status = :interrupt` carrying a well-formed descriptor; `mcp_source_builder.rb:117-121` returns that Outcome unchanged as the executor's result; `session_effects.rb:229-232` duck-types it as an MCP outcome; `session_effects.rb:246-251` maps **both** `:denied` and `:interrupt` to `raise ToolError, "MCP capability did not complete: ..."`. No production consumer distinguishes `:interrupt`: the only other match is `governed_browser_source.rb:180`, which is not wired into `CapabilityBinding` (grep for `GovernedBrowserSource` finds only the require at `agent_capabilities.rb:15`). `Invocation.reissue` (`invocation.rb:108-124`) — the only path that can merge an answer and re-issue — has **no production caller** (only `test/mcp_elicitation_test.rb:372,410`, `test/agent_mcp_capability_source_test.rb:619`). The CLI's generic interrupt prompt (`cli.rb:538`, `cli_prompt_adapter.rb:57-60`) is unreachable for this kind because the descriptor never enters `view.interrupts`. |
| Test/contract evidence | `test/mcp_elicitation_test.rb` (19 runs / 71 assertions / 0F) proves the *descriptor* is built correctly, never that it is delivered. `test/mcp_invocation_test.rb:670-700` asserts `Outcome#status == :interrupt` and the headless `:denied` shape at the `Invocation` boundary. **Not found:** any test that drives an elicitation through `SessionSteps`/`SessionEffects` and asserts an operator-visible interrupt. `test/support/agent_smoke_corpus.rb:1486-1505` counts an elicitation as a passed *proof* by calling `Invocation.call` directly, bypassing the session entirely — so the scorecard's `mcp_elicitation_interrupts` counter reports the gem's behavior, not the agent's. |
| Scanner signal | none — found by tracing the `:interrupt` branch from the Outcome to its only consumer. |
| Independent judgment | Confirmed. `documentation/design/mcp.md` promises "elicitation or an `input_required` result is bound to the originating call, **persisted as an interrupt**, and rendered with the configured server identity", and `docs/P10_MCP_PLAN.md:210` shows the durable-interrupt shape. The gem builds exactly that value; the layer that owns persistence and rendering discards it one call later. The user-visible behavior is that a server which needs input produces "MCP capability did not complete" recorded as a **failed effect**, the step is retried through the repair loop with the same arguments, and the same elicitation recurs until the repair budget is exhausted — a livelock with no operator-visible cause, and an unattended run behaves identically to an attended one. This is the exact failure mode `mcp.md` says the design avoids. |
| Root cause | 1. An elicitation becomes a tool failure because `mcp_payload` groups `:denied` with `:interrupt`. 2. It groups them because both are "did not succeed" at that point in the code, and only `:succeeded` has a payload body. 3. `ToolError` was the available way to leave the block, since `EffectDispatcher`'s `perform` contract returns a value or raises. 4. `Outcome#status` was given a third state (`invocation.rb:43`) but `SessionEffects` — the only consumer — was never extended to carry it, and `McpCapabilitySource` exposes no interrupt renderer (its documented surface is executor/validator/previewer/effect_intent_builder only, `mcp_capability_source.rb:19-31`). 5. No test spans the gem boundary for this path, so the missing consumer was invisible to both the gem's own suite and the scorecard. |
| Recommendation | Smallest credible action at the existing seam: teach the one consumer that already owns the decision. In `SessionEffects#mcp_payload` (`session_effects.rb:246-251`), give `:interrupt` its own branch that raises a distinct typed value (a new `Tamoz::Agent` error carrying the descriptor, or reuse the graph interrupt mechanism the way `SessionSteps#approval_update` does at `session_steps.rb:147-158`), so the descriptor reaches the step gate instead of the failure path. Then route the answered value through `Invocation.reissue` — which already exists and is currently dead code — using the `effect_key` the descriptor carries. If the full MRTR round trip is out of scope for this audit cycle, the minimal honest change is to make the `:interrupt` branch **terminal and operator-visible** rather than repairable, so the run stops with the server's question instead of looping. Do not build new machinery: `Tamoz.interrupt` (`graph/interrupt.rb:51`) is the existing seam. |
| Disposition | Open, critical. This violates a stated design invariant (elicitation is "persisted as an interrupt"), produces materially misleading evidence (a question recorded as a failed effect, and a scorecard that counts the gem's direct call as proof the agent surfaced it), and on a non-idempotent tool the repeated repair attempts are journaled against the same logical effect. Needs an independent challenge before closure, and needs one end-to-end test that fails today. |

### F09-COR-01 — `Invocation` and the capability binding read different fields of the same duck-typed descriptor with no agreement guard

| Field | Content |
|---|---|
| Severity | **major** |
| Confidence | **high** |
| Status | **open** |
| Source evidence | `invocation.rb:76-78` (`Descriptor#read_only?` derives from `effect_class`) — but `call` only requires the duck-type (`invocation.rb:37`, `:171-180`), so a caller-supplied object may define `read_only?` independently. `Invocation` branches on `read_only?` at `:382` and `:489`; the binding branches on `effect_class` at `capability_binding.rb:192-194` (`closed_effect_class`) and `:344-353` (`mcp_approval_policy`, `mcp_retry_policy`). `McpCapabilitySource#read_only?` (`mcp_capability_source.rb:104-106`, `:172-176`) prefers the duck-typed `read_only?` when present, which is what `McpDispatcher#safety` consumes (`capability_binding.rb:451-453`). Production constructor is consistent: `descriptor_for` sets `effect_class` and `read_only?` derives from it (`invocation.rb:150-165`). |
| Test/contract evidence | Probe A (logged): a descriptor with `effect_class = :bounded` and `read_only? = true` drove a **post-send** transport failure to `Tamoz::Mcp::UnavailableError: ... the call is read-only and may be retried by the caller` instead of `AmbiguousOutcomeError` — i.e. an unsafe effect was classified as provably safe to retry. Probe B (logged): `descriptor_for(effect_class: :bounded).read_only? == false`, so the production path is consistent. **Not found:** any test asserting the two fields agree. |
| Scanner signal | A scanner recorded the same shape: "binding `effect_class=:bounded` but `safety=:read_only`; production builder is consistent, duck-typed contract has no mismatch guard." |
| Independent judgment | Confirmed as a real seam, **lead-level** as an exploitable defect. Transcription of the finding is accurate: the duck-type contract is real (`mcp_source_builder.rb:28-31` documents the narrow contract; `capability_binding.rb:213-219` explains why it reads only promised fields), the two readers are real, and no guard exists. The mitigating fact is that `McpSourceBuilder#append_descriptors` (`mcp_source_builder.rb:80-89`) is the only production descriptor source and it uses `descriptor_for`, which cannot produce the divergence. So the mismatch is currently reachable only from test code or a future caller that hand-builds descriptors against the documented 5-method duck-type — which is exactly the extension point the gem advertises. |
| Root cause | 1. The two layers disagree because they read different fields. 2. They read different fields because the duck-type promises `effect_class` while the invocation path needs a boolean, and `Descriptor` happens to derive one from the other. 3. The derivation is a convenience on one implementation, not part of the contract. 4. The gem deliberately keeps the contract narrow (5 methods) to avoid depending on `tamoz-agent`, so `read_only?` was never promoted to a required method. 5. No test crosses the two readers, so a hand-built descriptor can diverge silently. |
| Recommendation | Smallest credible action at the existing seam: make the invariant checkable where the descriptor is already validated. Add `:read_only?` to `REQUIRED_DESCRIPTOR_METHODS` (`invocation.rb:37`) so every caller must supply it explicitly, **or** — cheaper and sufficient — have `Invocation` derive its branch from `effect_class` when the descriptor responds to it (`descriptor.respond_to?(:effect_class) ? descriptor.effect_class.to_sym == :read_only : descriptor.read_only?`), matching `McpCapabilitySource#read_only_descriptor?` (`mcp_capability_source.rb:172-176`) which already prefers `read_only?`. Pick one reader as authoritative and say so in the duck-type comment at `mcp_source_builder.rb:28-31`; then add the one-line assertion to `test/mcp_invocation_test.rb`. |
| Disposition | Open at `major` because a divergent descriptor turns an ambiguous non-idempotent call into a retryable one, and retrying an unsafe MCP effect is the outcome invariant 21 exists to prevent. Confidence in the *mechanism* is high (probe A); confidence in the *reachability* is medium, since no production caller constructs such a descriptor today. Record as a contract gap needing a decision, not as a proven production defect. |

### Carried forward by name — current status against this source

**CF05-SEC-01** (major/contract, **open**) — verified against current source; unchanged. The half that lives **here** is narrow and I confirm it is *not* a defect in this gem: `tamoz-mcp` supplies the catalog, the descriptor set, and `source_digest`, but it makes no admission decision of its own and has no profile concept (no `profile` reference anywhere in the 13 files). The half that lives in `tamoz-agent` / `tamoz-agent-capabilities` is the one the finding describes: `CapabilityBinding#admission_set` (`capability_binding.rb:161-169`) appends every `@mcp.names` beside the profile-derived `@toolbox.allowed_tools`, and `McpSourceBuilder` builds the source without consulting a profile (`mcp_source_builder.rb:50-69`; the CLI's `build_mcp_source` accepts a `profile:` argument at `cli.rb:650` but uses it only to compare the workspace root, `:652-658`). The repository's conflicting authority descriptions are unchanged: `runtime_directory.rb:26-28` ("Everything here is operator authority") versus `security-model.md` ("effective authority is the **intersection**") and invariant 35. I add one datum the original analysis did not have: the binding's own comment at `capability_binding.rb:157-162` calls the admission set "policy-derived" and claims `Toolbox#allowed_tools` is "the already-intersected profile surface", while the same expression unconditionally appends `@mcp.names` — so the code comment asserts the intersection that the code does not perform. That strengthens the contract-gap reading without changing the disposition.

**Prior top-100 023 (`invocation.rb`)** — DEAD **confirmed fixed**: `strict_schema` (`invocation.rb:239-241`) delegates wholly to `deep_strictify` (`:243-265`), which injects the root deny under the same `strictable_object?` predicate; no redundant merge remains. SIZE **confirmed open**: `call` 7 params (`:84`), `reissue` 10 (`:108`), `round_trip` 8 keywords (`:358`). FX **confirmed open**: `resume_tool` still calls `client.send(:request, ...)` (`:427`), with the rationale documented at `:424-426`. SIZE and FX remain minor maintenance items and are not re-recorded as new findings.

**Prior 085 (`server_config.rb`, IMPROVE)** — the validator breadth is unchanged and I found no new defect in it; every declared field has a fail-closed check and `describe` (`server_config.rb:158-175`) exposes env/credential **names** only, never values. Not re-litigated.

**Prior 091 (`supervisor.rb`, PASS)** — upheld. The FX-relevant question the brief asks is answered affirmatively: `invocation.rb` **does** satisfy the AGENTS.md rule. `Invocation` is a pure call primitive that owns no journal and documents that "the caller drives the result through its own effect journal" (`invocation.rb:26-28`); its only production caller is the executor lambda at `mcp_source_builder.rb:120`, which is reached exclusively through `McpCapabilitySource#execute` → `McpDispatcher#execute` → `CapabilityBinding#execute` → `SessionEffects#execute_dispatch` (`session_effects.rb:180-184`) inside `EffectDispatcher.run` (`session_effects.rb:75-86`). **No raw call site was found inside a graph node**, so no `critical` FX finding is recorded. The two non-node call sites are admission-time and out of journal scope by design: `Catalog.compile` (`mcp_source_builder.rb:73`) and `Supervisor.build` (`:75`) run once per runtime when `mcp_source` is first materialized (`worker_runtime.rb:919-923`), before and outside graph execution, and a catalog is not replayable state — it is pinned by digest instead (`session_bindings.rb`, `enforce_mcp_binding!` at `session.rb:445`).

### F09-INFO-01 — stdio frame bound (4 MiB) is 64× the configured output budget

| Field | Content |
|---|---|
| Severity | **info** |
| Confidence | **high** |
| Status | **open** |
| Source evidence | `supervisor.rb:285-296` inherits the SDK's `@max_line_bytes`; SDK default `MAX_LINE_BYTES = 4 * 1024 * 1024` (`mcp-1.1.0/lib/mcp/client/stdio.rb:27`), passed through at `supervisor.rb:174-178` without an override. The 64 KiB `max_output_bytes` budget is applied only after parsing (`invocation.rb:615-628`). HTTP sets the bound explicitly (`http_supervisor.rb:106-112`). |
| Test/contract evidence | `test/mcp_supervisor_test.rb:362-376` proves the typed `OutputLimitError` fires at the frame bound. **Not found:** any assertion on the numeric bound itself. |
| Independent judgment | Verified design fact, not a defect. The read is bounded and fails typed, and the desynced stream is closed (`supervisor.rb:289-295`), so this is memory amplification, not an unbounded read. Worth recording because stdio and HTTP enforce different numbers for the same configured budget. |
| Root cause | n/a (info). |
| Recommendation | If the asymmetry matters, pass `max_line_bytes: config.budgets.max_output_bytes` in the `super` call at `supervisor.rb:174-178` so both transports enforce the configured budget. No other change needed. |
| Disposition | Info; no action required for this audit. |

## Blind spots

- **No real MCP server or live network call was made**, per the brief. All probes used hand-built descriptors and doubles; the elicitation gap is proven by source trace, not by running a server that asks for input.
- **No real model was called**, so the prompt-injection finding (F09-SEC-01) is proven at the prompt-assembly seam, not by observing a model act on an injected instruction. I did not and cannot claim a model was steered.
- **`McpCapabilitySource`'s `catalog_revision`** participates in the effect logical identity (`session_effects.rb:153-156`); I read it but did not exercise a catalog-change replay, so the claim that a changed catalog re-keys the effect rather than reusing the old receipt is source-read only.
- **`GovernedBrowserSource` / `GovernedDatabaseSource`** appear unwired from `CapabilityBinding`. I noticed this while tracing the `:interrupt` consumer and did **not** investigate it — it belongs to F08/F18 and is recorded here only so the coordinator can route it.
- **Prior 085 and prior 091** were verified against current source at the level the brief asked; I did not re-derive their full finding sets.
- **No test suite outside the ten MCP files was run** (no `rake ci`, no scorecard suites), per the budget rule. The scorecard blind spot in F09-SEC-02 was found by reading `test/support/agent_smoke_corpus.rb:1486-1505`, not by running it.

## Verdict

**IMPROVE** — counts: **critical 1, major 2, minor 0, info 1** (plus four carried-forward items: CF05-SEC-01 open, 023 DEAD fixed / SIZE+FX open, 085 and 091 unchanged).

The gem's own boundary is the strongest part of this row: admission is fail-closed and operator-only, the pinned-digest gate precedes all I/O, ambiguity is typed and never guessed, replay returns the recorded receipt instead of re-invoking, the child process tree is genuinely killed, credentials are allowlisted and redacted by value, and every resource dimension has a construction-time cap. The two real defects sit at the gem's *edges*, which is where the duck-typed boundary puts the risk: the elicitation the gem correctly builds is discarded by its only consumer (critical), and the server-authored text the gem correctly bounds is forwarded to the planner without the provenance marker the result path already carries (major). Neither is fixed by adding machinery inside `tamoz-mcp`; both are fixed at the existing consumer seams this report names.

Lens summary: correctness reviewed, security/authority reviewed, reliability/durability reviewed, observability/evidence reviewed, scalability/resource bounds reviewed, maintenance/architecture reviewed. No lens is `not evidenced`.
