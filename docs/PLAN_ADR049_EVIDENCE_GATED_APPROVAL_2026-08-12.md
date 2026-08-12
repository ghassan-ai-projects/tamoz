# Implementation plan — ADR-049 evidence-gated Telegram approval

Status: proposed. Authorizes no code until ADR-049 is accepted (Phase 0). This plan
implements `ADR-049_TELEGRAM_APPROVAL_AUTHORITY.md` and turns the red oracle in
`test/comms_evidence_gated_approval_test.rb` green while keeping every existing green test
green. It targets contract §7.1 (INV-A…E), bar groups A–E, and the T4 live-ALMS gate.

Review state: rounds 1 and 2 rejected by UX, reliability, and security reviewers. After
iterating through six review rounds, the UX, reliability, and security reviewers all approved
the current plan. Implementation remains blocked only on the explicit Phase 0 owner decision.

Session status (2026-08-12): ADR-049 accepted; P1–P7 shipped (one commit each) plus the
gap-closing C4 receipt binding, C5/C6 oracles, the Phase 0 doc-consistency check, and C7
credential separation. The contract test has zero skips; bar C1–C6 met. Remaining: the
Phase 5 `DeliveryJournalContext` table (MIG-11+) and its effect-key wiring — the journal
machinery itself (`tamoz_effects`, `EffectJournal#prepare/start/complete/reconcile/
resolve`, the drainer's claim/bind/send_started/mark/reconcile path, UNKNOWN non-retry
proven by scorecard case 15) already exists; only the persisted context table and the
plan-specified `EffectJournalKey.build` inputs are outstanding. Phase 8 (T4 live gate)
waits on live Telegram/ALMS infrastructure and the owner go-ahead.

## Design invariants this plan must preserve

- **INV-A** denial is unconditional for the bound correspondent.
- **INV-B** approval requires `approver_evidence >= required_evidence`; approve never shares
  deny's unguarded path.
- **INV-C** `required_evidence` is trusted, pinned to the interrupt digest, never
  model-settable.
- **INV-D** v1 policy returns `filesystem_operator` for every effect ⇒ deny-only in
  practice.
- **INV-E** absent/ambiguous evidence never approves.

## The key simplification that orders the work

The v1 policy is a **constant**: every effect requires `filesystem_operator`. Three
consequences shape the phases:

1. INV-C is satisfied trivially — a function that returns a constant cannot be influenced by
   model output, so **no interrupt-descriptor enrichment or effect classification is needed
   now**. That hard work is deferred to the follow-up per-effect ADR (ADR-049 §4), not this
   plan.
2. The pinned value carried on the prompt (Phase 2) is, for v1, always the same constant.
   It is still pinned and threaded end-to-end so the enforcement (Phase 3) is structurally
   correct and the future non-constant policy is a one-line change.
3. The observable behavioral change is exactly one thing: a Telegram `approve` stops
   producing an approve decision. Everything else is scaffolding that keeps behavior
   identical.

So the plan front-loads inert scaffolding (Phases 1–2, no behavior change, each independently
testable and green) but does not authorize merging, deployment, or live testing until Phase 0
acceptance and governing-document consistency are complete. The behavioral flip remains
isolated in Phase 3.

## Touchpoints (grounded in the current branch)

| Concern | File | Method/seam |
|---|---|---|
| Callback parse + resolve | `gems/tamoz-agent/lib/tamoz/agent/comms_gateway.rb` | `resolve_callback`, `split_callback` |
| Callback identity envelope | `gems/tamoz-telegram/lib/tamoz/telegram/normalizer.rb` | inbound callback context and originating message identity |
| Atomic consume + decision insert | `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb` | concrete `consume_prompt_and_append_decision_intent` transaction |
| Prompt value | `gems/tamoz-comms/lib/tamoz/comms/approval_prompt.rb` | fields, `build`, `wire`/`from_wire`, `validate!` |
| Decision value | `gems/tamoz-comms/lib/tamoz/comms/decision_record.rb` | `direction`, `actor_kind` (`telegram_user`/`os_user`), `source` |
| Prompt build site | `gems/tamoz-agent/lib/tamoz/agent/outbox_delivery_sink.rb` | `push_approval_prompt` |
| Interrupt facts (pin source) | `gems/tamoz-agent/lib/tamoz/agent/worker.rb` | `interrupt_facts`, `interrupt_digest`, `emit_approval_request` |
| Receipt persistence | `gems/tamoz-agent/lib/tamoz/agent/delivery_drainer.rb` | durable send receipt and UNKNOWN handling |
| Button rendering | `gems/tamoz-telegram/lib/tamoz/telegram/transport.rb` | approval markup → `inline_keyboard` |
| Local operator approve | `gems/tamoz-agent/lib/tamoz/agent/cli_worker_commands.rb` and CLI resume path | trusted OS authorization then shared approval operation |
| Process credential boundary | `scripts/start-tamoz-comms.sh`, `script/live_alms_telegram` | explicit gateway/worker/harness environment allowlists |
| Prompt schema | `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb` (+ migration) | `tamoz_comms_approval_prompts`, `PROMPT_COLUMNS` |

