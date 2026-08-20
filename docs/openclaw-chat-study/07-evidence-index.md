# Evidence index

This index records the primary evidence used in the first five-agent OpenClaw
pass. Paths are relative to `/Users/ghassan/external-projects/openclaw` unless
shown as absolute. Test names are included where the review surfaced them.

## Reviewers

| Lens | Reviewer | Evidence contribution |
| --- | --- | --- |
| Shared architecture | Chandrasekhar (`01a01e32-4742-7dd3-922c-5c304eccbedf`) | Lifecycle, Gateway admission, session/routing, persistence, delivery, recovery. |
| Telegram | Goodall (`01a01e32-48be-7cc2-81d3-411ead7eb7e0`) | Polling/webhook, auth, dedupe, topics, media, preview streaming, callbacks, failures. |
| CLI/UX | Halley (`01a01e32-4949-7213-8e4f-20031ce2532e`) | TUI, Gateway CLI, commands, progress, errors, cancellation, user model. |
| Safety/reliability | Sartre (`01a01e32-47a3-77c2-94b0-2331a06899b7`) | Trust model, policy, tool/sandbox, rate limits, restart, secrets, observability. |
| Tests/critique | Godel (`01a01e32-4813-7db0-8123-304c4818d767`) | Scenario matrix, evidence limits, missing live/full-journey proof. |

The same five agents were reused for the Tamoz pass after the first-pass agents
were closed and resumed. Their Tamoz contributions were architecture/current
state, Telegram, CLI/UX, safety/reliability, and tests/critique respectively.
The detailed findings and correction loop are recorded in
`08-review-log.md`; the current-state report cites the relevant Tamoz files and
tests at each claim.

## High-impact Tamoz evidence

- `gems/tamoz-agent/lib/tamoz/agent/comms_gateway.rb` — Telegram admission,
  command handling, status text, control delivery, and the Gateway/worker
  boundary.
- `gems/tamoz-telegram/lib/tamoz/telegram/normalizer.rb` — update normalization,
  command/callback identity, and the current payload digest behavior.
- `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb` and
  `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store_rows.rb` — atomic admission,
  history, inbound identity, and conversation status.
- `gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_*.rb` — FIFO request
  identity, leases, idempotency, redirect, and stale recovery.
- `gems/tamoz-agent/lib/tamoz/agent/session_effects.rb` and
  `gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb` — durable model/tool
  effects and checkpointed request execution.
- `gems/tamoz-agent/lib/tamoz/agent/outbox_delivery_sink.rb` and
  `gems/tamoz-agent/lib/tamoz/agent/delivery_drainer.rb` — terminal projection,
  bounded rendering, send boundary, retry classification, and unknown delivery.
- `gems/tamoz-agent/lib/tamoz/agent/worker.rb` — worker claim, lifecycle
  emission, settlement, and notification seams.
- `gems/tamoz-agent/lib/tamoz/agent/cli.rb`,
  `gems/tamoz-agent/lib/tamoz/agent/cli_session_commands.rb`, and
  `gems/tamoz-agent/lib/tamoz/agent/cli_rendering.rb` — ephemeral versus
  durable CLI paths, stream rendering, controls, and exit taxonomy.
- `documentation/design/comms.md`,
  `documentation/guides/telegram.md`, and
  `documentation/architecture/security-model.md` — intended communication,
  process-boundary, and security behavior; code takes precedence where they
  disagree.

## High-impact Tamoz tests

- `test/comms_admission_test.rb`, `test/comms_gateway_test.rb`, and
  `test/autonomy_scorecard_test.rb` — admission, authorization, typed controls,
  queueing, and no-turn/no-answer behavior.
- `test/sqlite_request_inbox_test.rb` and `test/sqlite_checkpoint_test.rb` —
  idempotency, leases, stale recovery, and checkpoint persistence.
