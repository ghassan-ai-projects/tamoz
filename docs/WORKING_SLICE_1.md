# Working slice 1 — reviewed read-only agent

## Outcome

Tamoz is now executable as a product, not only as framework infrastructure:

```sh
OPENAI_API_KEY="..." TAMOZ_MODEL="gpt-5-mini" \
  bundle exec tamoz --root . "Explain the graph execution model"
```

The runtime performs this complete loop:

```text
task → draft plan → structural review → semantic review → accepted plan
     → confined read-only tools → evidence-bound verification → answer
```

No workspace tool is callable before both review layers accept the exact plan. A rejected or
malformed plan is revised up to the configured attempt bound, then stops with no task action.

## Why this precedes M4

M4 remains the durable, tool-calling RubyLLM graph milestone. RubyLLM 1.16 does not expose
the public single-generation seam required for Tamoz to take over its native tool loop.

This slice avoids that blocked seam. Every RubyLLM chat is fresh and has no RubyLLM tools.
Tamoz requests strict JSON for planning, review, and verification, then invokes its own
confined read-only toolbox only after review. It does not claim M4 durability or native
RubyLLM tool fidelity.

## Implemented guarantees

- every task has a non-empty plan and observable definition of done;
- deterministic review rejects unknown tools, empty completion criteria, duplicate steps,
  and incomplete verification;
- semantic review runs in a fresh model context and can force bounded replanning;
- only `read_file`, `list_directory`, and literal `search_text` are available;
- tool paths must be relative, resolve symlinks, and remain under the declared root;
- file, directory, search, task, plan-attempt, and total-observation bounds are enforced;
- final answers state whether supplied evidence satisfied the task;
- human and newline-delimited JSON CLI output are available.

## Explicit non-guarantees

- no checkpoint or crash resume;
- no file mutation, shell execution, external effects, or approval UI;
- no multi-turn session;
- no native RubyLLM tools or hidden RubyLLM tool loop;
- no memory, self-healing, self-improvement, skills, MCP, scheduler, or streaming input;
- model calls are not yet journaled or replay-safe.

## Next product slice

Add a reviewed write/edit path with explicit approval and SQLite effect journaling. That
slice should make `tamoz "fix this small issue"` useful while reusing the working loop. The
release-evidence matrix remains paused until the product path needs it.
