# Iteration 2 — Simple Telegram message

## Journey analyzed

Input: an allowlisted user sends "hi, what is the capital of France?" to the bot.
Gateway (`tamoz comms serve`) and one worker (`tamoz worker`) are running.

Expected experience: an acknowledgement within a second or two (typing indicator
or "on it"), the answer within one model round-trip, and a visible distinction
between queued / running / done.

Observed outcome **[supported]** (full source trace; no live bot was run — the
channel requires operator config and live sends are outward-facing, so per-stage
times below are derived from code constants, marked accordingly): the message
takes the identical durable path as any task, and the user sees **nothing** until
the terminal answer.

This is the pre-implementation baseline. The deterministic follow-up now emits an
accepted acknowledgement, drains outbound rows independently, and handles typed
`/help`, `/status`, and `/cancel` controls. The historical timing and findings below
remain unchanged evidence of the original defect; current implementation status and
the unmeasured real-provider boundary are in
[`IMPLEMENTATION_EVIDENCE.md`](IMPLEMENTATION_EVIDENCE.md).

## Lifecycle trace (all stages confirmed in source)

Telegram update → gateway long-poll (`transport.rb:35-43`, 30 s timeout) →
synchronous admission, one SQLite transaction per message
(`comms_store.rb:88-119`) → request inbox row (`tamoz_requests`, `operation:
'turn'`, payload `{"task" => text}`) → worker pickup (idle poll 1.0 s,
`worker.rb:35`) → full durable session: intake → deliberate (plan + semantic
review) → step_gate → step_execute → evaluate → verify → terminal
(`session.rb:341-366`), ~17 synchronous SQLite transactions on top of the model
calls (iteration 1, benchmark: 8 checkpoints + ~9 effect-journal transactions) →
terminal answer projected into durable outbox before occurrence close
(`worker.rb:419-420,471-473`) → gateway drains outbox **only after its current
long-poll returns** (`comms_gateway.rb:90`) → one `sendMessage`
(`comms_gateway.rb:240-280`).

## Latency breakdown

| Stage | Time | Basis |
|---|---|---|
| Telegram → gateway admission | ~0–1 s (long-poll returns immediately when an update exists) | **[supported]** long-poll semantics, `transport.rb:35-43` |
| Admission → durable inbox | ms per message, sequential per batch | **[supported]** `comms_store.rb:88-119` |
| Acknowledgement to user | **never sent** | **[supported]** `outbox_delivery_sink.rb:29-32` — `request.accepted` deliberately dropped, "terminal answers are the only messages"; no `sendChatAction` anywhere in `gems/` (the `signal` seam exists, `transport.rb:63-68`, and is never called) |
| Inbox → worker pickup | ≤ ~1 s idle poll | **[supported]** `worker.rb:35` |
| Turn execution (simple question) | 6–16 s live (measured CLI equivalents: 5.1–16.4 s) + ~41 ms durability overhead | **[measured]** iteration 4; **[supported]** same deliberation graph runs in worker (`worker.rb:370-377`) |
| Progress updates during execution | **none exist** | **[supported]** design §11: "V1 does not stream token progress" (`COMMS_DESIGN.md:592`) |
| Answer ready → outbox drain | **up to 30 s + 1 s** if the gateway is parked in a quiet long-poll | **[supported]** `comms_gateway.rb:50-60,90` — drain runs only inside `serve_once` after `getUpdates` returns |
| Delivery | one send; receipt persisted | **[supported]** `comms_gateway.rb:240-280` |

Expected total for a one-word answer: ~7–18 s typical, **worst case ~48 s** of
which up to 31 s is the answer sitting in a durable outbox while the gateway
sleeps in `getUpdates`. Time to acknowledgement: ∞ (none exists). Time to first
visible anything: total completion time.

## Completion breakdown

The turn machinery itself reaches truthful terminal states (occurrence closed
with answer durable before close). But the *delivery* leg has no such guarantee:
a send timeout becomes `AmbiguousDeliveryError` → outbox row `unknown`, **never
retried**, resolvable only by an operator running `tamoz comms delivery resolve`
(`comms_gateway.rb:278-279`, `cli_comms_ops.rb:197-228`). Task complete, answer
produced, user never receives it — and nobody is alerted. **[supported]**

## Five Whys

Symptom: Telegram feels slow and silent.

1. Why silent? No ack, no typing indicator, no progress messages.
2. Why don't they exist? v1 deliberately drops `request.accepted` and streams
   nothing; the `signal`/typing seam was built but never wired.
3. Why was that acceptable? The channel was designed around durable terminal
   answers (correctness first); perceived latency had no design owner — there is
   no acknowledgement/progress requirement anywhere in the comms design's
   enforced invariants.
