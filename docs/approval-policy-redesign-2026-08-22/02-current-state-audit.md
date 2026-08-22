# 02 — Current-State Audit: Approval & Permission in tamoz

Date: 2026-08-22
Scope: how approval/permission actually works today, as evidence for the redesign that
will isolate it into a dedicated gem. Every claim below cites the code it was read from;
a sample of references was re-verified in a critique pass (see §9, Revision log).

---

## 0. Headline finding: "approval" is three mechanisms sharing one word

A grep for `approval` returns ~102 files, but they implement **three distinct pipelines
that share no code**:

- **Pipeline A — in-session tool-call approval (the real gate).** When the agent's plan
  executes a step whose tool is classified approval-required, the durable session graph
  throws an interrupt, the turn parks, and a human answer (interactive CLI, operator CLI,
  or Telegram deny) resumes or terminates it. This is the mechanism the owner experiences
  as "the approval policy."
- **Pipeline B — one-shot runtime callback.** A simpler in-process gate in the legacy
  non-durable runtime: a Ruby callback per tool call, denial raises
  `ApprovalDeniedError`.
- **Pipeline C — stream approval relay.** `ApprovalRelay` + `ApprovalReceiptStore` +
  `LiveLearningHandlers` implement the *external* `io.agenticstream.approval.*`
  notification protocol: the stream classifies risk and owns authority; tamoz only
  delivers prompts and returns signed human answers. It never gates a local tool call.
  Its 97 grep hits in `approval_relay.rb` are about a different system.

Any redesign must first decide which of these the new gem owns. Treating them as one
system is how the current sprawl happened.

---

## 1. End-to-end flow (Pipeline A, durable session — the primary path)

### 1.1 Sequence, with file:line for every step

**Step 1 — Classification: does this plan step need approval?**
Decided per plan step, at preparation time, before any effect runs.

- `gems/tamoz-agent/lib/tamoz/agent/session_steps.rb:69` — the gate:
  `return no_approval_preparation(intent, arguments) unless effects.approval_required?(tool)`.
  If required, the step is prepared with a `preview` and `approval_required: true`
  (`session_steps.rb:71-76`).
- `gems/tamoz-agent/lib/tamoz/agent/session_effects.rb:291-292` delegates to
  `@configuration.capabilities.approval_required?(tool)`, which lands on
  `gems/tamoz-agent/lib/tamoz/agent/capability_binding.rb:144-147`, routing to the
  per-source dispatcher — the same object that will later execute the call.
- The classification rule depends on the tool's source:
  - **Local tools:** `gems/tamoz-tools/lib/tamoz/tools/local_dispatcher.rb:51` →
    `Toolbox#approval_required?` (`gems/tamoz-tools/lib/tamoz/tools/toolbox.rb:105`):
    `@approval_required.include?(String(name))`. The set comes from the profile key
    `tools.approval_required`; if the profile omits it, the default is **every action
    tool**: `DEFAULT_APPROVAL_REQUIRED = ACTION_DESCRIPTIONS.keys` =
    `apply_patch, run_check, create_file`
    (`gems/tamoz-tools/lib/tamoz/tools/tool_catalog.rb:18-28`).
  - **Unattended workers widen, never narrow:**
    `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:864-866`:
    `(profile.tools_approval_required | profile.unattended_requires_approval).uniq` —
    everything allowed but not explicitly preauthorized requires approval when nobody is
    watching.
  - **MCP / websearch (fail-closed heuristic):**
    `gems/tamoz-agent/lib/tamoz/agent/mcp_capability_source.rb:129`:
    `def approval_required?(name) = !read_only?(name)` — default effect class is
    `:unknown_effects`, and "Nothing a server says can change this"
    (`mcp_capability_source.rb:126-128`).
  - **Child tasks:** always —
    `gems/tamoz-agent/lib/tamoz/agent/child_task_dispatcher.rb:117`:
    `def approval_required?(_descriptor) = true`.
  - The capability *descriptor* layer restates the same policy declaratively:
    `approval_policy: :none | :required`
    (`gems/tamoz-core/lib/tamoz/core/capability/descriptor.rb:155-160`) with the
    enforced invariant that a `read_only` capability cannot require approval
    (`descriptor.rb:168-171`).

**Step 2 — The approval request is a graph interrupt, not a message.**

- `session_steps.rb:100-111` (`approval_update`):
  ```ruby
  answer = Tamoz.interrupt(approval_descriptor(...), context)
  granted = [true, 'approve', 'approved'].include?(answer)
  return { approvals: [approval], next_node: 'terminal', terminal_reason: 'approval_denied' } unless granted
  { approvals: [approval], effect_intents: [prepared.intent], next_node: 'step_execute' }
  ```
- The descriptor (kind `approve_tool`, carrying `tool`, `arguments`, `preview`, and
  digests — `session_steps.rb:113-126`) is thrown through
  `gems/tamoz-graph/lib/tamoz/graph/interrupt.rb:31-45`: `InterruptCursor#call`
  `throw(:tamoz_interrupt, …)` unless a resume value exists for that
  `(task_id, call_index)`. The graph checkpoints with status `:paused` and the pending
  interrupt recorded.
- Either way, an approval record is journaled into graph state:
  `session_steps.rb:128-140` builds it; the state slot is
  `state :approvals, reduce: :append, default: []`
  (`gems/tamoz-agent/lib/tamoz/agent/session.rb:427`).

**Step 3 — Who answers.** Three responders, all funneling into the same durable decision
record (`tamoz_comms_decisions`, see §3):

- **Interactive CLI (`tamoz run`):** the paused view is rendered, answers collected by
  `answer_for` (`gems/tamoz-agent/lib/tamoz/agent/cli.rb:467-484`) →
  `PromptAdapter#approve_tool`; `map_answer` accepts `y/yes/a/approve` → true,
  `n/no/d/deny` → false (`cli.rb:494-503`). Then `session.resume(answers, …)` in-process.
  - `--all --i-understand-approve-all` answers `true` to every `approve_tool` interrupt
    and emits an `audit.approve_all` event (`cli.rb:472-480`).
  - `options[:non_interactive]` returns `nil` — no answer, fail-closed (`cli.rb:481`).
