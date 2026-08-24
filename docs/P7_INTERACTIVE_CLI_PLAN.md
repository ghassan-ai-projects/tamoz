# P7 — Interactive and Resumable CLI

## 1. Authoritative inputs, scope, and non-goals

### 1.1 Authority

This plan is derived from:

- `docs/PROJECT_HANDOVER_PLAN.md` §P7 (outcome, work packages P7-D/A/B/C/E, product proof, stop/redesign criteria).
- `docs/design-v0.1/TAMOZ_AGENT_DESIGN.md` §§3–5, 8 (turn lifecycle, surfaces, first milestone).
- `docs/design-v0.1/AGENT_DESIGN.md` §§5 and 8 (approval/authorization, compaction, hooks).
- `docs/design-v0.1/GRAPH_DESIGN.md` sections on interrupts, request inbox, durable runner, and checkpointing.
- `docs/design-v0.1/PERSISTENCE_DESIGN.md` sections on request inbox, lease/fence, checkpoint store.
- `docs/design-v0.1/INVARIANTS.md` clauses 23, 25–27, 52–55.
- Existing code:
  - `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb` (one-shot CLI)
  - `gems/tamoz-agent/lib/tamoz/agent/session.rb` (P6 durable session API)
  - `gems/tamoz-agent/lib/tamoz/agent/session_nodes.rb` (`step_gate` interrupts)
  - `gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb` and `request_record.rb`
  - `gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_store.rb` and `lease.rb`
  - `gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb`
  - `bin/tamoz-eval`, `gems/tamoz-agent-cli/exe/tamoz`

### 1.2 Scope

P7 turns the one-shot `tamoz` executable into a durable, interactive, resumable CLI while preserving the existing one-shot path. One stable session (thread) supports:

- clarification
- approval
- follow-up turns
- redirect
- cancellation
- continuation
- `--resume` over P6

### 1.3 Non-goals

- No TUI, ncurses, gateway, daemon, or chat-channel abstraction.
- No agent policy or tool logic moves into the CLI.
- No new dependency without explicit justification.
- No second session model; all durable work goes through `Tamoz::Agent::Session`.

---

## 2. CLI command surface

### 2.1 Choice: subcommands with backward-compatible bare invocation

Subcommands are clearer than flags for operations that target a thread (`resume`, `show`, `cancel`, `redirect`). They also keep the help surface discoverable as the CLI grows.

Bare `tamoz [options] TASK` remains the existing one-shot `Tamoz::Agent::Runtime` invocation. It is **not** reinterpreted as `tamoz ask`; it is non-durable and behavior-identical to P6. Durability is opt-in via `tamoz ask --session NAME TASK`, `tamoz --session NAME TASK`, or `tamoz resume NAME`.

### 2.2 Surface

```
tamoz [global-options] ask [ask-options] TASK
tamoz [global-options] resume THREAD [resume-options]
tamoz [global-options] continue THREAD
tamoz [global-options] list
tamoz [global-options] show THREAD [--transcript N]
tamoz [global-options] follow-up THREAD TASK
tamoz [global-options] redirect THREAD "new task"
tamoz [global-options] cancel THREAD [--force]
tamoz [global-options] resolve THREAD EFFECT_KEY {succeeded|failed|abandoned}
tamoz --version
tamoz --help
```

### 2.3 Global options

| Flag | Env | Default | Meaning |
|------|-----|---------|---------|
| `--model MODEL` | `TAMOZ_MODEL` | required | RubyLLM model identifier |
| `--provider PROVIDER` | `TAMOZ_PROVIDER` | `openai` | Provider |
| `--root PATH` | `TAMOZ_ROOT` | `Dir.pwd` | Workspace root |
| `--session-dir PATH` | `TAMOZ_SESSION_DIR` | platform default (see §3.2) | Durable store directory |
| `--session NAME` | `TAMOZ_SESSION` | generated | Explicit thread name |
| `--json` | — | false | NDJSON event output |
| `--allow-changes` | — | false | Enable reviewed/approved mutations |
| `--check NAME=COMMAND` | — | — | Configured verification command (requires `--allow-changes`) |
| `--assume-model-exists` | — | false | Allow unlisted model at custom endpoint |
| `--non-interactive` | — | false | Fail instead of prompting; requires `--answer` or pre-approved mode |

