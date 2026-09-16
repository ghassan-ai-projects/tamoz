# CF06 request, worker, and multi-turn control routing — IMPROVE

Row / queue / baseline / analyst

- Row: **CF06** — request, worker, and multi-turn control routing.
- Queue: cross-gem flow inventory in `COVERAGE.md`.
- Code baseline: `audit-15-09` at `582ae55`, 2026-09-15.
- Analyst: coordinator direct read-only review after the cross-flow scanner. No
  subagent was used for this continuation.
- Scope: CLI lifecycle verbs, durable request enqueue/claim/recovery, worker
  occurrence settlement, paused/resume routing, cancellation, and reconnect.
- Budget: bounded source trace, existing challenge evidence, and focused
  contracts; no implementation.

## Source map and boundary

| Source | Lines | Boundary role |
|---|---:|---|
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb` | 29-61, 122-239 | ask/resume/continue/follow-up/redirect/cancel command submission |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb` | 209-350, 579-685 | durable driving, drain loop, stale rendering, session construction |
| `gems/tamoz-agent/lib/tamoz/agent/worker.rb` | 84-130, 227-340, 509-561, 635-777 | polling, open-occurrence priority, claim/recover, pause and terminal settlement |
| `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb` | 331-371 | durable open-occurrence records and runtime ownership |
| `gems/tamoz-agent-session/lib/tamoz/agent/session.rb` | 316-338, 409-419, 439-470 | lifecycle API, request delivery, resume guards and outcome projection |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_bindings.rb` | 17-25, 82-99 | task intake and cancellation terminal update |
| `gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb` | 25-206 | submit, FIFO claim, execute, recover, stale terminal failure, deliver |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_enqueuer.rb` | 17-35, 92-158 | canonical request identity, mode validation, idempotent enqueue |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_claimer.rb` | 18-37, 160-231 | fenced claim, early-turn deferral, stale failure, bounded candidate scan |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_rows.rb` | 24-71, 90-108 | durable history and one pending head per thread |

The flow has two durable control boundaries. CLI/session methods create a
request with a caller-owned id and an explicit operation/delivery pair. The
SQLite inbox canonicalizes the payload and input digest, inserts it
idempotently, and records the enqueue transition. `DurableRunner` opens a
fenced writer, asks the claimer for the next request, executes the graph, and
fetches the terminal request value. The worker adds the second boundary: an
open occurrence is durable work even when its request is no longer pending,
so it settles that occurrence before considering another queued request.

## Behavior path

1. `ask`, `resume`, and `continue` call `Session#start`, `#resume`, or
   `#continue`; follow-up constructs the canonical transcript payload before
   submitting a `:turn`; redirect and cancel submit a `:redirect` request with
   `delivery: :redirect` (`cli_session_commands.rb:29-61,122-239`). The request
   id is allocated before authority resolution on new turns, preserving the
   id used by any consumed transition.
2. `Session#deliver_turn` creates a run context and delegates to
   `DurableRunner#deliver` (`session.rb:409-419`). `deliver` first performs the
   idempotent enqueue, then runs the oldest eligible request and fetches the
   originally submitted request (`durable_runner.rb:177-206`). FIFO therefore
   remains a store property even when the caller's request is still queued.
3. `RequestInboxClaimer` validates the writer lease in the same transaction,
   scans the oldest eight non-terminal rows, skips only the explicit early
   `:turn` verdict (`latest checkpoint is not terminal`), and otherwise claims
   or terminal-fails the row under the same fence (`request_inbox_claimer.rb:
   160-231`). Request ids, operation/delivery modes, payload digests, and
   duplicate inputs are checked before the row becomes runnable.
4. `Worker#work_list` combines durable open occurrences with pending inbox
   heads. An open occurrence owns its thread slot; a queued request behind it
   is excluded until the occurrence settles (`worker.rb:227-255`). Claim and
   recovery both mark the occurrence before execution, and a crash-held
   `claimed`/`running` row re-enters `DurableRunner#recover` rather than
   starting a second execution (`worker.rb:509-542`).
5. A paused view is parked with a typed approval or clarification reason. A
   queued resume targeting that occurrence is detected from request history and
   sent through the same `run_next` seam (`worker.rb:289-333`). The CLI drain
   loop advances queued work first, then collects answers or continues a
   running view, and renders stale request failures once per request id
   (`cli.rb:261-350`).
6. Cancellation is an ordinary durable redirect carrying a cancellation task.
   `SessionBindings#intake` turns it into a terminal record with reason
   `cancelled_by_user`; the worker records the cancellation-observed point
   before settlement (`session_bindings.rb:82-88`; `worker.rb:544-561`). The
   current projection still routes by graph status alone, which is the source
   of carried F25-COR-01.

## Lens: correctness