---

## Phase 0 — Accept ADR-049 (decision gate, no code)

**Goal.** Close the contract §2 blocker before any code moves.

- Decide exit 2 (evidence-gated, recommended) vs exit 1 (hard revert). This plan assumes
  exit 2; if exit 1 is chosen, the work is only "delete the approve path" and Phases 1–6 do
  not apply.
- Record the owner decision explicitly: exit 2 (recommended) or exit 1. No implementation
  phase may infer acceptance from the plan's recommendation.
- Accept ADR-049; apply its §18 one-liner and ADR-043 amendment (the draft block in the ADR).
- Make acceptance and the governing-document reconciliation an unconditional prerequisite for
  every merge, migration, deployment, and live test. Add a CI/doc consistency check that ADR
  status, ADR-043, `COMMS_DESIGN.md`, the contract, and the bar agree.
- **Exit:** ADR-049 status `Accepted`; contract §2 marked resolved-via-exit-2; the consistency
  check passes. If the owner chooses exit 1, stop after documenting the hard-revert scope.

---

## Phase 1 — Evidence lattice + approval policy (trusted core, inert)

**Goal.** Introduce the vocabulary and the v1 policy function. No wiring, no behavior change.

**Changes.**
- New `gems/tamoz-comms/lib/tamoz/comms/authority_evidence.rb`: a closed, ordered enum
  `chat_bound < filesystem_operator` with a total-order compare. Telegram maps to
  `chat_bound`; `filesystem_operator` is issued only inside a trusted CLI authorization
  boundary after verifying the authorized OS/runtime directory. No `from_actor_kind` mapping
  may grant operator evidence: serialized payloads, models, workers, Telegram callers, and
  caller-supplied actor kinds are rejected. Frozen constants; a value object, not a bag of
  strings.
- New `gems/tamoz-comms/lib/tamoz/comms/approval_policy.rb`: `required_evidence(effect) ->
  AuthorityEvidence`. v1 body returns the `filesystem_operator` constant unconditionally.
  Its signature takes the pinned effect facts (interrupt descriptor) even though v1 ignores
  them, so the future per-effect ADR changes only the body.

**Tests.** Unit tests for the lattice order and trusted actor-capability issuance; a test
asserting the v1 policy returns `filesystem_operator` for every fixture effect including a hostile
model-shaped descriptor (locks INV-C: input is ignored).

**Exit.** New files, fully unit-tested, referenced by nothing. Suite green. Zero behavior
change.

---

## Phase 2 — Pin `required_evidence` on the prompt (INV-C wiring, inert)

**Goal.** Carry the pinned requirement end-to-end without enforcing it yet.

**Changes.**
- `ApprovalPrompt`: add a 15th field `required_evidence` (a string from the lattice).
  Set it in `build` from `ApprovalPolicy.required_evidence(interrupts)`; add to `wire`,
  `from_wire`, `validate!` (must be a lattice member). It is pinned in the same value as
  `interrupt_digest`, so it cannot drift from the question.
- SQLite: migration adding `required_evidence TEXT` plus the complete callback-binding envelope
  to `tamoz_comms_approval_prompts`; extend `PROMPT_COLUMNS`, binds, `CURRENT_VERSION`, the
  migration ordinal/checksum registry, and the requirements manifest. The envelope must bind
  surface ID/revision, correspondent, conversation/chat ID, originating message receipt,
  thread, occurrence, interrupt/effect digest, action, evidence, status, and TTL. Persist the
  originating send receipt before a prompt can be actionable. **Backfill/compat:** a row with
  `NULL` `required_evidence` (pre-migration prompt in flight) is normalized at the store/value
  boundary to `filesystem_operator` — the safe default, so an old prompt can never be
  under-gated. Require an in-place v8→v9 test, interrupted-migration recovery test, and
  mixed-version startup failure-closed behavior.
- Define the exact prompt/callback fields and constructors for surface/revision, chat,
  correspondent, `callback.message.message_id`, chat ID, bot/surface revision, receipt digest,
  thread, occurrence, effect/interrupt digest, allowed action, prompt-required evidence, actor
  evidence, status, and TTL. Distinguish prompt-required
  evidence from actor evidence. A Telegram prompt is non-actionable until its trusted transport
  receipt and callback-binding envelope are atomically persisted; incomplete legacy prompts
  remain non-actionable (deny may still be recorded as an explicit refusal).
