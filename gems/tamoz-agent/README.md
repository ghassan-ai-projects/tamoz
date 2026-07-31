# tamoz-agent

The first usable Tamoz Agent slice is a read-only workspace assistant. It performs a real
RubyLLM call to draft a plan, runs deterministic structural review and an isolated semantic
review, executes only the accepted plan, and performs a final evidence-bound verification.

```sh
export OPENAI_API_KEY="..."
export TAMOZ_MODEL="gpt-5-mini"
bundle exec tamoz --root /path/to/project "Explain how authentication works"
```

Use `--provider`, `--model`, and `--json` to select another RubyLLM provider/model or emit
machine-readable events. The current built-in tools are `read_file`, `list_directory`, and
`search_text`; all resolve symlinks and remain confined to `--root`.

This is deliberately a walking skeleton, not the completed v0.1 runtime. It does not yet
mutate files, run shell commands, checkpoint sessions, resume after crashes, or activate
memory, self-healing, skills, MCP, scheduling, or streaming inputs. Those features remain in
the accepted design and will be added as vertical product slices.
