# Coding with Tamoz: `tamoz code`

`tamoz code` runs a coding task in the **work loop**. The model holds a real
conversation with native tool calls. It finds and reads code, writes a plan that
a second model call reviews, edits files through approved, digest-checked
patches, runs your configured checks, and stops when the task is done or when a
budget runs out. Every model call and every tool call goes through the durable
effect journal, so a killed turn resumes without repeating an edit.

Use `tamoz ask` for a question or a small reviewed change. Use `tamoz code` for
work that takes many steps: building a feature, a multi-file fix, or a change
that needs a test written and run.

Current version: `0.1.0.alpha.1` (pre-release).

## Run it

```bash
export OPENROUTER_API_KEY="..."
```

```bash
rbenv exec bundle exec tamoz --provider openrouter --model deepseek/deepseek-v4.1-flash --root . --allow-changes --check 'test=rbenv exec bundle exec rake test' --guidance AGENTS.md code "Add X"
```

- `--allow-changes` (or a trusted `--profile`) is required, because a coding turn
  edits files.
- `--check NAME=COMMAND` names the verification command. The model can only run
  checks that you configured, by name. It cannot run any other command.
- `--guidance FILE` adds project guidance such as `AGENTS.md`. The file must be
  in the workspace root. The flag is repeatable.
- Global options go **before** the subcommand. Placed after `code`, they are
  ignored.
- Real runs need a UTF-8 locale (`LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`).
- The session directory must be private (mode `0700`). Tamoz refuses a directory
  that other users can read.

The model route needs a known context window. See
[Context window](#context-window) below.

## What a turn does

1. **Discover.** The model uses `glob`, `search_text`, `list_directory` and
   ranged `read_file` to find the code it needs. It reads ranges, not whole
   large files.
2. **Plan.** Before its first change, the model writes a plan with
   `update_plan`: the goal, what "done" means, the paths and checks in scope,
   and the steps. A separate plan-review call accepts or rejects it. An edit
   before an accepted plan is refused and fed back to the model. So is an edit
   outside the plan's paths. Widening the scope sends the plan back for review.
3. **Edit.** `create_file` and `apply_patch` show you the exact change. A patch
   binds the file's SHA-256, so it fails if the file changed after the model
   read it. The model must read the file again and retry.
4. **Verify.** `run_check NAME` runs a configured check. A failing check is
   evidence for the next step, not the end of the turn.
5. **Finish.** When the model stops calling tools, the turn ends with a status:

| Status | Meaning |
|---|---|
| `done` | Files changed, and a configured check passed after the last change |
| `done_unverified` | Files changed, and no check passed after the last change |
| `answered` | Nothing changed (a question, or nothing to do) |
| `verified_no_changes` | Nothing changed, and a check passed |
| `handed_off` | A budget or the repeat guard stopped the turn. The answer is a handoff note with the plan's state |
| `work_failed` | The model call failed, or the context window was exceeded again after a reduction |

The CLI prints the model's final report. It then prints `Verification:
satisfied` only for `done` and `verified_no_changes`.

## Approvals

The work loop uses the same approval engine and policy as every other turn
(`gems/tamoz-approval/policy/*.yaml`). With the bundled default policy:

- **Reads** never ask.
- **The first file write** asks, and offers to remember the grant for the
  session. That grant covers later writes under the same workspace root.
- **Every `run_check`** asks.

For a throwaway workspace, `yes y | tamoz ... code "..."` answers every prompt.
Never point that at a checkout you care about.

## Continuing a thread

`--session NAME` names the thread. A work thread's surface, guidance files and
persona are pinned at its first turn, in `<session-dir>/NAME.harness.json`, so
later turns build the same prompt without repeating the flags. Run `code` again
on the same thread for the next turn:

```bash
rbenv exec bundle exec tamoz --root . --allow-changes --session feature code "Now add tests for the edge cases"
```

The next turn starts a fresh conversation. It receives the previous turn's answer
and the accepted plan, so a handed-off turn can pick up where it stopped.
`resume`, `show` and `cancel` work as in any durable session (see
[sessions](../getting-started/sessions.md)). `tamoz code --session NAME` refuses
a thread that was not started as a work thread.

## Context window

The loop manages the model's context window itself, so it must know the window
size. The window is resolved in this order:

1. The profile role's `context_window` setting.
2. `TAMOZ_CONTEXT_WINDOW`.
3. The documented window for the route in
   `gems/tamoz-agent-kernel/data/model_windows.yml`, keyed on `provider/model`.

A route that is not recorded, with no override, is refused before any model
call. Tamoz never guesses a window. See [model providers](../reference/model-providers.md#context-windows).

As the conversation grows, long tool results are spilled to the artifact store
and replaced by a locator. The model can read them back with `recall_output`.
Near the window limit, old tool results are pruned first. If that is not enough,
the history is compacted once into a structured summary. Past that, the turn
hands off.

## Budgets

| Budget | Default | On exhaustion |
|---|---|---|
| Model calls per turn | 60 | `handed_off` (`model_call_budget`) |
| Tool calls per turn | 120 | `handed_off` (`tool_call_budget`) |
| Wall time per turn | 1800 s | `handed_off` (`time_budget`) |
| Identical call repeated | reminder at 3 and 5, stop at 8 | `handed_off` |
| Tool calls in one model message | 8 | the extra calls are refused |

Repeating a read or a check after a successful edit counts as progress, not as a
loop.

## Persona and preferences

An operator persona is read from `<runtime dir>/persona.md` (at most 16 KB),
where the runtime directory is `--runtime-dir` or `TAMOZ_RUNTIME_DIR`. The
persona, the project guidance and the prompt pack are data. They shape how the
model works; they never grant a tool, a path or an approval.

## Chat

The worker and chat runtime serve work turns when started with
`--work-routing`. A chat work turn uses the chat surface prompt and the same loop
and budgets. Its approvals follow the channel's rules (see [Telegram](telegram.md)).

## Inspect a run

```bash
script/context_trace SESSION_DIR THREAD
```

This prints one line per model request of the thread's latest turn: the step, the
request series, the message count, the estimated tokens, and the prompt and
cached tokens the provider reported. Without `THREAD`, it summarizes every work
thread in the directory. `--json` prints the full records. `tamoz show THREAD`
prints the thread's state and outcome.

## A worked example

On 2026-09-23, `tamoz code` over OpenRouter `deepseek/deepseek-v4.1-flash` was
given an empty git workspace and `--check 'test=node test.js'`. The task was to
build Conway's Game of Life in plain HTML/CSS/JS, with pure rules in `life.js`
and a Node test. It finished `done`: 36 model calls, 30 tool calls, four files,
and the check passed after the last edit. A follow-up task on a new thread added
a wrap-edges option and a live speed slider. It also fixed a bug described only
by its symptom ("cells look stretched when the window is narrow"). That task
finished `done` in 22 model calls. Both results were checked by hand in a
browser.

That is one real task, not an evaluation. The real-model evaluation suite is
described in [evaluation](evaluation.md), and its current status is in
[limitations](../limitations.md#the-coding-harness-has-one-real-task-run-not-a-real-model-evaluation).

## Next reads

- [design/coding-harness.md](../design/coding-harness.md): how the loop, the
  context engine and the harness protocol fit together
- [reference/cli.md](../reference/cli.md): every flag and subcommand
- [reference/model-providers.md](../reference/model-providers.md): providers
  and recorded context windows
