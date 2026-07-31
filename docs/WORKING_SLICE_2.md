# Working slice 2 — reviewed coding change loop

## Outcome

Tamoz can complete one bounded coding change end to end:

```sh
OPENAI_API_KEY="..." TAMOZ_MODEL="gpt-5-mini" \
  bundle exec tamoz --root . --allow-changes \
  --check 'test=bundle exec rake test' \
  "Fix the failing test"
```

Read-only mode remains the default. `--allow-changes` activates a separate lifecycle:

```text
task
  → discovery plan → structural review → semantic review → read-only evidence
  → action plan    → structural review → semantic review
  → exact diff approval → atomic patch
  → configured-command approval → bounded check
  → evidence-bound verification
```

## Patch contract

`apply_patch` performs one exact substitution in one existing UTF-8 text file. The accepted
plan binds:

- a relative canonical path with no symlink component;
- the SHA-256 digest emitted by `read_file` discovery;
- exact `before` text that must occur once;
- exact replacement text.

Before execution, Tamoz recomputes the digest and renders the exact replacement as a unified
diff. The human must approve it. Execution recomputes the same conditions, writes a temporary
file in the target directory, flushes it, preserves permission bits, atomically renames it,
and attempts to fsync the directory. A stale, missing, ambiguous, binary, oversized, escaped,
or symlinked target stops without mutation.

## Check contract

`--check NAME=COMMAND` is parsed by the CLI into a fixed argv array. The model receives only
the configured name and can invoke only `run_check({"name": NAME})`; it cannot add flags,
redirections, pipes, environment assignments, or another executable. Tamoz displays the
fixed argv and requires approval before starting it.

Checks run directly without a shell, under the workspace root, with a 60-second default
timeout and bounded stdout/stderr capture. Non-zero exit and signal outcomes are returned as
evidence rather than misreported as success. Timeouts terminate the process group. Effect
execution also reserves enough of the 160 KiB run observation budget for its bounded receipt
before approval or dispatch.

## Evaluation

`test/agent_change_evaluation_test.rb` creates a broken Ruby project and proves the complete
loop: discovery exposes the file digest, the action plan binds that digest, the approved
patch changes `41` to `42`, a real Ruby subprocess checks the result, and final verification
uses the `exit_0` receipt. A second case proves denied approval leaves the file byte-for-byte
unchanged.

## Explicit non-guarantees

- no arbitrary shell or model-supplied command arguments;
- no file creation, deletion, rename, or multi-file transaction;
- no durable approval/effect journal or crash resume;
- no automatic rollback after a failing check;
- no multi-turn correction loop after failed verification;
- no memory, self-healing, self-improvement, skills, MCP, scheduling, or streaming input.

The next product slice should add SQLite-backed session and effect recovery around this
working loop. A crash between atomic rename and receipt recording must reconcile the file
digest instead of applying the patch twice.
