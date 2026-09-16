# CF08 — channel admission, rendering, outbox delivery, and approval relay — IMPROVE

## Row, boundary, and method

- **Row:** CF08 — channel admission, rendering, outbox delivery, and approval relay.
- **Queue:** cross-gem flow inventory in `COVERAGE.md`.
- **Code baseline:** branch `audit-15-09`, commit `582ae55` (2026-09-15).
- **Analyst:** coordinator direct source review after the cross-flow scanner and
  the Telegram/comms challenges. No subagent was used for this continuation.
- **Scope:** Telegram normalization and transport, Comms admission and rendering,
  gateway polling, SQLite admission/outbox state, delivery draining, and the
  approval callback relay.
- **Method:** end-to-end source trace, challenge re-read, focused contracts and
  gateway tests. No implementation or production/test/configuration edits.

## Source map and ownership

| Source | Lines | Boundary role |
|---|---:|---|
| `gems/tamoz-telegram/lib/tamoz/telegram/normalizer.rb` | 17-156 | raw Telegram update → closed `InboundEnvelope` wire |
| `gems/tamoz-telegram/lib/tamoz/telegram/transport.rb` | 19-106 | poll, deliver, callback signal, and Telegram request mapping |
| `gems/tamoz-telegram/lib/tamoz/telegram/client.rb` | 21-137 | bounded HTTP, response classification, timeout and throttle taxonomy |
| `gems/tamoz-comms/lib/tamoz/comms/admission.rb` | 8-136 | pure surface, binding, conversation, and command admission |
| `gems/tamoz-comms/lib/tamoz/comms/rendering.rb` | 7-75 | grapheme-safe split and render limits |
| `gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb` | 84-148, 237-398 | worker event → durable delivery/prompt rows |
| `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb` | 146-275 | poller lease, poll/admit/offset order, loop and supervision boundary |
| `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb` | 10-115 | typed inbound routing and durable disposition |
| `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_callbacks.rb` | 10-87 | binding/evidence checks and single-use approval decision |
| `gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb` | 12-151 | fenced claim, pacing, send boundary, receipt and ambiguity handling |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb` | 123-157, 311-402, 922-990 | atomic admission, request projection, outbox/prompt delegates |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb` | 30-175, 197-260 | capacity, claims, pacing, send fence, unknown resolution |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb` | 1219-1248, 739-771 | durable inbound/outbox/prompt schema |
| `gems/tamoz-agent/lib/tamoz/agent/worker.rb` | 754-777 | paused approval/clarification events from the worker |
| `test/comms_gateway_test.rb`, `test/delivery_drainer_test.rb` | current files | gateway, approval, fencing, pacing, and ambiguity contracts |
| `test/tamoz_telegram_transport_test.rb`, `test/telegram_normalizer_test.rb` | current files | Telegram adapter and normalizer contracts |

The ownership boundary is explicit. Telegram owns untrusted update parsing and
HTTP classification. Comms owns the admission/rendering contracts and does not
open sessions or make network calls. The gateway owns the long-running poller
and admission order. SQLite owns durable request, outbox, prompt, and lease
state. The drainer owns the external send boundary. Worker output and approval
events enter the same outbox rather than a second direct transport path.

## End-to-end behavior path

1. `Transport#poll` calls `getUpdates` with the durable candidate offset and
   allowed update kinds, then maps each result through `Normalizer#normalize`
   and computes the next offset from the returned update ids
   (`telegram/transport.rb:37-46`). The normalizer maps message, callback, and
   membership shapes into bounded envelopes and collapses unknown update kinds
   to `unsupported` (`normalizer.rb:34-49,94-113`).
2. `Gateway#serve_once` renews the fenced poller lease, reads the stored offset,
   polls, admits every returned envelope, persists the next offset only after
   admission, and then drains the outbox (`gateway.rb:189-201`). A transient
   read leaves the offset unchanged; a poller conflict escapes as the named
   `:poller_conflict` result (`:202-220`).