- Add one atomic receipt/activation store operation: trusted transport receipt, receipt digest,
  effect completion, and prompt activation commit together. A pre-commit crash leaves the
  prompt inactive/`UNKNOWN`; a post-commit crash leaves it active and replayable through the
  existing recovery path.
- Its concrete API is `complete_delivery_and_activate_prompt(delivery_id:, effect_key:,
  receipt:, receipt_digest:, prompt_ref:, now:)`, returning `:activated`, `:already_active`,
  `:unknown`, `:missing`, or `:conflict`. It uses a transaction-scoped effect-journal
  primitive; no caller may separately mark delivery complete, persist a receipt, or activate
  a prompt. The primitive is `effect_journal.complete_in_transaction(tx:, effect_key:,
  execution_id:, task_id:, call_index:, operation:, safety:, request_digest:, attempt_token:,
  receipt:)`; `tx` is the already-open SQLite transaction handle and validates the lease
  fence/attempt token before writing `SUCCEEDED`. The outer sequence is one transaction:
  journal completion → ReceiptV1 persistence → prompt activation → commit. The SQLite adapter
  seam is `with_transaction { |tx| effect_journal.complete_in_transaction(tx:, ...);
  persist_receipt(tx:, ...); activate_prompt(tx:, ...); }`; it validates the delivery
  lease/fence, CASes the attempt token, transitions the effect, writes the ReceiptV1 row, and
  activates the prompt using the same `tx`. Before-commit crash yields no succeeded journal row
  and an inactive/UNKNOWN prompt; after-commit crash yields all rows and idempotent recovery.
  Add a fault matrix for each boundary and assert no partial journal/receipt/prompt state.
- `outbox_delivery_sink.push_approval_prompt`: already has `event.fetch(:interrupts)`; pass
  them to `ApprovalPrompt.build` (already does) — verify the built prompt now carries the
  requirement. No new data needed from the worker for v1 (constant policy).

**Tests.** Prompt round-trips the requirement and complete binding envelope through wire/store;
a built prompt for any interrupt set pins `filesystem_operator`; migration test: a NULL column
reads as `filesystem_operator`; stale, cross-chat, cross-surface, wrong-message, wrong-thread,
wrong-occurrence, wrong-digest, and expired envelopes are rejected without a decision.

**Exit.** Prompts carry the requirement. `consume_prompt` still ignores it. C1 still red (no
enforcement yet). Suite otherwise green.

---

## Phase 3 — Enforce the gate at consumption (INV-A/B/E — the one behavioral flip)

**Goal.** Approve is refused unless `approver_evidence >= required_evidence`; deny is
unconditional. Every approval actor uses the same atomic boundary. This is the only phase
that changes observable behavior.

**Changes.**
- `resolve_callback`: pass only an immutable authenticated actor capability/context. A Telegram
  callback carries a Telegram actor context; it never carries an evidence level. The store
  derives `chat_bound` internally. The trusted CLI authorization boundary alone may issue the
  filesystem-operator capability; `from_actor_kind('os_user')` never grants it.
- Introduce one store transaction, named conceptually
  `consume_prompt_and_append_decision_intent`, for Telegram callbacks and local operator
  approval alike. It accepts the complete immutable callback envelope and trusted actor
  context. It must compare surface ID/revision, correspondent, conversation/chat ID,
  originating message receipt, thread, occurrence, interrupt/effect digest, action, evidence,
  status, and TTL; then perform expiry, single-use CAS, disposition/refusal, and decision
  intent in that same transaction. The canonical wire version is `v1`. The value-object
  schemas are: `PromptRef` = immutable `{reference_digest, surface_id, surface_revision,
  correspondent_id, conversation_id, thread_id, occurrence_id, interrupt_digest, effect_digest,
  bot_id, originating_prompt_message_id}`; `CallbackEnvelope` = the same binding plus
  `{callback_message_id, callback_update_id, raw_payload_hash, prompt_receipt_digest,
  receipt_digest, action,
  callback_revision, received_at, ttl}`; `ActorContext` = opaque
  `{actor_id, surface, authenticated_capability}` with no evidence field. Prompt and callback
  constructors validate the wire version and reject missing/extra security fields.
- `originating_prompt_message_id` is the outbound Telegram prompt message; `callback_message_id`
  is the inbound callback message; `callback_update_id` is the Telegram update identity;
  `prompt_receipt_digest` is the persisted outbound receipt digest; `receipt_digest` is the
  callback's claimed receipt and must equal it; `bot_id` is bound to the configured bot. Receipt
  wire values have bounded lengths, canonical encoding, and an opaque versioned type. Define
  `ReceiptV1` as canonical JSON `{version: 1, bot_id, chat_id, message_id, surface_id,
  surface_revision, sent_at, transport_reference}` with sorted keys and bounded UTF-8 values;
  its digest is `SHA256("tamoz.telegram.receipt.v1:" + canonical_json)`. Persist that exact
  digest in the prompt row. Forged digest, wrong-chat, wrong-bot, wrong-message, and
  wrong-surface tests reject before any decision.