- **Operator CLI (`tamoz approve REQUEST_ID [--deny]`):**
  `gems/tamoz-agent/lib/tamoz/agent/cli_worker_commands.rb:392-410` (`record_approval`)
  builds a `DecisionRecord` with `actor_kind: 'os_user'`, `source: 'cli'`, and mints
  `AuthorityEvidence.filesystem_operator` itself — "set by this code, never taken from
  CLI arguments or any wire" (`cli_worker_commands.rb:402-405`) — then writes it via
  `worker_runtime.rb:572-576` (`record_decision`). It never executes anything.
- **Telegram channel (deny-only in v1):** a button press normalizes to a `callback`
  envelope with text `approve:<ref>` / `deny:<ref>`, resolved in
  `CommsGateway#resolve_callback`
  (`gems/tamoz-agent/lib/tamoz/agent/comms_gateway.rb:209-242`):
  - prompt must exist and be `active` (`:214`);
  - the press must bind exactly to the prompt row (surface id+revision, correspondent,
    conversation, originating message receipt — `prompt_binding_matches?`, `:248-254`);
  - an `approve` press is refused when the presser's evidence is below the pinned
    requirement (`approval_insufficient_evidence?`, `:259-262`).
  The pinned requirement comes from
  `gems/tamoz-comms/lib/tamoz/comms/approval_policy.rb:15-17`, which returns
  `filesystem_operator` **unconditionally**; the lattice is
  `chat_bound < filesystem_operator`
  (`gems/tamoz-comms/lib/tamoz/comms/authority_evidence.rb:28-30`). Telegram supplies
  only `chat_bound`, so a Telegram approve is always rejected as
  `insufficient_evidence` (`comms_gateway.rb:226-230`). Only `deny` ever lands — a bare
  reference also means deny (`split_callback`, `:266-273`).
  On success the decision is written atomically with prompt consumption
  (`comms_gateway.rb:232-239`).

**Step 4 — Prompt transport (Telegram path only).**