### 2.4 Ask options

| Flag | Meaning |
|------|---------|
| `--session NAME` | Use or create named thread |

### 2.5 Resume options

| Flag | Meaning |
|------|---------|
| `--answer ANSWER` | Non-interactive answer to the current interrupt |
| `--all` | Non-interactive only: approve all pending interrupts. Requires `--non-interactive` plus a separate dangerous opt-in (`--i-understand-approve-all`) and emits an `audit.approve_all` CLI event. |
| `--recover` | Force `Session#recover` before resuming |

### 2.6 Exit codes

| Code | Meaning |
|------|---------|
| `0` | Satisfied / completed |
| `1` | Agent/graph/runtime error |
| `2` | Completed but not satisfied |
| `3` | Paused / waiting for user input |
| `64` | Usage error |
| `130` | Cancelled by SIGINT |
| `143` | Cancelled by SIGTERM |

Exit code `3` is new and lets shell scripts detect an interrupt seam.

---

## 3. Session identity and storage layout

### 3.1 Identifiers

- `thread_id` — stable session identifier. Persistent across restarts. Generated from a URL-safe base64-encoded 12-byte random value if not supplied, e.g. `th_8XqR3mKpL9vW`. User-supplied `--session` names are normalized and validated (`^[A-Za-z0-9_\-\.]{1,64}$`).
- `request_id` — one per turn/resume/redirect/cancel operation. UUIDv4 by default. Exposed in `--json` events and `show` output.
- `owner_id` — one per CLI process invocation. UUIDv4. Passed to `Session#start/resume/continue/recover` to acquire the lease.

### 3.2 Storage layout

Default `--session-dir` is resolved in XDG order:

- If `TAMOZ_SESSION_DIR` is set, use it.
- Otherwise, on macOS use `~/Library/Application Support/tamoz/sessions`.
- Otherwise, fall back to `${XDG_STATE_HOME:-~/.local/state}/tamoz/sessions`.

The CLI creates the directory if it does not exist with mode `0700` (owner read/write/execute only), matching the SQLite file mode `0600` from `PERSISTENCE_DESIGN.md` §6. If creation cannot set `0700`, the CLI exits with a usage error.

```
$TAMOZ_SESSION_DIR/
  <thread_id>.sqlite3
  <thread_id>.sqlite3-journal   (SQLite transient)
  lock/                         (optional advisory lock files)
```

Each thread maps to one `Tamoz::SQLite::Adapter` file. The CLI opens the adapter, binds the graph checkpoint codec, and constructs a `Session`.

### 3.3 Adapter lifecycle in the CLI

```ruby
adapter = Tamoz::SQLite::Adapter.new(
  path: File.join(session_dir, "#{thread_id}.sqlite3"),
  limits: Tamoz::SQLite::Limits.new(lease_ttl: 30.0)
)
checkpointer = adapter.bind_graph(checkpoint_codec: Tamoz::Graph::CheckpointCodec.new)
session = Tamoz::Agent::Session.new(
  model:,
  toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes:, checks:),
  checkpointer:
)
```

The adapter is closed cleanly on normal exit. On `SIGINT`/`SIGTERM`, the handler cancels the run's `Tamoz::CancellationToken` (see §10.4); the current durable request finishes its checkpoint append, then the CLI exits. `kill -9` is safe because the next owner recovers the lease and request.

### 3.4 Stream/emitter contract

`Session#start`, `Session#resume`, and `Session#continue` currently return a `SessionOutcome`; they do not return a stream. For P7 the CLI must observe graph events (run start/end, task start/end, interrupts, checkpoints, custom agent events) as real `Tamoz::StreamPart`s. The contract is extended so that `Session` accepts an emitter/sink block, and `DurableRunner` propagates that emitter into the `Context` used by `Compiled#execute_durable_request`.

