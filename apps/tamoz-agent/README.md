# Tamoz Agent

Tamoz Agent now has a working reviewed-change CLI:

```sh
OPENAI_API_KEY="..." TAMOZ_MODEL="gpt-5-mini" \
  bundle exec tamoz --root . "Summarize this project"

OPENAI_API_KEY="..." TAMOZ_MODEL="gpt-5-mini" \
  bundle exec tamoz --root . --allow-changes \
  --check 'test=bundle exec rake test' "Fix the failing test"
```

Every run drafts and reviews a plan before any workspace tool executes. Change mode first
runs a reviewed read-only discovery plan, then reviews an evidence-backed action plan. The
CLI displays and asks for approval of every exact patch and configured command. Failed
checks can drive at most two separately reviewed repairs with fresh approvals. Durable
sessions, memory, recovery, skills, MCP, scheduling, and physical-world streams follow as
separate vertical slices.
