# Decision and implementation roadmap

This roadmap is intentionally ordered around user trust and evidence. It does
not authorize implementation by itself; each slice needs its own change brief,
bar, review, and gates.

## Decision table

| Decision | Choice | Reason |
| --- | --- | --- |
| Next user problem | Clarification, work-state truth, portable references, and recovery | These are current correctness or high-friction gaps in Telegram/CLI. |
| Execution model | Reuse Gateway, Session, Worker, EffectDispatcher, outbox, drainer, and SQLite | The prior study’s durable seams are the strongest evidence. |
| Human output | Typed bounded projection with surface-specific rendering | Semantic parity matters; byte-identical copy does not. |
| Progress | One editable/coalesced card plus meaningful transitions | More internal events would increase noise without adding meaning. |
| New channel | Defer; evaluate one local web or TUI adapter after gates | No evidence yet that a third channel is the limiting failure. |
| Approval | Keep policy/evidence authority; deny-only remains valid where required evidence is unavailable | UI cannot widen authority. |
| Unknown delivery | Explicit uncertain state; no unsafe blind resend | Duplicate external effects are a hard-zero risk. |

## Slice 0 — Close the interruption correctness defect

**Goal:** a clarification pause must never enter the approval-only evidence
contract or become channel silence.

**Existing seams:** Worker#settle_paused_view, OutboxDeliverySink#push,
ApprovalPrompt, session clarification descriptors, and existing CLI
prompt/answer flow.

**Required behavior:**

- preserve clarify versus approve_tool kind;
- project a bounded question and text-answer action;
- keep the same occurrence, caller, conversation, and expiry binding;
- leave an unanswered turn paused;
- keep approval evidence and one-use decision receipts unchanged;
- if a surface cannot answer, emit a typed unavailable notice rather than
  raising or pretending completion.

**Acceptance:** focused worker/sink test with a real clarify descriptor; no
KeyError; no approval keyboard/evidence lookup; one question row; same
occurrence resumes after a valid answer. Add a guarded Telegram observation
when credentials and a private chat are authorized.

**Hard zero:** a clarify descriptor cannot mint approval authority or be
discarded as a terminal answer.

## Slice 1 — Unify request ownership, handles, and worker health

**Goal:** make request-local truth and exact targeting authoritative before
making any new human card claimable.

**Existing seams:** CLI queue/ask commands, comms request/status operations,
CommsStore request/delivery/effect resolution, gateway commands, and
worker/launcher health.

**Required decisions:**

- choose one caller-bound short reference for operator-visible work;
- retain thread and occurrence IDs as internal authority handles;
- make cancel, redirect, and status echo the affected reference and resulting
  state;
- make delivery and effect summaries request-local when a request reference is
  supplied; keep conversation-wide aggregates separately named;
- define an explicit clarification answer ingress with occurrence, caller,
  conversation, expiry, and replay binding;
- choose whether admission queues or refuses when no worker is healthy;
- expose accepted, queued-without-worker, working, and waiting distinctly.

**Acceptance:** actual CLI subprocess test captures stdout/stderr/exit status,
reopens the database, and resolves the printed handle; equivalent Telegram
and CLI turns share semantic status; two open refs produce a hard-zero for
cross-target cancellation; request A cannot inherit request B's delivery or
effect state; a clarification answer resumes only its own occurrence; worker
death after admission is visible and recovery does not duplicate effects.

**Hard zero:** no human projection may be built over conversation-wide
delivery/effect aggregates or thread-wide cancellation.

## Slice 2 — Define the human projection

**Goal:** make every default update answer state, reference, now, next, and
delivery certainty without exposing diagnostics or model-authored authority.

**Dependency:** Slice 1 must first freeze request ownership, exact controls,
clarification ingress, and worker-health semantics. A card before that gate can
make the wrong request look complete.

**Existing seams:** lifecycle constants, OutboxDeliverySink, rendering,
Gateway::StatusProjection, and CLI rendering.

