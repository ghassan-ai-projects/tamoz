# Intelligence and capability evidence index

This index records the evidence used in the five-agent OpenClaw pass. Paths
under `/Users/ghassan/external-projects/openclaw` are the inspected OpenClaw
repository. Tamoz evidence will be added after the mirrored second pass.

## Reviewers

| Lens | Reviewer | Contribution |
| --- | --- | --- |
| Intelligence architecture | Herschel (`01a01e40-de02-79c2-be47-015ea095b63b`) | Shared loop, outer runtime, planning, model selection, context, delegation, channel integration |
| Tools and capability catalog | Gauss (`01a01e61-7691-7dd3-b774-d4f38f8aa6d2`) | Core tools, plugins, web, browser, MCP, schemas, config/state, self-modification |
| Autonomy and product capability | Dewey (`01a01e61-7768-74c3-a548-d00a1e01f89a`) | User-visible capability, continuation, cron, approvals, compaction, Telegram/CLI/TUI journeys |
| Safety and reliability | Epicurus (`01a01e61-77e2-76b3-b247-5f26744dab69`) | Authority, sandbox, SSRF, secrets, injection, config mutation, MCP trust, recovery, audit |
| Tests and evidence critique | Lovelace (`01a01e61-770b-77e2-943a-1e21b6ac1063`) | Scenario matrix, evidence gaps, intelligence claim discipline, acceptance bar |

All five reviews were read-only. No OpenClaw or Tamoz source files were changed.

## Intelligence-loop evidence

- `packages/agent-core/src/agent-loop.ts` — shared model/tool/observation loop,
  continuation, steering, tool result injection, abort, and policy hooks.
- `packages/agent-core/src/agent-loop.test.ts` — tool continuation, truncated
  calls, deferred tools, termination, policy blocks, and abort cases.
- `src/agents/embedded-agent-runner/run-loop.ts` — retry, fallback, timeout,
  compaction, loop detection, and terminal settlement.
- `src/agents/embedded-agent-runner/model.ts` and registry/fallback helpers —
  model/provider/auth resolution.
- `src/agents/tools/update-plan-tool.ts`, `src/agents/openclaw-tools.ts` —
  structured plan/goal affordances and tool assembly.
- `src/context-engine/types.ts`, `src/context-engine/legacy.ts`,
  `src/agents/compaction.ts` — context lifecycle and compaction behavior.
- `src/agents/sessions/sdk.ts` — session persistence, branches, transcript,
  model/thinking state, and context setup.
- `extensions/memory-core/src/tools.ts` — memory search/get, bounded retrieval,
  provenance, visibility, and degraded states.

## Tool and capability evidence

- `src/agents/tool-catalog.ts` — core tool IDs, groups, and profiles.
- `src/agents/core-tool-factory-descriptors.ts` — factory identity and tool
  construction families.
- `src/agents/agent-tools.ts` and `src/agents/openclaw-tools.ts` — effective
  tool assembly and policy filtering.
- `src/agents/tool-search.ts`, tool-search runtime/run-plan helpers — deferred
  discovery, description, Code Mode, and bounded execution.
- `src/plugins/registry-types.ts`, `src/plugins/captured-registration.ts`,
  `src/plugins/tools.ts` — plugin registration and reachability checks.
- `src/agents/sessions/tools/read.ts`, `grep.ts`, `find.ts`, `bash.ts` — file and
  shell boundaries, bounds, truncation, and replay caution.
- `src/agents/tools/web-search.ts`, `web-fetch.ts` — provider binding, bounded
  search/fetch, cache, output, and external-content handling.
- `src/infra/net/fetch-guard.ts`, `src/infra/net/ssrf.ts` — network/redirect/SSRF
  protections.
- `extensions/browser/src/browser-tool.ts` and browser action policy/helpers —
  browser targets, action bounds, and stale-target recovery.
- `src/agents/tools/message-tool.ts` — channel-derived messaging capability and
  target requirements.
- `src/infra/outbound/delivery-queue-storage.ts` — stable outbound IDs, claims,
  attempts, and `unknown_after_send`.

## MCP, state, and self-modification evidence