- `test/agent_session_test.rb`, `test/agent_session_kill_matrix_test.rb`, and
  `test/agent_worker_test.rb` — durable session/effect behavior, worker recovery,
  approval, cancellation, and isolation.
- `test/agent_outbox_delivery_sink_test.rb`, `test/delivery_drainer_test.rb`,
  `test/tamoz_telegram_transport_test.rb`, and `test/comms_rendering_test.rb` —
  bounded output, transport failure, outbox ambiguity, and rendering.
- `test/comms_evidence_gated_approval_test.rb` and
  `test/comms_cli_ops_test.rb` — approval evidence and operator reconciliation.
- `test/agent_cli_test.rb` — durable CLI commands, signals, streaming, resume,
  redirect, failure, and exit behavior.

The scenario matrix identifies where these tests are component evidence only and
where a new composed test is required.

## High-confidence architecture evidence

- `src/channels/message/ingress-drain.ts` — `createChannelIngressDrain`,
  `runClaimed`, `completeClaimWithRetry`; claim leases, lanes, deferred work,
  adoption completion, retries, watchdog, and dead letters.
- `src/channels/turn/kernel.ts` and `src/channels/turn/lifecycle.ts` — shared
  channel turn lifecycle.
- `src/channels/message/durable-delivery.ts` — successful, suppressed, partial,
  failed, and unknown delivery outcomes.
- `src/routing/resolve-route.ts` — route precedence and route result.
- `src/routing/session-key.ts` — canonical session identity and malformed-key
  failure behavior.
- `packages/agent-core/src/agent-loop.ts` — channel-agnostic model/tool loop.
- `src/gateway/server-methods/chat-send-handler.ts` — durable user-turn
  admission, idempotency, started ACK, detached dispatch.
- `src/gateway/server-methods/chat-send-admission.ts` and
  `src/gateway/server-methods/chat-send-request.ts` — validation and lifecycle
  ownership.
- `src/gateway/server-methods/chat-abort-handler.ts` and
  `src/gateway/server-methods/chat-abort-runtime.ts` — scoped abort and partial
  persistence.
- `src/infra/agent-events.ts` and `src/gateway/server-chat.ts` — live event
  sequence/projection, delta merge/throttle, terminal flush.
- `src/config/sessions/session-accessor.sqlite-transcript-store.ts` and
  `src/config/sessions/session-accessor.sqlite-transcript-write.ts` — canonical
  SQLite transcript persistence and event/message identity handling.
- `src/infra/outbound/delivery-queue-storage.ts` and
  `src/infra/outbound/delivery-queue-recovery.ts` — write-ahead delivery, unknown
  send classification, and conservative recovery.

## High-confidence Telegram evidence

- `extensions/telegram/src/telegram-ingress-spool.ts` — durable update spool.
- `extensions/telegram/src/polling-session.ts` — long-polling offset ordering,
  retry/fatal/conflict classification.
- `extensions/telegram/src/webhook.ts` — secret, body limit, durable enqueue,
  non-200 on spool failure, durable-acceptance response.
- `extensions/telegram/src/telegram-ingress-drain.ts` and
  `src/channels/message/ingress-drain.ts` — shared drain/adoption semantics.
- `extensions/telegram/src/bot-handlers.authorization.runtime.ts`,
  `extensions/telegram/src/dm-access.ts`, and
  `extensions/telegram/src/group-access.ts` — authorization before side effects,
  DM/group policy separation.
- `extensions/telegram/src/bot-update-tracker.ts` and
  `extensions/telegram/src/message-dispatch-dedupe.ts` — update and logical
  message dedupe.
- `extensions/telegram/src/conversation-route.ts`,
  `extensions/telegram/src/bot-message-context.session.ts`, and
  `extensions/telegram/src/bot-message-context.ts` — route/session/context.
- `extensions/telegram/src/bot-native-commands.ts` and
  `extensions/telegram/src/bot-handlers.callback.runtime.ts` — fast command path
  and immediate callback acknowledgement.
