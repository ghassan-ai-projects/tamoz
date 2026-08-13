# Configuration

Everything Tamoz can be configured to do is operator authority: environment
variables for the model, a trusted profile for project authority, and a
runtime directory for unattended work. Content — a task, model output, a skill,
MCP metadata — can never widen any of it.

Current version: `0.1.0.alpha.1` (pre-release).

## Environment variables

| Variable | Meaning |
|---|---|
| `TAMOZ_MODEL` | RubyLLM model identifier (e.g. `gpt-5-mini`) |
| `TAMOZ_PROVIDER` | RubyLLM provider (default: `openai`) |
| `OPENAI_API_KEY` | Credential for the default provider |
| `ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY`, ... | Credentials for other providers — the provider's own standard variable |
| `TAMOZ_TELEGRAM_BOT_TOKEN` | Telegram bot token, referenced by NAME in channel config |
| `TAMOZ_RUNTIME_DIR` | Operator runtime directory (alternative to `--runtime-dir`) |
| `TAMOZ_SESSION_DIR` | Default durable session directory |
| `TAMOZ_PROFILE` / `TAMOZ_PROFILE_ID` | Default profile selection |
| `TAMOZ_CONFIG_HOME` | Redirects the whole operator config tree (profiles, registries) |
| `TAMOZ_LEASE_TTL` | Writer lease TTL in seconds, within `(0, 30]` |
| `TAMOZ_WEBSEARCH_GRANT` / `TAMOZ_WEBSEARCH_EGRESS` / `TAMOZ_WEBSEARCH_PROVIDER` | Governed websearch gates |

Model precedence is CLI flag > `TAMOZ_MODEL`/`TAMOZ_PROVIDER` > the profile's
`primary` role. A profile role may reference a credential by NAME via
`credential_ref`; a referenced variable that is not set fails typed at session
start rather than silently falling back.

## The operator runtime directory: `~/.tamoz`

Unattended work runs against an operator-owned **runtime directory** — one
directory holds the configuration, the trusted profiles, and a single SQLite
database with the schedules, the request inboxes and the checkpoints.

```text
~/.tamoz/config.yaml          operator configuration (schema 2)
~/.tamoz/profiles/*.yaml      trusted profiles
~/.tamoz/runtime.sqlite3      the durable runtime database
```

Create it with `tamoz init --workspace PATH`. The directory carries unattended
authority, so Tamoz refuses to use one that is readable or writable by group or
others. Keep it private (`0700` directory, `0600` files).

### `config.yaml` (schema 2)

`config.yaml` carries the workspace root, `sources:` (skills, memory, MCP,
websearch), `budgets:` and `channels:`. A schema 1 directory loads unchanged as
"no channels"; migrate explicitly with a backup and atomic rename:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz config migrate
```

An example fragment:

```yaml
sources:
  skills:
    enabled: true
    root: skills          # relative to the runtime directory
  memory:
    enabled: true
    tenant: acme
    owner: alice
  mcp:
    enabled: true
    servers:
      - id: notes
        command: /usr/bin/ruby
        arguments: [/opt/notes-mcp/server.rb]
        env_allowlist: [PATH, HOME]
        read_only_tools: [search_notes]
  websearch:
    enabled: true
    command: /opt/websearch/adapter
    env_allowlist: [PATH, HOME]
budgets:
  model_calls: 40
  wall_clock_seconds: 900
channels:
  telegram-ops:
    kind: telegram
    revision: 1
    enabled: true
    profile: ops
    credential_ref: {kind: env, name: TAMOZ_TELEGRAM_BOT_TOKEN}
    expected_bot_id: 7463512990
    threading: conversation
    admission:
      direct: allowlist
      correspondents: ["telegram:user:11111111"]
    approvals:
      mode: deny_only
      prompt_ttl_s: 900
```

## Trusted profiles

A profile stores project authority OUTSIDE the repository being worked on. It is
a schema-v1 YAML document that pins the canonical root, the named checks, the
model roles, the budgets and a policy digest, and is validated fail-closed: no
code execution, no aliases beyond a small count, no interpolation, no embedded
secrets, owner-only permissions.

```yaml
profile:
  schema_version: 1
  profile_id: ops
  profile_version: "1.0"
  canonical_root: /path/to/project
roots:
  workspace: /path/to/project
model_roles:
  primary: {provider: openai, model: gpt-5-mini, credential_ref: {kind: env, name: OPENAI_API_KEY}}
budgets:
  model_calls: 40
  wall_clock_seconds: 900
checks:
  test: {argv: [rbenv, exec, bundle, exec, rake, test], safety: read_only}
tools:
  allowed: [list_directory, read_file, search_text, apply_patch]
policy:
  allow_changes: true
  default_check_safety: read_only
  behavior_version: tamoz.agent.session/1
  tool_catalog_digest: sha256:...
unattended:
  read_only: [list_directory, read_file, search_text]
  reconcilable: [apply_patch]
  forbidden: []
```

Key facts:

- **The digest is the authority.** Every profile carries a canonical digest
  (`sha256:` over the normalized data model). A durable session pins the digest
  it was planned under; a changed profile re-prompts rather than silently
  taking effect, and a session whose catalog matches neither pinned digest is
  refused.
- **`suggested-profile.yaml` is suggestion-only.** A file in the repository
  (`.tamoz/suggested-profile.yaml`) can suggest configuration; it never becomes
  executable authority without an explicit `preview` + `import` + confirmation.
  Loading one directly is refused.
- **Adoption is explicit.** `profile preview PATH` validates and renders
  without adopting; `profile import PATH` installs the exact validated bytes
  into the operator profile directory and activates them after confirmation;
  `profile activate --thread THREAD --digest DIGEST` records a candidate digest
  transition that takes effect at the next turn boundary.
- **An imported profile is inert until activated.** A profile in
  `~/.tamoz/profiles/` only applies when a command selects it.

The `unattended` section preauthorizes what a worker may do with nobody
watching; anything not listed pauses durably and waits for a human, and
`forbidden` wins over every other list.

## Next reads

- [`../getting-started/install.md`](../getting-started/install.md) — the full subcommand surface.
- [`../guides/agent-operator.md`](../guides/agent-operator.md) — the operator runbook.
- [`../limitations.md`](../limitations.md) — which budget keys are enforced, and what is not there yet.