Concretely:

- `Session#start`, `Session#resume`, and `Session#continue` gain an optional `emitter:` keyword. The value is a `Tamoz::Graph::Emitter` or any object responding to `emit(type, namespace, data, run_id:, task_id:)`.
- Internally, `Session` constructs a `Tamoz::CancellationToken` and a `Tamoz::Graph::Context` (or uses the `context:` parameter) and passes both to `DurableRunner#run_next`/`deliver` via the new `context:` keyword. `DurableRunner` forwards them into `Compiled#execute_durable_request`, which already builds a `run_context` with `cancellation:` and `emitter:` (see `compiled.rb:631-767`).
- The CLI provides a blocking `StreamSink`/`EventStream` consumer (see `compiled.rb:89-166`, `event_stream.rb:1-104`, `stream_emitter.rb:1-58`) and iterates over the yielded `Tamoz::StreamPart`s. `StreamEmitter` filters the parts; `mode: :all` is used for `--json`, and a human-friendly projection (`:tasks`, `:updates`, `:interrupts`, `:checkpoints`, plus `:errors`) is used for human mode.
- CLI-specific events (`cli.session`, `cli.prompt`, `cli.answer`, `cli.paused`, `cli.resumed`, `audit.approve_all`) are emitted by the CLI itself into the same NDJSON sink or printed to `stderr`; they are not a parallel event source inside the graph.
- For `--json`, the CLI emits one NDJSON line per `StreamPart`. For human mode, it renders progress from `:task_start`, `:node_update`, `:tool_started`, etc., and prompts on `:interrupt`.

```ruby
sink = Tamoz::Graph::StreamSink.new(
  capacity: Tamoz.configuration.stream_buffer,
  cancellation:,
  clock: Tamoz::Clock.monotonic,
  run_id:
)
emitter = Tamoz::Graph::StreamEmitter.new(sink:, mode: :all)
thread = Thread.new do
  session.start(
    task,
    thread: thread_id,
    request_id:,
    owner_id:,
    emitter:
  )
end
sink.each { |part| render(part) }
```

This reuse avoids inventing a parallel event source and keeps the CLI a consumer of the existing `Tamoz::StreamPart` contract.

---

## 4. Task mapping to `Session#start` and `resume`

### 4.1 New task: `tamoz ask "..."`

1. Normalize thread id.
2. Open or create SQLite adapter.
3. Build `Session`.
4. Generate `request_id` and `owner_id`.
5. Start a stream consumer with a `StreamSink`/`StreamEmitter` and call `session.start(task, thread:, request_id:, owner_id:, emitter:)` in a worker thread.
6. Render stream events; on `:interrupt`, collect answers.
7. If outcome is `:paused`, prompt for answers, call `session.resume(...)` with a new `request_id`, loop.
8. If outcome is `:blocked`, explain the blocked effect, print the resolution command, and exit `3`.
9. If outcome is `:completed`, print answer and verification.
10. After the current request finishes terminal, drain the queue: call `session.runner.run_next(thread:, owner_id:)` in a loop (with the same emitter/cancellation context) until it returns `nil` or a non-runnable request.

### 4.2 `resume` semantics

`tamoz resume THREAD`:

1. Open adapter for `THREAD`.
2. Call `session.view(thread:)` to inspect status and interrupts.
3. If status is `:paused`:
   - For each interrupt, render descriptor and read answer from stdin or `--answer`.
   - Build answer map `{task_id => {call_index => value}}`.
   - Call `session.resume(answers, thread:, request_id:, owner_id:, emitter:)`.
4. If status is `:running`:
   - Call `session.continue(thread:, request_id:, owner_id:, emitter:)`.
5. If status is `:blocked`:
   - Print the blocked effect and tell the user to run `tamoz resolve THREAD EFFECT_KEY {succeeded|failed|abandoned}`; exit `3`.
6. If status is `:completed`/`:failed`, `show` a summary and exit accordingly.
7. Loop while new interrupts appear.
8. After the resumed/continued request finishes terminal, drain the queue as in §4.1 step 10.