3. `Gateway::Admission` invokes pure `Comms::Admission.decide` with the latest
   binding and conversation. Requests are bound and admitted through one SQLite
   transaction; controls and refusals write durable dispositions; callbacks
   resolve a prompt and then best-effort acknowledge Telegram
   (`gateway_admission.rb:17-53,55-103`; `gateway_callbacks.rb:10-17`). Replayed
   updates return `:duplicate` without rendering another control row.
4. SQLite checks open-request, inbound-byte, and outbox-capacity limits before
   inserting the inbound anchor, admitted request, and checkpoint inbox row
   (`sqlite/comms_store.rb:123-157`). The worker's `OutboxDeliverySink` renders
   lifecycle events into one or more `Delivery` rows, keeps terminal output
   journaled, and reserves the request's terminal slot (`outbox_delivery_sink.rb:94-148`).
   Approval prompts are stored inactive; their markup carries a reference and
   actions, and the prompt becomes active only after the drainer has a durable
   send receipt (`:287-325`; `sqlite/comms_store.rb:924-965`).
5. `DeliveryDrainer#drain_once` reconciles expired claims, selects a bounded
   pending batch, claims each row, reserves durable pacing slots, binds its
   journal effect, marks the send boundary, calls Telegram, and marks a receipt
   or `unknown` (`delivery_drainer.rb:45-57,61-151`; `sqlite/comms_outbox.rb:82-175,230-260`).
   A pre-send throttle releases to `pending`; an ambiguous send is never retried
   automatically.
6. A callback update carries `approve:<reference>` or `deny:<reference>`.
   `resolve_callback` requires an active prompt, exact surface/correspondent/
   conversation/message binding, and sufficient pinned evidence for approval;
   `consume_prompt` changes the prompt and inserts the decision atomically
   (`gateway_callbacks.rb:19-64`; `sqlite/comms_store.rb:969-990`). The callback
   acknowledgement is ephemeral and cannot grant authority by itself.

## Correctness

Reviewed. Admission dispositions are closed and deterministic; unknown senders,
group chats, unsupported update kinds, and malformed command intents do not enter
the request path. Request identity is digest-bound and duplicate-safe. The
gateway persists the Telegram offset only after durable admission, preserving
replay on a failure. Outbox delivery distinguishes pending, claimed, succeeded,
failed, and unknown, and the drainer never reports an ambiguous send as success.

The independent challenge closes the apparent revocation/allowlist defect:
`Admission.decide` rejects a non-active binding before the allowlist branch
(`comms/admission.rb:36-46`), so `F11-SEC-02` is closed. It also demotes the
callback admission lead (`F11-SEC-03`) to a minor defence-in-depth/test gap:
unknown references and exact prompt binding prevent an unlisted callback from
consuming a prompt. `F11-ERR-01` and `F11-ERR-02` are minor store-contract
findings owned by F07, because Comms ships only structural store methods.

Three correctness findings remain material at this flow's boundaries. `F11-COR-01`
is an undisclosed rendering overflow: truncation keeps only the first
`max_parts * part_characters` and emits no recovery marker. `F12-REL-01` is the
open major ordering violation: after one same-conversation multipart row becomes
unknown, the drainer continues through its preselected pending batch and can send
the successor. `F14-COR-01` is the open major taxonomy mismatch: a Telegram 409
on a send raises `PollerConflictError`, which the drainer cannot classify, so its
send thread stops until the row is reconciled. The challenged reports reproduce
and uphold these two major boundary findings; no new CF08 count is added.

## Security and authority

Reviewed. The gateway constructs no session or workspace access while deciding an
inbound update. Admission checks the surface, private-chat shape, binding, and
allowlist before request insertion. Callback approval is deny-by-default unless
the prompt's stored evidence requirement is met; the button label is not the
security check. Telegram credentials are held by the client and are not part of
the normalized envelope or durable inbound row. The client enforces HTTPS mode
from the configured origin, bounded response bytes, and typed authentication,
throttle, conflict, and ambiguous-send outcomes.

