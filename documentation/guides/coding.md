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
  checks that you configured, by name. It cannot run any other command. Without
  a check, a turn that changes files can finish only as `done_unverified`.
- `--guidance FILE` adds project guidance such as `AGENTS.md`. The flag is
  repeatable. See [Project guidance](#project-guidance).
- Global options go **before** the subcommand. Anything after `code` becomes
  part of the task text, so `code --check t=x "Add X"` configures no check.
- Tamoz creates the session directory with mode `0700`. It refuses an existing
  session directory that has any group or other permission bit set.

The model route needs a known context window. See
[Context window](#context-window) below.

## What a turn does

1. **Discover.** The model uses `glob`, `search_text`, `list_directory` and
   `read_file` to find the code it needs. A `read_file` without a range returns
   an 800-line window.
2. **Plan.** Before its first change, the model writes a plan with
   `update_plan`: the goal, what "done" means, the paths and checks in scope,
   and the steps. A separate plan-review call accepts or rejects it, at most
   three times per turn. An edit before an accepted plan is refused and fed back
   to the model. So is an edit outside the plan's paths. Widening the scope
   sends the plan back for review.
3. **Edit.** `create_file` and `apply_patch` show you the exact change. A patch
   binds the file's SHA-256, so it fails if the file changed after the model
   read it. The model must read the file again and retry.
4. **Verify.** `run_check NAME` runs a configured check. A failing check is
   evidence for the next step, not the end of the turn.
5. **Finish.** When the model stops calling tools, or the turn is stopped, it
   ends with a status:

| Status | Meaning |
|---|---|
| `done` | Files changed, and a configured check passed after the last change |
| `done_unverified` | Files changed, and no check passed after the last change |
| `answered` | Nothing changed (a question, or nothing to do) |
| `verified_no_changes` | Nothing changed, and a check passed |
| `handed_off` | A budget, the repeat guard, or context pressure stopped the turn. The answer is a handoff note with the plan's state |
| `work_failed` | The model call failed, or the context window overflowed again right after a reduction |
| `effect_unknown` (blocked) | A tool call's outcome is unknown. The thread waits for `tamoz resolve` |

The CLI prints the model's final report. `done` and `verified_no_changes` print
`Verification: satisfied` and exit 0. The other finished statuses print
`Verification: not satisfied` and exit 2. A blocked thread exits 3 (see
[exit codes](../getting-started/sessions.md#exit-codes)). For `handed_off`, the CLI suggests reviewing the
evidence and resuming. To continue the work, run `code` again on the same thread
(see [Continuing a thread](#continuing-a-thread)).

## Approvals

The work loop uses the same approval engine as every other turn. Its policy is
data in `gems/tamoz-approval/policy/`. The interactive CLI runs with the
`review` approval profile, which behaves like this:

- **Reads** never ask.
- **The first file write** asks, and offers to remember the grant for the
  session. A remembered grant lasts for the current CLI process only. A new
  `code` or `resume` command asks again.
- **Every `run_check`** asks, and offers no session grant.

For a throwaway workspace, `yes y | tamoz ... code "..."` answers every prompt.
Never point that at a checkout you care about.

## Continuing a thread

`--session NAME` names the thread. Only the thread's **guidance files and
persona** are pinned at its first turn, in `<session-dir>/NAME.harness.json`.
Everything else comes from the command line of each turn, so repeat the
provider, the model, `--allow-changes` and the checks every time:

```bash
rbenv exec bundle exec tamoz --provider openrouter --model deepseek/deepseek-v4.1-flash --root . --allow-changes --check 'test=rbenv exec bundle exec rake test' --session feature code "Now add tests for the edge cases"
```

Without `--check`, the next turn cannot run a check. Without `--provider` and
`--model`, it falls back to the default provider. A `--guidance` flag on a later
turn is ignored; start a new thread to change the guidance.

The next turn starts a fresh conversation. It receives the previous turn's answer
and the accepted plan, so a handed-off turn can pick up where it stopped.
`resume` (with the same provider, model and check flags), `show` and `cancel`
work as in any durable session (see [sessions](../getting-started/sessions.md)).
`tamoz --session NAME code` refuses a thread that was not started as a work
thread.

## Project guidance

`--guidance FILE` shows a project file, such as `AGENTS.md`, to the model as
project data. It can shape conventions, but it never grants a tool, a path or an
approval.

- The value must be a bare file name in the workspace root: no `/`, no leading
  `.`.
- A symlink, a file over 1 MiB, or an empty or non-UTF-8 file is skipped.
- All guidance together is capped at 16 KB. Over the cap, the earliest files are
  dropped first, then the last one is cut.

## Context window

The loop manages the model's context window itself, so it must know the window
size. The window is resolved in this order:

1. The profile role's `normalized_settings.context_window`, written as a string
   (for example `"163840"`).
2. `TAMOZ_CONTEXT_WINDOW`.
3. The documented window for the route in
   `gems/tamoz-agent-kernel/data/model_windows.yml`, keyed on `provider/model`.

A route that is not recorded, with no override, is refused before any model
call. Tamoz never guesses a window. See
[model providers](../reference/model-providers.md#context-windows).

As the conversation grows, the loop reduces it in this order:

1. **Spill.** A long tool result is stored in the artifact store and replaced by
   a head, a tail and a locator. The model reads more with `recall_output`.
   `read_file` results are never spilled.
2. **Prune.** Old tool results outside the recent tail are cut to a head and a
   tail.
3. **Compact.** Near the window limit, the history is summarized once per turn.
4. **Reset.** Further pressure replaces the history with a handoff note, and the
   turn keeps going. This can happen at most twice.
5. **Hand off.** Pressure after two resets ends the turn as `handed_off`.

## Budgets

| Budget | Default | On exhaustion |
|---|---|---|
| Model calls per turn | 60 | `handed_off` (`model_call_budget`) |
| Tool calls per turn, including refused ones | 120 | `handed_off` (`tool_call_budget`) |
| Wall time since the turn started or the last approval was answered | 1800 s | `handed_off` (`time_budget`) |
| Identical call repeated | reminder at 3 and 5, stop at 8 | `handed_off` |
| Tool calls in one model message | 8 | the extra calls are refused |
| Plan reviews per turn | 3 | the plan stays unaccepted |
| Context resets per turn | 2 | `handed_off` |

Repeating a read or a check after a successful edit counts as progress, not as a
loop.

## Persona

`tamoz code` reads an operator persona from `<runtime dir>/persona.md`, where
the runtime directory is `--runtime-dir` or `TAMOZ_RUNTIME_DIR`. `--runtime-dir`
needs an initialized runtime directory whose workspace matches `--root`.

- The file is at most 16 KB. A symlinked `persona.md` is ignored.
- It is pinned at the thread's first turn, so later edits to the file do not
  change that thread.
- The persona shapes how the model works. It never grants a tool, a path or an
  approval.

## Chat

The worker and chat runtime serve work turns when started with
`--work-routing`. A chat work turn uses the chat surface prompt and the same loop
and budgets. It does not load `persona.md`. Its approvals follow the channel's
rules (see [Telegram](telegram.md)).

## Inspect a run

```bash
script/context_trace SESSION_DIR THREAD
```

This prints one line per model request of the thread's latest turn: the step, the
request series, the message count, the estimated tokens, and the prompt and
cached tokens the provider reported. Without `THREAD`, it prints every request
of every work thread in the directory, then one summary line. `--json` prints
the full records. `tamoz show THREAD` prints the thread's state and outcome.

## A worked example

On 2026-09-23, `tamoz code` over OpenRouter `deepseek/deepseek-v4.1-flash` was
given an empty git workspace and `--check 'test=node test.js'`. The task was to
build Conway's Game of Life in plain HTML/CSS/JS, with pure rules in `life.js`
and a Node test.

- **The first three runs failed on harness defects.** A non-ASCII reply crashed
  the turn, approval previews printed twice, and a long turn hit the graph's
  step limit. All three are fixed.
- **The fourth run finished `done`.** It used 36 work-step model calls, 2 plan
  reviews and 30 tool calls, created four files, and the check passed after the
  last edit.
- **A follow-up task, on a new thread, finished `done` in 22 model calls.** It
  added a wrap-edges option and a live speed slider. It also fixed a bug
  described only by its symptom ("cells look stretched when the window is
  narrow").
- **Both results were checked by hand in a browser.**

That is one real task, not an evaluation. The continuation path (`code` again on
the same thread) is covered by tests but has not yet been run against a real
model. The status of the real-model evaluation is in
[limitations](../limitations.md#the-coding-harness-has-one-real-task-run-not-a-real-model-evaluation).

## Next reads

- [design/coding-harness.md](../design/coding-harness.md): how the loop, the
  context engine and the harness protocol fit together
- [reference/cli.md](../reference/cli.md): every flag and subcommand
- [reference/model-providers.md](../reference/model-providers.md): providers
  and recorded context windows