- Make this a concrete public store API. It loads and validates the prompt inside the
  transaction, derives actor evidence inside the trusted boundary, performs the CAS, records
  disposition/refusal, and inserts a decision intent. Route `resolve_callback`, `cmd_approve`,
  interactive `resume`, and every other approval entry point through it. Remove all direct
  decision insertion and all pre-read/build/consume/disposition sequences. Add kill points
  immediately before and after commit plus concurrent approve/deny assertions.
- Update the shared comms-store façade to expose only this operation for approval decisions;
  remove or make `activate_prompt`, `consume_prompt`, and raw `record_decision` unavailable to
  approval callers. Route `CommsGateway#resolve_callback`, `cmd_approve`, and interactive
  resume through the façade, while worker execution accepts only a committed decision-intent
  ID. Enumerate and remove/privatize `CommsStore#activate_prompt`, `CommsStore#consume_prompt`,
  raw `record_decision`, `CLIWorkerCommands#cmd_approve`, `WorkerRuntime#record_decision`, and
  direct interactive `session.resume` approval bypasses. Retain
  `CommsGateway#resolve_callback` only as a parser/dispatcher that invokes the façade and
  performs no decision write itself.
  Add a source-audit test that fails if any approval path calls raw decision insertion.
- Its required signature is `(prompt_ref:, callback_envelope:, actor_context:, direction:)` and
  its closed result enum is `:approved`, `:denied`, `:refused_insufficient_evidence`,
  `:rejected_binding`, `:expired`, `:missing`, `:unknown`, or `:replayed`. A successful deny
  or authorized approve atomically writes the consumed-prompt CAS, one decision-intent row,
  and disposition; a refusal atomically writes refusal disposition only; all other results
  write no decision intent. `session.resume` may only apply an already committed intent.
- Inside that boundary, after the expiry check and before the CAS-consume, read the prompt's
  `required_evidence`; if the decision direction is `approve` and
  `approver_evidence < required_evidence`, **do not** consume or insert a decision — record a
  durable refusal and return `:refused_insufficient_evidence`. A `deny` skips the check
  entirely (INV-A). Expiry/missing/unknown already return terminal non-approval outcomes
  before any decision (INV-E). No caller may insert an approve decision directly.
- `resolve_callback`: map the new outcome to the durable refusal disposition inside the same
  transaction, creating no decision. The same result contract is used by the local operator
  path; it must not have a parallel approval lifecycle. Remove direct approval insertion from
  `cmd_approve` and direct resume-to-approve paths.
- Keep `split_callback` (a bare v1 reference still means deny; `approve:`/`deny:` parsed) —
  the parser is unchanged; only the approve *outcome* changes.

**Tests.** `test/comms_evidence_gated_approval_test.rb`:
- `test_a_chat_bound_approve_is_refused_under_v1_policy` flips **red → green**.
- `test_the_equivalent_deny_still_succeeds` stays green.
- Add: an approve records a durable refusal with `insufficient_evidence` and no decision row;
  concurrent approve+deny on one prompt yields exactly the deny (INV-A wins, single-use).
- Add exact-envelope tests: forged or stale surface/revision, correspondent, chat, message
  receipt, thread, occurrence, digest, action, evidence, status, or TTL yields no decision;
  a second chat is a negative case; replay yields zero additional consumption.

**Exit.** C1 green. Telegram is deny-only in practice. The shared approval boundary is used
by Telegram and local operators, and the suite remains explicitly fail-closed during partial
rollout.

**Rollback.** Rollback must not restore approve-everything. The gate has a fail-closed default
when policy, schema, callback code, or version compatibility is mixed; rollback either keeps
the evidence check or disables approve entirely. Add a mixed-version test before rollout.

---

## Phase 4 — Local operator approval carries `filesystem_operator` (INV-B positive path)

**Goal.** Ensure the legitimate approve path still works — an operator meets the requirement.

**Changes.**
- The CLI/session resume approval (`os_user`, `source: cli`) must resolve
  `approver_evidence = filesystem_operator` only after trusted CLI authorization verifies the
  OS user and runtime directory; it must then pass the same Phase 3 transaction boundary.
  Reject caller-supplied actor kind/evidence in CLI arguments, serialized prompts, worker
  events, model output, or Telegram callbacks. Refactor any direct `session.resume` approval
  (including the path covered by `agent_acceptance_workflow_test`) to call the shared
  operation; there must be no second approve path that can bypass prompt binding, evidence,
  CAS, or durable refusal.