The callback branch is deliberately reviewed as a layered boundary. The pure
admission table reaches `:decision` before the allowlist check, but the gateway
then requires an active prompt whose surface, correspondent, conversation, and
originating message receipt all match (`gateway_callbacks.rb:25-37,66-71`). The
challenge therefore demotes the concern rather than treating it as an authority
bypass. `F11-SEC-01` is also minor after challenge: `restricted_html` is dead
configuration, the shipped caller selects plain rendering, and no transport
`parse_mode` is set. No live markup exposure was proven in this checkout.

Approval relay has no channel-side grant shortcut. `AuthorityEvidence.from` is a
closed lattice, the prompt pins its required value at construction, and
`consume_prompt` is a single-use CAS. The carried profile/MCP/egress findings
(`F25-SEC-01`, `F22-SEC-01`, `F18-SEC-01`, `F09-SEC-01`, `F09-SEC-02`, and
`F10-SEC-01`) remain owned by their runtime or adapter seams.

## Reliability and durability

Reviewed. Inbound anchor, request, checkpoint, and capacity reservation are one
transaction. Poll offset advancement follows admission, so a crash before that
write replays the same update safely. Outbox claims and send-start are fenced by
owner and fence; pre-send expiry returns a row to pending, while a post-send
expiry records unknown. Prompt insertion and decision consumption are durable,
single-use operations. Gateway and drainer stop paths release their owned leases.

The critical reliability decision is the unknown delivery barrier. The written
contract says an unknown part blocks later parts in a conversation, but
`DeliveryDrainer#drain_once` selects pending rows once and advances after marking
the current row unknown (`delivery_drainer.rb:45-53,94-106`). SQLite filters
unknown rows out and orders only by creation time (`comms_outbox.rb:197-205`), so
the next part can cross the external boundary first. `F12-REL-01` is upheld as
open major by `comms-unknown-ordering.md` and its independent challenge.

The other reliability major is the 409 classification seam. The client chooses
`PollerConflictError` for every HTTP 409 (`telegram/client.rb:75-81`), while the
drainer rescues only throttle, authentication, and ambiguous-delivery classes
(`delivery_drainer.rb:54-57,107-151`). The row is self-reconciled to unknown
after the claim TTL, so this is a bounded stop and wrong-vocabulary failure, not
data loss; the challenge nevertheless upholds `F14-COR-01` as major. The
malformed-update path (`F14-REL-01`) is retained at minor after the challenge
found the CLI caller's `StandardError` supervision guard and the absence of a
proven normal Bot API trigger.

## Observability and evidence

Reviewed. Every inbound decision has a durable disposition and reason. Outbox
rows preserve delivery state, receipt, send-boundary timestamp, journal effect,
and claim evidence. Gateway status renders pending, delivered, failed, and
unknown separately; approval decisions and binding mismatches are durable.
Telegram poll and delivery errors are typed and named at the CLI supervision
boundary.

The evidence gaps are carried rather than inflated. Schedule-like control rows
and terminal cards can fail to activate a prompt when a stale fence loses the
receipt update (`F11-OBS-01`, minor). The outbox has no attempt count or distinct
exhaustion projection (`F12-COR-01`, `F12-OBS-01`, minor). Schedule-independent
delivery ordering has no predecessor-blocked event (`F12-REL-01`). The client
does not expose effective timeout settings through a surface status projection
(`F14-OBS-01`, minor). No real Telegram endpoint, external approval operator, or
production sink was used; the passing evidence is fixture and durable-plumbing
evidence only.

## Scalability and resource bounds