4. Why does a delivered answer add up to 31 s? Outbox draining is sequenced
   behind the inbound long-poll in the same single-threaded loop — outbound work
   waits on inbound weather.
5. Why is a simple chat as slow as a task? No classification (iteration 1):
   every admitted message becomes a full durable occurrence with plan/review/
   verify. Root cause: **the channel has no user-feedback contract, and the
   request path has no conversational class; both are policy absences, not
   transport limits.**

## Findings

| # | Finding | Severity | Frequency | Confidence | Components | User impact |
|---|---|---|---|---|---|---|
| 2.1 | No acknowledgement, typing indicator, or progress update; `request.accepted` intentionally dropped | Critical | Every message | **[supported]** | `outbox_delivery_sink.rb:29-32`, `transport.rb:63-68` | Users cannot distinguish "working" from "dead"; perceived latency = total latency |
| 2.2 | Outbound answers wait behind the inbound long-poll: up to ~31 s added delivery latency when quiet | High | Every answer sent during quiet periods | **[supported]** | `comms_gateway.rb:50-60,90` | Random-feeling extra delay uncorrelated with task size |
| 2.3 | Failed/ambiguous sends never retried; answer strands in `unknown` until manual operator resolution | High | Rare but unbounded in impact | **[supported]** | `comms_gateway.rb:278-279`, `comms_outbox.rb:57-59` | Completed work silently never reaches the user |
| 2.4 | `/status`, `/cancel`, `/help` are parsed but execute nothing and reply nothing | High | Every status/cancel attempt | **[supported]** | `admission.rb:63-68`, `comms_gateway.rb:132-135` | No way to ask "what's happening" or stop a task |
| 2.5 | Approval prompt is deny-only, generic ("An action needs your approval."), no callback ack, silent expiry; the button spins and pressing it late does nothing with no feedback | Medium | Every approval | **[supported]** | `outbox_delivery_sink.rb:121`, `comms_gateway.rb:149-170` | Confusing approval UX; user can't tell what they're denying |
| 2.6 | Strict per-conversation FIFO + default 1 worker: a second message queues invisibly behind a running task | Medium | Concurrent use | **[supported]** | `request_inbox_rows.rb:90-108`, `worker.rb:36` | "hi" sent during a long task is answered only after it finishes, with no queue notice |
| 2.7 | Long answers: split at 3500 chars × max 5 parts, overflow silently truncated (no marker despite design requiring one) | Medium | Long answers | **[supported]** | `rendering.rb:41-52` vs `COMMS_DESIGN.md:611-613` | Answers silently incomplete |
| 2.8 | No formatting (`format: plain` only; no parse_mode) | Low | Every message | **[supported]** | `outbox_delivery_sink.rb:72-76` | Dense wall-of-text answers |

## Recommended change (behavior, not code)

- Define a **user-feedback contract** for the channel: (a) immediate
  acknowledgement on admission (message or typing action — the transport seam
  already exists); (b) periodic progress while a turn runs beyond a threshold;
  (c) a truthful terminal message for *every* terminal state including budget
  stops and failures (today budget exhaustion closes the occurrence without
  notifying the sink, `worker.rb:301-320`); (d) delivery retry with backoff for
  ambiguous sends instead of operator-only resolution.
- Decouple outbox draining from the inbound long-poll (drain on a short timer
  or on outbox write notification), eliminating the up-to-31 s quiet-period
  penalty.
- Wire the already-parsed `/status` and `/cancel` commands to real effects so
  users can see queued/running state and stop work.
- Route conversational messages to the fast path from iteration 1 so chat
  doesn't pay durable-occurrence + plan/review costs.
- Tradeoffs: progress messages multiply Telegram API calls (rate limits);
  retries risk duplicate sends (mitigated by the existing content-derived
  delivery ids). Approval richness increases prompt surface — keep deny-only
  authority but make the prompt describe the pending action.

## Validation plan

- Staged channel with a scripted transport (the scorecard already drives channel
  cases through test clients): assert ack ≤ 1 poll cycle after admission,
  progress message cadence, terminal message for every stop reason, and retry of
  an ambiguous send.
- Measure stage latencies from existing columns (`ingested_at_ms`,
  `tamoz_request_transitions`, outbox `created_at_ms`/`updated_at_ms`, receipt
  `platform_time`) — the data is already stored; only the queries are missing.
- Thresholds: chat answer visible ≤ 5 s p50 end-to-end (with fast path);
  delivery-leg latency ≤ 2 s p95 after outbox write.

## Open questions

- Live Telegram polling behavior (429s, real network jitter) — unmeasured;
  requires an operator-configured staging bot. Not blocking: every finding above
  rests on source-confirmed mechanics.

## Next iteration

Complex multi-step task completion — why tasks fail to finish, with live and
scorecard evidence.