### 4.3 Backward-compatible one-shot mode

Bare `tamoz [options] TASK` remains the existing one-shot, non-durable `Tamoz::Agent::Runtime` invocation. It does not create a session file and does not accept `--resume` or `--follow-up`. This preserves P6 behavior exactly.

- `tamoz TASK` → ephemeral `Runtime` run (existing behavior).
- `tamoz --session NAME TASK` or `tamoz ask --session NAME TASK` → durable `Session`.
- `tamoz resume NAME` → durable `Session`.

This satisfies "preserve existing one-shot CLI behavior; new flags are additive."

---

## 5. Interrupt rendering and answer flow

### 5.1 Interrupt descriptors

The CLI receives `:interrupt` stream events with:

```json
{
  "graph": "tamoz.agent.session",
  "task_id": "<task id>",
  "call_index": 0
}
```

To render details, the CLI correlates `task_id`/`call_index` with `SessionView#interrupts`, which holds the full `Interrupt` records including the descriptor.

Descriptor for `approve_tool` (from `session_nodes.rb:242-253`):

```json
{
  "kind": "approve_tool",
  "session_id": "...",
  "plan_id": "...",
  "plan_digest": "...",
  "step_id": "...",
  "tool": "apply_patch",
  "arguments": { ... },
  "preview": "...",
  "arguments_digest": "...",
  "preview_digest": "..."
}
```

Kinds rendered by the CLI:
- `approve_tool`: show tool, preview, and ask `[y/N/a/d/?]`.
- `clarify`: show question and read free-text answer.
- `resolve_effect`: show effect key and ask `[fixed/skipped/unknown]`.

Descriptor for `clarify` (P7-B adds this branch in `SessionNodes#deliberate`):

```json
{
  "kind": "clarify",
  "session_id": "...",
  "plan_id": "...",
  "plan_digest": "...",
  "question": "<the question text>",
  "context": { "phase": "discovery", "repair_attempt": 0 }
}
```

When the semantic review returns `decision: "needs_input"`, `deliberate` emits a `clarify` interrupt instead of raising `PlanRejectedError`. The CLI resumes by supplying a non-empty string answer, which `deliberate` treats as additional evidence and replans (or, if the answer is sufficient, proceeds to `step_gate`).

P7-B graph change: implement the clarification flow **inside the existing `deliberate` node** (no new branch or node target) to preserve the graph definition digest and P6 resume compatibility.
1. When the semantic review returns `decision: "needs_input"`, `deliberate` builds the `clarify` descriptor and calls `Tamoz.interrupt(descriptor, context)`.
2. On resume, the answer is appended to `observations` as a `clarify` observation record and `deliberate` returns `next_node: "deliberate"` to replan using the new evidence.
3. If the same clarify interrupt is answered more than once, raise `InvalidUpdateError` to prevent loops.

### 5.2 Prompt validation, not policy

The CLI validates only that the answer is one of the positional choices allowed for the descriptor kind:

| Kind | Allowed answers | Mapped resume value |
|------|----------------|---------------------|
| `approve_tool` | `y`, `yes`, `a`, `approve` | `true` |
| `approve_tool` | `n`, `no`, `d`, `deny` | `false` |
| `approve_tool` | `?`, `h`, `help` | CLI shows help and re-prompts |
| `clarify` | any non-empty string | string |
| `resolve_effect` | `fixed`, `approve`, `ok`, `succeeded`, `yes` | `:succeeded` |
| `resolve_effect` | `skipped`, `deny`, `no`, `abandoned` | `:abandoned` |
| `resolve_effect` | `failed` | `:failed` |
| `resolve_effect` | `unknown`, `?` | no-op; the effect remains unresolved and the session stays `:blocked` |

The CLI never decides whether a tool is safe; that remains in `Toolbox#approval_required?` and the policy wrapper.

### 5.3 Resume answer map

`Session#resume` expects a Hash shaped like:

```ruby
{
  "<task_id>" => {
    0 => true,
    1 => "clarification text"
  }
}
```