- Audit: an operator approval records identity, evidence level, reason, timestamp (contract
  §7.1 requirement for the stronger path).

**Tests.** `agent_acceptance_workflow_test` stays green (operator approve → RUNNING). A new
test: an operator approve on a `filesystem_operator` prompt succeeds where a Telegram approve
was refused (the asymmetry, both directions).

**Exit.** Operator approve works; Telegram approve is refused; both paths prove the same
transactional boundary and audit contract.

---

## Phase 5 — Transport UX: no Approve button under v1 policy (defense in depth)

**Goal.** Don't render a button that can only ever be refused; shrink the attack surface.

**Changes.**
- `outbox_delivery_sink.push_approval_prompt` / `tamoz-telegram` transport: render the Deny
  button only, whenever every active interrupt's `required_evidence` exceeds `chat_bound`
  (always true under v1). The markup `actions` reflects the policy, not a hardcoded list.
- A stray `approve:` callback (crafted, replayed, or from a cached old keyboard) is still
  refused by Phase 3 — the button's absence is UX, not the security boundary.
- The existing effect journal is authoritative for delivery attempts, receipts, UNKNOWN, and
  resolution. The outbox remains only the desired-delivery/claim projection; it must not own a
  parallel attempt, receipt, or resolution lifecycle.
- Add a concrete migration phase using `EffectJournal#prepare`, `#start`, `#complete`,
  `#reconcile`, and `#resolve`. Grade journal rows—not outbox status—as the authority for
  attempts, receipts, `UNKNOWN`, and resolution; prove every delivery has one journal effect
  and no outbox-owned attempt/receipt state machine.
- Map each delivery to `effect_key = EffectJournalKey.build(guard: context.guard,
  execution_id: request_id, task_id: task_id, call_index: terminal_delivery_sequence,
  operation: "telegram.send")`, `operation = telegram.send`,
  `safety = unsafe` (non-blind-retry), and the journal attempt token as the ownership/fence
  token. Telegram delivery is never automatically retried after `UNKNOWN`; only an explicit
  reconciliation operation with operator evidence may resolve whether to suppress or reissue.
  Its exact
  journal key inputs use a persisted `DeliveryJournalContext` that maps the comms owner/fence
  to a delivery-specific journal lease (`namespace = tamoz.comms.delivery`, `thread_id =
  request_id`, `lease_id = comms_owner_id`, `fence = comms_fence`). The adapter constructs a
  guard from that context; it never borrows a graph worker lease. Then
  `execution_id = request_id`, `task_id = task_id`,
  `call_index = terminal_delivery_sequence`, where `terminal_delivery_sequence` is the
  monotonically allocated per-task terminal-message sequence, and `operation = telegram.send`;
  `task_id` and `terminal_delivery_sequence` are persisted at admission and allocated by one
  SQLite CAS per request. `MIGRATION_9` adds `tamoz_comms_delivery_journal_context` with
  request/task/sequence/namespace/thread/owner/fence/attempt/checkpoint fields. One admission
  transaction persists that context, creates the active delivery execution/checkpoint required
  by `EffectJournal#prepare`, and feeds the same context to `prepare`, `start`, `complete`,
  `reconcile`, and `resolve`. The exact call is `EffectJournalKey.build(guard: context.guard,
  execution_id:, task_id:, call_index:, operation: "telegram.send")`; its identity
  verification also binds `safety = unsafe` and the canonical request digest. The
  `DeliveryJournalContext` satisfies the active-execution precondition by creating one fenced
  delivery execution before `prepare`; expiry transitions to `UNKNOWN` and does not grant a
  new attempt. Convert
  outbox `send_started`, `unknown`, receipt, and resolution fields to one-way projections;
  remove their state transitions. Tests must mutate/read journal state and assert the outbox
  projection cannot claim a different attempt or terminal result.
- `MIGRATION_9` also adds immutable effect-context/result evidence columns or a linked table
  keyed by `effect_key`: server ID, tool name, argument digest, catalog digest, learning IDs,
  source references, result digest, and summary-verification digest. `prepare` writes context;
  `complete` writes result evidence in the same transaction as terminal state. The journal
  reader grades these rows, never a generic outbox success row.

**Tests.** The rendered keyboard for a v1 prompt has Deny only; a hand-crafted `approve:`
press is still refused (Phase 3 test already covers this).

**Exit.** Users see a Deny-only prompt; the gate holds regardless of what callback arrives.

---

## Phase 6 — Conformance: C2/C3, adversarial, registry (bar group C green)

**Goal.** Turn the remaining bar rows into passing oracles.

