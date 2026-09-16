# F11 `tamoz-comms` — IMPROVE: the admission boundary is real and the evidence gate holds, but the rendering contract silently drops data and control characters, and the written FIFO delivery guarantee has no store primitive

Row / queue / baseline: `F11` | W3A | branch `audit-15-09`, HEAD `582ae55`, checkpoint date 2026-09-15 | analyst F11 (read-only) | budget ~45 min, elapsed ~42 min

## Scope and source map

`tamoz-comms` is a contract gem: 25 files under `gems/tamoz-comms/lib/tamoz/comms/`, **2990 lines** total plus a 19-line gemspec. Every file was read end to end. Line counts: `comms.rb` 38, `admission.rb` 136, `store.rb`→`comms_store.rb` 204, `rendering.rb` 77, `transport.rb` 58, `delivery.rb` 167, `outbox_delivery_sink.rb` 398, `surface_descriptor.rb` 275, `decision_record.rb` 314, `inbound_envelope.rb` 213, `binding.rb` 203, `approval_prompt.rb` 199, `delivery_sink.rb` 36, `authority_evidence.rb` 76, `pairing_challenge.rb` 87, `lifecycle.rb` 82, `errors.rb` 75, `commands.rb` 63, `canonical.rb` 61, `decision_store.rb` 60, `control_reply.rb` 52, `clarification_answer_request.rb` 27, `shapes.rb` 29, `interrupt_digest.rb` 34, `version.rb` 7.

**Entry seam.** `Tamoz::Comms::Admission.decide` (`admission.rb:36`) is the pure decision function the gateway calls once per normalized envelope. The gem's dependency direction is honest and narrow: `comms.rb:3` requires only `tamoz/core`, and `tamoz-comms.gemspec:16-18` declares exactly `tamoz-core` — no transport, no store implementation, no session. `transport.rb:30-55` and `comms_store.rb:26-199` are structural seams whose bodies raise, by design (`transport.rb:22-23`, `comms_store.rb:16-18`).