Reviewed. Request identity is canonical and idempotent: a repeated id with
different operation, delivery mode, or payload digest raises a checkpoint
conflict. Claim-time stale validation is transactional, and the explicit early
turn exception preserves a message accepted while its predecessor is still
running. The worker's open-occurrence census prevents a new turn from racing a
paused or crash-recovering execution. The direct contracts below passed **98
runs / 1,138 assertions / 0 failures / 0 errors / 0 skips**.

The main correctness boundary remains **F25-COR-01**. `Worker#settle_view`
dispatches only on `view.status` (`worker.rb:677-688`), while cancellation
stores `terminal.reason = cancelled_by_user` alongside the graph's normal
completed status (`session_bindings.rb:82-88`). The independent F25 challenge
reproduced a `request.completed` delivery and a `completed` status projection
whose durable terminal reason says cancellation and unsatisfied verification.
The defect is carried under F25 and is not counted again here.

**F22-COR-01** is the session-side control defect: `--force cancel` can re-enter
`SessionBindings#intake` after a satisfied terminal checkpoint and overwrite the
latest terminal reason. `challenge-session-stream-gates.md` upheld it and
corrected the evidence to include the lost receipts/check status. CF06 carries
the finding because cancel is submitted and drained on this path; ownership
remains `tamoz-agent-session`.

## Lens: security and authority

Reviewed. Thread ids are validated before session-file paths are formed. Every
claim, recovery, and terminal transition is fenced by the writer lease, and a
redirect records its target execution and cancellation generation. The worker
has no headless approval shortcut: an approval or clarification stays parked
until a durable operator decision is available. Request payloads are decoded by
the closed checkpoint wire vocabulary, so an arbitrary operation cannot enter
the graph through the CLI.

The authority weakness is carried **F25-SEC-01** and its session component
**F22-SEC-01**. Worker restart reloads the profile by id without comparing the
recorded profile digest, and `Session#guard_state!` checks graph, skill, MCP,
egress, and behavior bindings but no profile digest (`session.rb:439-447`).
The profile-authority challenge upheld the critical worker finding. CF06 does
not introduce a second authority record.

CLI command validation is only a front door. `cmd_cancel` allows `--force`, and
the session/graph seam must therefore preserve terminal monotonicity even when
the caller bypasses the CLI precondition. The existing F22 challenge is the
evidence for that boundary. F24's parser/help defects are adjacent command
surface findings and remain owned by F24 rather than being recounted here.

## Lens: reliability and durability

Reviewed. Enqueue and transition writes are atomic; a stale claim becomes a
terminal request rather than an exception that can wedge the inbox. `run_next`
and `recover` use the same graph validator, and recovery re-enters the exact
request id under a fresh fenced writer. Worker restart reopens the durable
occurrence and settles it after the prior lease expires. Paused occurrences are
parked in memory only as a scheduling hint; the open-occurrence record is the
durable source used after restart.

The accepted major **F07-REL-01** is the material liveness defect crossing this
flow. `candidate_rows` limits the scan to eight rows. With eight deferred
early turns ahead of a valid queued resume, every candidate is skipped and the
resume remains unreachable; repeated `run_next` calls return `nil`. The
independent queue challenge reproduced the threshold and upheld the finding.
The worker's paused-resume path is otherwise correct, but it rides this same
claim seam, so CF06 carries F07-REL-01 without double-counting.

`Session#recover` also lacks the paused-with-live-interrupts precondition that
the CLI resume path enforces (**F22-REL-02**, minor, open). Fenced replay keeps
this bounded and no duplicate execution was observed; it remains a session
finding and is recorded as a control-entry gap here.

## Lens: observability and evidence

Reviewed. Worker events identify thread and request, durable request transitions
retain enqueue/claim/failure evidence, and stale failures are rendered once per
request id. `worker.started`/`worker.stopped` include lifecycle and processed
counts, while the CLI JSON envelope keeps stream identity and sequence. The
focused worker suite confirms a completed request emits the expected claimed,
completed, and stopped sequence; the reconnection contract confirms milestone
ordering and one terminal delivery after restart.

The terminal projection is not semantically complete for cancellation. A
supervisor can see `terminal.reason` in a session view, but the worker outbox
and status projection say `completed` because settlement keys on lifecycle
status. This is the observability side of F25-COR-01, already challenged and
owned by F25. The starvation path also has no distinct deferred-age event; that
absence is part of F07-REL-01's evidence gap, not a new CF06 count.

No real provider, MCP service, network endpoint, or external comms transport
was used. The tests prove durable plumbing and deterministic fixtures only.

## Lens: scalability and resource bounds

Reviewed. Worker concurrency is clamped to 1..32, each poll and pool has a
configured batch, pending-thread and open-occurrence queries take explicit
limits, and request payloads/ids are byte-bounded by the SQLite wire layer. The
CLI's drain loop is synchronous and joins each stream worker before advancing,
so it does not accumulate threads during ordinary multi-turn driving.