The CLI builds this map by collecting all pending interrupts from the view, prompting, and then calling resume once with all answers.

### 5.4 EOF behavior

- If stdin reaches EOF while interrupts are pending:
  - In non-interactive mode (`--non-interactive` or stdin not a TTY): exit `3` with a JSON event `{ "type": "paused", "reason": "eof" }`.
  - In interactive mode: print a message, save the session state, and exit `3`.

---

## 6. Event/StreamPart schema for CLI output

### 6.1 JSON mode (`--json`)

The CLI emits newline-delimited JSON. Each line is a JSON object with at least `type` and `data`. Types are drawn from `Tamoz::StreamPartContract::CORE_TYPES` plus CLI-specific wrappers.

Core event types already emitted by the graph/agent:

| Type | Source | Data |
|------|--------|------|
| `run_start` | executor | graph, thread_id |
| `run_end` | executor | graph, thread_id, status |
| `task_start` | executor | task_id, node |
| `task_end` | executor | task_id, status |
| `node_update` | executor | graph, node, channels |
| `interrupt` | executor | graph, task_id, call_index |
| `checkpoint` | executor | graph, checkpoint_id, sequence, status |
| `effect_unknown` | effect dispatcher | effect_key |
| `error` | various | message, class |
| `custom` | runtime | type-specific |

Agent/runtime custom events currently include:

| Type | Data |
|------|------|
| `task_started` | task |
| `plan_drafted` | attempt, phase, plan |
| `plan_reviewed` | layer, decision |
| `repair_started` | repair_attempt, observations |
| `repair_stopped` | repair_attempt, reason, ... |
| `tool_started` | tool |
| `tool_progress` | ... |
| `tool_end` | ... |
| `completed` | answer, satisfied, evidence |

### 6.2 CLI-specific JSON events

P7 adds:

```json
{"type":"cli.session","data":{"thread_id":"th_...","request_id":"...","status":"paused"}}
{"type":"cli.prompt","data":{"kind":"approve_tool","task_id":"...","call_index":0,"preview":"..."}}
{"type":"cli.answer","data":{"task_id":"...","call_index":0,"value":"approve"}}
{"type":"cli.paused","data":{"reason":"interrupt","thread_id":"..."}}
{"type":"cli.resumed","data":{"thread_id":"...","request_id":"..."}}
{"type":"audit.approve_all","data":{"thread_id":"th_...","request_id":"...","count":3,"opt_in":"i-understand-approve-all"}}
```

### 6.3 Human mode (default)

Human output goes to `stdout` for progress and `stderr` for prompts. Example:

```
$ tamoz --session fix-bug --allow-changes --check answer=ruby test.rb "set value to 2"
Session: th_8XqR3mKpL9vW
Plan 1 (discovery):
  - Read app.rb [read_file]
Review (structural): accept
Review (semantic): accept
Plan 2 (action):
  - Patch app.rb [apply_patch]
  - Run check [run_check]
Approval required for apply_patch:
  --- preview ---
  +value = 2
  ---------------
Approve apply_patch? [y/N/?] y
Running apply_patch...
Running run_check...

Done. Broken.answer is 42.
Verification: satisfied
```

---

## 7. Redirect and cancellation semantics

### 7.1 Redirect

`tamoz redirect THREAD "new task"` enqueues a redirect request. The durable inbox supports `operation: :redirect` with `delivery: :redirect` (see `PERSISTENCE_DESIGN.md` §5 and `checkpoint_store.rb:353-448`). The flow is:

1. `submit(... operation: :redirect, delivery: :redirect)` queues a new redirect request with the new task as payload.
2. `claim_next_request` allocates a fresh `execution_id`, records the active execution as `target_execution_id`, and increments `cancellation_generation` atomically under the thread lease.
3. Before the redirect execution starts, the runner reconciles in-flight effects of the target execution (invariant 53).
4. The new execution starts with the redirect payload; `intake` sets `task` to the new goal and proceeds normally.

CLI flow:

