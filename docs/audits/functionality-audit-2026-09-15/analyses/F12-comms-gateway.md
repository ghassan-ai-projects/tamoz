# F12 `tamoz-comms-gateway` — IMPROVE: the boundary, fencing, and no-blind-retry contracts hold; the drain loop has three unbounded-or-invisible edges

Row F12 / queue W3A / baseline commit `582ae55` on branch `audit-15-09`, 2026-09-15 / analyst `analyst_f12` / budget 45 min, hard cap 60.

## Scope and source map

Read end to end before any test (13 files, 1552 lines of `lib`):

| File | Lines | Role |
| --- | --- | --- |
| `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb` | 309 | lifecycle: `start`/`serve_once`/`serve_loop`/`stop`, constants, collaborator constructor |
| `.../delivery_drainer.rb` | 165 | the drainer: claim, pace, bind, mark, ambiguous-send |
| `.../gateway_admission.rb` | 130 | normalize -> disposition -> route |
| `.../gateway_status.rb` | 240 | `/status` human + `--diagnostic` projections |
| `.../gateway_commands.rb` | 176 | `/help /status /new /cancel /redirect /answer /whoami /start` |
| `.../gateway_answers.rb` | 162 | clarification answer path + `reply_to` receipt resolution |
| `.../gateway_callbacks.rb` | 91 | approval callback resolve + `answerCallbackQuery` ack |
| `.../gateway_pairing.rb` | 84 | first-contact challenge issue/reuse |
| `.../gateway_admission_binding.rb` | 55 | write-once thread/profile + correspondent binding |
| `.../gateway_context_controls.rb` | 53 | `/reset /compact /usage /context /think /verbose` over injected `@controls` |
| `.../gateway_delivery.rb` | 37 | the single bounded control-reply construction point |
| `.../gateway_admission_acknowledgement.rb` | 26 | `Received r<ref>.` |
| `.../gateway_conversation_commands.rb` | 24 | `/new` generation bump, `/whoami` |
| `tamoz-comms-gateway.gemspec` | 20 | deps: `tamoz-comms`, `tamoz-core` only |

