# Agent tool-error surfacing and recovery correction

Review target: `Tamoz::Agent::ToolError` handling across `Toolbox`, `EffectDispatcher`,
`SessionNodes`, `Runtime`, and `CLI`; `Tamoz::NodeError#safe_message`.

Reviewed base: `cce735e38d9e0390187d794293d30d5fad1eab38`.

Decision: accepted correction on 2026-08-02, subject to the recorded full gate under both
`en_US.UTF-8` and `C`, and a passing agent smoke scorecard.

## Observed defect

Against a real provider (DeepSeek `deepseek-chat`) with `--allow-changes` and a real
`--check`, a session that produced one imperfect `apply_patch` argument died:

```
intake -> deliberate -> step_gate -> step_execute -> evaluate
       -> step_gate -> step_execute -> evaluate
       -> step_gate -> step_execute
ERROR node=step_execute class=Tamoz::Agent::ToolError category=node safe_message="A workflow step failed."
SESSION status=failed
```

The operator saw exactly this:

```
Error:
tamoz: session failed
```

Read-only mode was unaffected and worked end to end.

## Finding

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| High (D-7a) | The CLI printed `Error: ` with no text. | `cli.rb` read `part.data["message"]`, but a `:error` stream part carries `graph`, `node`, `task_id`, `error_class`, `category`, `safe_message` — never `message`. The missing key returned `nil`. | Render from the keys that exist, fall back through `safe_message` -> `error_class` -> a literal, and repeat the reason on the final failure line. |
| High (D-7b) | Every node failure reported `"A workflow step failed."` | `Tamoz::NodeError::SAFE_MESSAGE` is a single generic constant and `Executor#emit_errors` emits `error.safe_message` unconditionally. Nothing let a class that authors its own message disclose it. | Introduce the `Tamoz::DisclosableMessage` marker. `NodeError#safe_message` returns the wrapped original's normalized message only when the original opts in. `NodeError` itself is not widened. |
| Critical (D-7c) | A recoverable `ToolError` during action terminated the session. | `SessionNodes#step_gate` and `#step_execute` raised `ToolError` for every tool failure, and `Runtime#execute` let every `ToolError` propagate. `ToolError` was one undifferentiated class, so "your `before` text has a typo" and "you tried to escape the workspace root" were indistinguishable. | Split `ToolError` into an explicitly repairable subclass and an explicitly terminal policy subclass. A repairable failure becomes a typed observation that re-enters the *existing* bounded repair loop. Everything else, including the unclassified base class, still propagates. |

## Five Whys: the agent is unusable in action mode

1. Why did the session fail? `step_execute` raised `Tamoz::Agent::ToolError` and the graph
   executor turned it into a terminal `NodeError`.
2. Why was a `ToolError` terminal? `step_execute` had exactly one branch for
   `outcome.status == :failed`: `raise ToolError`. There was no path from a failed tool
   attempt back into planning.
3. Why was there no such path? The bounded repair loop was built in P2 for *failed
   configured checks* only. It is driven by `evaluate` finding a `check` record with a
   `failure_signature`. A tool that never ran produces no check record, so `evaluate`
   never saw the failure and there was nothing to repair from.
4. Why did that gap survive P2 through P8? Every scripted corpus case reaches the tool
   with arguments the fixture guarantees are exact. `agent.stale-digest` is the only case
   that produces a real tool failure, and it *asserted* the terminal outcome
   (`expected_terminal: %w[tool_error]`), which froze the defect into the scorecard as
   intended behavior.
5. Why does a real model expose it immediately? An LLM reconstructing exact source text
   for `apply_patch#before` frequently reproduces it with one whitespace or indentation
   error. That single miss is a `ToolError`, and therefore, until now, the end of the run —
   with a blank message.

Contributing cause for the blank message: nobody read the `:error` stream part shape.
`emit_errors` in `executor.rb` and `stream_error_data` in `compiled.rb` both emit
`safe_message`; no producer anywhere in the codebase emits `message`. The CLI's key was
never correct, so the bug was invisible until a node actually failed with a user watching.

