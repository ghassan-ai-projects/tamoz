# Tamoz Agent

Tamoz Agent now has a working read-only CLI slice:

```sh
OPENAI_API_KEY="..." TAMOZ_MODEL="gpt-5-mini" \
  bundle exec tamoz --root . "Summarize this project"
```

Every run drafts and reviews a plan before any workspace tool executes. This first slice
proves the product loop with real model calls and confined read-only tools. Durable sessions,
mutation, memory, recovery, skills, MCP, scheduling, and physical-world streams follow as
separate vertical slices.
