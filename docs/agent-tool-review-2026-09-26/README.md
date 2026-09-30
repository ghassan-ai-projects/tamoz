# Tamoz agent tool-call review

Date: 2026-09-26. Repository snapshot: `a3da7485`.

Scope: recommendation only; no capability, policy, or cross-gem interface changed.

## Decision

Improve the tools the agent can *find and use* before increasing the catalog. The first delivery should expose admitted MCP tools to the native work loop, make local search report incomplete scans, and give the model a bounded way to inspect its effective capabilities. Then add narrowly scoped tools for real gaps: evidence windows, run status, Git changes, source-page retrieval, and file removal or moves.

This is a source inspection and recommendation, not a claim that a real model completes these missions. The [active-investigation real run](../eval-improvement/measurement-plans/16-active-investigation.md#run-2--real-model-after-the-prompt-change-2026-09-26-development-set) is the one measured behavior signal used here. Its development-set probe precision was 0.29; three resolvable cases were never solved because the model never searched for a matching word. That result supports testing better evidence retrieval, not assuming that a new tool will improve accuracy.

## Current tool path

| Surface | What exists | Consequence for this review |
| --- | --- | --- |
| Local toolbox | `read_file`, `list_directory`, `search_text`, `glob`; in change mode, `apply_patch`, `create_file`, and named `run_check`; optional skill reads. [Catalog](../../gems/tamoz-tools/lib/tamoz/tools/tool_catalog.rb#L14-L67) | Reading and small edits work. There is no local remove, move, Git inspection, or general state-inspection call. |
| Native work loop | Uses model tool calls, a reviewed `update_plan`, `recall_output`, and probe-only `report_findings`. Calls then pass through capability validation, approval, and `SessionEffects`. [Work context](../../gems/tamoz-agent-session/lib/tamoz/agent/work_context.rb#L97-L119), [gate](../../gems/tamoz-agent-session/lib/tamoz/agent/work_gate.rb#L77-L105) | The model's work-loop schema list is built from local toolbox schemas plus configured probes. It does not project the otherwise admitted general MCP/websearch descriptors into that list. This finding is about the **work route**, not every Session route. |
| Capability host | Sealed, policy-filtered local, skills, MCP, and websearch descriptors; source-owned validation and dispatch. [Binding](../../gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb#L48-L150) | Extend this seam; do not build a parallel tool registry or grant authority from server text. |
| External reads | Operator-configured MCP, governed websearch with one `search` tool, and operator-defined read-only probes. [Websearch adapter](../../script/websearch_adapter#L76-L119), [probe catalog](../../gems/tamoz-agent-capabilities/lib/tamoz/agent/probe_catalog.rb#L14-L72) | Search snippets cannot be followed with a first-party page-read call. Probes can be improved through operator data without a new generic executor. |
| Operator state | `WorkerRuntime#capability_peek` can inspect config without connecting; `capability_catalog` currently names local tools. [Worker runtime](../../gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb#L815-L829) | Reuse the status/inventory projection for a caller-bound model read; do not expose raw runtime files. |

### Root cause, in five whys

1. **Why can a configured capability still be ineffective for the agent?** The model cannot call a tool it is not shown.
2. **Why is it not shown on the work route?** `WorkContext#toolbox_schemas` appends configured probes to the toolbox list, but does not append general admitted MCP descriptors.
3. **Why does the capability still appear elsewhere?** `CapabilityBinding` seals and routes MCP descriptors independently of that model-facing projection.
4. **Why would adding another server alone fail?** It would increase the sealed catalog while leaving the work route's selection surface unchanged.
5. **What must change first?** Project the *already admitted, pinned* descriptor schema into the work route and test that the model sees exactly what the gate will dispatch. This is a projection fix, not a new authority path.

There is a second, local evidence-quality issue. `search_text` scans at most 2,000 files and returns at most 100 results, but renders `No matches.` or a bare result list without reporting whether the file cap or result cap ended the search. `glob` reports its 500-result truncation but shares the same 2,000-file walk. A negative answer can therefore be incomplete without saying so. [Read operations](../../gems/tamoz-tools/lib/tamoz/tools/read_operations.rb#L59-L96), [walk bound](../../gems/tamoz-tools/lib/tamoz/tools/read_operations.rb#L145-L164). Repair this existing tool before adding semantic search machinery.

## Recommended calls, in delivery order

These are proposed model-visible names and minimal contracts, not an implementation spec. Each call stays behind the current descriptor, profile, plan, approval, and durable-effect boundaries. A new descriptor changes the pinned catalog; it must not appear in an existing bound session by surprise.

| Priority | Call | Work it simplifies or adds | Existing seam and main constraint | Evidence strength |
| --- | --- | --- | --- | --- |
| 1 | `inspect_capabilities({"id": "mcp:notes/search_notes"})` or `{}` | Learn the available tool's schema, source, effect class, approval need, and typed unavailable reason before guessing arguments. An omitted ID lists a bounded page of admitted names. | `CapabilityBinding#inventory` + sealed descriptor/schema; no connection, materialization, or new grant. [Host inventory](../../gems/tamoz-tools/lib/tamoz/tools/capability_host.rb#L35-L95) | High: source shows inventory exists and work-route schema projection is incomplete. |
| 2 | `probe_event_window({"lookback_minutes":180})` in a session; no free target/window arguments in an episode | Investigate a physical situation by time and event source when the right keyword is unknown. Return bounded, ordered events with timestamp, source, continuation, and truncation. | An **operator-declared probe** backed by a read-only evidence source; the episode's target and window remain bound to the verified situation, as `ProbeSource` already does. No domain event names in Ruby. [Probe source](../../gems/tamoz-agent-capabilities/lib/tamoz/agent/probe_source.rb#L13-L105) | Medium: real run identifies keyword search as a bottleneck; improvement remains a hypothesis until a matched holdout run. |
| 3 | `inspect_run({"view":"progress"})` | Answer “what am I waiting for?”, “which capability is unavailable?”, or “was this effect unknown?” from the current request, pending approval, budget, and source-health records. | Reuse `SessionView`, worker status, and inventory. Infer thread/request from durable context; no arbitrary ID, raw config, credentials, or other user's state. [Existing operator peek](../../gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb#L821-L829) | High for absence of a model call; usefulness needs a user-facing mission. |
| 4 | `inspect_git({"view":"status"})`; `inspect_git({"view":"diff","path":"lib/x.rb"})` | Understand pre-existing edits and review the exact change before proposing a patch; especially useful for coding tasks and avoiding overwriting user work. | Local read-only tool under the configured root. Use fixed Git operations with custom helpers disabled, strict path scope, bounded diff and explicit truncation. Treat commit messages and diffs as untrusted data. | High for catalog absence; size of benefit is unmeasured. |
| 5 | `mcp:websearch/fetch_result({"search_receipt":"…","index":0})` | Read the cited source page behind a search hit, compare sources, and quote/attribute the actual page instead of relying on snippets. | First normalize and bind search hits to a recorded receipt. Extend the existing websearch MCP source and egress client; resolve the result handle there. An arbitrary URL must not become network authority. Every destination and redirect needs the operator's egress policy and bounded output. [Current single search call](../../script/websearch_adapter#L76-L96) | High for capability absence; live usefulness and provider compatibility unproven. |
| 6 | `remove_file({"path":"…","expected_sha256":"…"})` and `move_file({"from":"…","to":"…","expected_sha256":"…"})` | Complete ordinary refactors and cleanup that `apply_patch` plus `create_file` cannot finish. | Extend `Toolbox`/`LocalDispatcher`; exact preview, reviewed plan scope, approval, path and symlink confinement, no-clobber destination, before/after receipt, crash reconciliation. Start with regular files only. | High for catalog absence; prioritize after read-side wins because effects add recovery work. |

### First two repairs before new integrations

1. **Expose admitted MCP/websearch schemas to the work route.** Build native tool schemas from the session's sealed descriptors and pinned MCP schemas, filtered by current phase and profile. Keep server descriptions bounded and attributed as untrusted. Verify that a configured read-only MCP tool is model-visible, callable through `WorkGate`, and absent when disabled, stale, or unadmitted. Do not use MCP `readOnlyHint` as authority; the operator's `read_only_tools` declaration remains decisive. [MCP's tool annotations are hints](https://blog.modelcontextprotocol.io/posts/2026-03-16-tool-annotations/); Tamoz already classifies from operator configuration in [McpSourceBuilder](../../gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb#L204-L228).
2. **Make local search complete or explicitly incomplete.** Keep `search_text` and `glob` rather than adding a duplicate `code_search` call. Add `scanned_files`, `limit_reached`, `truncated`, and a stable continuation/smaller-scope instruction; never render an incomplete scan as plain `No matches.`. Exercise a repository over 2,000 files with a match beyond the bound. If continuation is costly, a clear incomplete result plus a narrower path is the smaller first fix.
3. **Bound websearch before extending it.** `max_results` is accepted whenever it is a positive integer, then forwarded to the provider without a maximum. Add a schema maximum and runtime clamp or refusal before implementing `fetch_result`. [Adapter](../../script/websearch_adapter#L83-L118).

### Why these calls, and why this order

- **`inspect_capabilities` first:** every later tool depends on the model knowing its exact usable surface. The [MCP tool contract](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) already distinguishes tool schemas and results; Tamoz should project its *pinned* subset, not let a live server reconfigure a turn.
- **`probe_event_window` next:** the [real-model run](../eval-improvement/measurement-plans/16-active-investigation.md#run-2--real-model-after-the-prompt-change-2026-09-26-development-set) points to failed retrieval, not a missing reasoning label. A bounded time window can expose relevant events without guessing `paddlewheel`, `harvest`, or `level` in advance. Its output must be short enough for the existing episode budget and carry `tool:<index>` evidence identity.
- **`inspect_run` and `inspect_git`:** both turn operator-visible facts into bounded model-visible reads. They reduce avoidable back-and-forth without allowing mutation. `inspect_git` is relevant only for Git workspaces; the other calls serve CLI, Telegram, and physical investigations.
- **`fetch_result`:** current search is an entry point, not source inspection. Reusing the existing governed client is simpler than adding a general browser for static pages. [OWASP's SSRF guidance](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html) supports allowlisted destinations and careful redirect handling. The [browser adapter](../../gems/tamoz-agent-capabilities/lib/tamoz/agent/governed_browser_source.rb#L7-L42) is only a seam today; the [Phase 4 review](../openclaw-intelligence-study/implementation-plan/evidence/phase-4/implementation-review.md#not-delivered) reports no live connector.
- **File removal/moves last:** the missing verbs are real, but they require exact approval and durable reconciliation. A generic shell is a poor substitute for these narrow actions.

## Acceptance evidence for a later implementation

| Slice | Minimum proof before calling it useful |
| --- | --- |
| Projection and discovery | Fixture with two MCP servers and one probe: native work header equals the admitted action-phase surface; disabled/stale names absent; schema digest and operator effect class match dispatch; no status/list call connects. Real-provider task chooses a read-only MCP tool without being told its name. |
| Search repair | Match after the 2,000th candidate is either found through continuation or returned as explicitly incomplete; no false “No matches.” Stable order, symlink/root rules, byte and time caps remain. |
| Evidence window | Same real model, task set, budget, and scoring as the keyword probe, with a held-out set. Report evidence precision, resolvable success, unresolvable fabrication, unnecessary calls, latency, and bytes. Success must cite an actually returned event; unknown plus a cause-specific action still fails. |
| Run/Git inspection | Current-thread isolation and redaction; no hooks/custom helpers/credentials; no file mutation; bounded output and truthful truncation. A coding mission preserves pre-existing edits and can explain its diff. |
| Web fetch | Search-hit handle cannot be forged across sessions; allowlist, DNS/IP pinning, per-hop redirect checks, content type, size/deadline, secret scrubbing, provenance and citation tests. One live search → source read → answer run is labelled real-provider evidence. |
| Remove/move | Denial, changed digest, symlink/root escape, destination exists, crash before/after filesystem effect, restart, and duplicate request each produce the correct terminal or reconciled receipt with no duplicate effect. |

For every new call, measure tool-choice validity, task completion, redundant calls, output bytes, latency, approval accuracy, and unknown/duplicate effects. Scripted tests prove policy and plumbing. Model usefulness requires a real provider and a task that does not prescribe the tool sequence.

## Defer

- **Arbitrary shell or HTTP:** the current named-check and governed egress paths are narrower and easier to audit. Add a specific missing action or source instead.
- **A second database executor:** `GovernedDatabaseSource` already narrows operator-owned MCP SQL access; evaluate real demand and its current path before introducing another interface. [Source](../../gems/tamoz-agent-capabilities/lib/tamoz/agent/governed_database_source.rb#L7-L77).
- **A batch-read tool:** native work responses can contain several tool calls, and ranged `read_file` plus `recall_output` already address output size. Measure a call-count problem before adding a batch protocol.
- **Broad autonomous messaging, scheduling, or profile writes:** Tamoz already has governed worker, scheduler, child-task, and candidate lifecycles. A model tool for any of these needs a specific user mission and its own approval/reconciliation evidence, not a general “manage everything” verb.

## Review limits and sources

I inspected the current local code and prior committed evaluation record. I did not run a fresh model benchmark or change code. Enola snapshot generation was attempted but automatic approval review rejected it because the MCP destination was unverified for repository-derived architecture data; no Enola finding is used here. Internal links above are the evidence for current Tamoz behavior. The external [MCP tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools), [MCP resources specification](https://modelcontextprotocol.io/specification/2025-11-25/server/resources), and [OWASP SSRF guidance](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html) inform the proposed contracts, not claims that Tamoz already implements them.