## Error-surfacing policy (D-7b)

### What invariant 24 actually requires

Invariant 24 is *"Secret values are rejected from checkpoints, streams, and
instrumentation unless a named policy protects them; no lossy key-name scrubbing
occurs."* Its subject is `Tamoz::Secret` and its enforcement points are
`StateCodec`, `SessionRecords.reject_sensitive!`, and the stream boundary. It does not
say "no exception text may be streamed."

The generic `safe_message` is a *separate*, and correct, defensive default: an arbitrary
`StandardError` reaching a node boundary may carry a provider response body, a connection
string, an environment value, or a third-party gem's stringified request — none of which
Tamoz authored and none of which it can audit. Default-deny is right for that population.
The defect is that default-deny was the *only* policy, with no way for a class that
provably authors its own text to opt in.

### The rule

A class may disclose its own `message` through `safe_message` if and only if every
message it can produce is built exclusively from:

1. string literals in Tamoz source;
2. values Tamoz itself computed (SHA-256 digests, byte counts, occurrence counts, limits);
3. workspace-relative paths and tool/argument names that are already visible to the same
   operator in the approval preview, the plan record, and the review issues.

It must never interpolate a provider response body, an exception message from a
third-party library, an environment value, file contents, or a `Tamoz::Secret`.

Opt-in is by including the `Tamoz::DisclosableMessage` marker module. Disclosure is not
raw: `NodeError#safe_message` passes the message through a normalizer that forces UTF-8,
scrubs invalid bytes, replaces control characters, clamps to 512 bytes on a character
boundary, and falls back to the generic constant when the result is empty.

### Applying the rule

| Class | Discloses | Justification |
|---|---|---|
| `Tamoz::Agent::ToolError` and all subclasses | **Yes** | Every message is a Tamoz literal plus Tamoz-computed metadata (digests, counts, limits) or a workspace-relative path/argument name. `Deliberation.structural_issues` already interpolates these exact messages into durable `review` records that the CLI prints, so the disclosure surface is not new — the stream was simply less informative than the checkpoint. |
| `Tamoz::Agent::ProtocolError` | **No** | `plan.rb:76` produces `"model returned invalid JSON: #{error.message}"`, where the `JSON::ParserError` message quotes the raw provider payload, and `ruby_llm_model.rb:58` produces `"#{stage} model call failed: #{error.class}: #{error.message}"`, where the wrapped exception is a provider/HTTP error whose text can contain URLs, headers, or credential material. This is precisely the population default-deny exists for. |
| `Tamoz::Agent::PlanRejectedError`, `ApprovalDeniedError` | **No** (this change) | Their messages are safe, but they are not part of the observed defect and each already reaches the operator through a dedicated CLI path. Not widened without a reason. |
| Every `Tamoz::Error` in `tamoz-core`, `tamoz-graph`, `tamoz-sqlite` | **No** | Unchanged. Checkpoint, store, lease, pool, and stream errors keep their existing generic constants. |

`NodeError::SAFE_MESSAGE` itself is unchanged, and `NodeError` gains no blanket
disclosure: an original that does not include the marker still yields
`"A workflow step failed."`

## Propagate-vs-observe taxonomy (D-7c)

Invariant 17: *"Invalid arguments, denial, timeout, and declared external failures become
typed tool results; cancellation, policy violations, programmer bugs, and storage
corruption propagate."*

The boundary is encoded in the exception class hierarchy, never in string matching on
messages.

```
Tamoz::Agent::Error
└── Tamoz::Agent::ToolError            repairable? => false   PROPAGATES  (default-deny)
    ├── Tamoz::Agent::ToolPolicyError  repairable? => false   PROPAGATES  (security boundary)
    └── Tamoz::Agent::ToolArgumentError repairable? => true   OBSERVED    (bounded repair)
```

The base class is terminal. A raise site that has not been classified therefore fails
closed. Only `ToolArgumentError` is ever converted into evidence, and it is selected by
`is_a?`/`repairable?`, not by inspecting text.

### `ToolPolicyError` — always terminal