- `extensions/telegram/src/draft-stream.ts` — preview edit/finalize/pagination
  behavior and safe ambiguity policy.
- `extensions/telegram/src/bot/delivery.send.ts` — outbound retry, flood wait,
  rich-to-plain and quote fallbacks.

## High-confidence test evidence

- `src/channels/message/ingress-drain.test.ts` — lost-claim recovery,
  complete-at-adoption, deferred ownership, tombstone and lease races.
- `src/infra/outbound/delivery-queue.recovery.test.ts` — unknown-after-send,
  crash recovery, queue capability requirements, concurrency.
- `extensions/telegram/src/webhook.test.ts` — auth order, body limit, durable
  enqueue, non-200 on spool failure, startup drain.
- `extensions/telegram/src/polling-session.test.ts` and
  `extensions/telegram/src/telegram-ingress-worker.runtime.test.ts` — replay,
  offsets, 429/5xx/409 handling.
- `extensions/telegram/src/dm-access.test.ts`,
  `extensions/telegram/src/bot-native-commands.group-auth.test.ts`, and
  `extensions/telegram/src/group-access.base-access.test.ts` — DM/group auth.
- `extensions/telegram/src/message-dispatch-dedupe.test.ts` — persisted claims,
  account/bot isolation, concurrency, rollback.
- `extensions/telegram/src/draft-stream.test.ts` and
  `extensions/telegram/src/delivery-trace.test.ts` — preview, edit, overflow,
  streaming/final traces.
- `extensions/telegram/src/bot-message-dispatch.progress-updates.test.ts` and
  `extensions/telegram/src/bot-message-dispatch.progress-summary.test.ts` —
  tool progress projection.
- `src/auto-reply/reply/commands-compact.test.ts` — compaction guards and
  failure/success/skipped reporting.
- `src/commands/agent-via-gateway.test.ts` — accepted run identity, abort,
  transient Gateway retry, ambiguous transport handling.
- `src/tui/tui-command-handlers.test.ts` — optimistic message and run identity.
- `src/tui/tui-event-handlers.test.ts` and `src/tui/tui-pty-local.e2e.test.ts` —
  partial output, abort, diagnostic handling.
- `src/agents/embedded-agent-runner/run/llm-idle-timeout.test.ts` and
  `src/agents/embedded-agent-runner/run/attempt-timeout-prepare.test.ts` —
  provider idle/attempt timeout behavior.

## Safety and operations evidence

- `SECURITY.md` — trusted Gateway model, session IDs as routing controls,
  personal-assistant boundary, plugin trust, prompt injection limits.
- `docs/gateway/security/index.md` — hard boundaries: authorization, tool policy,
  approvals, sandboxing, and host trust.
- `docs/gateway/security/rate-limiting.md` — rate-limit scope and process-local
  limitation.
- `docs/gateway/restart-recovery.md` — restart markers, bounded recovery,
  tombstones, partial transcripts, crash-loop breaker.
- `docs/gateway/secrets.md`, `src/security/secret-mask.ts`, and redaction tests —
  secret references and masking limits.
- `docs/gateway/logging.md` and `docs/gateway/diagnostics.md` — bounded,
  redacted operational evidence.
- `src/agents/agent-tools.policy.ts` and
  `src/agents/agent-tools.before-tool-call.approval.ts` — layered tool policy and
  fail-closed approval behavior.

## Important confidence limits

- No live Gateway, Telegram Bot API, provider, or full real conversation was
  executed in this pass.
- Most “useful chat” evidence is deterministic test/harness evidence, not model
  quality evidence.
- Pairing is tested as a policy seam more strongly than as a complete first-contact
  journey.
- Inbound replay/dedupe is stronger than outbound exactly-once delivery.
- Session isolation is tested structurally, not as concurrent real multi-user
  Telegram traffic.
- OpenClaw's trusted-one-user Gateway model must not be treated as Tamoz's
  authorization model without an explicit decision.