**Changes/tests.**
- **C2 (INV-C):** replace the `skip` in the contract test with a real assertion — the
  requirement is reproducible offline from the pinned prompt (equals policy output for the
  interrupt digest), is part of the callback comparison, and a model-supplied requirement in
  the interrupt descriptor is ignored by the constant policy.
- **C3 (INV-E):** approve on expired/missing/unknown evidence never approves (extend existing
  guard to the `UNKNOWN` prompt-delivery case).
- **C4:** extend the exact-match callback comparison test to include `required_evidence` in
  the bound context.
- Adversarial: cross-surface / cross-correspondent approve refused; replayed approve consumed
  zero times.
- Optional (aligns with contract §6): a closed-registry enumeration test for the decision
  directions × evidence lattice, failing on an unregistered value.
- Add crash/concurrency tests at callback commit, local approval commit, migration
  interruption, and competing approve/deny points. The worker may apply only a committed
  decision intent, and delivery must remain a projection of the existing effect journal rather
  than a parallel delivery lifecycle.
- **C7 credential separation:** replace broad `.env` export in the launcher and live harness
  with exact allowlists. Every child additionally receives only `PATH`, `HOME`, `LANG`,
  `LC_ALL`, `TMPDIR`, `GEM_HOME`, `GEM_PATH`, and `RUBYLIB`. Gateway receives only
  `TAMOZ_TELEGRAM_BOT_TOKEN`, `TAMOZ_RUNTIME_DIR`, and `TAMOZ_TELEGRAM_SURFACE`; worker
  receives only `DEEPSEEK_API_KEY`, `TAMOZ_ALMS_MCP_ENDPOINT`, `TAMOZ_RUNTIME_DIR`,
  `TAMOZ_MODEL`, and `TAMOZ_PROVIDER`; harness receives only sanitized endpoint, runtime
  directory, database path, and test authorization. It may not receive `TAMOZ_ENV_FILE`, any
  bot token, or any model credential. Reject unexpected credentials and construct separate
  `gateway_env`, `worker_env`, and per-command harness environments. Prove every allowed and
  forbidden variable in subprocess tests. Command routing is explicit: `queue` receives
  runtime/config and model keys but no bot token; `worker` receives runtime, provider/model,
  ALMS endpoint, and provider credential only; `gateway` receives runtime/surface and bot token
  but no model/ALMS credential; `status` receives runtime/database path only; the harness
  receives sanitized runtime/database/endpoint values only. Prove provider credential
  selection and forbidden variables in every child. Model/provider credential validation moves
  into the worker child; the harness performs no model preflight. `queue` and `status` use
  their own filtered maps; `worker` alone validates provider credential selection.
  Implement `build_gateway_env`, `build_worker_env`, `build_queue_status_env`, and
  `build_harness_env` from already-parsed operator configuration. Remove `ENV.to_h` from the
  harness loader and remove shared-env passing to `Open3.capture3`; each command receives only
  its map. The harness receives sanitized values, never an env-file path, bot token, or model
  credential. Add positive/negative subprocess assertions for every command.
  Construct separate subprocess environments and prove Telegram credentials never reach the
  worker, model/ALMS credentials never reach the gateway, and the harness receives no bot
  token. Add redaction property tests for secrets, private addresses, URLs, raw ALMS/model
  output, and exceptions on every user-facing path.
- **Schema/deployment fence:** define the schema/policy epoch and `MIGRATION_9`, fence all v8
  processes before migration, and make startup refuse incompatible old-binary/new-schema and
  new-binary/old-schema combinations without auto-migrating. First deploy a fence-aware v8
  compatible binary that checks a pre-created maintenance marker before opening the store;
  only then deploy the v9 migrator. Store/check the epoch through a startup compatibility API.
  Deployment order is: fence and verify all v8 processes stopped,
  migrate v8→v9, start only the enforcing binary. Rollback is forward-only to an
  evidence-enforcing or deny-only binary; it may never restore the old approve-everything
  implementation. Test old-on-v9, new-on-v8, interrupted migration, and rollback.
- Store `schema_policy_epoch` in the metadata table with accepted values `8/legacy` and
  `9/evidence_gated`; expose `check_startup_compatibility(binary_epoch:, allow_migrate: false)`
  from the SQLite façade. `MIGRATION_9` adds the prompt envelope/evidence columns and epoch
  update. Startup takes a maintenance lock row `{owner_pid, owner_nonce, epoch, heartbeat,
  expires_at, fenced}` before opening worker/gateway stores; every v8 process checks the same
  row on startup and heartbeat, and refuses to run when `fenced` or when a newer owner exists.
  The marker record is `${TAMOZ_RUNTIME_DIR}/schema-maintenance.fence` containing
  `{version, owner_pid, owner_nonce, created_at, expires_at, phase}`. Migration uses a two-phase
  `PENDING → OWNED → FENCED` protocol: fsync the marker, acquire the SQLite lock with the same
  nonce, fsync the marker as `OWNED`, then atomically set the SQLite row `fenced` and marker
  `FENCED`. If either artifact exists without a matching nonce/phase, startup fails closed;
  recovery requires verified absence of all v8 processes/leases and a fresh nonce. Stale-owner
  recovery, fsync failures, marker-before-lock, lock-before-migration, post-migration
  verification, PID reuse, restart/fork races, interrupted migration, and rollback are tested.

