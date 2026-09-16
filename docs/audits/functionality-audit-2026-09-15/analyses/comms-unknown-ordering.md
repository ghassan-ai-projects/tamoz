# F12-REL-01 — an unknown delivery does not fence later same-conversation parts

| Field | Assessment |
| --- | --- |
| Functionality | F12 `tamoz-comms-gateway` delivery drainer; affected F07 `tamoz-sqlite`, F11 `tamoz-comms`, and CF08 |
| Severity | **major** — a durable ambiguity can produce externally visible out-of-order or incomplete channel output |
| Confidence | **high** — the source path, written contract, focused tests, and a temporary database/transport probe agree |
| Status | **open**; no implementation was made in this audit |
| Scanner signal | F12-REL-01: pending rows are selected without an unresolved same-conversation predecessor check |
| Independent judgment | **Confirmed for later multipart parts.** The current behavior is not an intentional non-blocking rule in the written contract. The request-local status test is reporting coverage, not a drainer-order contract. |

## Finding and exact trigger

`DeliveryDrainer#drain_once` reconciles expired rows, reads only `pending` rows, and
walks that fixed result set in order (`gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb:45-53`).
When `send_delivery` receives `Comms::AmbiguousDeliveryError`, it returns an
`unknown` outcome and `send_row` marks the current row before returning
(`.../delivery_drainer.rb:94-106,142-151`). The loop then proceeds to its next
already-selected row; it does not stop the conversation or re-query eligibility.

The exact trigger is two pending rows for one `(surface_id, conversation_id)`,
where A is earlier than B and the transport makes A ambiguous. If A is a
multipart answer part (`part_index=0`, `part_count=2`) and B is its successor
(`part_index=1`), the drainer attempts B in the same pass. The durable outbox
does not supply a barrier: `reconcile_expired_deliveries` changes only expired
claimed rows based on `send_started_at_ms` (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:146-163`),
`claim_delivery` is a row-local compare-and-set (`.../comms_outbox.rb:73-98`),
and `outbox_rows` filters A out by selecting `status IN (?)` for `pending` and
orders only the remaining rows by `created_at_ms` (`.../comms_outbox.rb:197-205`).
The schema has `conversation_id`, part fields, and status, but no durable
conversation sequence or predecessor state (`.../migrator.rb:1219-1248`; the
row projection has the same fields at `.../comms_store_rows.rb:41-47`).

The written contract is stronger than this behavior: agent output is a real
unsafe external effect, an ambiguous send remains `unknown`, and “Delivery
order is fenced FIFO per conversation; an `:unknown` part blocks later parts
until operator resolution” (`documentation/design/comms.md:105-109`). The
transport can produce this state in production: a response-cap failure maps to
`AmbiguousDeliveryError` (`gems/tamoz-telegram/lib/tamoz/telegram/transport.rb:49-72`),
and network send failures are ambiguous in the client (`gems/tamoz-telegram/lib/tamoz/telegram/client.rb:85-92,116-121`).

An independent temporary-database probe used the real `CommsOutbox` and
`DeliveryDrainer` harness with same-conversation parts A/B. The transport raised
`AmbiguousDeliveryError` for A and returned a receipt for B. The result was
`outcome=:drained`, `attempts=["A", "B"]`, `deliveries=["B"]`, and durable
statuses `A=unknown`, `B=succeeded`. This is a same-pass reproduction, so a
restart is not required to expose the gap.

## Impact and six-lens assessment

If Telegram accepted A but its response was lost, B becomes visible first and
the conversation order is inverted. If Telegram did not accept A and the
operator later resolves it as `failed`, B remains visible without its first
part. Explicit resolution cannot restore the original order because B has
already crossed the transport boundary. The no-blind-retry property remains
correct, and claim fences still prevent stale owners from writing another row;
the defect is the missing per-conversation ambiguity barrier around that safe
state.

| Lens | Assessment |
| --- | --- |
| Correctness | **Defect confirmed:** the implementation violates the explicit FIFO/unknown predecessor contract for multipart output. |
| Security/authority | No authority widening or secret exposure is shown. Fencing and explicit operator resolution remain active. |
| Reliability/durability | **Major impact:** durable `unknown` truth is preserved, but later output can become externally observable before the unresolved predecessor is decided. |
| Observability/evidence | The store can report conversation `unknown` while a current request reports `succeeded` (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:843-869`; `test/sqlite_comms_store_test.rb:707-740`), but it records no “blocked by predecessor” reason or ordering evidence. |
| Scalability/resource bounds | The current batch and outbox bounds remain finite. A fix should block only the affected conversation so independent conversations continue to drain; it must keep the bounded candidate query. |
| Maintenance/architecture | Ownership is clear at `CommsOutbox`/`DeliveryDrainer`, but the contract describes FIFO without a store primitive for sequence or eligibility. Rate pacing (`.../comms_outbox.rb:101-118`) is not an ordering barrier. |

## Evidence and test gap

`ruby -Itest test/delivery_drainer_test.rb` passes 10 runs and 50 assertions.
Its unknown cases prove that a crashed send or oversized response becomes
`unknown` and is not retried (`test/delivery_drainer_test.rb:100-117,238-255`),
but they contain no successor row. `test/comms_gateway_test.rb:554-570` has the
same single-row coverage. The request-local status test manually marks one
request unknown and another succeeded, then checks per-request and aggregate
projections (`test/sqlite_comms_store_test.rb:707-740`); it never calls the
drainer and therefore does not establish intentional non-blocking delivery.
No test covers multipart part order, a same-pass ambiguous outcome, a restart
with a pending successor, or release after explicit resolution.

## Five Whys

1. **Why did B send after A became unknown?** The drainer continued its pending-row loop after marking A unknown.
2. **Why could it continue?** The candidate list was built before A’s outcome and had no per-conversation eligibility guard.
3. **Why is there no guard?** The SQLite claim and reconciliation operations are row-local; `unknown` rows are filtered out rather than treated as predecessors.
4. **Why is the contract unrepresented in storage?** FIFO is stated in design prose, but the outbox exposes only `created_at_ms` ordering and no durable sequence/barrier primitive.
5. **Why did the gap survive?** Tests cover ambiguity preservation and request-local status independently, but no cross-row test connects an ambiguous predecessor to later multipart delivery. The root cause is an incomplete ordering contract at the existing CommsOutbox/Drainer seam.

## Recommendation and disposition

At the existing `CommsOutbox` eligibility/claim seam, make a pending delivery
ineligible while an earlier same-conversation delivery is `claimed` or
`unknown` after its send boundary. Preserve ordinary pre-send retry behavior;
once an operator resolves the unknown row to `succeeded` or `failed`, the next
drain may claim the successor. Keep independent conversations drainable and
retain the existing bounded batch. The implementation needs one durable order
rule (including a deterministic tie-breaker for equal `created_at_ms`) rather
than a sleep or process-local flag.

Add a focused drainer regression with A/B multipart rows: make A ambiguous,
assert B has no transport attempt and remains pending, resolve A explicitly,
then assert the next drain sends B. Add a second case proving another
conversation is not blocked. A separate review should decide whether the same
barrier must cover concurrent `claimed` rows; that broader in-flight FIFO race
is adjacent and is not claimed as an additional finding here.

Historical material confirms the intended separation of task and delivery
states and the no-blind-retry rule (`docs/openclaw-chat-study/04-tamoz-target-architecture.md:15-23,186-211`),
but it does not close this ordering case. The prior request-local status change
(`69c4a4d`, reflected in the test above) fixes projection scope only.

**Disposition: accept as an open major finding for F12, with F07/F11/CF08 owner follow-up.**