Sandbox containment and approval integrity. Converting any of these into a retryable value
would let a model iterate against the security boundary.

- `path escapes the workspace root` (patch/read resolution and create-file resolution)
- `path must be relative to the workspace root` (absolute path supplied)
- `patch path must not contain symlinks`, `parent path must not contain symlinks`
- `path contains a null byte`, `content must not contain a null byte`,
  `<argument> must not contain a null byte`, `query must not contain a null byte`
- `workspace no longer matches the approved before state for <path>` — the operator
  approved specific bytes and the world changed underneath the approval

### `ToolArgumentError` — observed, feeds bounded repair

Failures fully attributable to the arguments the planner chose, where the correct response
is to re-read the workspace and plan different arguments. None of them mutates anything:
`apply_patch` and `create_file` do all of this preflight before any write.

- `patch text was not found`
- `patch text is ambiguous: found N occurrences`
- `patch text requested N times but found M occurrences`
- `replacements overlap`
- `file changed: expected digest <a>, observed <b>` (stale digest)
- `expected_sha256 must be 64 lowercase hex characters`
- `content digest mismatch: expected <a>, computed <b>`
- `path is not a file`, `path is not a directory`, `path must name a file`
- `file already exists`, `parent directory does not exist`, `parent is not a directory`
- `file exceeds N bytes`, `patched file exceeds N bytes`, `file is not valid UTF-8 text`,
  `file is not text`
- argument shape and encoding validation: missing/unknown argument keys, wrong types,
  empty or oversized text, non-UTF-8 or invalid-UTF-8 arguments, bad `mode`,
  `replacements` shape, `before`/`after` combined with `replacements`, unknown configured
  check name

### Unclassified base `ToolError` — still terminal

Environment and framework failures where a different plan cannot help, and gate bypasses
that must stay loud:

- `workspace root is not a directory`, `workspace root is unavailable`, `path is unavailable`
- `atomic patch failed: <class>`, `atomic create failed: <class>`,
  `created file did not verify`, `check <name> could not start: <class>`
- `unknown tool <name>`, `tool <name> does not require approval`,
  `no committed effect intent for step <id>` — each means a gate upstream did not hold
- `insufficient observation budget for <tool>`, `tool observations exceed N bytes` — a
  framework budget, not an argument mistake; retrying cannot shrink an append-only channel

Denial (`ApprovalDeniedError`), cancellation, `PlanRejectedError`, `InvalidUpdateError`,
`RecursionLimitError`, `CheckpointCorruptionError`, `LeaseLostError`, `StoreError`, and
every `FatalRuntimeFailure` are untouched and remain terminal.

### Crossing the effect journal

`EffectDispatcher.run` rescues `ToolError` inside the attempt and records
`{"class" =>, "message" =>, "repairable" =>}`. `repairable` is derived from the exception
type *at the raise site* and then persisted, so a replayed `:failed` decision reaches the
same conclusion as the original attempt without re-deriving anything from text. A journal
record written before this change has no `repairable` key; `== true` is false, so legacy
records propagate. Fail-closed on replay.

## Recovery routing

No second loop is created. The P2 loop is `evaluate -> deliberate(phase: "repair")` guarded
by three stops, and all three keep operating over the same channels:

1. `seen_action_signatures` — an identical accepted action plan stops with
   `repeated_action`;
2. `repair_attempt >= MAX_REPAIR_ATTEMPTS` (2) — a hard cap on repairs, now *shared*
   between failed checks and failed tools, so total repair work is bounded exactly as
   before;
3. `seen_failure_signatures` — identical failure evidence twice stops with a repeated
   stop reason.

A repairable `ToolError` is caught at the two places it can arise:

- `step_gate`, where `toolbox.effect_intent` and `toolbox.preview` run the filesystem
  preflight *before* any interrupt or journal entry. Nothing has been prepared, so the
  failure is pure evidence.
- `step_execute`, where the journal reports a failed attempt.

Both produce one `observation` record carrying an optional `failure` field
(`kind`, `tool`, `error_class`, `reason`, `failure_signature`) and route to `evaluate`.

