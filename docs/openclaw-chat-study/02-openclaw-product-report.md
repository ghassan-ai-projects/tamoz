# OpenClaw communication: product and user report

## The user-visible model

OpenClaw makes an asynchronous agent feel trustworthy by answering four questions
for every message:

1. Did the system receive my request?
2. Is it working, waiting, or blocked?
3. What useful evidence of progress do I have?
4. What is the final state, and what should I do if it is uncertain?

The experience is not mainly a polished terminal or Telegram bot. It is a clear
agreement between the user and the system about work state.

## Why it feels useful

### Immediate acknowledgement without a false promise

The message appears optimistically in the TUI. The Gateway replies with a run ID
and `started`, not with a claim that the task is already finished. Telegram can
send an accepted or queued response before long work completes.

This removes the most common asynchronous-chat anxiety: “Did my message go
through, or should I send it again?”

### A visible state vocabulary

OpenClaw uses semantic states such as sending, waiting, streaming, running,
finishing context, idle, error, and aborted. The status line and elapsed time
make silence meaningful.

This is better than a generic spinner because each state answers a different
question and implies a different next action.

### Progress is evidence, not noise

Streaming previews, typing, tool starts, rolling tool rows, reasoning or command
status, and finalization tell the user that the system is alive. Progress can be
kept outside the durable transcript so the conversation remains readable.

The useful pattern is selective visibility: show enough to build confidence, but
do not make internal tool chatter the permanent conversation.

### Context control belongs to the user

`/status`, `/context`, `/usage`, `/think`, `/verbose`, `/trace`, `/new`, `/reset`,
and `/compact` turn hidden agent state into explicit controls. The user can
inspect context pressure, change the operating mode, start fresh, or compact
history without trying to phrase an implementation instruction as natural
language.

### Cancellation is an honest outcome

Escape, `/abort`, or a stop request can cancel a specific run or queued work.
Partial output that was already visible is retained; output that never became
visible is not falsely presented as delivered. The transcript records that the
run was aborted.

The user does not need to infer whether “stop” worked from a frozen spinner.

### Errors give a next action

OpenClaw distinguishes a known failure from a possibly accepted or still-running
operation. CLI failures are concise by default and provide recovery or doctor
hints. An ambiguous Gateway transport failure points to status and transcript
inspection instead of asking the user to blindly retry.

### Conversations have durable identity

The system keeps identity across Telegram users, groups, topics, accounts,
agents, and CLI sessions. A reconnecting client can reload history and in-flight
state, so a lost WebSocket is not the same thing as lost work.

## Key user journeys

| Journey | What the user experiences | Product lesson |
| --- | --- | --- |
| First DM | Unknown sender receives a pairing challenge and no agent work happens until access is granted. | Explain access state without leaking agent behavior. |
| Normal message | Message is acknowledged, assigned a run, shows progress, then resolves to a final reply. | Make admission and completion visibly different. |
| Long answer | One preview is edited; overflow becomes additional ordered messages. | Use the channel's strongest affordance without duplicating the answer. |
| Tool work | Progress rows or summaries show what is happening while the final transcript stays readable. | Separate transient work state from conversation history. |
| Approval | Allowed buttons appear, terminal state removes stale actions, and the tool does not run on timeout or invalid input. | Make permission a visible state machine, not a hidden prompt. |
| Cancellation | The current run and queued follow-ups can be stopped; partial visible output remains honest. | Define what stop means for already-visible work. |
| Context reset | `/new`, `/reset`, and `/compact` have direct, guarded behavior and explicit results. | Context lifecycle is a user feature. |
| Provider failure | The user sees a short reason and recovery guidance; partial streamed output is not erased. | Preserve evidence and state the next action. |
| Delivery ambiguity | The system avoids unsafe duplicate sends and makes uncertainty recoverable. | “Unknown” is better than a confident lie. |
| Multi-session use | Session identity follows the actual peer/topic/account, not just the process. | Conversation boundaries must be explicit. |

## Product principles to carry into Tamoz

1. **Acknowledge before you execute.** The user should know whether work is
   accepted, queued, rejected, or not yet admitted.
2. **Give every turn an identity.** Use it for status, cancellation, dedupe,
   transcript, and recovery.
3. **Render state, not internal machinery.** A worker process, lease, or journal
   is not a useful user message; “queued behind one task” is.
4. **Keep progress reversible and transient.** It should help the user follow
   work without polluting future context.
5. **Make controls first-class.** Help, status, new/reset, cancel, compact, and
   mode controls should never rely on model interpretation.
6. **Separate agent output from channel delivery.** “The agent finished” and
   “Telegram accepted the message” are different facts.
7. **Make uncertainty visible and actionable.** Give one recovery operation,
   not a generic retry suggestion.
8. **Keep the transcript trustworthy.** Preserve partial results, terminal
   outcomes, and identity; do not dedupe by answer text.
9. **Use one mental model across CLI and Telegram.** Surface details can differ,
   but accepted/running/paused/complete/failed/unknown should mean the same thing.
10. **Do not overclaim user value from plumbing tests.** Real model and live
    channel evidence must be labeled separately from deterministic coverage.

## What OpenClaw does not prove

The reviewed repository has strong deterministic coverage for protocol and
failure behavior, but that is not proof that every response is useful or that
the live Telegram experience always feels good. The five reviewers found no
single full live path proving Telegram receipt through real model/tool work to
real Telegram reply. Pairing, streaming, progress, restart recovery, and
multi-session behavior are supported primarily by focused tests and fixtures.

OpenClaw also assumes a trusted one-user Gateway domain. Session keys and
allowlists are not a hostile multi-tenant security boundary. Tamoz must not
adopt that assumption accidentally.

## The central design insight

The most reusable OpenClaw pattern is not “show a typing indicator” or “add more
slash commands.” It is the acknowledgement protocol:

```text
submitted -> accepted(run_id) -> queued/running -> progress -> terminal outcome
                                                    \-> unknown + recovery
```

Once this state model is real and durable, Telegram and CLI can render it in
different ways without becoming separate products.