```ruby
session.runner.submit(
  {"task" => new_task},
  thread:,
  request_id: SecureRandom.uuid,
  operation: :redirect,
  delivery: :redirect
)
session.runner.run_next(thread:, owner_id:)  # drains the redirect
```

### 7.2 Cancellation

P7 restricts `tamoz cancel THREAD` to threads whose latest checkpoint is `:running` or `:paused` (i.e. there is an active or paused execution). It is implemented by enqueueing a redirect request with a sentinel payload that the graph routes straight to terminal.

1. The CLI verifies the thread status is `:running` or `:paused` via `session.view`.
2. The CLI enqueues:
   ```ruby
   session.runner.submit(
     {"cancel" => true, "reason" => "cancelled_by_user"},
     thread:,
     request_id: SecureRandom.uuid,
     operation: :redirect,
     delivery: :redirect
   )
   ```
3. `claim_next_request` allocates `target_execution_id` and `cancellation_generation`; the runner reconciles in-flight effects of the active execution.
4. The new execution starts. `SessionNodes#intake` detects the sentinel payload (`payload["cancel"] == true`) and returns an update that routes directly to `terminal` with `terminal_reason: "cancelled_by_user"`.
5. `tamoz cancel` exits `130` if the terminal reason is `cancelled_by_user` and the process is terminating because of SIGINT; otherwise it reports the cancelled status and exits `0`.

Cancellation of a `queued` request before claim is **not** supported in P7. Users who need to stop a queued request should wait for it to become active or redirect the thread. A first-class `:cancel` operation that marks a queued request failed before claim is reserved for post-P7.

Required `SessionNodes` change: extend `intake` to recognize the sentinel payload and branch to `terminal` with reason `cancelled_by_user` instead of reading `state[:task]`.

### 7.3 Idempotency

Duplicate redirect/cancel with the same `request_id` returns the prior request record (invariant 23). The CLI generates a fresh `request_id` for each user invocation.

---

## 8. Follow-up / queue semantics

### 8.1 Follow-up turn

`tamoz follow-up THREAD TASK` enqueues a new `:turn` request on an existing thread:

```ruby
session.runner.submit(
  {"task" => task},
  thread:,
  request_id: SecureRandom.uuid,
  operation: :turn,
  delivery: :queue
)
```

Then `session.runner.run_next(thread:, owner_id:)` drains the queue. The session graph's `intake` node receives the new task and continues.

### 8.2 Queue ordering

Requests are FIFO by `enqueue_sequence` (invariant 23). A follow-up queued behind a paused request will not run until the paused request completes. The CLI tells the user:

```
Follow-up queued behind request <id> (status: paused).
Run `tamoz resume <thread>` to advance.
```

### 8.3 List

`tamoz list` scans `--session-dir` and prints a summary of each thread:

```
THREAD                 STATUS      LAST_UPDATED          SUMMARY
th_8XqR3mKpL9vW        paused      2026-08-01 16:33      set value to 2
th_AbcDefGhiJkl        completed   2026-08-01 16:20      Explain note.txt
```

### 8.4 Show

`tamoz show THREAD [--transcript N]` prints:
- thread id, checkpoint id, sequence, status
- accepted plan digest
- pending interrupts
- recent effect receipts (last N)
- terminal result if completed

`--transcript N` bounds output to the last `N` checkpoint records and effect receipts. If omitted, a default cap (e.g. 50) is applied. Transcript rendering applies the same sensitive-data classification as checkpoints and streams:
- values marked `sensitive: true` in state are replaced with `[redacted]`;
- credentials, API keys, and credential-provider references are never printed;
- tool outputs longer than a configurable byte limit are truncated with a `[truncated]` marker.

With `--json`, emits a single JSON object with the same redaction applied.

Add an adversarial test (`test_transcript_redacts_sensitive_data`) to `test/agent_cli_test.rb`.

---

## 9. New scorecard case(s) for durable session/resume

### 9.1 Rationale

P6 has no behavioral scorecard case. P7 adds deterministic coverage for `--resume` after an approval interrupt and a real `kill -9`, giving the durable session hard-zero safety-counter coverage.

### 9.2 Case: `resume_after_kill`