`evaluate` consults the current-pass tool failure **only in the `action` and `repair`
phases**, because the repair loop is defined over that phase machine. In `discovery` and
`read_only` the failure is recorded as evidence and the plan simply continues to its next
step — bounded by the plan's own step count, with no repair budget consumed and no phase
change.

### Failure signature for a tool error

A check's `failure_signature` digests `(name, outcome, stdout, stderr)` — rich evidence
that differs whenever the world differs. A tool error's reason string is coarse:
`"patch text was not found"` is byte-identical for two *completely different* wrong
`before` strings. Digesting the reason alone would collapse two genuinely distinct attempts
into "repeated evidence" and allow exactly one repair.

The faithful analogue of "the evidence I got" for a tool error is *the reason together with
the arguments that were rejected*, so `failure_signature` digests
`(kind, tool, reason, arguments_digest)`. An identical retry still matches — and is in any
case already refused one layer earlier by `seen_action_signatures`. A different attempt that
fails the same way is new evidence and is allowed to consume one of the two repair
attempts. The hard cap is unchanged, so the maximum number of action attempts against a
task is still three.

## Material change to `agent.stale-digest`

The case previously asserted `expected_terminal: %w[tool_error]`. That expectation encodes
the defect: it required the run to die. Under the correction the stale digest is refused,
becomes typed evidence, the bounded repair runs, the model re-offers the same stale plan,
and `seen_action_signatures` stops the session with `repeated_action`. The terminal is now
`completed` with `terminal_reason: repeated_action`.

The case is not weakened. Two changes strengthen it:

- **Terminal expectation.** `%w[completed]` plus a scripted `repeated_action` stop. The
  case now proves the stale patch is refused *and* that refusing it does not let the model
  loop.
- **Oracle.** The old oracle was `load_value(root) == 42`. For this adversarial case that
  is perverse: had the stale evidence actually written 42, the oracle would have scored
  `task_success = true` — it rewarded the exact violation the case exists to forbid. The
  oracle now asserts the case's own definition of done: the file still holds 40, is
  byte-identical to what was written, and no `apply_patch` ever completed. It fails if the
  file changes *in any direction*.
- **Verification.** The scripted verifier now claims `satisfied: true`. The framework's
  `enforce_configured_check` must override it to `false` because no configured check
  passed. If that override ever regressed, `false_positive_completion` would become true
  and the `no_false_positive_completions` hard gate would fail.

Consequence to declare openly: because the corrected oracle asserts a property that is now
satisfied, `task_successes` in the aggregate moves from 9 to 10. That is the direct result
of the oracle no longer contradicting the case's stated definition of done, not of any
relaxed expectation.

## Fixed behavioural case

`test/agent_tool_error_recovery_test.rb` covers the new capability deterministically over
both drivers:

- a `before` string that does not match becomes evidence and a corrected second plan
  repairs the file and passes the configured check, on `Runtime` and on `Session`;
- the observation carries the exact reason, and the repair planner is given it;
- three consecutive distinct failing patches stop at `MAX_REPAIR_ATTEMPTS` and never mutate
  the file — no unbounded retry;
- an identical repeated failing patch stops at `repeated_action`;
- a `ToolPolicyError` (symlink escape, absolute path, null byte) still terminates the
  session and never becomes an observation;
- `ApprovalDeniedError` remains terminal;
- `NodeError#safe_message` discloses a `ToolError` message and still returns the generic
  constant for a `ProtocolError` and for a plain `StandardError`;
- the CLI renders a non-empty, specific error line for a terminal node failure.

## Out of scope

- Read-only sessions keep terminating on an unusable tool argument. They have no
  repair-budget semantics and no configured check to re-evaluate against. They do now
  report the specific reason.
- `MAX_REPAIR_ATTEMPTS` is unchanged at 2. Making a real model more likely to succeed by
  raising it is a separate, measured decision.
- The planner is not given a new "how to write an exact `before`" prompt section beyond the
  remediation sentence carried in the failure observation.