**Acceptance:** golden Telegram and CLI cards for accepted, queued, working,
waiting-clarification, waiting-approval, completed, failed, stopped, and
unknown. Each card has a stable ref and bounded copy; diagnostic JSON still
contains the durable fields; milestones do not enter history. A safe goal label
has a deterministic framework-owned source and redaction test.

**Design check:** use framework-owned phase templates. A model may supply task
answer content, but not lifecycle truth, approval rationale, or delivery state.

## Slice 3 — Recovery, reconnect, and attention budget

**Goal:** long work is calm but not silent, and returning users can recover
without guessing or resending.

**Existing seams:** outbox milestone coalescing, Telegram edit delivery,
CommsStore history/status, unknown-delivery resolution, CLI show/follow-up,
and gateway status.

**Default contract:**

- Telegram: one acceptance, one live card, at most two meaningful edits, one
  terminal card;
- waiting and terminal changes always interrupt quiet mode;
- status after a gap may show one “since you were away” card;
- unknown delivery is explicit and never automatically resent;
- CLI human mode uses the same semantic cards; JSON remains diagnostic.

**Acceptance:** C10/C13/C14-style tests record pushes versus edits, first
meaningful update, maximum silence gap, restart behavior, confirmed-only
history, and unknown resolution. Include actual Telegram receipts when
authorized.

## Slice 4 — Evidence and release gate

**Goal:** stop calling fixture plumbing an experience result.

**Existing seams:** OpenclawCommsRunner, scenario index/readiness, actual CLI
entry point, Telegram transport, worker process, and independent trace source.

**Required changes:**

- missing required surface or metric makes a scenario inconclusive/blocked;
- actual CLI parser/process/stdout/exit status is exercised;
- C2 uses controlled slow liveness; C4 covers declared restart moments; C8
  observes runner cancellation rather than stamping the store;
- callback acknowledgement and pairing command paths are observed;
- each real artifact binds durable receipts to an independent trace;
- Track B records provider/transport provenance and answer-quality rubric;
- comprehension, trust, actionability, annoyance, and recovery are reported
  separately from plumbing.

**Acceptance:** no publishable readiness result if a required cell is absent,
an unavailable metric is filtered, or the two witnesses diverge. A private
real Telegram/provider happy path is an entry gate, not proof of broad
readiness.

## Slice 5 — Future channel decision gate

Only start this slice if Slice 4 identifies a measured need that Telegram and
CLI cannot serve. Choose one local web or TUI adapter, not both by default.

**Entry criteria:**

- interruption, reference, worker-health, and unknown-delivery contracts pass;
- actual Telegram and CLI paths show semantic parity;
- capability descriptor and isolation tests pass;
- the user need is evidenced by comprehension, task completion, or recovery
  data;
- security and deployment ownership for the new surface are named.

**Exit criteria:** the new surface passes the same durable request,
identity/isolation, delivery ambiguity, restart, action authorization, and
human-comprehension gates. It does not add a second executor.

## Dependency graph

Slice 0 -> Slice 1 -> Slice 2 -> Slice 3 -> Slice 4 -> Slice 5 decision

Slice 4 can develop its harness in parallel after the scenario bar is frozen,
but it cannot declare product readiness before Slices 0–3 define what is being
measured.

## Rollout and rollback

- Roll out projection changes behind a versioned rendering/schema choice, with
  old rows untouched under the repository’s fresh-schema convention.
- Keep diagnostic output available during human-card rollout.
- Roll back human rendering to the last known bounded renderer if card
  serialization, redaction, or delivery tests fail.
- Do not roll back by replaying unknown unsafe sends. Resolve ambiguity through
  the existing operator path.
- For clarification, stop admission of new clarification waits if the typed
  projection gate fails; do not route them through approval as a fallback.
- A new channel must be disabled at configuration/admission without changing
  worker or durable request semantics.