- `src/agents/agent-bundle-mcp-runtime.ts` — MCP connection, catalog, timeout,
  cooldown, recycling, and no-replay behavior.
- `src/agents/agent-bundle-mcp-materialize.ts` — provenance-preserving tool
  materialization.
- `src/agents/mcp-config-shared.ts` and `mcp-connection-resolver.ts` — scoped
  resolution, credential handling, and bounded refresh.
- `src/mcp/openclaw-tools-serve.ts` and `src/mcp/plugin-tools-serve.ts` —
  selected built-ins/plugins as MCP servers.
- `src/agents/tools/gateway-tool.ts` — bounded read-only config/schema access.
- `src/agents/tools/system-agent-tool.ts` — ring-zero operation approval and
  exact operation hash.
- `src/gateway/server-methods/config.ts` and
  `src/system-agent/config-write-policy.ts` — config CAS, changed-path audit,
  restart sentinels, redaction, and write policy.
- `src/skills/workshop/auto-apply.ts` and skill-workshop lifecycle files —
  proposal, evaluation, quarantine, application, and rollback metadata.

## Autonomy, channel, and recovery evidence

- `src/agents/tools/sessions-spawn-tool.ts`, `src/agents/subagent-registry.ts`,
  and pending-lifecycle helpers — child sessions, policy inheritance, depth,
  capacity, completion, and recovery.
- `src/cron/isolated-agent.ts`, cron tool/runtime files, and continuation tests —
  background work, isolated runs, ownership, delivery, and restart.
- `extensions/telegram/src/bot-message-dispatch-turn.ts` — Telegram turn
  callbacks for progress, tools, plans, approvals, and delivery.
- `extensions/telegram/src/draft-stream.ts`, group context/watermark files, and
  approval handlers — channel-native progress, context, and approval UX.
- `src/gateway/server-methods/chat-send-handler.ts` and
  `src/tui/gateway-chat.ts` — Gateway ACK, detached execution, event streams,
  reconnect, history, and abort.
- `src/agents/agent-tools.before-tool-call.approval.ts` — durable approval wait,
  exact binding, stale answer rejection, and fail-closed behavior.
- `src/agents/main-session-restart-recovery-runtime.ts` and related tests —
  orphan claims, restart recovery, and ambiguous dispatch handling.
- `src/agents/tool-loop-detection.ts` — repetition, polling, ping-pong, and
  no-progress detection.

## Scenario/test evidence

The specialist review identified these as useful scenario families:

- `src/agents/agent-tools.before-tool-call.e2e.test.ts` — tool policy and
  approval plumbing;
- `src/agents/agent-bundle-mcp-*.test.ts` and `mcp-transport*.test.ts` — MCP
  reachability/materialization/recovery;
- `src/agents/main-session-restart-recovery.test.ts` and
  `src/agents/tool-replay-safety.test.ts` — restart and replay safety;
- `src/agents/embedded-agent-runner/run.incomplete-turn.test.ts` and
  compaction loop tests — incomplete turns and context recovery;
- `src/tui/tui-event-handlers.test.ts`, `gateway-chat.test.ts`, and PTY tests —
  event gaps, reconnect, history, abort, and terminal behavior;
- `extensions/telegram/src/approval-handler.runtime.test.ts`,
  prompt-context tests, and draft-stream tests — Telegram context/approval/
  progress plumbing;
- `qa/scenarios/runtime/*.yaml`, `qa/scenarios/plugins/*.yaml`,
  `qa/scenarios/scheduling/*.yaml`, and `qa/scenarios/models/*live.yaml` —
  composed scenario definitions with mixed mock/live evidence.

## Confidence limits

- No configured OpenClaw process, real Gateway, real Telegram bot, MCP server,
  browser, database, or provider was run in this pass.
- Focused tests were inspected; they are not represented as executed results.
- Tool catalog and policy plumbing have stronger evidence than effective model
  tool selection.
- OpenClaw's trusted single-operator Gateway model is not a safe default for
  Tamoz's authority boundary.
- Internal persistence and memory stores do not prove that arbitrary database
  access is a first-party agent capability.
- Self-update and self-modification mechanics are stronger than evidence of
  correct model judgment about when to use them.