**Exit.** Bar C1–C7 green; the contract test file has no skips.

---

## Phase 7 — Authority + docs

**Goal.** Make the record match reality.

**Changes.**
- Apply ADR-049 §18 one-liner and the ADR-043 amendment to `COMMS_DESIGN.md` (Phase 0 gates
  this).
- Contract: flip the §2 status from "blocked" to "resolved via exit 2 (ADR-049)"; header note
  updated.
- Bar §7.2/7.3: C1 moves from "fails today" to "met"; update the standing/level.
- Remove the temporary note in `comms_deny_callback_test.rb` once the new file is the
  canonical home.

**Exit.** Docs and authority consistent with code; no lingering "blocked" language.

## Phase 8 — T4 communication-bar and live ALMS gate

**Goal.** Prove the complete user-visible Telegram flow, not only the approval subsystem.

**Required oracles.**
- A1–A5: no success-like claim before verified terminal outcome; queued/running and
  empty/outage/failure are distinct; every failure has a fixed redacted reason code,
  retryability, and next action.
- B1–B4: admission and terminal intents are atomic, sequenced per logical identity, and
  delivered as a projection of the existing effect journal with no competing delivery state
  machine.
- D1–D4: scheduled work is not called final, retry policy is bounded and idempotent, unknown
  delivery is never silently retried or reported complete, and ownership/fencing/lease
  behavior is exercised.
- E1–E3: enforce a gradeable message matrix: no-approval fast = receipt + terminal; no-approval
  slow = receipt + at most one progress + terminal; approval = receipt + one prompt (editable)
  + terminal, with no separate decision acknowledgement. References are short and nonsecret.
  Telegram `/status` shows only the caller's bound task and both state axes, with cross-chat
  isolation; `tamoz status` is operator-scoped and exposes delivery ambiguity, audit
  transitions, and resolution controls.
- E4: run the canonical live ALMS scenario end-to-end from the CLI. The request carries an
  authorized surface ID/revision, correspondent, conversation/chat ID, and thread binding;
  the gateway delivers only to that bound Telegram chat. Use only the exact ordered pinned
  read-only tool list `[mcp:alms/learning.search]`. The agent verifies and summarizes
  non-empty ALMS evidence, and the result is delivered in the same chat. Assert no approval
  prompt or decision for this read-only request; test managed-action approval separately with
  a synthetic no-op gate. The live run uses only operator-configured endpoints, a
  private-network allowlist, no redirects, no credentials in the request, bounded time/results,
  and fails closed for discovery, sync, or mutation tools. Assert exact request/effect/outbox/
  terminal linkage, learning IDs/source references, result digest, deterministic summary
  verification, second-chat isolation, and terminal evidence printed only after the durable
  commit. Capture redacted evidence only; never put infrastructure addresses or credentials in
  the test or report.
- The live harness invokes the CLI request command with the explicit Telegram binding and a
  unique request reference, using explicit CLI flags `--surface`, `--surface-revision`,
  `--correspondent`, `--conversation`, and `--thread`; the CLI durably persists that binding
  through `QueueRequestBinding.persist(request_id:, binding:)` and returns the request ID.
  `QueueRequestBinding.authorize!` resolves the supplied surface/revision and conversation
  against an existing configured Telegram route and correspondent; arbitrary or cross-chat
  bindings are rejected before persistence. The route binding is copied, not caller-created.
  A separately started gateway owns the bot credential and delivery. The harness receives only
  sanitized runtime configuration, polls `JournalReader#live_alms_evidence(request_id:)`,
  whose output is `{request_id, ordered_effects, learning_ids, source_references, result_digest,
  summary_verification, terminal_state, terminal_delivery_intent, prompt_count, decision_count}`.
  Each `ordered_effects` item is `{effect_key, server_id, tool_name, argument_digest,
  catalog_digest, status, attempt_token, committed_at}`; the reader queries only persisted
  request/effect/result/terminal rows and rejects any tool other than
  `mcp:alms/learning.search`.
  Assert request → effect → non-empty evidence/source IDs → summary digest → outbox → terminal
  linkage, no prompt/decision rows, second-chat isolation, and terminal output only after the
  durable commit. It never loads `.env` or calls Telegram directly.