- On settle of a paused turn the worker calls
  `notify_sink(thread_id, "request.approval_request", …)`
  (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:636-638`) →
  `OutboxDeliverySink#push_approval_prompt`
  (`gems/tamoz-agent/lib/tamoz/agent/outbox_delivery_sink.rb:109-137`): builds a
  single-use `ApprovalPrompt` (128-bit random reference, only its digest stored, status
  `inactive`, `expires_at = created_at + prompt_ttl_s` —
  `gems/tamoz-comms/lib/tamoz/comms/approval_prompt.rb:75-89`), inserts it, and appends
  an outbox `Delivery` of kind `approval_request` whose markup carries the **plaintext
  reference** for one send attempt.
- `offered_actions` (`outbox_delivery_sink.rb:169-174`) renders an Approve button only
  if `chat_bound >= required_evidence` — under v1 policy, never, so Telegram renders
  Deny-only. The comment is explicit: "the button's absence is UX, not the security
  boundary" (`:163-168`).
- Only after the send receipt is durable does the `DeliveryDrainer` activate the prompt
  (`gems/tamoz-agent/lib/tamoz/agent/delivery_drainer.rb:114-121`), so a callback can
  never resolve against a prompt the human could not have seen.
- If the surface's `approvals.mode` is not `deny_only`, the sink instead appends a
  "waiting for approval … use `tamoz approve`" notice
  (`outbox_delivery_sink.rb:145-161`).

**Step 5 — The decision travels back by polling, fenced claim, resume.**

- Each pass over a paused occurrence, the worker computes `interrupt_digest(view)` and
  calls `pending_decision` (`worker.rb:258-270` →
  `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:543-550` →
  `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_decision_store.rb:58-70`: newest unexpired
  `pending` row matching the exact digest; expired claim leases are reclaimable).
  No decision → `park(entry, view)` and wait for the next pass (`worker.rb:268`).
- With a decision, `apply_decision` (`worker.rb:398-425`): fenced `claim_decision`
  (30 s lease, `worker_runtime.rb:556-563`), `granted = decision.granted?`, one answer
  per pending interrupt (`answer_for`, `worker.rb:430-436` — `approve_tool` gets the
  boolean; a deny answers `nil` for clarify-type interrupts), then
  `session.resume(answers, …, request_id: decision.resume_request_id)` and
  `consume_decision` (`worker.rb:419-422`). The resume request id is *derived* from the
  decision, so a crash between enqueue and consume dedups instead of duplicating
  (`worker.rb:395-397`).

**Step 6 — Execution resumes (or terminates).**

- On resume, `InterruptCursor#call` returns the supplied value instead of throwing
  (`interrupt.rb:34`). Back in `approval_update`, `granted` decides: emit the effect
  intent and go to `step_execute` (`session_steps.rb:110`), or terminate the turn with
  `terminal_reason: 'approval_denied'` (`session_steps.rb:108`).
- Denial is a **state transition, not an exception**: the turn ends cleanly, the channel
  gets "Denied." (`worker.rb:416-417`), and the model never sees a tool error it could
  react to.
- **Timeout:** prompts expire at activate/consume time; decisions expire after
  `DEFAULT_TTL_S = 900` (`gems/tamoz-comms/lib/tamoz/comms/decision_record.rb:45`).
  Expiry makes a decision invisible (`comms_decision_store.rb:64-65` filters
  `expires_at_ms > ?`) — there is **no auto-deny and no escalation**: an unanswered
  occurrence stays parked indefinitely.

### 1.2 Flow diagram

```
 plan step
    |
    v
 session_steps.rb:69  effects.approval_required?(tool)?
    |  (toolbox.rb:105 | worker_runtime.rb:864 | mcp_capability_source.rb:129 |
    |   child_task_dispatcher.rb:117 — rule depends on tool source)
    +---- no ------------------------------------+
    |                                            v
    |                              approval_update (session_steps.rb:100)
    |                              Tamoz.interrupt(descriptor)
    |                                   |  throw(:tamoz_interrupt)  (interrupt.rb:37)
    |                                   v
    |                        graph checkpoints :paused; approval record journaled
    |                                   |
    |        +--------------------------+---------------------------+
    |        |                          |                           |
    |  interactive CLI           unattended worker             Telegram surface
    |  cli.rb:467 answer_for     worker.rb:636 notify_sink       outbox_delivery_sink.rb:109
    |  y/n -> session.resume     "request.approval_request"      insert_prompt (inactive)
    |  (in-process)              + park                          delivery sent ->
    |                                    ^                       delivery_drainer.rb:114 activates
    |                                    |                            |
    |    operator CLI: tamoz approve ID  |                     operator presses button
    |    cli_worker_commands.rb:392      |                            v
    |    record_approval ----------------+                     comms_gateway.rb:209
    |    (writes tamoz_comms_decisions)  |                     resolve_callback:
    |                                    |                     binding + evidence gates
    |                                    |                     (approve refused in v1);
    |                                    |                     deny -> consume_prompt :239
    |                                    |
    |                        worker.rb:258 next pass:
    |                        pending_decision(interrupt_digest)
    |                             | found
    |                             v
    |              apply_decision (worker.rb:398): fenced claim ->
    |              answers -> session.resume -> consume_decision
    |                             |
    +-----------------------------+
                                  v
              interrupt.rb:34 returns the resume value
              session_steps.rb:106 granted?
                     |-- yes --> step_execute (effect runs through the journal)
                     +-- no  --> terminal, reason = approval_denied
```

### 1.3 The other two pipelines (for completeness)

- **Pipeline B (one-shot):** `gems/tamoz-agent/lib/tamoz/agent/runtime.rb:582-605`:
  `if toolbox.approval_required?(step.tool)` → emit `:approval_requested` →
  `approved = approval&.call(tool:, arguments:, preview:)` →
  `unless approved == true … raise ApprovalDeniedError`. The callback is
  `CLI#approve_one_shot` (`cli.rb:853-858`): prints `Approve <tool>? [y/N]`, accepts
  only `y/yes`, EOF/nil = deny. No durability, no digests, no evidence.
- **Pipeline C (stream relay):** the stream emits `approval.requested`; tamoz reserves a
  receipt, claims delivery, delivers via an injected port, records the receipt
  (`gems/tamoz-stream/lib/tamoz/stream/live_learning_handlers.rb:102-125`); a human
  answer is submitted as an 11-field signed assertion with a single-use nonce,
  fail-closed expiry, and relay≠approver separation
  (`gems/tamoz-stream/lib/tamoz/stream/approval_relay.rb:116-168`). Boot wiring requires
  an operator-supplied `build_approval_relay` file (`bin/tamoz-stream-subscriber:42-64`)
  — nothing in the repo provides one.

---

## 2. Decision points — every place an approval/permission decision is made or enforced

### 2.1 Classification rules ("does this need approval?")

| # | Location | Rule |
|---|---|---|
| 1 | `gems/tamoz-tools/lib/tamoz/tools/toolbox.rb:105` | Local tool: name ∈ profile-supplied `@approval_required` set |
| 2 | `gems/tamoz-tools/lib/tamoz/tools/tool_catalog.rb:28` | Default when the profile omits the key: **all** action tools |
| 3 | `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:864-866` | Unattended: interactive set ∪ everything-not-preauthorized |
| 4 | `gems/tamoz-agent/lib/tamoz/agent/mcp_capability_source.rb:129` | MCP/websearch: everything except caller-declared `:read_only` |
| 5 | `gems/tamoz-agent/lib/tamoz/agent/governed_browser_source.rb:34-35` | Browser: same rule via descriptor `effect_class` (reported; see §9) |
| 6 | `gems/tamoz-agent/lib/tamoz/agent/child_task_dispatcher.rb:117` | Child tasks: always |
| 7 | `gems/tamoz-core/lib/tamoz/core/capability/descriptor.rb:155-171` | Descriptor invariant: `approval_policy ∈ {:none,:required}`; `read_only` ⇒ `:none` (enforced at build) |
| 8 | `gems/tamoz-comms/lib/tamoz/comms/approval_policy.rb:15-17` | Channel evidence policy: always `filesystem_operator` (constant) |

### 2.2 Enforcement gates ("execution stops here")

| # | Location | Rule |
|---|---|---|
| 9 | `gems/tamoz-agent/lib/tamoz/agent/session_steps.rb:69` | Per-step: skip approval prep when not required |
| 10 | `gems/tamoz-agent/lib/tamoz/agent/session_steps.rb:100-111` | Interrupt + `granted = [true,'approve','approved'].include?(answer)`; deny → terminal `approval_denied` |
| 11 | `gems/tamoz-agent/lib/tamoz/agent/runtime.rb:582-605` | One-shot: callback must return exactly `true`, else `ApprovalDeniedError` |
| 12 | `gems/tamoz-agent/lib/tamoz/agent/worker.rb:258-270` | Worker: no matching unexpired decision → stay parked |
| 13 | `gems/tamoz-agent/lib/tamoz/agent/worker.rb:398-425` | Worker: fenced claim; decision must match the exact interrupt digest |
| 14 | `gems/tamoz-agent/lib/tamoz/agent/session_plan_outcomes.rb:115-127` | Repeated approval-required action signature → terminate `repeated_action` |
| 15 | `gems/tamoz-agent/lib/tamoz/agent/cli.rb:472-481` | `--all`+`--i-understand-approve-all` blanket-approves; non-interactive → no answer (fail closed) |

### 2.3 Responder-side checks (channel/CLI)

| # | Location | Rule |
|---|---|---|
| 16 | `gems/tamoz-agent/lib/tamoz/agent/comms_gateway.rb:214` | Prompt must exist and be `active` |
| 17 | `gems/tamoz-agent/lib/tamoz/agent/comms_gateway.rb:220,248-254` | Callback must bind exactly to the prompt row (surface, correspondent, conversation, message receipt) |
| 18 | `gems/tamoz-agent/lib/tamoz/agent/comms_gateway.rb:226-230,259-262` | Approve refused when presser evidence < pinned `required_evidence` |
| 19 | `gems/tamoz-agent/lib/tamoz/agent/cli_worker_commands.rb:392-410` | CLI approval mints `filesystem_operator` evidence itself, never from arguments |
| 20 | `gems/tamoz-agent/lib/tamoz/agent/outbox_delivery_sink.rb:169-174` | Approve button offered only when `chat_bound >= required_evidence` (never in v1) |

### 2.4 Stream relay guards (Pipeline C)

| # | Location | Rule |
|---|---|---|
| 21 | `gems/tamoz-stream/lib/tamoz/stream/approval_relay.rb:119-123` | Receipt must be in state `requested` |
| 22 | `gems/tamoz-stream/lib/tamoz/stream/approval_relay.rb:125-127` | Decision ∈ {approve, deny} |
| 23 | `gems/tamoz-stream/lib/tamoz/stream/approval_relay.rb:129-132` | Relay may never be the asserted approver |
| 24 | `gems/tamoz-stream/lib/tamoz/stream/approval_relay.rb:136-139` | Expired approval: fail closed before submission |
| 25 | `gems/tamoz-stream/lib/tamoz/stream/approval_relay.rb:141-144` | Durable single-use nonce: replay refused |

### 2.5 Adjacent approval-shaped gates (same concept, other subsystems)

- **Self-improvement candidates:** `gems/tamoz-agent/lib/tamoz/agent/improvement/candidate_lifecycle.rb`
  — `approve!` requires a matching `approval_digest` and `human:<actor>` evidence
  (`:89-103`); creator cannot self-approve (`:160-162`); `apply!/activate!/rollback!`
  consult the recorded approval (`:105-132`). In-memory only. (Reported; see §9.)
- **Inbound channel admission (permission, not approval):**
  `gems/tamoz-comms/lib/tamoz/comms/admission.rb` — surface disabled / unbound
  correspondent / group chat refusals. (Reported; see §9.)

---

## 3. Data model — what is persisted about approvals

### 3.1 `tamoz_comms_approval_prompts` (single-use channel prompts)

Migration 6, `gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb:753-770`:

```sql
CREATE TABLE tamoz_comms_approval_prompts (
  reference_digest TEXT NOT NULL PRIMARY KEY,
  surface_id TEXT,
  surface_revision INTEGER CHECK (surface_revision IS NULL OR surface_revision > 0),
  thread_id TEXT NOT NULL,
  occurrence_id TEXT NOT NULL,
  interrupt_digest TEXT NOT NULL,
  correspondent_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  prompt_receipt TEXT,
  status TEXT NOT NULL CHECK (status IN ('inactive', 'active', 'consumed')),
  created_at_ms INTEGER NOT NULL,
  activated_at_ms INTEGER,
  consumed_at_ms INTEGER,
  expires_at_ms INTEGER NOT NULL
) STRICT
```

Migration 9 adds `required_evidence TEXT` (`migrator.rb:846-849`, ADR-049: pins the
evidence level the approver must present). Only the **digest** of the 128-bit reference
is stored; the plaintext lives in memory for one send attempt
(`approval_prompt.rb:75-89`). Lifecycle: `inactive` → `active` (after the send receipt is
durable, `delivery_drainer.rb:114-121`) → `consumed` (single-use CAS with the decision
insert in the same transaction, via `comms_gateway.rb:239`). Rows are deleted only by
thread purge; no sweeper.

### 3.2 `tamoz_comms_decisions` (durable approve/deny records)

Migration 6, `migrator.rb:771-789`:

```sql
CREATE TABLE tamoz_comms_decisions (
  decision_id TEXT NOT NULL PRIMARY KEY,
  thread_id TEXT NOT NULL,
  occurrence_id TEXT NOT NULL,
  interrupt_digest TEXT NOT NULL,
  direction TEXT NOT NULL CHECK (direction IN ('approve', 'deny')),
  actor_kind TEXT NOT NULL CHECK (actor_kind IN ('os_user', 'telegram_user')),
  actor_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('cli', 'telegram')),
  decided_at_ms INTEGER NOT NULL,
  expires_at_ms INTEGER NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'claimed', 'consumed')),
  claim_owner TEXT,
  claim_fence INTEGER CHECK (claim_fence IS NULL OR claim_fence > 0),
  claim_expires_at_ms INTEGER,
  consumed_at_ms INTEGER
) STRICT
```

Migration 10 adds `evidence TEXT` and `reason TEXT` (`migrator.rb:858-864`, ADR-049
audit trail). Default TTL 900 s (`decision_record.rb:45`). Lifecycle: `pending` →
`claimed` (fenced 30 s lease) → `consumed`; newest-wins supersession on the same
interrupt digest (`comms_decision_store.rb:54-57`). Deleted only by thread purge.

### 3.3 Stream approval receipts (KV, not a table)

`gems/tamoz-sqlite/lib/tamoz/sqlite/approval_receipt_store.rb` stores JSON values in the
generic versioned KV store under namespace `tamoz.stream.approvals.<tenant>` (`:8,14`),
key `"approval/<sha256(domain + approval_id)>"` (`:133-135`). Record fields written at
`:34-45`: `approval_id, tenant_id, identity, state (requested|withdrawn|resolved),
payload_digest, delivery_receipt, delivery_claimed, last_event_digest, traceparent,
tracestate`. API: `fetch` (`:17`), `reserve_requested` (`:21`), `record_delivery`
(`:54`), `claim_delivery` (`:66`, 3 CAS retries), `release_delivery` (`:83`),
`transition` (`:90`, tenant+identity verified, event-digest idempotent).
**No expiry and no cleanup: receipts accumulate forever** (no `expires_at` field, no
delete path in the file).

### 3.4 Approval records inside the durable session graph

Every interactive step approval is appended to checkpointed graph state:
`state :approvals, reduce: :append, default: []`
(`gems/tamoz-agent/lib/tamoz/agent/session.rb:427`), records built by
`session_steps.rb:128-140` with `approval_id, plan_id, plan_digest, step_id, tool,
arguments_digest, preview_digest, decision`. Also `state :seen_action_signatures`
(`session.rb:432`) persists the repeated-action guard's memory.

### 3.5 Adjacent persisted permission state

- `tamoz_comms_bindings` — active/revoked correspondent bindings (the dynamic allowlist).
- `tamoz_comms_pairing_challenges` — pending/approved/consumed pairing with expiry.
- `tamoz_comms_outbox` rows of kind `approval_request` — prompt delivery records whose
  markup carries the plaintext reference until activation.
- **Profile YAML files** — `tools.allowed`, `tools.approval_required`,
  `unattended.*` (file-based config; validated so `approval_required ⊆ allowed`).
- **Improvement-candidate approvals** — in-memory only (`candidate_lifecycle.rb`).

---

## 4. Strengths (each tied to code)

1. **Fail-closed classification with an enforced structural invariant.** Unknown-effect
   MCP tools default to approval-required and "Nothing a server says can change this"
   (`mcp_capability_source.rb:126-129`); the descriptor layer makes
   `read_only ⇒ no approval` a build-time error, not a convention
   (`descriptor.rb:168-171`). Unattended operation widens the approval set, never
   narrows it (`worker_runtime.rb:864-866`).
2. **A decision can only ever answer the exact question it was given.** Decisions bind
   the precise `interrupt_digest` of the paused turn (`worker.rb:261-267`,
   `comms_decision_store.rb:58-70`), are single-use (`consume_decision` after resume,
   `worker.rb:422`), and the resume request id is derived from the decision so a crash
   mid-resume dedups instead of duplicating (`worker.rb:395-397`). The fenced claim
   lease makes worker crashes recoverable (`worker_runtime.rb:552-563`).
3. **Authority evidence is a property of the trusted path, never of the wire.** The
   lattice is closed and total (`authority_evidence.rb:28-30`), non-member values raise
   instead of being coerced (`authority_evidence.rb:44-49`), the CLI mints its own
   evidence (`cli_worker_commands.rb:402-405`), and the gateway compares presser evidence
   against the requirement pinned at prompt-build time
   (`comms_gateway.rb:256-262`, `approval_prompt.rb:85`).
4. **Single-use prompt consumption is atomic.** Consuming a prompt and inserting its
   decision happen in one store transaction with a status CAS (`comms_gateway.rb:239`;
   store-side contract at `comms_store.rb` — see §9), so a replayed button press cannot
   resolve twice.
5. **Durable audit trail at both layers.** Every approval is journaled into graph state
   (`session.rb:427`, `session_steps.rb:128-140`) and every channel/CLI decision persists
   with actor, evidence, and reason (`migrator.rb:771-789,858-864`).
6. **Pipeline C is already extraction-shaped.** `ApprovalRelay` takes all I/O as
   injected ports (delivery, submission, nonce store, signer, approval state) and
   depends only on `tamoz/core` — it is the model the new gem should copy
   (`approval_relay.rb:116-168` signature surface; port-injection comment reported at
   `:28-31`, see §9).
7. **The invariants are pinned by tests.** Evidence-gating, single-use consumption, and
   deny-only rendering have dedicated suites (`test/comms_evidence_gated_approval_test.rb`,
   `test/comms_deny_callback_test.rb`, `test/stream_approval_relay_test.rb` — inventory
   reported, spot-checked in §9).

## 5. Weaknesses (each tied to code)

1. **Three mechanisms, one word, zero shared abstraction.** The same concept is
   implemented as a graph interrupt (`session_steps.rb:100-111`), a callback +
   exception (`runtime.rb:582-605`), and a signed-assertion relay
   (`approval_relay.rb:116-168`). There is no common "decision" type between A and B —
   Pipeline A terminates via state transition while Pipeline B raises
   `ApprovalDeniedError` — so behavior differs depending on which runtime happens to
   host the same tool call.
2. **No single place answers "does this action need approval?"** The rule is split
   across at least six sites in four gems (§2.1, rows 1–8): a default constant in
   tamoz-tools (`tool_catalog.rb:28`), profile YAML, a union in worker runtime
   (`worker_runtime.rb:864-866`), a per-source heuristic
   (`mcp_capability_source.rb:129`), a hardcoded `true` (`child_task_dispatcher.rb:117`),
   and a declarative descriptor field (`descriptor.rb:155-171`) that restates but does
   not drive the runtime gate. Changing the policy means editing all of them
   consistently.
3. **The channel policy is a hardcoded constant that neutralizes a fully built
   mechanism.** Prompts, single-use references, activation-after-receipt, evidence
   lattice, callback binding — all implemented — and then
   `ApprovalPolicy.required_evidence` returns `filesystem_operator` unconditionally
   (`approval_policy.rb:15-17`), making Telegram approve unreachable
   (`comms_gateway.rb:226-230`) and the Approve button never rendered
   (`outbox_delivery_sink.rb:169-174`). The behavior the owner wants to tune lives in a
   Ruby constant, not in configuration.
4. **No timeout semantics — the agent blocks forever.** An unanswered occurrence stays
   parked with no escalation and no auto-deny (`worker.rb:268`); the 900 s decision TTL
   only makes late decisions *invisible* (`decision_record.rb:45`,
   `comms_decision_store.rb:64-65`); stream receipts have no expiry field at all
   (`approval_receipt_store.rb:34-45`). A human who walks away bricks the turn.
5. **Fail-closed defaults + no scoped grants = maximal interruption.** Default is
   approval for every action tool (`tool_catalog.rb:28`); unattended widens that to
   everything not preauthorized (`worker_runtime.rb:864-866`); every MCP tool that
   isn't declared read-only (`mcp_capability_source.rb:129`); every child task
   (`child_task_dispatcher.rb:117`). And there is **no "allow this for the session"**:
   each decision binds one exact interrupt digest and is consumed on use
   (`comms_decision_store.rb:58-70`, `worker.rb:422`), so the tenth identical
   `run_check` prompts a tenth time. The only escape valves are profile edits or the
   blanket `--all --i-understand-approve-all` (`cli.rb:472-480`) — nothing in between.
6. **Denial is terminal and silent.** A deny ends the turn with
   `terminal_reason: 'approval_denied'` (`session_steps.rb:108`); the model receives no
   tool error and cannot course-correct, and the repeated-action guard terminates a
   replan that tries the same approval-required action again
   (`session_plan_outcomes.rb:115-127`). Useful work dies on the first "no."
7. **Policy is entangled with mechanism across five gems.** Classification lives in
   tamoz-tools/tamoz-agent dispatchers, the pause primitive in tamoz-graph
   (`interrupt.rb:31-45`), the gate in tamoz-agent session steps, the evidence policy in
   tamoz-comms, and persistence in tamoz-sqlite — one logical decision touches
   `toolbox.rb:105` → `session_effects.rb:291-292` → `session_steps.rb:100` →
   `worker.rb:258` → `comms_decision_store.rb:58` → `approval_policy.rb:15`. The
   classifier is even the same object that executes the call
   (`capability_binding.rb:144-147` routes `approval_required?` to the per-source
   dispatcher).
8. **Resume is polling-based.** The worker learns of a decision only on its next pass
   over parked threads (`worker.rb:258-270`); there is no push wakeup from
   `record_decision` (`worker_runtime.rb:572-576` writes the row and stops). Approval
   latency is bounded below by the worker's loop cadence, not by the human's answer.
9. **Two interactive UIs with divergent vocabularies.** The durable path accepts
   `y/yes/a/approve` and `n/no/d/deny` (`cli.rb:494-503`); the one-shot path accepts
   only `y/yes` (`cli.rb:853-858`). Same product, same question, two contracts.
10. **Dead policy surface in the scheduler.** `Schedule` carries an `approval_policy`
    hash that is validated only as "a hash" and is informational; the CLI hardcodes
    `{"mode" => "deterministic", "risk" => "read_only"}` when creating schedules
    (reported: `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb:35,305`,
    `gems/tamoz-agent/lib/tamoz/agent/cli_schedule_commands.rb:92` — spot-checked in §9).
11. **Prompt activation is coupled to message delivery plumbing.** The plaintext
    reference transits the outbox markup (`outbox_delivery_sink.rb:106-108,123`) and the
    prompt becomes usable only after the send receipt round-trips through the drainer
    (`delivery_drainer.rb:114-121`). Correct for the channel, but it means "ask a human"
    is inseparable from "send a Telegram message" in the current factoring.

---

## 6. Coupling inventory — what isolating approval into a gem would touch

### 6.1 Core implementation files (the things that would move)

| File | Defines | Depends on |
|---|---|---|
| `gems/tamoz-comms/lib/tamoz/comms/approval_policy.rb` | `Comms::ApprovalPolicy.required_evidence` (constant body) | `authority_evidence` (same gem) only |
| `gems/tamoz-comms/lib/tamoz/comms/approval_prompt.rb` | `Comms::ApprovalPrompt` value; `REFERENCE_DOMAIN`; build pins `required_evidence` (:85) | comms internals: `canonical`, `errors`, `interrupt_digest`, `authority_evidence`, `shapes` |
| `gems/tamoz-comms/lib/tamoz/comms/authority_evidence.rb` | `Comms::AuthorityEvidence` lattice | `errors` (same gem) |
| `gems/tamoz-comms/lib/tamoz/comms/decision_record.rb` | `Comms::DecisionRecord` value; `DEFAULT_TTL_S` (:45) | comms internals |
| `gems/tamoz-comms/lib/tamoz/comms/decision_store.rb` | decision-store contract (no impl) | — |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb` | prompt persistence: `insert_prompt` (:500), `activate_prompt` (:524), `consume_prompt` (:546), `prompt` (:567) | sqlite adapter; **must stay transactional with decision insert** |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_decision_store.rb` | `CommsDecisionStore` | sqlite adapter |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/approval_receipt_store.rb` | `SQLite::ApprovalReceiptStore` (Pipeline C) | `tamoz/core` digest, `StoreConflictError`, KV store handle |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb:753-789,846-864` | prompt + decision tables, `required_evidence`, `evidence`/`reason` | migration ordinals are manifest-pinned — schema moves are delicate |
| `gems/tamoz-stream/lib/tamoz/stream/approval_relay.rb` | `Stream::ApprovalRelay` (Pipeline C) | `tamoz/core` only; all I/O injected |
| `gems/tamoz-stream/lib/tamoz/stream/live_learning_handlers.rb:102-153` | approval event handlers | injected `approval_receipts:` / `approval_relay:` ports |
| `gems/tamoz-agent/lib/tamoz/agent/session_steps.rb:69,100-140` | the actual runtime gate + journaling | graph interrupt, session records |
| `gems/tamoz-agent/lib/tamoz/agent/runtime.rb:582-605` + `errors.rb:46` | one-shot gate + `ApprovalDeniedError` | toolbox, event bus |

### 6.2 Consumers, per gem (symbols used — the call sites that would re-point)

**gems/tamoz-agent** (heaviest):
- `outbox_delivery_sink.rb` — `Comms::ApprovalPrompt.build` (:114), `insert_prompt`
  (:122), `Comms::ApprovalPolicy.required_evidence` (:171), `Comms::AuthorityEvidence`.
- `comms_gateway.rb` — `ApprovalPrompt::REFERENCE_DOMAIN` (:211), store `prompt` (:212),
  `AuthorityEvidence` compare (:259-262), `DecisionRecord.build` (:232),
  `consume_prompt` (:239).
- `delivery_drainer.rb:114-121` — `activate_prompt`, `REFERENCE_DOMAIN`.
- `cli_worker_commands.rb` — `DecisionRecord.build` + `AuthorityEvidence`
  (:392-410); `paused_approvals` status (:444, reported).
- `worker.rb` — `pending_decision`/`claim_decision`/`consume_decision` wrappers
  (:258-270, :398-425); `notify_sink(..., "request.approval_request")` (:636-638).
- `worker_runtime.rb` — decision-store wrappers (:543-576); `unattended_approval_required`
  (:864-866); toolbox wiring (:1072, :1086-1089, reported).
- `session.rb:427,432` — `approvals` / `seen_action_signatures` graph state.
- `session_effects.rb:291-292`, `capability_binding.rb:144-147,203,285` — the
  `approval_required?` dispatch chain + descriptor `approval_policy:` synthesis.
- `cli.rb` — `answer_for`/`map_answer` (:467-503), `approve_one_shot` (:853-858),
  toolbox build with `approval_required:` (:615, reported).
- `cli_prompt_adapter.rb` — interactive approve/deny loop (:26-40, reported).
- `profile.rb` / `profile/fields.rb` / `profile/authority_validator.rb` — the
  `tools.approval_required` / `unattended.*` schema and validation (reported:
  `profile.rb:72,89`; `fields.rb:87-97`; `authority_validator.rb:115-124`).
- `deliberation.rb:307-314` (reported) — action signatures digest approval-required steps.
- `improvement/candidate_lifecycle.rb` — separate human-gate with its own digests.
- `session_status_projection.rb`, `terminal_progress.rb:15`, `cli_comms_shared.rb:87`
  (reported) — status/projection/config strings.

**gems/tamoz-tools**:
- `toolbox.rb:105` — `approval_required?`; `tool_catalog.rb:28` — default set;
  `tool_policy_normalizer.rb:119-133` (reported) — `approval_required ⊆ allowed`;
  `local_dispatcher.rb:51-53` — delegation;
  `capability_host.rb:91,197` (reported) — descriptor policy surfaced in inventory.

**gems/tamoz-core**: `capability/descriptor.rb:155-171` — `approval_policy` field +
invariant; `error.rb:179` — `StoreConflictError`.

**gems/tamoz-comms** (beyond core files): `surface_descriptor.rb` — `APPROVAL_MODES` and
the `approvals:` config block (reported: `:35,206-228`); `delivery.rb:29` (reported) —
`approval_request` kind; `comms_store.rb:122-139` (reported) — prompt store contract.

**gems/tamoz-sqlite** (beyond core files): `adapter.rb:58-60` (reported) —
`bind_approval_receipt_store`; `thread_purge.rb:185,190` (reported) — deletes;
`comms_routes.rb:69` (reported) — routes.

**gems/tamoz-telegram** (wire-format coupling only): `transport.rb:81-88` (reported) —
`callback_data: "#{action}:#{reference}"`; `normalizer.rb:66-77` (reported) — callback
envelope shape.

**gems/tamoz-scheduler**: `schedule.rb:35,305` (reported) — informational
`approval_policy` hash field.

**gems/tamoz-observability**: `catalog.rb:154,161` (reported) — `tamoz.approval.pending`,
`tamoz.approval.wait_ms` metric names.

**gems/tamoz-evals**: scoreboard/smoke harness `approval:` lambdas, denied-approval
cases (reported: `harness/agent_smoke_corpus.rb:1027-1043`, `harness/agent_run_audit.rb:43-45,97-105`).

**bin/**: `bin/tamoz-stream-subscriber:42-64` — Pipeline C boot wiring (dynamic
`build_approval_relay` require; receipt-store binding). `bin/tamoz-stream-worker` and
`bin/tamoz-eval`: no approval references (reported).

**apps/tamoz-agent**: metadata only; no code (reported).

### 6.3 Gem dependency graph today (reported from gemspecs; spot-checked in §9)

- `tamoz-comms` → `tamoz-core` only. `tamoz-stream` → `tamoz-core` (+grpc) — deliberately
  **not** tamoz-comms. `tamoz-sqlite` → `tamoz-graph`, `tamoz-scheduler`,
  `tamoz-stream`. `tamoz-agent` → `tamoz-tools`, `tamoz-graph`, `tamoz-sqlite`,
  `tamoz-comms`, `tamoz-observability`. `tamoz-tools` → `tamoz-core`.
- A `tamoz-approval` gem would be depended on by comms (policy/prompt), stream (relay),
  sqlite (stores), and agent (call sites) — or the graph inverts if only the pure
  values move and stores stay.

### 6.4 Tests that pin current behavior (would need updating)

- Stream: `test/stream_approval_relay_test.rb` (14 tests), `test/stream_invariants_test.rb`
  (**pins the gem's file inventory by glob including `approval_relay`** — reported:
  `:26`; moving the file breaks this), `test/stream_learning_loop_test.rb`.
- Comms: `test/comms_evidence_gated_approval_test.rb` (15 tests, ADR-049 bar),
  `test/comms_deny_callback_test.rb`, `test/comms_authority_evidence_test.rb` (pins the
  constant policy body), `test/sqlite_comms_store_test.rb`, `test/comms_values_test.rb`.
- Agent: `test/agent_decision_flow_test.rb`, `test/agent_unattended_policy_test.rb`,
  `test/agent_runtime_test.rb:256`, `test/agent_tool_error_recovery_test.rb:286`
  (`ApprovalDeniedError`), `test/agent_capability_binding_test.rb:44`.
- Meta/packaging: `test/public_api_test.rb` (pins `Tamoz::Agent::ApprovalDeniedError`,
  `Tamoz::Comms::ApprovalPrompt`, `Tamoz::Stream::ApprovalRelay` — reported:
  `:17,47,242`; mirrored in `docs/public-api.json` and
  `documentation/reference/public-api.md`), `test/packaging_test.rb`.

### 6.5 Non-Ruby coupling

- `gems/tamoz-stream/contracts/notification-contract-v1.json` — JSON schemas for the
  three `io.agenticstream.approval.*.v1` events, runtime-loaded, shipped in the gem
  (reported: `:15-17,50-64`; goldens in `notification-goldens-v1.json:39-78`).
- `test/fixtures/domains/*.json` — operator-prompt text mentions human approval for R2
  intents (digest-gated data, not machinery).
- `gems/tamoz-evals/suites/agent/smoke/*.case.json` — `07_denied_approval` and siblings.
- `script/autonomy_scorecard`, `script/live_alms_telegram`, manifest generators —
  read `paused_approvals` status (reported).
- Docs with structural claims that rot on a move: `documentation/adr/adr-049-telegram-approval.md`,
  `documentation/design/comms.md`, `documentation/architecture/security-model.md`,
  `docs/requirements-manifest.json`. Note: `docs/new-design/impl/P8_CHANNEL_UNIFICATION.md:11`
  already mislabels the relay as `Tamoz::Agent::ApprovalRelay` — it is `Tamoz::Stream`
  (reported).

### 6.6 Extraction-relevant structural facts

- The prompt/decision store pair is **transactionally coupled**: `consume_prompt`
  inserts the decision in the same SQLite transaction, so the store contract and its
  implementation must move (or stay) together.
- Migration ordinals are checksummed and manifest-pinned (`migrator.rb:852-854,867-869`
  for migrations 9/10) — the tables' *definitions* cannot move gems without a plan for
  the migrator.
- `ApprovalPolicy` is 7 lines with one same-gem dependency — trivially movable, but its
  constant is referenced from `approval_prompt.rb:85`, `outbox_delivery_sink.rb:171`,
  and pinned by `test/comms_authority_evidence_test.rb`.
- The three pipelines share no code; the new gem's first design decision is whether it
  absorbs Pipeline C's relay or leaves it in tamoz-stream.

---

## 7. Lessons learned — what the redesign must keep, fix, and avoid

**Keep (proven properties):**
- Digest-bound, single-use decisions: a decision answers exactly one paused question and
  dies on use (`comms_decision_store.rb:58-70`, `worker.rb:395-422`).
- Authority-as-evidence with a closed lattice, minted only by trusted paths, never
  parsed from wire input (`authority_evidence.rb:40-49`, `cli_worker_commands.rb:402-405`).
- Fail-closed classification for unknown/undeclared effects
  (`mcp_capability_source.rb:126-129`).
- Durable journaling of every approval decision, both in graph state and in the
  decisions table (`session.rb:427`, `migrator.rb:858-864`).
- Port-injected design of Pipeline C — the extraction template (`approval_relay.rb`).
- Crash-safe resume: fenced claims, derived resume ids (`worker_runtime.rb:552-563`,
  `worker.rb:395-397`).

**Fix (what makes the owner feel blocked):**
- One policy, one place: replace the six-site rule split (§2.1) with a single policy
  object the new gem owns, consulted by every source (local, MCP, browser, child,
  unattended) through one interface.
- Make policy data, not constants: the v1 evidence rule (`approval_policy.rb:15-17`)
  and the default action-tool set (`tool_catalog.rb:28`) belong in configuration/data
  with the same digest-discipline the repo already uses for domain data.
- Add middle states between "ask every time" and `--all`: scoped grants (this tool /
  this action signature / this session), persisted and auditable like decisions are now.
- Give timeout a semantics: expiry should resolve to a declared outcome (deny, escalate,
  or park-with-deadline), not to silence (`worker.rb:268`).
- Let denial be informative: return a structured denial the model can react to instead
  of an unconditional terminal transition (`session_steps.rb:108`).

**Avoid (mistakes not to repeat):**
- Don't build full machinery and then neutralize it with a constant — the deny-only
  Telegram pipeline (§5.3) is code that can never fire carrying real maintenance and
  test cost.
- Don't let the classifier be the executor: routing `approval_required?` through the
  per-source dispatcher (`capability_binding.rb:144-147`) welded policy to mechanism.
- Don't split one logical decision across five gems; the polling, CAS, TTL, evidence,
  and journaling concerns should compose behind one gem boundary, not be rediscoverable
  only by reading six files in four gems.
- Don't add a fourth pipeline: Pipeline B (`runtime.rb:582-605`) duplicates Pipeline A
  with weaker guarantees and should converge, not be preserved.
- Don't rely on polling as the only wakeup for a human-waiting state (`worker.rb:258-270`).

---

## 8. Verification status

References fall into two classes: (a) verified by direct reading during drafting —
everything in §1, §3.1–3.4, and most of §2/§4/§5; (b) reported by codebase exploration
and marked "(reported)" inline, a sample of which was re-read in the critique pass below.
Anything that could not be pointed at code was dropped rather than asserted.

## 9. Revision log

**Pass 1 — self-critique against bar items 1–7, after the first full draft.**

Method: every reference that originated from codebase exploration rather than direct
reading during drafting (the "(reported)" markers) was treated as suspect. A sample
spanning all sections and all three exploration tracks was re-read in the source:

- §1 flow chain: `session_effects.rb:291-292`, `capability_binding.rb:144-147,203,285,343-344,392-393`, `local_dispatcher.rb:51-52`, `cli_prompt_adapter.rb:26-40`, `comms_store.rb:524-565` — all accurate.
- §2 decision points: `governed_browser_source.rb:34-35` — accurate; `candidate_lifecycle.rb:89-103` — accurate.
- §6 coupling: `schedule.rb:35,56,65,83,274,288,305,316` and `cli_schedule_commands.rb:92` — accurate (`approval_policy` validated only via `validate_hash!` at `schedule.rb:305`); `surface_descriptor.rb:35,206-228` — accurate; `delivery.rb:29` — accurate; `comms_store.rb:122-139` contract — accurate; `thread_purge.rb:190` — accurate; `adapter.rb:58-60` — accurate; `worker_runtime.rb:1072` — accurate; `cli.rb:615` — accurate; `deliberation.rb:307-311` — accurate; `transport.rb:59,81-88` — accurate; `bin/tamoz-stream-subscriber:42-64` — accurate; `public_api_test.rb:17,47,242` — accurate.
- §6.3 gemspec dependency graph — re-read from `gems/gemspec_helper.rb` and the five gemspecs directly: accurate as stated.

Findings and changes:

1. **No incorrect references found.** Zero line drift, zero misattributed rules in the
   sample; the draft's claims stood. No corrections to §1–§7 were required.
2. **One nuance added to this log, not the body:** `transport.rb:76` carries the comment
   "v2 approve+deny (ADR-043 v1 was deny-only)" — the *wire format* already supports an
   `approve:` callback; the deny-only behavior comes entirely from
   `ApprovalPolicy.required_evidence` (`approval_policy.rb:15-17`) plus
   `offered_actions` (`outbox_delivery_sink.rb:169-174`), exactly as §1/§5.3 state. The
   body text was already correct; noted here so a future reader is not confused by the
   comment.
3. **Bar self-check:** (1) flow + diagram — §1.1/§1.2, every step carries file:line;
   (2) decision points — §2, 25 enumerated across five categories; (3) data model — §3,
   both table schemas verbatim plus KV record shape, lifecycle, and cleanup status;
   (4) strengths — §4, seven items, each with file:line; (5) weaknesses — §5, eleven
   items, each with file:line; (6) coupling inventory — §6, per-gem tables including
   tests, non-Ruby artifacts, and the gemspec graph; (7) lessons — §7 in keep/fix/avoid
   form. Items left unverifiable (e.g. exact worker poll cadence in wall-clock terms)
   were phrased to claim only what the code shows.