Add:

- File: `gems/tamoz-evals/suites/agent/smoke/13_resume_after_kill.case.json`
- Entry in `AgentSmokeCorpus::CASE_DEFINITIONS` as the 13th case.
- Implementation: `run_resume_after_kill(case_artifact, definition)`.

### 9.3 Scenario

1. Create workspace with `broken.rb` containing `module Broken; def self.answer = 40; end`.
2. Configure a check that requires `Broken.answer == 42`.
3. Run `tamoz --session resume-kill-test --allow-changes --check answer=... "set Broken.answer to 42"` as a subprocess.
4. Wait until the subprocess emits `cli.prompt` for `apply_patch` (approval seam).
5. Send `kill -9` to the subprocess.
6. Verify the subprocess died and the workspace is unchanged.
7. Run `tamoz resume resume-kill-test` as a new subprocess with stdin piped to answer `y`.
8. Wait for completion.
9. Verify:
   - `broken.rb` now contains `42`.
   - The configured check passes.
   - Request history contains exactly two requests in order: the original turn and the resume.
   - The `apply_patch` effect happened exactly once.

### 9.4 Fixture details

The harness uses a scripted model identical to `one_pass_repair` but drives the CLI binary instead of `Runtime`. The approval function is not a lambda; instead the harness provides the answer over the subprocess stdin.

### 9.5 Oracle

The harness reads request history from the durable adapter after the test completes. A helper `AgentSmokeCorpus#read_request_history(adapter, thread_id)` queries the `tamoz_requests` table (or the equivalent adapter API if one is added for P7-E) and returns `RequestRecord` objects sorted by `enqueue_sequence`.

The oracle must tolerate a recovery redirect request (which may appear between the original turn and the resume) without weakening the hard-zero claims:

```ruby
oracle = lambda do |result, events, workspace, request_history|
  user_requests = request_history.reject { |r| r.delivery_mode == :redirect }
  turn_requests = user_requests.select { |r| r.operation == :turn }
  resume_requests = user_requests.select { |r| r.operation == :resume }

  File.read(File.join(workspace, "broken.rb")).match(/answer = 42/) &&
    result&.satisfied &&
    events.count { |e| e.type == :tool_started && e.data["tool"] == "apply_patch" } == 1 &&
    turn_requests.length == 1 &&
    resume_requests.length == 1 &&
    resume_requests.first.enqueue_sequence > turn_requests.first.enqueue_sequence &&
    request_history.none? { |r| r.status == :failed && r.terminal_error }
end
```

### 9.6 Harness changes

- Add a helper `run_cli_with_input(argv, input_lines)` in `AgentSmokeCorpus`.
- Add `run_resume_after_kill`.
- Update the `cases` identity check from 12 to 13.
- Add metrics: `resumes_after_kill`, `kill_recovery_success`.

---

## 10. Kill matrix / test matrix for P7-E

### 10.1 Unit tests

| Test | What it proves |
|------|----------------|
| `test_ask_creates_session_file` | `tamoz ask` writes a durable SQLite file |
| `test_resume_collects_interrupt_answers` | `resume` prompts and maps answers correctly |
| `test_resume_non_interactive_with_answer` | `--answer` bypasses stdin |
| `test_duplicate_request_id_returns_same_outcome` | invariant 23 |
| `test_follow_up_queues_behind_paused_request` | queue ordering |
| `test_redirect_replaces_in_flight_goal` | redirect semantics |
| `test_cancel_routes_to_terminal` | cancellation sentinel |
| `test_eof_exits_three_when_interactive` | EOF handling |
| `test_sigint_exits_one_thirty` | signal handler |
| `test_json_event_stream_is_ndjson` | output schema |

### 10.2 Integration tests

| Test | What it proves |
|------|----------------|
| `test_kill_minus_nine_at_approval_seam_is_resumable` | product proof |
| `test_two_cli_processes_cannot_claim_same_request` | lease/fence |
| `test_resume_after_process_crash_continues_plan` | checkpoint replay |
| `test_redirected_in_flight_effect_is_reconciled` | invariant 53 |
| `test_stale_graph_version_rejects_session_load` | guard_state! / invariant 18 |
| `test_stale_behavior_or_catalog_prompts_reconciliation` | blocked effect |