- Add negative status oracles: Telegram `/status` is caller-bound, read-only, and cannot resolve
  or expose `UNKNOWN` operator controls; only `tamoz status` and the operator delivery-
  resolution command may expose or resolve delivery ambiguity.

**Exit.** T4 is met only when all A–E rows have passing automated or explicit live evidence,
the live ALMS result is verified in the target chat, and unknown/failure/approval cases remain
honest. If any row is unproven, the bar remains below T4 and implementation is not declared
complete.

---

## Sequencing and dependencies

```
Phase 0 ─▶ Phase 1 ─▶ Phase 2 ─▶ Phase 3 ─▶ Phase 4 ─▶ Phase 5 ─▶ Phase 6 ─▶ Phase 7 ─▶ Phase 8
(accept)  (core)     (pin)      (enforce)   (operator)  (UX)       (oracles)  (docs)     (T4/live)
                     │            ▲
                     └── inert ───┘  behavior change isolated here
```

- Phases 1–5 are CI-only and non-deployable until Phase 0 acceptance, C7 credential isolation,
  redaction tests, governing-document consistency, and Phase 8 T4 completion all pass. No
  intermediate phase may start a live gateway/worker or claim production readiness.
- Phase 3 is the reviewable, revertible behavioral change and should be its own PR.
- Phases 4–7 depend on 3; Phase 8 depends on the complete preceding behavior and documentation.

## Crash-oracle coverage (contract §9 fault table, approval rows)

Phase 3/4 must preserve the existing approval oracles and add the evidence dimension:
- "During callback consumption" → at most one exact decision; an under-evidenced approve
  creates none.
- "After callback commit, before worker application" → a refused approve leaves no intent; a
  passed decision applies exactly once.
- "Approval prompt send becomes UNKNOWN" → stays inactive; an approve on it never resolves
  (INV-E).
- "Competing Telegram and local approval" → one winner under the same transaction; no second
  decision or worker application.
- "Migration interrupted or mixed-version process" → approve is refused or unavailable, never
  fail-open; deny remains unconditional.
- "Delivery projection crash" → replay is ordered/idempotent and never invents a terminal
  success.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| In-flight prompts without `required_evidence` after migration | NULL reads as `filesystem_operator` (safe default); no prompt is ever under-gated |
| A second approve path bypasses `consume_prompt` | Phase 4 audits every approve entry point; a grep-gate test asserts approve decisions are only inserted via the gated path |
| Over-engineering the lattice | v1 policy is a constant; the plan forbids effect-classification work until a per-effect ADR (ADR-049 §4) |
| Silent divergence of contract/bar/docs | Phase 7 makes the doc update part of "done" |

## Definition of done

- `test/comms_evidence_gated_approval_test.rb` fully green, no skips.
- Every pre-existing test green; no test asserts a Telegram approve producing an approve
  decision.
- Bar C1–C7 have passing oracles; contract §2 no longer "blocked".
- ADR-049 accepted and recorded in `COMMS_DESIGN.md`; ADR-043 amended.
- No production approve decision is created for `chat_bound` evidence under v1 policy.
- Bar A1–A5, B1–B4, D1–D4, and E1–E4 are proven; the live ALMS scenario has redacted,
  reproducible evidence showing query → summary → verification → same-chat Telegram delivery
  and terminal observability.
- No skip, unknown delivery, partial rollout, local-approval bypass, or rollback path can
  produce a success-like report without committed terminal evidence.

## Review loop

- Round 1: UX, reliability, and security reviewers rejected the plan.
- Round 2: all three reviewers rejected the revision. Gaps included full callback binding,
  trusted operator authorization, migration/rollback enforcement, credential separation, and
  gradeable T4 UX/live-ALMS evidence.
- Round 3: re-review this revision against the complete immutable envelope, trusted authority
  derivation, explicit process allowlists, bounded read-only ALMS flow, and message/status
  identity oracles.
- Round 4: UX and security approved; reliability rejected until the concrete data schemas,
  receipt API, journal mapping, epoch storage/fence, exact environment maps, and canonical
  live evidence were specified.
- Round 5: security approved; UX and reliability identified final consistency requirements for
  the single CLI-origin E4 fixture, exact `learning.search` scope, callback identity names,
  façade routing, journal transaction handle, maintenance-lock protocol, and sanitized harness
  environment. These are recorded above for the next approval round.
- Round 6: UX, reliability, and security all approved. No P0/P1 plan blockers remain.
- If any reviewer rejects it, patch the plan and repeat the full three-reviewer round. Begin
  implementation only after all three approve and the owner explicitly accepts ADR-049's exit
  choice.