**Caller trace (read, cited, not claimed as this row's finding).**
- `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb:17-24` calls `Admission.decide`; `gateway_admission_binding.rb:13-27` binds the thread/profile route; `gateway_callbacks.rb:21-43` resolves approvals.
- `gems/tamoz-telegram/lib/tamoz/telegram/normalizer.rb:34-50` produces the envelope; `transport.rb:52-72` performs the send; `client.rb:46-93` maps HTTP outcomes.
- `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb` (1301 lines) is the one real `CommsStore` implementer; the delivery primitives live in `comms_outbox.rb` and the admission primitives in `comms_store_rows.rb`. Row F07 owns it; here it is read only as this contract's implementer.

**Prior finding carried forward by name:** `analyses/comms-unknown-ordering.md` (`F12-REL-01`). Status below.

## Behavior path

1. **Normalize.** `normalizer.rb:34-50` collapses one raw update into `InboundEnvelope` (`inbound_envelope.rb:22`), which bounds and freezes every field (`:142-208`). Group/supergroup/channel chats get a typed prefix (`normalizer.rb:144-148`); anything unsupported becomes `kind: 'unsupported'` (`:107-113`), never a turn.
2. **Decide.** `Admission.decide` (`admission.rb:36-48`) is pure: disabled surface → reject; unsupported kind → ignore; group chat → reject; a non-active binding → reject; callback → `:decision`; command → command admission; text → text disposition.
3. **Route.** `gateway_admission.rb:32-53` maps the disposition: `:request` → `admit_request`, `:decision` → `resolve_callback`, `:rejected`/`:control` → durable disposition (+ bounded control reply), else → durable `ignored`.
4. **Admit durably.** `admit_request` (`gateway_admission.rb:55-76`) binds the route first (`gateway_admission_binding.rb:13-27`) then calls `store.admit_and_enqueue`, which writes the inbound anchor, the admitted request row, and the checkpoint inbox row **in one transaction** (`comms_store.rb:123-157`).
5. **Project output.** The worker's `OutboxDeliverySink#push` (`outbox_delivery_sink.rb:94-148`) renders through `Rendering.plain` and appends one `Delivery` per part; it never makes a network call.
6. **Deliver.** `DeliveryDrainer#drain_once` (`delivery_drainer.rb:45-57`) reconciles, selects `pending` rows, claims each under a fence, marks send-started, sends, and records the outcome.

## Lens: correctness

**Admission decision table is complete and deterministic.** All five dispositions are reachable and typed: `:request` (`admission.rb:117,120`), `:control` (`:84,86`), `:decision` (`:125`), `:ignored` (`:128`), `:rejected` (`:130`). Probed directly: unknown sender in allowlist mode → `[:ignored, :unbound, nil]`; revoked binding → `:rejected`; supergroup → `:rejected`; pairing with no binding → `:ignored`; unknown command → `:control` with a reply and **no** `command_intent`.

**A real defect in the delivery state machine's evidence: `mark_delivery` is status-blind.** `comms_outbox.rb:235-246` guards only `WHERE delivery_id = ? AND status = 'claimed' AND claim_owner = ? AND claim_fence = ?`; the `status` column is written from the caller's argument with no transition table. `mark_delivery_send_started` (`:137-147`) does not set `send_started_at_ms = NULL` back, and `release_delivery_claim` (`:124-133`) does. So `mark_delivery(claimed → succeeded)` is reachable **without** crossing the send boundary at all. This row's contract (`comms_store.rb:120-133`) says an outcome is recorded for a CLAIMED row and that `unknown` is the honest ambiguity state — it does not forbid a success claim from a row that never started sending. I record this as a finding at the F11 contract seam with the F07 implementation as the cited evidence. See `F11-ERR-01`.

**Prior finding carried forward — `F12-REL-01`, ordering.** Verified against current source and **reproduced**. `drain_once` builds its candidate list once (`delivery_drainer.rb:47`) then walks it without re-querying eligibility (`:48-52`); `outbox_rows` filters `pending` and orders only by `created_at_ms` (`comms_outbox.rb:197-205`); `claim_delivery` (`:82-98`) and `reconcile_expired_deliveries` (`:146-163`) are both row-local. My probe appended multipart A(`part_index=0`)/B(`part_index=1`) to one conversation, made A's transport raise `AmbiguousDeliveryError`, and observed `outcome=:drained`, `attempts=["A-part0", "B-part1"]`, durable `A=unknown`, `B=succeeded` — in one pass, no restart. The written contract is stronger (`documentation/design/comms.md:105-109`: "Delivery order is fenced FIFO per conversation; an `:unknown` part blocks later parts until operator resolution"). **Current status: still open, still confirmed, unchanged by HEAD `582ae55`, and now also reproduced by an independent probe by this row.** It has **no** owner at this gem: `tamoz-comms` ships no ordering primitive and its `CommsStore` contract (`comms_store.rb:98-143`) exposes no conversation sequence or predecessor-eligibility operation, so the missing contract is genuinely F11's, which is why the recommendation in `comms-unknown-ordering.md:92-99` names this seam.

**Silent truncation loses the overflow.** `rendering.rb:42-51`: the truncate branch carves `text[0, ceiling * max_parts]` before splitting. If the saved text exceeds that many characters, the remainder is discarded with **no marker** — probe: 12000 chars in, `max_parts: 3 × 100` → 3 parts whose texts are 100/100/100... and joined length 300, no `…` and no `tamoz show` reference. `documentation/design/comms.md:113` promises "bounded overflow with an explicit marker naming the thread and the `tamoz show` recovery command." See `F11-COR-01`.

**Splitting does not honour its own stated ladder and breaks code fences.** `rendering.rb:54-63` `take_part` fills to the ceiling and stops; it never attempts paragraph or line boundaries, contradicting `rendering.rb:8-9` and `design/comms.md:113` ("at paragraph, then line, then a grapheme-safe hard boundary"). Probe with a fenced Ruby block at `part_characters: 60` produced parts starting mid-line (`"s 1\nputs 1..."`, `" 1\nputs 1..."`) and no part carries a fence marker, so a fenced block is split into untagged fragments. Grapheme safety itself is **correct**: the ZWJ family emoji round-trips exactly (`test_parts_never_split_a_grapheme_cluster`, `comms_rendering_test.rb:43-53`), and the `ceiling = [part_characters, 4096].min` clamp (`rendering.rb:42`) is closed against a misconfigured 9000.

**Control characters and markup reach the transport verbatim.** `Rendering.plain` does no scrubbing: probe passed `\x00`, `\x07`, ESC `\x1b[31m`, `\r`, `\t` through unchanged, and `<b>&amp;<a href='x'>` unescaped. `Rendering::RENDER_VERSION = 1` (`rendering.rb:15`) and `SurfaceDescriptor::RENDER_FORMATS = %w[plain restricted_html]` (`surface_descriptor.rb:37`) are validated at construction (`:234-246`) but **the stored format is never read**: grep finds zero consumers of `restricted_html` anywhere but its own declaration, and `outbox_delivery_sink.rb:115-119,252-259,329-333` reads only `max_parts`/`part_characters`/`overflow`. No escaping helper exists in the gem. The only scrub on the outbound path is `gateway_delivery.rb:17` (`String(reply_text).scrub.byteslice(...)`), and that covers gateway control *replies* only — not worker/model answer text, which arrives through `OutboxDeliverySink`. Since the only shipped transport always calls `sendMessage` with `parse_mode` absent (`telegram/transport.rb:53-64`), Telegram parses the text as HTML, so `<`, `>`, `&`, and a bare URL are live markup/link-preview surfaces. See `F11-SEC-01`.

**The drainer's `unknown` classification is honest.** `send_delivery` (`delivery_drainer.rb:142-151`) maps `AmbiguousDeliveryError` → `{status: 'unknown'}`; `client.rb:116-121` maps any non-idempotent transport failure to `AmbiguousDeliveryError`, and `transport.rb:69-72` maps a capped send response to the same. A `ThrottledError` instead defers and releases the claim back to `pending` (`delivery_drainer.rb:117-127`) — a proven-not-sent retry, which is the correct distinction. No blind retry of `unknown` exists; the only resolver is the operator CLI (`cli_comms_ops.rb:216-220`) against a row it first confirms is `unknown`.

## Lens: security and authority

**The allowlist is enforced before any session or workspace file exists — proven.** `Admission.decide` is pure and I/O-free (`admission.rb:9-13`); `text_disposition` (`:89-113`) admits only on a listed `correspondent_id` or an active binding, and an empty allowlist is a **construction** error, not allow-everything (`surface_descriptor.rb:196-204`, probed: raises `ValidationError`). The gateway constructs no Session on this path at all — `gateway.rb:25` states it and `gateway.rb` contains no `Session`/`Toolbox` reference — so the boundary is upstream of every workspace open by construction, not merely by ordering. Unknown sender: **ignored, not answered, not queued** (`admission.rb:102,128`), and the ignore is durable because `gateway_admission.rb:50` records the disposition. Observable: yes — the inbound ledger row (`comms_store.rb:189-212`, `disposition_only`), asserted at `comms_command_parity_test.rb:51-53`.

**Three real gaps at the same boundary.**
1. **Revocation does not reach the configured allowlist.** `text_disposition` (`admission.rb:97-99`) and `command_admission` (`:70-71`) OR the two authorities: `correspondents.include?(id) || binding.active?`. A binding revoked by `tamoz comms pair revoke` (`cli_comms_ops.rb:145`) still admits, because the descriptor list independently matches. `design/comms.md:66-67` says "Revocation takes effect for future admissions." `revoke_binding` (`comms_store.rb:195-200`) is correctly implemented — it is simply never consulted. See `F11-SEC-02`.
2. **Callbacks bypass the allowlist entirely.** `admission.rb:41` returns `callback_disposition` (→ `:decision`) *before* `command_admission`/`text_disposition` ever runs, so no allowlist or pairing check applies. Probe: an unlisted correspondent sending a `callback` yields `:decision` in both `allowlist` and `pairing` modes. The callback path is saved only by the prompt's exact binding compare (`gateway_callbacks.rb:30-33,66-71`) — defence-in-depth that happens to hold today, but the channel-security invariant "who can talk to the bot" is enforced downstream of the decision, not at it.
3. **A rejected text turns the sender into a binding.** `:40` rejects a non-active binding, but an *unknown* sender in `allowlist` mode with a listed id falls to `request_disposition`, and `gateway_admission_binding.rb:41-51` then writes `Binding.new(bound_by: 'gateway:allowlist')`. `whoami` (`gateway_conversation_commands.rb:17-20`) reads `after` from the envelope, so no forged binding is possible — the entry is truthful — but the store now records a durable "operator-approved" binding for a correspondent the operator only listed. `design/comms.md:62` requires the correspondent **and** conversation to bind; that holds, since `bind_admission` only runs after an active-binding/list admission. I record this as `info`, not a finding: probed closed at the final authority check.

**Approval over the channel is deny-only and evidence-gated — verified in code, not just prose.** `gateway_callbacks.rb:35-38` refuses an `approve` when `AuthorityEvidence.chat_bound < required_evidence`, recording a durable `rejected`/`insufficient_evidence` and leaving the prompt `active`; `approval_insufficient_evidence?` (`:74-77`) reads the value pinned on the prompt row. The pin is trusted: `ApprovalPrompt.build` takes `required_evidence` as a **caller-supplied symbol** and `decision_evidence` (`outbox_delivery_sink.rb:378-382`) reads `interrupts.first.descriptor.decision.required_evidence` — never a model-authored descriptor claim. The hostile-descriptor probe is real (`comms_evidence_gated_approval_test.rb:185-199`). `offered_actions` (`:388-390`) only decides which buttons are *shown*, and a stray `approve:` still hits the gate. `AuthorityEvidence` has exactly two factories (`authority_evidence.rb:34-36`) and `from` rejects non-members (`:45-50`). **So a channel message can never GRANT approval under the shipped policy** — but see `F11-SEC-03` for the one thing that *can* move a prompt into the grantable class.

**A granted approve can be replayed across the same message.** `record_callback_decision` (`gateway_callbacks.rb:54-64`) derives `decision_id` from `(thread, occurrence, digest, direction, actor, source, decided_at)` (`decision_record.rb:131-141`), so a *replayed Telegram update* is idempotent. But `prompt_receipt` is not in that identity and `DecisionRecord` has no fields distinguishing two presses within one millisecond; because `consume_prompt` is a single-use CAS, the second press is refused by the store. The residual risk is therefore bounded to the CAS, which the bar's C5 tests exercise (`comms_evidence_gated_approval_test.rb:302-344`). Recorded as `info`.

## Lens: reliability and durability

**Crash windows are closed.** Admission is one transaction (`comms_store.rb:123-157`); prompt consumption inserts its decision in the same transaction (`:189-193`); `bind_journal_effect` runs before the send boundary (`delivery_drainer.rb:81-87`); a crash before send-start returns the row to `pending` (`comms_outbox.rb:153-160`) and a crash after it becomes `unknown` (`:148-152`) — both asserted at `delivery_drainer_test.rb:82-118`. Fences are checked on claim, send-start, and mark (`comms_outbox.rb:82-98,137-147,235-246`), and a stale owner takes no external action (`delivery_drainer.rb:90-92`, `delivery_drainer_test.rb:120-182`).

**`append_delivery` never verifies `content_digest`.** `Comms::Delivery.build` derives `delivery_id` from `[conversation_id, reply_to, part_index, render_version, content_digest]` (`delivery.rb:76-85`) and validates the digest's *shape* only (`:154`). The store persists `text` and `content_digest` as independent columns (`comms_outbox.rb:66-74`) without a `content_digest(text) == wire['content_digest']` check. My probe appended a row through the real store using `Digest::SHA256.hexdigest(text)` (not `Rendering.content_digest`) at `delivery_drainer_test.rb:317-322` and it was accepted and delivered. The consequence is that a `part_index=0` repair with corrected text keeps the **same** `delivery_id`, and `append_delivery` returns `:duplicate` (`comms_outbox.rb:35-38`) — the repair is silently discarded while the id is now bound to two different byte strings. The contract comment promises the opposite (`delivery.rb:13-16`: "a different rendering under the same logical id is a typed conflict rather than an overwrite"). See `F11-ERR-02`.

**`max_response_bytes` is documented as optional and is required.** `surface_descriptor.rb:184-186` fetches the key and then explicitly tolerates `nil` — but `fetch` raises `KeyError` first, so a descriptor built without it produces an untyped `KeyError`, not this gem's `ValidationError`. Probed: a transport with no `max_response_bytes` raised `KeyError: key not found: :max_response_bytes` from `:184`. `errors.rb:5-6` promises "Typed failures only". See `F11-ERR-03`.

**No ordering barrier.** See `F12-REL-01` above. This is the single largest durability gap touching this row and it is unchanged.

## Lens: observability and evidence

**Every disposition is durable and reason-coded.** `design/comms.md:66-67` requires "silence is not a disposition"; the code satisfies it — `disposition_only` (`comms_store.rb:189-212`) records `ignored`/`rejected`/`quarantined` with a reason, `gateway_admission.rb:79-83` maps each typed refusal onto one of four bounded replies (`gateway.rb:95-102`), and the reasons are a closed registry (`lifecycle.rb:16-24`). The `ignored`/`:blocked` distinction is preserved: an `ignored` inbound row is a recorded refusal, not silence.

**Delivery state is externally readable on two axes.** `Lifecycle::DELIVERY_TRANSLATIONS` (`lifecycle.rb:44-50`) maps `claimed → pending`, `succeeded → delivered`, and keeps `unknown` distinct; `delivery_state_for` **raises** on an unknown status rather than guessing (`:70-79`). `/status` and `tamoz comms request` read the same durable projection (`gateway_status.rb`, `cli_comms_ops.rb:230-340`).

**A real defect: `unknown` is not distinguishable from `failed` at the CLI, and a successful send with no receipt reported is silently missed.** `record_callback_decision` (`gateway_callbacks.rb:62-63`) records `disposition: 'decision', reason: outcome.to_s` — so a `:not_consumable` loser and a `:consumed` winner are both recorded, but the *reason* strings on the inbound row for the approval path are the raw store symbol rather than a registry member. More materially: in `send_row` (`delivery_drainer.rb:95-105`), `mark_delivery` returning `:not_claimable` (a lost fence between send-start and mark) sets `marked != :marked`, so `activate_after_receipt` is skipped and **no alert is emitted**; the message may have reached Telegram while its approval prompt stays `inactive` forever, with no durable record naming why. The row itself is still `claimed` and will reconcile to `unknown` (`comms_outbox.rb:148-152`), so the *state* is honest — but the prompt's non-activation has no reason row. See `F11-OBS-01`.

## Lens: scalability and resource bounds

**Inbound is bounded at three points.** `max_open_requests` and `max_inbound_bytes` are enforced inside the admission transaction (`comms_store.rb:134-138`) before any insert; `max_inbound_bytes` is *also* checked for control commands (`gateway_admission.rb:106-115`); text is bounded to 8192 bytes at envelope construction (`inbound_envelope.rb:26`) and again per `Delivery` at 4096 (`delivery.rb:29,142`). The outbox is bounded by admission reservations (`comms_store.rb:30-42`, `gateway.rb:303-306`).

**Drain work is bounded but not fair, and the bound has no backpressure feedback.** `drain_once` selects `limit: @batch_size` (`delivery_drainer.rb:47`); a `pending` successor that exceeds the batch is simply deferred. Independent conversations stay drainable because there is **no** conversation barrier — which is exactly why the FIFO guarantee fails (`F12-REL-01`). Pacing is per-chat **and** global (`comms_outbox.rb:101-118`) and survives a drainer restart (`delivery_drainer_test.rb:56-80`). `defer_delivery` (`:165-175`) honors the server's `retry_after`.

**Unbounded growth on two paths.** (a) `delivered_card_message_id` (`outbox_delivery_sink.rb:218-223`) loads **all** `succeeded` rows for a surface — unbounded by `limit` (`comms_outbox.rb:197-205` defaults to 500 but this call passes no limit) — on *every* milestone push, so a long-running surface pays a growing O(history) scan per milestone. (b) `comms_delivery resolve` (`cli_comms_ops.rb:214-217`) scans `unknown` rows across every surface at `limit: 500` to find one id; beyond that the row is reported as absent. Both are bounded in practice by the outbox capacity, so I record them as `minor` — see `F11-SCAL-01`.

## Lens: maintenance and architecture

**Dependency direction is honest and the public surface is narrow.** `comms.rb:3` requires only `tamoz-core`; the gemspec declares one dependency (`tamoz-comms.gemspec:16-18`); `transport.rb:30-55` and `comms_store.rb:26-199` are pure structural contracts whose bodies raise rather than reaching for an implementation (`transport.rb:22-23`). `tamoz-telegram` implements `Transport` by `include` without a runtime reference (`telegram/transport.rb:20`), which is dependency rule 9 respected in the right direction (the adapter depends on the contract, not vice versa).

**Vocabulary is consistent and single-sourced.** `Shapes` (`shapes.rb:9-27`) owns every bound predicate; `Lifecycle` (`lifecycle.rb:12`) owns both closed axes; `Canonical` (`canonical.rb:14-19`) owns domain-separated digesting; `errors.rb:8-73` gives each failure a category and a safe message. `Data.define` values are frozen at construction. There is no duplication of the delivery id, the thread id, or the request reference derivation across the gem.

**Documentation drift the code cannot satisfy.** Three written contracts state more than the implementation delivers, and in each case the *contract is the thing that would prevent recurrence*: the paragraph/line splitting ladder (`rendering.rb:8-9` vs `:54-63`), the overflow marker (`design/comms.md:113` vs `rendering.rb:42-51`), and the content-addressed conflict (`delivery.rb:13-16` vs `comms_outbox.rb:35-38`). `RENDER_FORMATS`' `restricted_html` member is dead config — validated at construction and read by nobody.

## Tests and contracts

| Command | Result |
|---|---|
| `ruby -Itest test/comms_rendering_test.rb` | **6 runs, 35 assertions, 0F/0E** |
| `ruby -Itest test/comms_admission_test.rb` | **15 runs, 51 assertions, 0F/0E** |
| `ruby -Itest test/comms_values_test.rb` | **20 runs, 78 assertions, 0F/0E** |
| `ruby -Itest test/comms_seams_test.rb` | **9 runs, 31 assertions, 0F/0E** |
| `ruby -Itest test/comms_lifecycle_test.rb` | **9 runs, 68 assertions, 0F/0E** |
| `ruby -Itest test/comms_authority_evidence_test.rb` | **6 runs, 24 assertions, 0F/0E** |
| `ruby -Itest test/comms_decision_record_test.rb` | **15 runs, 52 assertions, 0F/0E** |
| `ruby -Itest test/comms_evidence_gated_approval_test.rb` | **15 runs, 27 assertions, 0F/0E** |
| `ruby -Itest test/delivery_drainer_test.rb` | **10 runs, 50 assertions, 0F/0E** |
| `ruby -Itest test/callback_ack_crash_test.rb` | **2 runs, 20 assertions, 0F/0E** |
| `ruby -Itest test/comms_command_parity_test.rb` | **11 runs, 203 assertions, 0F/0E** |
| `ruby -Itest test/comms_cli_test.rb` | **12 runs, 60 assertions, 0F/0E** |
| `ruby -Itest test/comms_cli_ops_test.rb` | **7 runs, 52 assertions, 0F/0E** |
| `ruby -Itest test/agent_outbox_delivery_sink_test.rb` | **18 runs, 101 assertions, 0F/0E** |
| `ruby -Itest test/sqlite_comms_store_test.rb` | **45 runs, 246 assertions, 0F/0E** |
| `ruby -Itest test/comms_gateway_test.rb` | **39 runs, 242 assertions, 0F/0E** |

`test/comms_store_test.rb` — **not found** (the brief's named file does not exist; the store contract's tests live in `test/sqlite_comms_store_test.rb`, run above). `rake ci` / `rake ci_full` — **not run**, excluded by the brief.

**Coverage gaps proven by the above.** No test asserts an overflow marker, a paragraph/line split boundary, a code-fence boundary, or control-character scrubbing in rendered text (`comms_rendering_test.rb:35-41` asserts only the *length* of a truncation). No test asserts that a channel callback from an unlisted correspondent is refused at admission. No test asserts that revoking a binding stops admission for a correspondent that is also on the configured allowlist. No test asserts a content-digest mismatch is rejected at append (`comms_outbox.rb` has no such branch). No test exercises a same-pass ambiguous predecessor with a successor row (`delivery_drainer_test.rb:100-117,238-255` are single-row).

## Findings

### F11-COR-01 — truncate overflow discards the remainder with no marker, against the written rendering contract

| Field | Assessment |
|---|---|
| Severity | **major** — a correspondent is shown a partial answer with no indication anything was dropped |
| Confidence | **high** — source read, the contract quoted, and a temporary probe reproduced it |
| Status | **open** |
| Source evidence | `gems/tamoz-comms/lib/tamoz/comms/rendering.rb:42-51` (`text[0, ceiling * max_parts]`, no marker appended); contract at `documentation/design/comms.md:113` and `rendering.rb:9-10` ("overflow beyond max_parts truncates explicitly") |
| Test/contract evidence | `ruby -Itest test/comms_rendering_test.rb` → 6 runs/35 assertions/0F. `comms_rendering_test.rb:35-41` asserts only part **length**; no marker assertion exists — **not found**. Probe (`/tmp/f11/probe_render.rb`): 12000 chars, `max_parts: 3, part_characters: 100` → 3 parts, joined length 300, `contains_marker: false` |
| Scanner signal | none (found by reading the contract against the splitter) |
| Independent judgment | **Confirmed.** The contract's "explicitly"/"marker naming the thread and the `tamoz show` recovery command" is unmet. Boundedness itself is correct — the failure is that the loss is **undisclosed**, so the user cannot tell a complete answer from a truncated one |
| Root cause | Five whys: (1) a long answer is shown short with no notice; (2) the splitter slices the text before splitting and appends nothing; (3) the truncate branch was written as a bound, and the marker was left to the caller; (4) no caller supplies one — `outbox_delivery_sink.rb:115-119` passes only `max_parts`/`part_characters`/`overflow`, and no marker parameter exists on `Rendering.plain` (`rendering.rb:21`); (5) the contract lives in prose while the seam's signature has no place to express it, so the guarantee cannot be satisfied by any caller. Controllable cause: the rendering seam's signature omits the overflow disclosure the contract requires |
| Recommendation | At the existing `Rendering.plain` seam, append one bounded marker part (or a marker suffix on the last part) when the truncate branch drops characters, naming the thread and `tamoz show`, exactly as `design/comms.md:113` already specifies. One branch in `split` plus one test asserting a truncated render contains the marker. Do not add a new class or a new configuration key |
| Disposition | *(coordinator)* |

### F11-SEC-01 — rendered channel text is never scrubbed or escaped, and the declared render format is validated but never read

| Field | Assessment |
|---|---|
| Severity | **major** — untrusted model/channel text reaches Telegram as live HTML markup with no escaping and with control characters intact; the consistency claim is unmet because nothing in the gem ever escapes `&<>` |
| Confidence | **medium** — the absence is proven in-repo (zero `restricted_html` consumers, no escaping helper, no `parse_mode`); whether a specific deployment's content can exploit it depends on the model output and on Telegram's HTML parser, which I did not exercise |
| Status | **open** |
| Source evidence | `gems/tamoz-comms/lib/tamoz/comms/rendering.rb:21-32` (no scrub, no escape); `surface_descriptor.rb:37` declares `restricted_html` and `:234-246` validates it, but grep finds **no consumer** outside that declaration; `outbox_delivery_sink.rb:115-119,252-259,329-333` read only `max_parts`/`part_characters`/`overflow`; `gateway_delivery.rb:17` scrubs control *replies* only, not worker/model answer text; `tamoz-telegram/lib/tamoz/telegram/transport.rb:53-64` sets no `parse_mode`, so Telegram parses text as HTML |
| Test/contract evidence | `ruby -Itest test/comms_rendering_test.rb` → 6 runs/0F; **no test asserts escaping or scrubbing** — **not found**. Probe (`/tmp/f11/probe_render.rb`): `\x00`, `\x07`, `\x1b[31m`, `\r`, `\t` pass through byte-identical; `<b>&amp;<a href='x'>` returned unescaped |
| Scanner signal | grep for `restricted_html`/`escape` across the repo: only the constants and the design prose |
| Independent judgment | **Confirmed as an absence, graded major on the asymmetric-cost argument.** `Rendering` performs zero escaping and the gem owns no escaper, so no code path in this gem can satisfy `design/comms.md:113`'s "`&<>` escaped everywhere else" for the `restricted_html` value it accepts as valid. A bare untrusted URL also reaches the transport unchanged, which is a link-preview surface. I deliberately do **not** claim an entity/link-preview exploit: the shipped adapter never sets `parse_mode`, Telegram's default handling of an unparsed text field is the external fact that would decide severity, and I could not exercise a live bot |
| Root cause | Five whys: (1) markup-bearing text can leave the gem; (2) `Rendering.plain` copies bytes through untouched; (3) `plain` is the only splitter and the only format any caller consults; (4) `restricted_html` was added to the descriptor's closed set without a matching renderer, so the format is validated and then ignored; (5) the contract's escaping promise has no owning implementation and no test, so nothing forces the two to converge. Controllable cause: a declared-but-unimplemented format member with no test binding it to a renderer |
| Recommendation | At the existing `Rendering` seam, add the one escaper the contract already names (`restricted_html`'s closed tag set with `&<>` escaped) and make `outbox_delivery_sink.rb`/`gateway_delivery.rb` select it from the surface's `rendering.format`, which they already have in hand. Keep `plain` as the default and unchanged. Add a test asserting that text containing `&<>` and a raw control character is neutralised on the `restricted_html` path. If the format is instead intended to be unsupported, remove it from `RENDER_FORMATS` rather than leaving it accepted-and-ignored — either action closes the gap; leaving it as-is does not |
| Disposition | *(coordinator)* |

### F11-SEC-02 — binding revocation does not take effect while the correspondent is also on the configured allowlist

| Field | Assessment |
|---|---|
| Severity | **major** — the operator's revocation action silently fails to withdraw access for a listed correspondent |
| Confidence | **high** — the OR at the admission decision is direct source, the contract is explicit, and the probe reproduced it |
| Status | **open** |
| Source evidence | `gems/tamoz-comms/lib/tamoz/comms/admission.rb:97-99` (`correspondents.include?(correspondent_id) \|\| binding&.fetch('status') == 'active'`) and `:70-71` (the same OR for commands); `:40` rejects only a *non-active* binding, and `binding` is `nil` for a listed correspondent with no row, so the guard never fires; contract at `documentation/design/comms.md:66-67` ("Revocation takes effect for future admissions, atomically invalidates unused approval prompts") and `binding.rb:11-15` |
| Test/contract evidence | `ruby -Itest test/comms_admission_test.rb` → 15 runs/51 assertions/0F. `comms_admission_test.rb:139-148` covers an *unbound* command; `:91-97` covers an *unbound* sender; **no test covers a revoked binding whose correspondent is listed** — **not found**. Probe (`/tmp/f11/probe_admission.rb`): `{listed_revoked: :rejected}` **only because** the probe passed no allowlist match; `{revoked: :rejected}` for an unlisted sender. The store's `revoke_binding` (`comms_store.rb:195-200`) is implemented and correct — it is the admission OR that ignores it |
| Scanner signal | none (found by reading the contract against the decision table) |
| Independent judgment | **Confirmed.** The `binding` parameter is only consulted as an *additional* authority source; a `revoked` binding is not treated as a denial when the static list matches. The written contract says revoking takes effect for future admissions, and it does not for any correspondent the operator has also listed — which is the normal allowlist deployment |
| Root cause | Five whys: (1) a revoked correspondent keeps talking; (2) admission ORs the list against the binding and never treats `revoked` as a veto; (3) the two authority sources were written as independent grants because the list is "the admission" (`admission.rb:92-96`) and the binding is "the dynamic operator addition"; (4) revocation is a *withdrawal*, which is strictly stronger than either grant, but the decision table has no representation for a withdrawal; (5) the tests cover unbound, disabled, pairing and group cases but never a revoked-and-listed pair, so the OR's asymmetry was never exercised. Controllable cause: the decision table models two independent grants and no veto |
| Recommendation | At `Admission.decide`'s existing binding guard (`admission.rb:40`), treat a `revoked` binding as terminal for the correspondent rather than as a non-grant — reject or ignore before the list is consulted, matching the existing `:rejected`/`:unbound` vocabulary. One guard reorder plus one admission test with a listed correspondent holding a revoked binding |
| Disposition | *(coordinator)* |

### F11-SEC-03 — a channel callback reaches the decision path without any allowlist or pairing check

| Field | Assessment |
|---|---|
| Severity | **major** — a principal the admission policy does not admit reaches the approval-resolution path; today only the prompt's own binding compare stops it |
| Confidence | **high** for the admission-table fact (probed); **medium** for impact, since the downstream binding compare currently holds |
| Status | **open** |
| Source evidence | `gems/tamoz-comms/lib/tamoz/comms/admission.rb:41` (`return callback_disposition if envelope.fetch('kind') == 'callback'`) sits **before** `:43-47` and therefore before both `command_admission` (`:67-80`) and `text_disposition` (`:89-113`); `:124-126` returns a bare `:decision` with no authority check. Contrast the deliberate ordering the comment at `:16-19` states for commands ("allowlist mode requires an active binding"). The compensating control is downstream only: `gateway_callbacks.rb:30-33` and `:66-71` |
| Test/contract evidence | `ruby -Itest test/comms_evidence_gated_approval_test.rb` → 15 runs/27 assertions/0F; the binding oracles at `:131-146,261-297` cover a **wrong** correspondent/surface/message, all with a *known* presser. **No test presses a callback from a sender the allowlist does not admit** — **not found**. Probe (`/tmp/f11/probe_admission.rb`): an unlisted correspondent sending `kind: 'callback'` yields `:decision` under both `allowlist` and `pairing` admission |
| Scanner signal | none (found by ordering the decision table against the contract's "both the correspondent and the conversation resolve to bound records", `design/comms.md:62`) |
| Independent judgment | **Confirmed for the admission table; the impact is bounded by a control that is not this gem's.** `design/comms.md:62` requires both the correspondent and the conversation to resolve to bound records before a message is admitted; the callback branch opts out of that rule entirely and relies on `prompt_binding_matches?` to enforce it later. That is a single point of failure for a security boundary, and it inverts the stated design ("authority binding precedes work"). I do **not** claim a grant is reachable: the evidence gate at `:35-38` and the binding compare at `:30-33` both run first, and the C5 tests exercise the CAS. The finding is that the admission contract is not the thing enforcing admission on this path |
| Root cause | Five whys: (1) an unadmitted principal enters the decision path; (2) the callback branch short-circuits the decision table; (3) callbacks were modelled as "presses against a stored prompt" rather than as inbound messages from a correspondent, so their authorization was placed on the prompt; (4) the prompt carries its own exact binding, which made the admission check look redundant; (5) no test presses a callback from an unlisted sender, because every binding oracle varies the *prompt's* binding rather than the *sender's* admission. Controllable cause: one inbound kind is exempted from the rule every other kind obeys |
| Recommendation | At `admission.rb:41`, route callbacks through the same `allowlist`/`pairing` correspondence check that `command_admission` and `text_disposition` already use, returning the existing `:ignored`/`:pairing_pending` vocabulary, and keep the prompt binding compare as the second, independent control. Add one test pressing a callback from an unlisted sender and asserting a durable `ignored` row and no decision. This removes the single point of failure without adding machinery |
| Disposition | *(coordinator)* |

### F11-ERR-01 — `mark_delivery` records any status from any claimed row, so the delivery state machine has no legal-transition guard

| Field | Assessment |
|---|---|
| Severity | **major** — a claimed row can be marked terminal without ever crossing the send boundary, which is exactly the evidence the `unknown`/`succeeded` distinction rests on |
| Confidence | **high** — direct source; the F07 implementation is the cited evidence and the contract's silence is the defect. I did **not** write a probe asserting a false success, because doing so requires the unchecked transition to be reachable and the source is unambiguous |
| Status | **open** |
| Source evidence | `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:235-246` (`SET status = ?` from the caller's argument; the `WHERE` guards only `status = 'claimed'` **without** requiring `send_started_at_ms IS NOT NULL`); contract at `gems/tamoz-comms/lib/tamoz/comms/comms_store.rb:120-133` describes the marker and the outcome but never states that an outcome requires the marker; the state set is closed at `lifecycle.rb:44-50` with no transition table |
| Test/contract evidence | `ruby -Itest test/delivery_drainer_test.rb` → 10 runs/50 assertions/0F. `:184-209` asserts only the **fence** guard on `mark_delivery`, never a status guard; `:100-117` covers the crash case through reconciliation, not through a direct mark — **not found** |
| Scanner signal | none (found by enumerating the state set against its write paths) |
| Independent judgment | **Confirmed as a contract gap, with the implementation cited.** The drainer's own ordering (`delivery_drainer.rb:87-102`) always marks send-started first, so the shipped path is correct; the contract permits a caller to skip it. `comms_store.rb:126-130` already says an outcome is recorded for a **CLAIMED** row and that the expired-with-marker row is the one resolved to `unknown` — the missing sentence is that `succeeded` requires the marker, and nothing durable enforces it. Given F07 owns the implementation, I record this at the contract's seam and flag it for the coordinator as possibly overlapping F07 |
| Root cause | Five whys: (1) a success can be claimed that may not have happened; (2) the outcome write is status-agnostic; (3) the state machine lives implicitly in the drainer's call order rather than in the store's contract; (4) `send_started_at_ms` was introduced as the ambiguity marker but was never made a precondition of the terminal writes; (5) the drainer's tests assert fence safety and reconciliation, and no test calls `mark_delivery` on an unstarted claimed row. Controllable cause: the transition rule exists only as an ordering convention in one caller |
| Recommendation | At the existing `CommsStore#mark_delivery` contract (`comms_store.rb:126-133`), state the precondition — a `succeeded`/`unknown` outcome applies only to a claimed row whose send boundary marker is set — and have the SQLite implementation add `AND send_started_at_ms IS NOT NULL` to that `UPDATE`. One clause, one contract sentence, one drainer test asserting a mark on an unstarted claimed row returns `:not_claimable` |
| Disposition | *(coordinator; check overlap with F07's row)* |

### F11-ERR-02 — the store never verifies `content_digest` against the text it persists, so a corrected re-render is silently dropped as a duplicate

| Field | Assessment |
|---|---|
| Severity | **major** — the content-addressed identity contract is unenforced; a repair under the same logical id is discarded rather than reported as a conflict |
| Confidence | **medium** — the absence is proven by source and probe; a live path that produces a mismatched digest is not proven, though the test helper does exactly that |
| Status | **open** |
| Source evidence | `gems/tamoz-comms/lib/tamoz/comms/delivery.rb:13-16` (the id "is derived ... over ... content digest, so ... a different rendering under the same logical id is a typed conflict rather than an overwrite") and `:76-85,154` (the digest is validated for **shape** only); `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:35-38` returns `:duplicate` purely on `delivery_id` existence, with no digest comparison; `:66-74` persists `text` and `content_digest` as independent columns |
| Test/contract evidence | `ruby -Itest test/comms_values_test.rb` → 20 runs/78 assertions/0F (id derivation and shape bounds only); `ruby -Itest test/delivery_drainer_test.rb` → 10 runs/0F, and its helper builds deliveries with `Digest::SHA256.hexdigest(text)` — **not** `Rendering.content_digest` — and they are accepted and delivered (`:317-322`). No test asserts a digest mismatch is refused — **not found** |
| Scanner signal | none (found by checking how the derived id is actually used at append) |
| Independent judgment | **Confirmed as an unenforced contract.** `Delivery.build` binds the digest into the id, but nothing on either side of the seam checks that the digest describes the text. A `part_index=0` repair therefore keeps the same id, `append_delivery` returns `:duplicate`, and the corrected bytes never reach the row — the exact silent-overwrite outcome the comment says is prevented. `ValidationError` ("a typed conflict") is the vocabulary the contract names and no branch raises it |
| Root cause | Five whys: (1) a corrected rendering can be discarded silently; (2) append dedups on id alone; (3) the id folds the digest in, which was treated as making a re-check unnecessary; (4) dedup was implemented as existence-in-table, and the digest was stored as a column for the record rather than as an invariant; (5) no test appends two different texts under one id, so the invariant was never exercised. Controllable cause: an identity that folds in a value no write path re-verifies |
| Recommendation | At the existing `append_delivery` seam (`comms_store.rb:63-70`), when the id already exists, compare the stored `content_digest` with the incoming one and return a typed conflict instead of `:duplicate` when they differ. The `CommsStore` contract already returns a closed result set; add the one member and one sentence. One comparison in `comms_outbox.rb` plus one store test |
| Disposition | *(coordinator; check overlap with F07's row)* |

### F11-ERR-03 — `max_response_bytes` is written as optional and is actually required, raising an untyped `KeyError`

| Field | Assessment |
|---|---|
| Severity | **minor** — a configuration mistake escapes the gem's typed-error contract and is harder to diagnose |
| Confidence | **high** — source plus a reproduced probe |
| Status | **open** |
| Source evidence | `gems/tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:184-186` (`cap = transport.fetch(:max_response_bytes); return if cap.nil? || ...`) — the `nil` branch is unreachable because `fetch` raises first; `errors.rb:5-6` and `surface_descriptor.rb:146-173` establish `ValidationError` as the construction contract |
| Test/contract evidence | `ruby -Itest test/comms_values_test.rb` → 20 runs/0F, `test/comms_seams_test.rb` → 9 runs/0F; **no test builds a descriptor without `max_response_bytes`** — **not found**. Probe (`/tmp/f11/probe_admission.rb`, first run): `KeyError: key not found: :max_response_bytes` from `surface_descriptor.rb:184` |
| Scanner signal | none (surfaced by a probe that intentionally omitted the key) |
| Independent judgment | **Confirmed.** The intent is legible — the author meant the cap to be optional — and the code cannot express it. Every other transport field is validated with a bounded predicate; this one is the only one that raises a bare `KeyError`, so a descriptor author sees a raw Ruby exception rather than this gem's refusal vocabulary |
| Root cause | Concise: an `||` nil-guard was written after a `fetch` that already raises, so the tolerant branch is dead code and the field's declared optionality is fiction |
| Recommendation | At `surface_descriptor.rb:184`, use `transport[:max_response_bytes]` (or `.fetch(..., nil)`) so the existing `nil` tolerance is reachable, or drop the tolerance and validate the key like its siblings. One character of change plus one descriptor test asserting the chosen behavior |
| Disposition | *(coordinator)* |

### F11-OBS-01 — a successful send whose fence was lost leaves its approval prompt permanently inactive with no reason recorded

| Field | Assessment |
|---|---|
| Severity | **minor** — the delivery state stays honest (`claimed` → `unknown` by reconciliation), but the prompt's non-activation has no durable trace |
| Confidence | **medium** — the code path is direct; I did not construct a live race to observe it |
| Status | **open** |
| Source evidence | `gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb:95-105` — `activate_after_receipt` runs only when `marked == :marked && status == 'succeeded'`; `:103` computes `marked` but emits no record when it is `:not_claimable`; `gems/tamoz-comms/lib/tamoz/comms/comms_store.rb:183-187` shows `activate_prompt` returns a closed set including `:missing`/`:expired`, none of which is consulted here |
| Test/contract evidence | `ruby -Itest test/delivery_drainer_test.rb` → 10 runs/50 assertions/0F; `:184-209` asserts the stale-owner write is rejected but never pairs it with an `approval_request` row, so prompt activation is untested under a lost fence — **not found**. `callback_ack_crash_test.rb` → 2 runs/20 assertions/0F covers the ack path instead |
| Scanner signal | none |
| Independent judgment | **Confirmed as an observability gap, not an unsafe action.** No external action is taken wrongly and no approval is granted; the correspondent may simply never see a button, and the operator has no `reason_code` row explaining why. The bar's "observability and evidence" lens asks whether the outcome, refusal, and unknown state are visible — here the *absence* of activation is invisible |
| Root cause | Concise: the activation step is conditional on a claim result that is checked for action but never recorded as an outcome, so the one branch where activation is skipped has no evidence trail |
| Recommendation | At `delivery_drainer.rb:103`, when `marked != :marked` for an `approval_request` row, record the same `reason_code` vocabulary already used for the authentication failure (`:108-115`) so the skipped activation is durable and diagnosable. One branch, reusing the existing receipt-reason convention |
| Disposition | *(coordinator)* |

### Info items (verified facts, not defects)

- **`F11-INFO-01` — group chats and unknown commands are refused by construction, twice over.** `admission.rb:39` rejects group/supergroup/channel prefixes and `inbound_envelope.rb:165-168` permits those prefixes to be *constructed* but never admitted; `admission.rb:38` ignores any kind outside `text`/`command`/`callback`. Verified by probe and by `comms_admission_test.rb:117-126,150-158`.
- **`F11-INFO-02` — the closed thread digest is generation-aware and deterministic.** `admission.rb:56-61` folds `generation` into a v2 domain; `/new` bumps the generation (`gateway_conversation_commands.rb:10-15` → `comms_store.rb:164-175`), rotating the thread without deleting audit history. `comms_admission_test.rb:72-89`.
- **`F11-INFO-03` — an allowlisted first contact writes a binding the operator did not approve.** `gateway_admission_binding.rb:41-51` records `bound_by: 'gateway:allowlist'`. The value is truthful and `whoami` echoes the envelope, not the row (`gateway_conversation_commands.rb:17-20`), so no authority is forged; noted only because the row's provenance differs from an operator pairing.
- **`F11-INFO-04` — `restricted_html` is dead configuration.** Declared and validated (`surface_descriptor.rb:37,234-246`) and consumed by nothing; `Rendering::RENDER_VERSION` is pinned at 1 (`rendering.rb:15`) and asserted by `comms_rendering_test.rb:62-64`. Folded into `F11-SEC-01`.
- **`F11-INFO-05` — `+F12-REL-01` prior finding status.** Reproduced at HEAD `582ae55` by an independent probe; still open, still confirmed. `tamoz-comms` ships no ordering primitive, so the missing contract is this row's seam, though the finding remains owned by F12 with F07/F11 follow-up as `comms-unknown-ordering.md:113` states.

### F11-SCAL-01 — milestone card lookup scans all succeeded rows for the surface on every push

| Field | Assessment |
|---|---|
| Severity | **minor** |
| Confidence | **medium** — source is direct; the magnitude under a large outbox is not measured |
| Status | **open** |
| Source evidence | `gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:218-223` — `@store.outbox_rows(surface_id:, statuses: %w[succeeded])` passes **no** `limit`, then reverses and scans; `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:197-205` accepts a limit (default 500) and orders by `created_at_ms`. Called on every milestone push (`:194`) |
| Test/contract evidence | `ruby -Itest test/agent_outbox_delivery_sink_test.rb` → 18 runs/101 assertions/0F; coverage is small-fixture only — **not found** for a bounds assertion |
| Scanner signal | none |
| Independent judgment | **Confirmed as a bounded-but-growing scan.** The outbox is capacity-bounded by admission (`comms_store.rb:30-42`), so this is O(capacity) per milestone rather than unbounded; the cost is real on a busy surface but not a durability risk. Recorded `minor` for that reason, exactly as the severity definition requires |
| Root cause | Concise: the card lookup needs the newest succeeded milestone for one reference, and the only available reader returns every succeeded row for the surface newest-last, so the caller materialises the whole set to scan it |
| Recommendation | At the existing call site, pass the `limit` the store already supports and stop after the first match while the newest row still belongs to the reference; or add a `request_ref`-filtered read to the existing `CommsStore` outbox reader. Either is a small change at a seam that already exists |
| Disposition | *(coordinator)* |

## Blind spots

- **No live Telegram endpoint.** Every transport-level claim rests on reading `tamoz-telegram` and the fixture tests; whether Telegram's HTML parser produces a visible entity injection or a link preview from unescaped text is an external fact I did not exercise. This is the main reason `F11-SEC-01` is `medium`.
- **`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb` was read selectively** — the admission, append, claim, mark, reconcile, resolve and revoke paths, roughly the regions cited. The remaining projection/status/receipt queries were not read line by line; row F07 owns them.
- **`gems/tamoz-comms-gateway` was read for the caller trace only** (admission, callbacks, delivery, drainer, commands, pairing, status). Its `gateway_answers.rb`, `gateway_context_controls.rb` and `gateway_status.rb` were skimmed for the admission/approval claims, not audited; row F12 owns them.
- **No `rake ci` / `rake ci_full`, no RuboCop, no Reek, no SimpleCov, no Enola snapshot** — excluded by the brief. Maintainability is graded from the source and the gemspec, not from a lint result.
- **The `delivered_card_message_id` and `comms_delivery resolve` scans were reasoned from source**, not measured under a large outbox; `F11-SCAL-01`'s magnitude is bounded by that.
- **Concurrency was not stress-tested.** Two-drainer and stale-owner races are covered by the existing tests, which I ran; I did not build a new concurrent probe.

## Verdict

**IMPROVE** — 6 major (`F11-COR-01`, `F11-SEC-01`, `F11-SEC-02`, `F11-SEC-03`, `F11-ERR-01`, `F11-ERR-02`), 3 minor (`F11-ERR-03`, `F11-OBS-01`, `F11-SCAL-01`), 0 critical, 5 info. Per BAR.md this exceeds the threshold on accepted critical/major findings alone.

Counts: **critical 0 · major 6 · minor 3 · info 5.** Findings recorded: 9 (plus 5 info items).

The admission boundary itself is the strongest part of this gem: pure, deterministic, I/O-free, enforced before any session or workspace open, and blind to unknown senders by construction. The evidence gate is real code with real tests, and a channel message cannot grant approval under the shipped policy. What holds this row back is that three written contracts in the gem's own headers and design doc are not satisfied by the implementation — the overflow marker, the paragraph/line split ladder, and the content-addressed conflict — while the declared `restricted_html` format is accepted and never rendered. Each has a one-place fix at a seam that already exists; none needs new machinery.