Reviewed. Telegram response bodies are byte-bounded, update batches are bounded,
inbound text and open requests are limited, rendering clamps each part to 4096
characters, and the outbox enforces durable capacity. Drainer batches and rate
pacing are bounded, prompt counts and approval actions are constrained by the
surface descriptor, and milestone rows coalesce under a fixed per-request bound.

The resource weaknesses are known. `delivered_card_message_id` scans succeeded
rows without an explicit limit on each milestone push, and resolving an unknown
delivery searches a bounded 500-row window (`F11-SCAL-01`, minor). Repeated
pre-send transport failures have no durable attempt ceiling (`F12-COR-01`) and
their stuck state is not distinguished in status (`F12-OBS-01`). A same-pass
unknown predecessor is not blocked, which is a correctness issue as well as a
fairness/resource concern (`F12-REL-01`). No sustained Telegram, drainer,
multi-process, or large-outbox load run was performed.

## Maintenance and architecture

Reviewed. Dependency direction is honest: the Comms contract gem depends only on
core values; the gateway depends on Comms; Telegram is an injected transport;
SQLite is the durable implementation. The single outbox is reused for worker
answers, control rows, clarification questions, and approval prompts. The
gateway process boundary is owned by the CLI, which installs signals and
supervises the gateway/drainer threads.

The main maintenance risk is a split response taxonomy. Telegram's HTTP client
uses the poller's conflict class for a send, while the drainer's delivery
contract has no handler for it. `F14-COR-01` names that cross-gem owner split.
The second is the FIFO promise without a store primitive: the Comms contract
does not expose conversation sequence/predecessor eligibility, leaving
`F12-REL-01` to the SQLite/gateway seam. The documented process ownership gap
(`F12-MNT-01`) is minor, and the challenge records it as documentation debt.
No new abstraction is justified; the smallest future actions are at the existing
client/drainer and outbox eligibility seams.

## Focused tests and contracts

| Command | Runs | Assertions | Failures | Errors | Skips |
|---|---:|---:|---:|---:|---:|
| `ruby -Itest test/comms_admission_test.rb` | 15 | 51 | 0 | 0 | 0 |
| `ruby -Itest test/comms_rendering_test.rb` | 6 | 35 | 0 | 0 | 0 |
| `ruby -Itest test/comms_evidence_gated_approval_test.rb` | 15 | 27 | 0 | 0 | 0 |
| `ruby -Itest test/comms_gateway_test.rb` | 39 | 242 | 0 | 0 | 0 |
| `ruby -Itest test/delivery_drainer_test.rb` | 10 | 50 | 0 | 0 | 0 |
| `ruby -Itest test/sqlite_comms_store_test.rb` | 45 | 246 | 0 | 0 | 0 |
| `ruby -Itest test/comms_cli_ops_test.rb` | 7 | 52 | 0 | 0 | 0 |
| `ruby -Itest test/comms_pairing_first_contact_test.rb` | 7 | 40 | 0 | 0 | 0 |
| `ruby -Itest test/comms_deny_callback_test.rb` | 3 | 8 | 0 | 0 | 0 |
| `ruby -Itest test/comms_lifecycle_test.rb` | 9 | 68 | 0 | 0 | 0 |
| `ruby -Itest test/comms_values_test.rb` | 20 | 78 | 0 | 0 | 0 |
| `ruby -Itest test/canonical_cross_surface_composition_test.rb` | 1 | 106 | 0 | 0 | 0 |
| `ruby -Itest test/tamoz_telegram_transport_test.rb` | 23 | 8 | 0 | 19 | 0 |
| `ruby -Itest test/telegram_normalizer_test.rb` | 10 | 28 | 0 | 0 | 0 |
| `ruby -Itest test/comms_serve_supervision_test.rb` | 1 | 6 | 0 | 0 | 0 |
| `ruby -Itest test/stream_approval_relay_test.rb` | 17 | 94 | 0 | 0 | 0 |

