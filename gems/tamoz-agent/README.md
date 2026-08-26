# tamoz-agent

Tamoz Agent is a reviewed workspace assistant. It performs real provider calls through the
digest-bound OpenAI-compatible transport to draft a
plan, runs deterministic structural review and an isolated semantic review, executes only
accepted plans, and performs final evidence-bound verification. Read-only operation is the
default.

```sh
export OPENAI_API_KEY="..."
export TAMOZ_MODEL="gpt-5-mini"
bundle exec tamoz --root /path/to/project "Explain how authentication works"

# Opt in to approved atomic patches and a named check.
bundle exec tamoz --root /path/to/project --allow-changes \
  --check 'test=bundle exec rake test' "Fix the failing test"
```

Use `--provider`, `--model`, and `--json` to select another supported provider/model or emit
machine-readable events. Read tools resolve symlinks but remain confined to `--root`.
`apply_patch` rejects symlinks, stale digests, missing text, and ambiguous replacements.
`run_check` can select only a user-configured name; it never accepts command text from the
model. Both tools require interactive approval. A failed check may drive at most two newly
reviewed repair plans. Every repair effect requires fresh approval, while repeated actions,
repeated failures, and exhausted attempts stop with an unsatisfied result.

This is deliberately a walking skeleton, not the completed v0.1 runtime. It does not expose
an arbitrary shell, create files, checkpoint sessions, resume after crashes, or activate
memory, self-healing, skills, MCP, scheduling, or streaming inputs. Those features remain in
the accepted design and will be added as vertical product slices.