The bounded inbox scan is simultaneously the source of the F07 starvation
failure: a finite query is safe for database work but has no fairness escape
for a control request behind an arbitrary early-turn backlog. The CLI drain
loop has no independent iteration ceiling, but its liveness is governed by the
same `run_next` result and no separate runaway was reproduced. No sustained
load, large-thread census, or multi-process worker benchmark was run; those are
evidence limitations, not new findings.

## Lens: maintenance and architecture

Reviewed. Ownership is legible: CLI parses and renders, Session binds lifecycle
operations, DurableRunner owns graph execution, SQLite owns identity/claim
transactions, and Worker owns occurrence settlement. Existing controls are
reused rather than duplicated: follow-up uses the canonical transcript payload;
resume, continue, redirect, and cancel all use the same request inbox; stale
rendering is centralized in `drain_to_terminal`.

The maintenance risk is a split terminal vocabulary. `scheduled_terminal_status`
already reads `terminal.satisfied` (`worker.rb:607-622`) while `settle_view`
reads only `view.status`; cancellation therefore has two projections at one
boundary. The smallest design action is to define one terminal disposition
function at the worker/session seam and reuse it for event, status, schedule,
and CLI exit projections. This is the existing F25/F22 repair seam, not a new
CF06 abstraction.

The CLI also maintains separate parser/help lists and has the documented help
failures recorded by F24. CF06 uses those reports as adjacent evidence and
does not claim a second command-parser owner.

## Tests and contracts

- `ruby -Itest test/agent_worker_test.rb` → **25 runs / 122 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/sqlite_stale_request_test.rb` → **26 runs / 176 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/sqlite_request_inbox_test.rb` → **8 runs / 46 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/agent_cli_test.rb` → **34 runs / 764 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/graph_resume_answers_test.rb` → **2 runs / 7 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/reconnection_resume_protocol_test.rb` → **1 run / 18 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/graph_durable_request_executor_test.rb` → **2 runs / 5 assertions / 0 failures / 0 errors / 0 skips**.

The worker suite covers open-occurrence restart, paused approval followed by a
queued turn, bounded multi-thread processing, and failure containment. The
SQLite suites cover early-turn deferral, stale resume/continue/fork failure,
FIFO unblocking, request idempotency, and redirect waiting. The CLI suite
covers continue, follow-up payload identity, redirect, cancel, and reconnect
entry points. None covers the eight-deferred-turn starvation threshold or the
worker terminal projection for cancellation; those gaps are exactly the
carried F07/F25 findings.

## Findings and disposition

No new machine-counted CF06 defect is added. Existing cross-boundary findings
are carried with their original owners and challenge evidence:

| Finding | CF06 disposition | Owner / evidence |
|---|---|---|
| F07-REL-01 | **Open major, upheld.** Eight early turns can make a valid queued resume unreachable; no duplicate count. | `RequestInboxClaimer#candidate_rows`; `challenge-queue-comms-schedule.md` |
| F25-COR-01 | **Open major, upheld.** Cancellation can be delivered as completed/verified. | `Worker#settle_view`; `challenge-f25-runtime.md` |
| F25-SEC-01 | **Open critical, upheld.** Restarted worker can widen profile authority. | `WorkerRuntime#session_for`; `challenge-profile-authority.md` |
| F22-COR-01 | **Open major, upheld.** Forced cancel can overwrite a satisfied terminal verdict. | `SessionBindings#intake`; `challenge-session-stream-gates.md` |
| F22-SEC-01 | **Open major, carried component.** Session stores but does not re-check profile digest. | `Session#guard_state!`; `F22-agent-session.md` |
| F22-REL-02 | **Open minor.** Public recovery entry lacks the resume interrupt precondition. | `Session#recover`; `F22-agent-session.md` |
| F24-ERR-01 / F24-ERR-02 / F24-ERR-03 | **Adjacent CLI findings; no CF06 duplicate.** Read-only model coupling and help/parser failures remain in F24. | `F24-agent-cli.md` |

## Blind spots and verdict

- No eight-row-plus starvation probe was rerun in this wave; the committed F07
  reproduction and challenge were read, and the exact `LIMIT 8` source path
  was rechecked.
- No end-to-end worker cancellation probe was added; the committed F25
  worker-to-outbox probe and independent challenge remain the evidence.
- No paused-with-live-interrupts `Session#recover` probe was run; F22 keeps
  medium confidence for that precondition gap.
- No concurrent worker race, multi-process lease test, large backlog benchmark,
  real model, network service, or external transport was used.
- No production code, tests, configuration, or generated artifact was changed.

**IMPROVE** under `BAR.md`: all six lenses and the complete CLI → Session →
DurableRunner → SQLite → Worker trace are reviewed, but the flow crosses the
open major/critical starvation, cancellation-projection, and profile-authority
findings listed above. CF06 adds no duplicate machine-counted finding.