The passing suites cover admission, rendering, callback evidence, replay,
pairing, durable outbox claims, pacing, gateway supervision, Telegram
normalization, and approval relay. The Telegram transport fixture could not bind
its loopback socket in this sandbox (`Errno::EPERM`): 19 of 23 cases errored at
fixture setup. The normalizer suite and all non-socket adapter contracts passed.
No test covers an ambiguous multipart predecessor with a successor, a send-side
409, an alternate transport response taxonomy, an unknown-row attempt ceiling,
or a real restart with an approval prompt waiting for its receipt.

## Findings and coordinator disposition

No new machine-counted CF08 finding is added. The current coordinator decisions
and challenge outcomes are:

| Finding | CF08 disposition | Owning seam / evidence |
|---|---|---|
| F11-COR-01 | **Open major, upheld.** Truncation drops overflow without the documented recovery marker. | `tamoz-comms` rendering; `challenge-comms-otel-schedule.md` |
| F11-SEC-01 | **Open minor, demoted.** Dead `restricted_html` configuration has no live caller. | Comms rendering/transport; same challenge |
| F11-SEC-02 | **Closed, refuted.** A revoked binding is rejected before the allowlist branch. | Comms admission; same challenge |
| F11-SEC-03 | **Open minor, demoted.** Callback admission is a defence-in-depth ordering gap; exact active-prompt binding blocks an unlisted callback. | Gateway callback; same challenge |
| F11-ERR-01 / F11-ERR-02 | **Open minor, reassigned to F07.** Store transition/digest checks are absent but the shipped producers are gated and consistent. | SQLite outbox; same challenge |
| F11-ERR-03 / F11-OBS-01 / F11-SCAL-01 | **Open minor, carried.** Typed descriptor, prompt activation, and bounded lookup gaps remain in their component reports. | Comms/outbox seams |
| F12-REL-01 | **Open major, upheld.** An unknown same-conversation part does not fence a later pending part. | Gateway drainer + SQLite outbox; `comms-unknown-ordering.md` and challenge |
| F12-COR-01 / F12-REL-02 / F12-SEC-01 / F12-OBS-01 / F12-MNT-01 | **Open minor, carried.** Attempt, retry-state, pairing-memo, visibility, and process-ownership debt remain bounded component findings. | Gateway/drainer reports |
| F14-COR-01 | **Open major, upheld.** HTTP 409 is classified as a poller conflict even for sends; the drainer has no handler. | Telegram client + gateway drainer; `challenge-core-telegram-evals.md` |
| F14-REL-01 | **Open minor, demoted.** Malformed update exceptions stop the supervised gateway loop and produce exit 1; the process-abort claim was overstated. | Telegram normalizer/transport; same challenge |
| F14-RES-01 / F14-OBS-01 / F14-SEC-02 / F14-MNT-02 / F14-MNT-01 | **Component leads carried without a CF08 duplicate.** The 429-body, timeout visibility, TLS doctor, comment, and descriptor-setting items retain F14 dispositions. | Telegram report |

The independent challenges uphold the two CF08-crossing majors and explicitly
close or demote the earlier revocation, callback, rendering-format, and malformed
update overstatements. Carried findings are excluded from CF08 counts.

## Blind spots and verdict

- The real Telegram transport fixture was blocked by sandbox loopback `EPERM`;
  no live Bot API endpoint was called.
- No two-process drainer/poller race, same-conversation multipart ambiguity,
  send-side 409 against the real client, or external approval operator was run.
- No sustained outbox/Telegram load or long-lived failure-loop measurement was
  performed.
- The callback and approval conclusions use source plus in-process/fake-store
  tests; no live Telegram callback was consumed.
- No production code, tests, configuration, or generated artifact was changed.

**IMPROVE** under `BAR.md`: all six lenses and the Telegram → gateway → SQLite →
outbox → drainer → approval callback trace are reviewed, but the open major
unknown-ordering and send-409 taxonomy findings remain, alongside the rendering
overflow major. CF08 adds no duplicate machine-counted finding.