### 10.3 Adversarial / safety tests

| Test | What it proves |
|------|----------------|
| `test_sensitive_output_not_logged_to_session` | no secrets in checkpoints/streams |
| `test_two_owners_cannot_advance_same_thread` | lease exclusivity |
| `test_duplicate_delivery_does_not_double_apply` | invariant 52 |
| `test_sigterm_during_execution_leaves_clean_checkpoint` | graceful shutdown |

### 10.4 Signal handling

The CLI creates one `Tamoz::CancellationToken` per run and passes it into the durable run context (see §3.4). Signal handlers call `cancel!` with the appropriate reason.

- `SIGINT` (`Ctrl-C`): `cancellation_token.cancel!("sigint")`. The runner checks `context.cancellation.cancelled?` between barriers and after the current effect attempt; the current durable request completes its checkpoint append, then the CLI exits `130`.
- `SIGTERM`: `cancellation_token.cancel!("sigterm")`; exit `143`.
- `kill -9`: no handler. Next process recovers via lease takeover and `Session#recover` if needed.

Behavior during critical sections:
- If SIGINT arrives during a storage transaction (checkpoint append or request transition), the signal is recorded but the transaction commits before exit. The cancellation token prevents scheduling new work after the commit.
- If SIGINT arrives during an interactive prompt, the prompt is aborted, the session state is left as-is, and the CLI exits `130`.
- The signal handler does not set `Thread.current[:tamoz_interrupt]`; it only calls `cancel!` on the run's `CancellationToken`.

---

## 11. Stop/redesign criteria and residual risks

### 11.1 Stop/redesign criteria

Stop P7 implementation and escalate for redesign if any of the following appear:

- The CLI must use private RubyLLM APIs to render or resume.
- Any agent logic (approval policy, plan review, tool safety) leaks into the CLI.
- A second checkpoint/effect model is created outside the existing `Session`/`DurableRunner`.
- `kill -9` at an approval seam leaves the session unresumable or applies a duplicate effect.
- `--resume` cannot be expressed using the existing `Session#resume/continue/recover` API.
- Redirect or cancel cannot be implemented without bypassing the request inbox.
- The scorecard case cannot be made deterministic without mocking the durable store.

### 11.2 Residual risks

| Risk | Mitigation |
|------|------------|
| User expects bare `tamoz TASK` to be durable | Document that durability requires `--session` |
| Concurrent `resume` from two shells | Lease/fence; second process gets conflict error |
| Large transcripts in `show` | `--transcript N` bounds output |
| Sensitive tool output in checkpoints | Streams are not checkpoints; checkpoints already contain effect receipts; verify no stdout/stderr stored |
| Redirect/cancel sentinel payload evolves | Document as internal protocol; P8 may add first-class cancel operation |

---

## 12. Definition of done

- [ ] `docs/P7_INTERACTIVE_CLI_PLAN.md` and `docs/reviews/P7_INTERACTIVE_CLI_PLAN_REVIEW.md` exist and are reviewed.
- [ ] CLI supports `ask`, `resume`, `continue`, `list`, `show`, `follow-up`, `redirect`, `cancel`, `resolve` subcommands.
- [ ] Existing one-shot `tamoz [options] TASK` behavior is unchanged.
- [ ] `--resume` after `kill -9` at an approval seam recovers and completes correctly.
- [ ] A new scorecard case `resume_after_kill` is added and passes.
- [ ] Kill matrix tests (duplicate delivery, two CLI processes, redirected in-flight effects, EOF, SIGINT/SIGTERM, crash/restart, stale graph/behavior/catalog, sensitive output) pass.
- [ ] `rake ci` passes.
- [ ] Behavioral scorecard is rerun and passes.
- [ ] No TUI, gateway, daemon, or chat-channel abstraction introduced.
- [ ] No agent policy logic moved into the CLI.
