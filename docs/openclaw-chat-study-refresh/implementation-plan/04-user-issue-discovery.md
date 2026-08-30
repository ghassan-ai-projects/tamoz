# 15 chat issues from the user's point of view — and how we tackle them

Discovery pass written in the user's voice: what a real person actually
experiences using the chat today, why it happens (grounded in source), and how
this program tackles it. Each issue maps to a phase in `01-plan.md` and a
finding in `../05-open-findings-ledger.md`. This is discovery/planning — no code.

Severity is felt impact: **Blocker** (breaks the interaction), **High** (erodes
trust or wastes time), **Medium** (friction/annoyance).

| # | The user's experience | Severity | Why (grounded) | How we tackle it | Phase · Finding |
|---|---|---|---|---|---|
| 1 | "It asks me a question but I can't just answer — my reply starts a whole new task, or nothing happens." | Blocker | Clarification pause crashes before the question is sent (`worker.rb:720-734` → `decision_evidence` `KeyError`); plain text is admitted as a new request. | Split clarify from approval; deliver a bounded question; bind my **reply to the message** (or `/answer ref`) back to the same occurrence. | 0 · CF-1, CF-4 (I1) |
| 2 | "It says 'Accepted, I'll report progress' and then a few seconds later tells me it couldn't form a plan." | Blocker | `PlanRejectedError` after `max_plan_attempts: 3` → `crashed_text`, following the rich acceptance. | Hold the progress promise until a plan passes review; convert an unplannable task into a question, not a dead-end. | 0b · SD-2 (I5) |
| 3 | "Even a simple question gets treated like a big job." | High | Every admitted message runs the task lifecycle; no chat-vs-task routing. | Answer conversational/read-only turns directly — no acceptance card, no plan/review, and they can't hit the plan-failure path. | 0b · SD-1 (I4) |
| 4 | "The progress updates are meaningless to me — `r7f3: claimed`, `running`." | High | Telegram milestone text is literally `r<ref>: <phase>` (`outbox_delivery_sink.rb:123-161`). | Replace with a goal-oriented card: state, ref, what it's doing now, what's next. | 2 · DG-3 |
| 5 | "It goes silent for a long time and I can't tell if it's alive, stuck, or dead." | High | Gateway can accept while no worker runs; worker health is not a user-facing fact (`telegram.md:90-103`). | Expose accepted / queued-no-worker / working as distinct states; worker-unavailable always notifies (never a quiet heartbeat). | 1 · DG-2 |
| 6 | "When I have two tasks and type `/cancel`, I'm scared it cancels the wrong one — or both." | Blocker | `/cancel` stamps every admitted row on the thread (`comms_store.rb:987-994`); no ref target. | Exact-ref cancel; a bare `/cancel` with several open **lists them and asks which**, stamping none. | 1 · CF-3 (I2) |
| 7 | "I ask about one task and it shows me another task's delivery status." | High | `conversation_runtime_status` resolves delivery by conversation, not request (`comms_store.rb:522-528`). | Make status request-local; conversation-wide stays a separately named aggregate. | 1 · CF-2 |
| 8 | "I started something on Telegram; on my laptop CLI I can't find the same task." | High | Telegram `r<ref>`, CLI UUID/thread, `comms request` `R<ref>` — three handle spaces (`cli_worker_commands.rb:220-241`). | One caller-bound short reference across Telegram and the actual CLI; internal IDs stay in diagnostics. | 1 · DG-1 |
| 9 | "I come back an hour later and have no idea where any of my tasks stand." | High | Durable recovery works, but there's no user-facing return summary; must use operator commands. | Minimal honest `/status ref` after reopen (Phase 1); a bounded "since you were away" card (Phase 3). | 1→3 · I3, MG-1 |
| 10 | "It went quiet at the end — did my answer actually get delivered or not?" | High | Ambiguous sends become `unknown` and are (correctly) not retried, but the user sees only silence (`comms_outbox.rb:222-233`). | Show `delivery: uncertain` explicitly with a safe next action; never auto-resend, never render as delivered. | 3 · HZ-4, G7 |
| 11 | "'An action needs your approval' — what action? why? what happens if I say no?" | High | The approval card text is exactly `An action needs your approval.` (`outbox_delivery_sink.rb:212`). | A bounded, redacted explanation: what it would do, why it's waiting, what deny means — framework-owned, no raw prose. | 2 · Lane B |
| 12 | "There's only a Deny button — I can't approve from Telegram, so I'm stuck." | Medium | Approval is deny-only unless policy evidence is met (`outbox_delivery_sink.rb:253-265`). | Explain the safe operator route on the card; do not fake an approve button (authority is a policy/ADR decision, not UI). | 2 · G8 |
| 13 | "Pairing feels like bureaucracy — I don't know who has to act or when the code expires." | Medium | First-contact reply gives a code but not a compact who-acts/expiry model (`gateway_pairing.rb`). | Rewrite first-contact copy: who to send the code to, expiry, and how to know pairing completed. | 2 · Lane B |
| 14 | "I don't know what it remembers about me or our earlier chats." | Medium | `/context` prints storage facts — "fragments visible X of Y … preferences reasoning_depth=high" (`control_reply.rb:37-42`). | Translate `/context` into human meaning: what it will remember next turn, at category level; tie to Decision 4 (chat memory). | 2 · Lane B, Decision 4 |
| 15 | "It's either too chatty with tiny updates, or dead quiet — never the right amount." | Medium | Milestones are capped/coalesced for delivery, but there is no human attention budget (`comms_outbox.rb:22-24`). | One acceptance, one editable live card, ≤2 meaningful edits, one terminal card; waiting/terminal/worker-unavailable always notify. | 3 · MG-3 |

## Also tracked (beyond the 15, real but secondary)

- **"It's slow to even acknowledge me."** Latency of acceptance/first update.
  There is an existing investigation (`documentation/operations/ux-latency-investigation/`); this
  program's Decision 3 (two-stage receipt) and Decision 4 (small N) help, but
  latency has its own workstream. → cross-reference, don't duplicate.
- **"The CLI is silent while durable work runs."** Human CLI stream drops
  task/update parts (`cli.rb:387-449`). → MG-4, Phase 2.
- **"When I redirect, I can't tell what it dropped and what it kept."** Redirect
  doesn't summarize what was superseded. → Phase 1 control wording (I2 sibling).
- **"Error messages are generic."** `crashed_text`/`failure_text` are bounded but
  non-specific; Decision 2's clarification conversion replaces most of these
  with a real question. → Phase 0b.

## How the 15 cluster (so we fix causes, not symptoms)

- **Interaction is broken** (1, 2, 3, 6): the highest-severity cluster — can't
  answer, whiplash, over-planning, wrong-target controls. Fixed by Phases 0/0b/1.
  This is the sponsor's named gap and the first-tier work.
- **Can't tell what's happening** (4, 5, 15): meaning, liveness, and attention.
  Phases 1–3.
- **Can't trust the outcome or recover** (7, 9, 10): request-local truth, return,
  and delivery certainty. Phases 1/3.
- **Cross-surface and control confidence** (6, 7, 8): one handle, exact targets.
  Phase 1.
- **Under-explained moments** (11, 12, 13, 14): approval, pairing, memory copy.
  Phase 2.

Fixing the four interaction issues (1, 2, 3, 6) first removes the most
trust-destroying experiences; the rest raise the experience from "correct" to
"good," and none is claimable as improved until validated on a real path.