Entry seam: `Tamoz::Comms::Gateway#serve_once` (`gateway.rb:190-212`), reached from `serve_loop` (`gateway.rb:148-165`) and from the CLI `tamoz comms serve [--once]` (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_commands.rb:41-94`). The gateway gem itself contains no `bin`, no `Signal.trap`, and no process entry point — the process owner is `cli_comms_commands.rb`.

## Behavior path

One pass is `renew -> poll -> admit -> persist -> drain`.

1. **Lease + authenticate.** `start` (`gateway.rb:168-180`) acquires a fenced poller lease and calls `authenticate_transport` (`gateway.rb:269-276`), which raises `Comms::AuthenticationError` unless the transport identity's `id` equals `bot_id`. `serve_once` renews first and returns `:poller_lost` if renewal fails (`gateway.rb:191`, `225-232`).
2. **Poll.** `poll_batch` (`gateway.rb:216-220`) reads `@transport.poll(next_offset:, limit: @batch_size, timeout_s: poll_timeout_s)`; a `TransientTransportError` returns `nil` and the pass returns `:transient` having persisted nothing, so the next pass retries the same durable offset (`gateway.rb:193-195`).
3. **Admit.** Each envelope goes through `admit` -> `Comms::Admission.decide` (`gateway_admission.rb:10-24`), then routes on disposition: `:request`, `:decision`, `:rejected`, `:control`, ignored (`gateway_admission.rb:32-53`).
4. **Persist.** `persist_next_offset` advances only after the whole batch is admitted (`gateway.rb:198`).
5. **Drain.** `drain_outbox` -> `DeliveryDrainer#drain_once` (`gateway.rb:199`, `261-263`). The drainer reconciles expired rows, selects `pending` rows bounded by `@batch_size`, claims each with a fence, reserves a pacing slot, binds its journal effect, marks `send_started`, then sends and marks the outcome (`delivery_drainer.rb:45-57`, `61-128`).

`--once` (`cli_comms_commands.rb:72-82`) calls `gateway.start` then a single `gateway.serve_once`, with `gateway.stop` in an `ensure`.

## Lens: correctness

**Proven.** The pass ordering contract holds: the offset is persisted only after admission (`gateway.rb:197-198`), and a failed poll persists nothing (`gateway.rb:216-220`). `test_a_transient_poll_failure_does_not_end_the_gateway` (`test/comms_gateway_test.rb:269-293`) and the restart tests at `:209-232` exercise this.

**Proven — the no-blind-retry rule.** An ambiguous send becomes `unknown` and is never resent: `send_delivery` maps `Comms::AmbiguousDeliveryError` to `{status: 'unknown', receipt: nil}` (`delivery_drainer.rb:147-151`), `drain_once` only ever selects `statuses: %w[pending]` (`delivery_drainer.rb:47`), and the store's `mark_delivery` writes to a `claimed` row only (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:235-246`). An `unknown` row can leave that state only through the operator's `resolve_delivery`, which requires `status = 'unknown'` (`comms_outbox.rb:251-260`), surfaced as `tamoz comms delivery resolve ID succeeded|failed` (`cli_comms_ops.rb:191-221`). README claim verified.

**Proven — crash semantics.** `reconcile_expired_deliveries` splits the two cases honestly (`comms_outbox.rb:146-163`): a claimed row whose send boundary was never crossed (`send_started_at_ms IS NULL`) returns to `pending` and is retried; a row past the boundary becomes `unknown` and is not. `delivery_drainer_test.rb:89-117` covers both directions.

**Minor defect — no max-attempts bound.** See `F12-COR-01`.

## Lens: security and authority

**Proven — the boundary claim holds.** README: "the gateway holds the bot token and never constructs a session or opens a workspace file." I searched the whole gem for the violating construct and found none: the only match for `session` anywhere in `lib` is a user-facing reply string (`gateway.rb:76`), and there is no `File.`, `Dir.`, `IO.`, `Pathname`, or `open(` in the gem at all. The full require set is `tamoz/comms`, `time`, `json`, and eleven `require_relative` siblings (`gateway.rb:3-18`, `delivery_drainer.rb:3-4`). The gemspec declares only `tamoz-comms` and `tamoz-core` (gemspec:14-17) — no `tamoz-agent-session`, no checkpoint/session gem.

The session seam is *injected*, not constructed: `@controls` is a caller-supplied callable (`gateway.rb:128`, consumed at `gateway_context_controls.rb:11,20`). The production CLI passes `comms_controls_source`, whose real body returns `nil` (`cli_comms_shared.rb:155-157`), so `/reset` and friends answer `CONTROLS_UNAVAILABLE_REPLY` (`gateway.rb:74`, `gateway_context_controls.rb:11`). Only test harnesses inject a real session (`test/support/openclaw_comms_fixture.rb:399`, `test/support/experience_harness.rb:166`). The CLI's own comment states the same invariant (`cli_comms_commands.rb:9-11`). **No violation found; not a defect.**

**Proven — control authority is the same gate as task text.** A command is not a separate authority path. `Admission.decide` resolves the binding and surface first (`gems/tamoz-comms/lib/tamoz/comms/admission.rb:36-46`) and only then branches to `command_admission`, which under `allowlist` requires the correspondent to be in the configured list *or* to hold an active binding (`admission.rb:63-75`); under `pairing` it requires an active binding. An unauthorized sender is `ignore(:unbound)` and never reaches `command_disposition`. Group chats and disabled surfaces are refused before that (`admission.rb:38-39`). `test_an_unbound_sender_is_ignored` (`test/comms_gateway_test.rb:521`) covers the text path; `test/comms_command_parity_test.rb` covers the command registry.

**Proven — replay is bounded.** Control operations key their durable request on the update identity: `command_request_id` hashes `[surface_id, update_id, *tags]` (`gateway_commands.rb:103-108`), so a replayed `/new` bumps the generation once and a replayed context control executes once — `test_a_replayed_new_command_bumps_the_generation_once_only` (`test/comms_gateway_test.rb:874`) and `test_a_replayed_context_control_executes_its_command_once` (`:895`). `idempotent_a_replayed_update_already_has_its_admission_durable` short-circuits before re-rendering (`gateway_admission.rb:71-73`).

**Proven — approval authority is evidence-gated and single-use.** `resolve_callback` checks `active_prompt?`, then a five-field binding match including the prompt receipt (`gateway_callbacks.rb:25-33`, `66-72`), then refuses `approve` when the prompt demands more evidence than chat-bound (`:35-38`, `74-77`). Consumption is one CAS (`:62`). A bare reference means *deny* (`:79-87`) — fail-safe.

**Minor — the pairing-code memo is process-local.** See `F12-SEC-01`.

## Lens: reliability and durability

**Proven — fences bar stale owners absolutely.** `next_fence` is `CLOCK_MONOTONIC` microseconds (`delivery_drainer.rb:157-159`). I probed collision density (`/tmp/probe_fence.rb`, 4 threads x 500 draws): 2000 samples, 325 distinct, 1675 collisions — monotonic microseconds collide freely. This is **not** a defect: the fence is only ever compared inside a per-row `UPDATE ... WHERE delivery_id = ? AND claim_owner = ? AND claim_fence = ?` (`comms_outbox.rb:235-246`), so a fence value is a tiebreaker scoped to one row and one owner string, and owners are process-unique (`cli_comms_commands.rb:208` embeds `Process.pid`). Collisions across rows or across different owners are inert.

The behavioral proof is stronger. I probed the TTL-expiry race directly (`/tmp/probe_ttl.rb`): drainer A claims at `t0` with a 30 s TTL, then "stalls" 45 s; drainer B runs a pass at `t0+45`, re-claims the expiry-released row and sends it (`B sends=1`); A then attempts `mark_delivery_send_started` with its **stale** fence and gets `not_claimable`, so A crosses no send boundary and writes nothing. `test_a_stale_owner_runs_no_external_send_and_records_no_result_after_takeover` and `test_a_fence_lost_between_claim_and_send_start_bars_the_external_send` (`delivery_drainer_test.rb:120-174`) assert exactly this. The same-row duplicate-send window is closed by the fence, not by the TTL.

**Proven — pacing deadlines are durable, not in-memory.** `reserve_delivery_slot` writes the next-allowed time into the store's pacing rows (`comms_outbox.rb:101-119`), and `defer_delivery` on a throttle pushes the durable `not_before` forward (`:165-175`). `test_rate_limit_reservation_survives_a_drainer_restart` (`delivery_drainer_test.rb:59-84`) proves a fresh drainer observes the prior drainer's reservation. Journal-effect binding is write-once (`comms_outbox.rb:179-195`).

**Proven — shutdown cannot lose an accepted message or strand a lease.** `Gateway#stop` sets `@stopping`, stops an owned drainer, and releases the poller lease (`gateway.rb:183-187`); `serve_loop` releases via `ensure` on every exit including a raise (`:163-165`), and `start` releases on auth failure (`:177-180`). The CLI installs INT/TERM through `Cancellation::Trap.install`, deliberately deferring `stop` to a thread because the lease release is a database write whose mutex would raise `ThreadError` in trap context (`cli_comms_commands.rb:130-136`) — an accepted message's durability comes from `admit_and_enqueue` (step 4) and is independent of loop teardown, and `--once` brackets `serve_once` with `stop` in an `ensure` (`:78-79`). `test_stop_ends_the_serve_loop_and_releases_the_lease` (`test/comms_gateway_test.rb:321`).

**Minor — retry pacing state is in-memory.** See `F12-REL-02`.

**Carried forward — `comms-unknown-ordering.md` (major, open): still present, unchanged.** `drain_once` builds its candidate list once (`delivery_drainer.rb:47`), walks it without re-querying, and `send_row` returns `nil` after marking a row `unknown` (`:94-106`); the loop advances to the next already-selected row. The store still offers no per-conversation predecessor barrier: `outbox_rows` filters on `status IN (?)` and orders only by `created_at_ms` (`comms_outbox.rb:197-207`), `claim_delivery` is row-local (`:82-99`), and `reconcile_expired_deliveries` touches only expired claimed rows (`:146-163`). I re-verified every citation in that report against current source and found no change; I did not re-litigate the finding itself.

## Lens: observability and evidence

**Proven.** Dispositions are durable and typed: `record_disposition` writes one of `ignored`/`rejected`/`decision` with a machine reason (`gateway_admission.rb:32-53`, `102-104`), and refusals use a fixed `ADMISSION_REFUSALS` table with bounded replies (`gateway.rb:95-102`). `/status` renders both a human projection and an explicit `--diagnostic` control-plane projection (`gateway_status.rb:45-50`, `128-157`) with a distinct cancellation timeline that never claims an external call stopped (`:204-222`). Delivery states are projected honestly, including `unknown` (`gateway_status.rb:37-41`). A supervise-time storage failure is named on stderr with its exception class and turns into a non-zero exit (`cli_comms_commands.rb:143-175`), proven by `test/comms_serve_supervision_test.rb` (1 run, 6 assertions).

**Minor — attempt exhaustion is not observable.** See `F12-OBS-01`.

## Lens: scalability and resource bounds

**Proven.** Inbound is bounded by `@batch_size` (`gateway.rb:217`), the drainer's candidate query is bounded by the same (`delivery_drainer.rb:47`), the outbox is bounded durably at append by `capacity` with a `:capacity_refused` outcome (`comms_outbox.rb:56-77`), control replies are clamped to `Comms::Delivery::MAX_TEXT_BYTES` at the single construction point (`gateway_delivery.rb:11-24`, tested at `test/comms_gateway_test.rb:776`), inbound control text is gated by the deployed `max_inbound_bytes` (`gateway_admission.rb:106-115`), and milestones coalesce with a `MILESTONE_BOUND` ceiling (`comms_outbox.rb:24-25`). Backoff is bounded: `min(base * 2**(n-1), 30.0)` (`gateway.rb:34-35`, `235-248`).

**Not evidenced — drain throughput under a sustained backlog.** No load or soak result exists in the checkout for the gateway; the batch bound is proven but the per-pass steady-state rate and the interaction with `per_chat_messages_per_s`/`global_messages_per_s` under a deep outbox are not measured. A bounded soak that keeps N>batch rows pending and records per-pass drain counts would prove it.

## Lens: maintenance and architecture

**Proven.** Ownership is honest: the gem consumes `tamoz-comms` values, errors, and the `CommsStore` contract and depends on `tamoz-core` only (gemspec:14-17). The lifecycle stays in `gateway.rb` while intent-specific behavior splits into ten small included modules (`gateway.rb:104-114`), each with a one-line charter. There is one bounded control-reply construction point (`gateway_delivery.rb:10-13`). The public surface is deliberately narrow — constructor, `start`, `serve_once`, `serve_loop`, `stop`, `admit`, `renew_poller`, `loop_delay` — and the two `rubocop:disable` blocks are each annotated with the specific contract they serve (`gateway.rb:116-117`, `222-224`; `delivery_drainer.rb:11`).

**Minor — the CLI is the process owner, not the gem.** See `F12-MNT-01`.

## Tests and contracts

All run one file per command under `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`.

| Command | Runs | Assertions | Failures |
| --- | --- | --- | --- |
| `ruby -Itest test/comms_gateway_test.rb` | 39 | 242 | 0 |
| `ruby -Itest test/delivery_drainer_test.rb` | 10 | 50 | 0 |
| `ruby -Itest test/callback_ack_crash_test.rb` | 2 | 20 | 0 |
| `ruby -Itest test/comms_command_parity_test.rb` | 11 | 203 | 0 |
| `ruby -Itest test/agent_outbox_delivery_sink_test.rb` | 18 | 101 | 0 |
| `ruby -Itest test/context_control_exposure_test.rb` | 6 | 58 | 0 |
| `ruby -Itest test/session_context_controls_test.rb` | 10 | 91 | 0 |
| `ruby -Itest test/comms_serve_supervision_test.rb` | 1 | 6 | 0 |

97 runs / 771 assertions / 0 failures across 8 files. `rake ci` / `rake ci_full` were **not run** (brief forbids them).

**Test gap for this row's findings:** no test asserts a max-attempts bound or an exhaustion signal (none exists in source); no test asserts that backoff state survives a restart (it cannot — it is in-memory); the pairing-code memo is covered only through `test/comms_pairing_first_contact_test.rb` first-contact reuse, not across a restart. `comms-unknown-ordering.md`'s cited gap stands: no test covers a same-pass ambiguous predecessor with a pending successor (`test/delivery_drainer_test.rb:238-255` and `test/comms_gateway_test.rb:554-570` are both single-row).

**Prior finding 012 (`top100-audit-2026-09-11/012-comms_gateway_test.md`) — test-shape, lower priority; source-side equivalent: not found.** Its three items were `[DEAD]` leftover `warn` dumps, `[TEST]` private-state probing, and `[DUP]` a duplicated graph fixture. `[DEAD]` and `[DUP]` are recorded **fixed** in that document (`:21-27`). `[TEST]` is **deferred** there, and I confirm the source-side equivalent does *not* exist: the raw-SQL probes work around the absence of a public observable-outbox read seam, which is a `CommsStore` surface gap (F07/F11 owner), not a gateway-gem defect. Nothing in `tamoz-comms-gateway/lib` is implicated.

## Findings

### F12-COR-01 — the delivery outbox has no attempt bound and no terminal exhausted state

| Field | Assessment |
| --- | --- |
| Severity | **minor** — bounded operational cost, no false completion and no data loss |
| Confidence | **high** — the schema, the claim predicate, and the reconciliation path are all read directly |
| Status | **open** |
| Source evidence | `gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb:707-726` (outbox columns: `status`, `claim_owner`, `claim_fence`, `claim_expires_at_ms`, `effect_key`, `effect_execution_id`, timestamps — **no attempt counter**); `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:146-163` (`reconcile_expired_deliveries` returns a pre-send claim to `pending` unconditionally); `comms_outbox.rb:82-99` (`claim_delivery` re-claims a `pending` row with no count check); `gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb:45-57` (the drain loop has no attempt ceiling) |
| Test/contract evidence | `ruby -Itest test/delivery_drainer_test.rb` -> 10 runs / 50 assertions / 0F; `test_crashed_claim_is_retried_only_before_the_send_boundary` (`:89-104`) asserts the retry happens and asserts nothing about how many times. **not found:** no test asserts an attempt ceiling or an exhausted terminal state. |
| Scanner signal | lead — `grep -rn "attempt" gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb` matches only prose comments and no column |
| Independent judgment | **Confirmed as a real, bounded gap.** A transport that repeatedly fails *before* crossing the send boundary (a connect error raised before transmission) lets the row be re-claimed and re-attempted forever; each cycle costs one transport attempt and one pacing reservation. This is not a false-completion or durability bug — `mark_delivery` still fences every write and a genuine ambiguity still lands on `unknown` — so the bar places it at `minor`, not `major`. I rejected promoting it: the outbox is capped at `outbox_capacity` and the drain is batch-bounded, so the loop cannot grow memory or rows without bound. |
| Root cause | The outbox models an attempt as a *claim*, and a claim is released without a counter. The schema's only counter columns live on the effect journal (`migrator.rb:249-268`), which the outbox binds to but never increments (`comms_outbox.rb:179-195`). The retry policy therefore lives implicitly in whichever transport error class is raised, not in a durable budget. |
| Recommendation | No new machinery. The effect journal the row already binds (`effect_key`, `effect_execution_id`) is the existing seam holding attempts; have `claim_delivery` refuse a re-claim once the row's journaled attempt count reaches the descriptor's existing retry ceiling, and surface that refusal through the existing `:not_claimable` path. If the simple path already delivers the property, prefer adding the attempt count to the existing `reconcile_expired_deliveries` return so exhaustion is countable in `/status` and do nothing else. |
| Disposition | Open, `minor`. Owner seam is `CommsOutbox` (F07) with the policy read by `DeliveryDrainer` (F12). Recorded as a bounded gap; the coordinator should not let it block F12. |

### F12-REL-02 — retry backoff and throttle deadlines are process-local

| Field | Assessment |
| --- | --- |
| Severity | **minor** — a restart resets pacing of *failures*, never of deliveries |
| Confidence | **high** — every counter is an unpersisted ivar and the restart consequences are traced |
| Status | **open** |
| Source evidence | `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb:130-131` (`@fence = 0`, `@stopping = false`); `gateway.rb:235-248` (`loop_delay` reads and writes `@transient_failures`, `@retry_after_s` — plain ivars, never persisted); `delivery_drainer.rb:53-56` and `:33` (the drainer's `@retry_after_s` is likewise process-local). Compare the *durable* pacing the same code path uses: `comms_outbox.rb:101-119`, `:165-175`. |
| Test/contract evidence | `ruby -Itest test/comms_gateway_test.rb` -> 39 runs / 242 assertions / 0F. `test_rate_limit_reservation_survives_a_drainer_restart` (`test/delivery_drainer_test.rb:59-84`) proves the *pacing* reservation survives; **not found:** no test asserts any backoff state across a restart, because no such durable state exists. |
| Scanner signal | lead — `grep -rn "@transient_failures\|@retry_after_s" gems/tamoz-comms-gateway/lib/` returns only reads/writes inside one process |
| Independent judgment | **Confirmed, and deliberately rated `minor`.** The delivered-message deadline is durable (`reserve_delivery_slot`/`defer_delivery`), so a restart does **not** cause a burst of channel sends — the property that actually matters is intact. What resets is only the *failure* backoff: a crash-loop against a dead transport restarts at the 1 s base instead of resuming at up to 30 s. That is a bounded extra-load cost, not a correctness or authority problem. |
| Root cause | The gateway's retry policy is a loop-local heuristic rather than a store projection, while the sibling policy two lines away (pacing) is durable. The asymmetry is an artifact of the loop having been written before the pacing seam existed, and no test pins the restart behavior of the backoff. |
| Recommendation | None required for correctness. If a bounded action is wanted, persist the failure streak through the durable surface the loop already has (`@store` is in scope at `gateway.rb:123`) and read it in `loop_delay`; do not add a new mechanism. |
| Disposition | Open, `minor`, recorded as a deliberate limitation to keep the verdict honest. Not a F12 blocker. |

### F12-SEC-01 — the plaintext pairing-code memo is process-local and dies with the gateway

| Field | Assessment |
| --- | --- |
| Severity | **minor** — an operational/UX cost, not an authority widening |
| Confidence | **high** — the memo, its pruning rule, and the durable contrast are all read |
| Status | **open** |
| Source evidence | `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb:132-134` (comment: "the store keeps only challenge digests; plaintext codes live here so a repeat contact can name the same code again"); `gateway_pairing.rb:48-65` (`ensure_pairing_code` reuses from and `prune_issued_pairing_codes` bounds `@issued_pairing_codes` against the live durable pending set); `gateway_pairing.rb:67-80` (`issue_pairing_code` writes the digest durably and the plaintext only into the memo) |
| Test/contract evidence | `ruby -Itest test/comms_pairing_first_contact_test.rb` — **not run** in this row (outside the assigned test surface). The reuse path is exercised through the gateway tests that drive first contact. **not found:** no test restarts the gateway between issuing a code and repeating contact. |
| Scanner signal | lead — `@issued_pairing_codes` is the only plaintext code holder and has no store counterpart |
| Independent judgment | **Confirmed as an inherent, bounded design property rather than a defect.** Bounding is correct and deliberate: `prune_issued_pairing_codes` deletes any memo entry with no live durable challenge, so the memo cannot outgrow the store's pending set and cannot leak a code whose challenge has expired. The plaintext is never persisted, which is the *safe* direction. The only consequence is that a gateway restart makes a pending challenge's code unreadable, so the correspondent must be issued a fresh one. No capability is widened, and `start_text` remains feedback-only with activation staying with operator approval (`gateway_pairing.rb:10-15`, `cli_comms_pairing`'s approve step). |
| Root cause | The security requirement (never persist a plaintext challenge) and the usability requirement (a repeat contact names the same code) are in tension; the design resolves it in favour of security with a process-local memo, and the restart cost was not separately decided. |
| Recommendation | None at the gateway seam — the tradeoff is already made correctly. If the restart cost is worth removing, the smallest action is a bounded re-issue on the first post-restart contact from the same correspondent (the existing `issue_pairing_code` path), not persisting plaintext. |
| Disposition | Open, `minor`, recorded so a future reader does not mistake the memo for a durability bug. |

### F12-OBS-01 — an exhausted or persistently failing delivery never becomes visible as a terminal state

| Field | Assessment |
| --- | --- |
| Severity | **minor** — an operator can see the row, but not that it is stuck |
| Confidence | **medium** — the in-memory mechanism is proven; the production frequency of a pre-send failure loop is not measured |
| Status | **open** |
| Source evidence | `delivery_drainer.rb:45-57` (the loop returns `:drained` whether it delivered, marked `unknown`, or re-released a row); `delivery_drainer.rb:117-127` (a throttle defers durably and releases the claim, leaving the row `pending`); `comms_outbox.rb:146-163` (a pre-send expiry silently returns the row to `pending`); `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_status.rb:37-41` (`DELIVERY_WORDS` maps `pending` to "pending" with no age or attempt fact) |
| Test/contract evidence | `ruby -Itest test/delivery_drainer_test.rb` -> 10 runs / 50 assertions / 0F; the auth-failure test (`:207-236`) proves a *terminal* failure is visible as `failed` with `reason_code: authentication_refused`. **not found:** no test or projection exposes a repeatedly-retried-but-never-terminal row. |
| Scanner signal | lead — `DELIVERY_WORDS` and `/status` render state only, never attempt count or first-attempt age |
| Independent judgment | **Confirmed as a real observability gap, held at `medium` confidence** because I proved the mechanism (a pre-send expiry re-pends silently and the loop's `:drained` return is indistinguishable from success) but did not reproduce a sustained production failure loop. It is `minor`: the row remains queryable via `tamoz comms list` and `tamoz comms request`, so evidence exists — it just does not distinguish "pending since a moment ago" from "pending across a hundred attempts". |
| Root cause | The outbox projects only the current status, and the drainer's return value collapses three materially different outcomes into `:drained`. Because no attempt counter exists (F12-COR-01), there is nothing for `/status` to render even if it wanted to. This finding is downstream of F12-COR-01's missing durable budget. |
| Recommendation | Resolve together with F12-COR-01: once an attempt count exists on the row, extend the existing `DELIVERY_WORDS` projection (`gateway_status.rb:37-41`) with the stuck fact. Do not add a separate metric or log subsystem. |
| Disposition | Open, `minor`, `medium` confidence — linked to F12-COR-01 as the same root cause. Flagged for the coordinator as a possible merge with F12-COR-01. |

### F12-MNT-01 — the gem owns no process lifecycle; signals and supervision live in the CLI

| Field | Assessment |
| --- | --- |
| Severity | **minor** — ownership is documented, but the split is not stated in the gem's own contract |
| Confidence | **high** — read directly from both sides |
| Status | **open** |
| Source evidence | `gems/tamoz-comms-gateway/tamoz-comms-gateway.gemspec:11-14` ("the long-running communications gateway and delivery drainer") vs. the absence of any `Signal.trap`/`bin` in the gem; the actual trap, thread supervision, failure naming, and exit codes are in `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_commands.rb:130-186`; the gem's `README.md:4-20` describes collaborators but never says the process/trap owner is the caller |
| Test/contract evidence | `ruby -Itest test/comms_serve_supervision_test.rb` -> 1 run / 6 assertions / 0F. The supervision contract is tested **against the CLI module** (`test/comms_serve_supervision_test.rb:47-51` extends `Tamoz::Agent::CLICommsCommands`), confirming the CLI is the owner. |
| Scanner signal | lead — `grep -rn "Signal.trap" gems/tamoz-comms-gateway` returns nothing while `cli_comms_commands.rb:136` installs the trap |
| Independent judgment | **Confirmed as a naming/documentation gap, not a functional defect.** The behavior is correct and well-reasoned: the CLI defers `stop` to a thread because releasing the lease is a database write whose mutex would raise `ThreadError` in trap context (`cli_comms_commands.rb:131-134`), and it stops every sibling loop when one loses its credential (`:141`, `:152`). The only real cost is that a reader of the gem — whose gemspec promises a "long-running process" — cannot find out from the gem where INT/TERM handling lives. |
| Root cause | The gem was split as a library boundary while the process boundary was left with the CLI; the gemspec summary still describes the process role the gem does not own, and the README's collaborator list omits the process owner. |
| Recommendation | One line in the gem's `README.md` naming the caller as the signal/supervision owner. Documentation only; no code change at any seam. |
| Disposition | Open, `minor`. Recorded for completeness; the coordinator may reasonably close this as `info` if it prefers the docs reading. |

## Blind spots

- **`tamoz-telegram` transport internals were not read in this row.** The mapping from HTTP failures to `Comms::AmbiguousDeliveryError` is cited from the prior `comms-unknown-ordering.md` report rather than re-verified here; it is that row's evidence, and the F12 conclusions only assume the error class is reachable.
- **`test/comms_pairing_first_contact_test.rb`, `test/comms_deny_callback_test.rb`, `test/comms_evidence_gated_approval_test.rb`, `test/cancellation_visibility_test.rb`, and `test/canonical_cross_surface_composition_test.rb` were not run** — outside the assigned test surface and beyond the 45-minute budget. The pairing and callback conclusions in this report rest on source tracing, not on those suites.
- **No load, soak, or multi-host concurrency test exists or was run.** The two-process question was answered by source (`comms_outbox.rb:82-99`, `235-246`) plus two `/tmp` probes on the real `CommsOutbox` and `DeliveryDrainer`, not by running two gateway processes. A genuine two-process test against one SQLite file would strengthen F12's concurrency claim from `high` to `high` with runtime evidence; nothing in the probes contradicts it.
- **The `@controls` seam was traced only to its production caller**, which passes `nil` (`cli_comms_shared.rb:155-157`). I did not read what a real session-controls implementation does with the thread id it receives, so "the gateway never constructs a session" is proven for the gateway gem and its production wiring, not for every conceivable injected implementation.
- **Enola was not used.** The row's blast radius was small enough (13 files, one gem) that direct reading was cheaper than a snapshot round-trip.

## Verdict

**IMPROVE** — per BAR.md a functionality is `IMPROVE` when it has at least one accepted critical/major finding **or three or more accepted minor findings**. This row has **0 critical, 0 major (new), 5 minor, 0 info**, so it clears the threshold on the minor count.

Counting the carried-forward prior finding, the row's live picture is **0 critical / 1 major open (`comms-unknown-ordering.md`, unchanged and not re-litigated) / 5 minor open**.

All six lenses were reviewed with `file:line` evidence. The two headline security and durability claims both hold under source proof: the gateway constructs no session and opens no workspace file, and the drainer never blindly retries an ambiguous send — a stale owner is barred from the send boundary by a per-row fence, verified against the real store by probe. The prior ordering finding remains the row's most material issue and remains open at its existing owner seam.
