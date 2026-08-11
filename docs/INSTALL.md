# Installing and running Tamoz

Every command on this page is checked against the real surface by
`test/documentation_surface_test.rb`: the CLI flags and subcommands shown here
must exist, and the gem list must match what the repository actually packages.

Read [`LIMITATIONS.md`](LIMITATIONS.md) before you build on any of it.

## Requirements

| Requirement | Value |
|---|---|
| Ruby | `>= 3.3, < 5.0` (the repository pins `3.3.11` in `.ruby-version`) |
| Bundler | the version in `Gemfile.lock`'s `BUNDLED WITH` |
| SQLite | via the `sqlite3` gem (`~> 2.9`); no server to run |
| Model access | any provider RubyLLM supports, through its own API key |
| Locale | either a UTF-8 locale or `LC_ALL=C` — both are gated in CI |

## From the repository

```bash
git clone https://github.com/ghassan-ai-projects/tamoz.git
```

```bash
cd tamoz && rbenv exec bundle install
```

```bash
rbenv exec bundle exec rake ci
```

`rake ci` runs design validation, a `ruby -wc` syntax pass over every source
file, and the whole test suite. It must be green before you trust anything else
on this page.

## The nine gems

Tamoz is a monorepo of independently publishable gems. Each one installs and
runs with only its declared dependencies — proven per gem by
`test/packaging_test.rb`, which installs each into its own `GEM_HOME` and runs a
named example task in a clean subprocess.

| Gem | What it is | Depends on |
|---|---|---|
| `tamoz-core` | Shared values, context, secrets, codec, pool | stdlib, Zeitwerk |
| `tamoz-graph` | Deterministic graph execution and durability contracts | `tamoz-core` |
| `tamoz-scheduler` | Schedule/occurrence values and the store contract | `tamoz-core` |
| `tamoz-stream` | Channels, envelopes, Situations, action boundary | `tamoz-core` |
| `tamoz-comms` | Channel values, admission policy, rendering, transport and store contracts | `tamoz-core` |
| `tamoz-telegram` | Telegram Bot API transport adapter | `tamoz-comms` |
| `tamoz-observability` | Signal catalog, derived correlation, Signal value, Recorder contract | `tamoz-core` |
| `tamoz-otel` | Optional governed OTLP/HTTP exporter | `tamoz-observability` |
| `tamoz-sqlite` | The durable adapter: checkpoints, inbox, effects, leases | `tamoz-graph`, `tamoz-scheduler`, `tamoz-stream`, `sqlite3` |
| `tamoz-tools` | The workspace toolbox and the skills compiler | `tamoz-core` |
| `tamoz-agent` | The deliberative agent runtime and the `tamoz` CLI | `tamoz-graph`, `tamoz-tools`, `tamoz-observability` |
| `tamoz-mcp` | Governed MCP client/host and websearch | `tamoz-core`, the official MCP SDK |
| `tamoz-evals` | Conformance, artifact verification, release evidence | stdlib only |

`tamoz-evals` is a non-runtime gem: no production gemspec may depend on it, and
`test/dependency_isolation_test.rb` enforces that.

## Running the agent

Read-only is the default. Nothing is written without `--allow-changes`, and
nothing is written without an approval you granted.

```bash
export OPENAI_API_KEY="..." && export TAMOZ_MODEL="gpt-5-mini"
```

```bash
rbenv exec bundle exec tamoz --root . "Explain the persistence boundary"
```

To let it change files, opt in and configure the check it must satisfy. The
model can choose to run `test`; it can never alter that command's arguments.

```bash
rbenv exec bundle exec tamoz --root . --allow-changes --check 'test=rbenv exec bundle exec rake test' "Fix the failing test"
```

The fused request router is opt-in while its qualification corpus is being
built. Use `--experimental-routing` for self-contained questions and short
writing requests; it falls back to the standard reviewed workflow for work,
current-state, or ambiguous requests. A direct response is reported as
`responded`, not as verified task completion.

Use `--shadow-routing` to record a route decision while retaining the standard
reviewed workflow; shadow records contain route, outcome, call count, and a
bounded disagreement reason, never the candidate answer.

### Durable sessions

Pass `--session-dir` and the turn becomes a durable thread: it survives
`kill -9`, resumes from its last committed barrier, and reconciles an
interrupted effect from proven state instead of guessing.

```bash
rbenv exec bundle exec tamoz --session-dir ~/.tamoz/sessions --session fix-parser --root . ask "Fix the parser"
```

```bash
rbenv exec bundle exec tamoz --session-dir ~/.tamoz/sessions list
```

The interactive subcommands drive one thread while you watch it.

| Subcommand | What it does |
|---|---|
| `ask` | Start a new turn on a thread |
| `resume` | Answer the approvals or questions a paused thread is waiting on |
| `continue` | Drive a paused thread forward without new input |
| `list` | Show every thread in the session directory |
| `show` | Render one thread's state, plan digest, receipts and outcome |
| `follow-up` | Queue another turn behind the current one |
| `redirect` | Replace the goal of an in-flight turn |
| `cancel` | Route a thread to a terminal cancellation |
| `resolve` | Record a human decision about an `:unknown` effect |
| `profile` | Preview, import, list, show and activate trusted profiles |

Add `--json` to any of them for a newline-delimited JSON event stream, and
`--non-interactive` to fail instead of prompting.

## Running unattended

The unattended subcommands work against an operator-owned **runtime directory**
rather than a session directory. One directory holds the configuration, the
trusted profiles, and a single SQLite database containing the schedules, the
request inboxes and the checkpoints.

| Subcommand | What it does |
|---|---|
| `init` | Create the runtime directory for a workspace |
| `queue` | Submit a task durably (`add`), or list pending work (`list`) |
| `worker` | Run the foreground worker that executes queued and scheduled work |
| `status` | Report pending work, capability sources and safety counters |
| `schedule` | `add`, `list`, `show`, `pause`, `resume`, `remove`, `run-now`, `occurrences` |
| `approve` | Grant (or `--deny`) a paused approval so its occurrence can resume |
| `observe` | Tail the local journal, render metrics, or run the redaction self-test |
| `trace` | Reconstruct the journal view for one thread from durable correlation identity |
| `comms` | The channel surface: `serve`, `list`, `pair`, `delivery resolve`, `doctor` (below) |
| `config` | Explicit configuration migration (`migrate`) |

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz init --workspace .
```

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz queue add --task "Summarise the test suite"
```

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz schedule add --id health --interval 3600 --task "Report repository health"
```

`worker` is an ordinary foreground process. It writes JSON events to stdout,
exits 0 on `SIGINT`/`SIGTERM` after finishing the turn in hand, and holds no PID
file — so launchd, systemd, Docker or runit supervise it the way they supervise
anything else. Tamoz does not ship a daemon manager.

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz worker --json
```

`--once` drains everything available and exits, which is what you want from cron
or from a test. `--concurrency N` bounds how many threads are worked in parallel;
one thread is never worked by two workers at once, because each claim takes a
fenced lease.

### Observability

Workers write bounded, rotating signal journals under the runtime directory. The
journal is observer-only and does not share the SQLite writer path.

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz observe tail --follow --json
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz observe metrics --format prometheus
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz observe doctor --json
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz trace THREAD --json
```

Content capture is disabled by default. Signals carry a policy digest and a digest/size
pair for omitted content. `tamoz-otel` is optional; its exporter refuses redirects,
non-HTTPS endpoints, proxy environment variables, and private destinations unless the
operator explicitly opts into local delivery.

A worker never answers a question on your behalf. Work that needs an approval
pauses durably and is reported by `status`; being headless is not a reason to
proceed.

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz status --json
```

The runtime directory carries unattended authority, so Tamoz refuses to use one
that is readable or writable by group or others.

### Capability sources

An operator turns on what Tamoz ships, in `config.yaml`. Nothing else can:
neither the workspace, nor model output, nor a skill, nor MCP metadata.

```yaml
sources:
  skills:
    enabled: true
    root: skills          # relative to the runtime directory
  memory:
    enabled: true
    tenant: acme
    owner: alice
```

Skills are the clearest case. A skill body is INSTRUCTIONS the agent will follow,
so the skills root must live outside the workspace — pointing it inside the tree
being worked on is refused, not quietly ignored. Enabling skills changes the tool
catalog, so the profile's pinned digests must be recomputed; the digest is
authority and re-pinning is a deliberate act.

`tamoz status --json` reports both `capability_sources` (what the operator asked
for) and `capability_catalog` (what the agent can actually dispatch). They differ
whenever a source is configured but not yet wired, which is a state you should be
able to see rather than infer.

Memory scopes its namespace by `tenant` and admits episodes under `owner`, both
from operator configuration and never from a task, a model or the workspace.
Memory is evidence the agent may read; it never alters policy.

### Telegram channel setup

Channels are a sibling of `sources:` — they are user surfaces, not capabilities
the model can call. Schema 2 config carries a strict `channels:` mapping; a
schema 1 directory loads unchanged as "no channels", and `tamoz config migrate`
performs the explicit, backup-and-atomic-rename migration:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz config migrate
```

First authenticate the bot and copy its numeric id into config — bootstrap
prints it and never persists or trusts it automatically:

```bash
export TAMOZ_TELEGRAM_BOT_TOKEN=<token from BotFather>
rbenv exec bundle exec tamoz comms doctor --bootstrap \
  --credential-ref TAMOZ_TELEGRAM_BOT_TOKEN
```

Then configure the surface. The token is referenced by NAME, never by value:

```yaml
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

`tamoz comms doctor` checks getMe against `expected_bot_id`, TLS, permissions,
the webhook/poller conflict, and the token — each failure is named and exits 1.
The gateway is a separate foreground process:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz comms serve --json
```

The gateway holds the bot token and never constructs a session, loads a model
credential, or opens a file under the workspace root. Installations without the
`tamoz-telegram` gem still run the agent and report a typed missing-adapter
error for `tamoz comms serve`.

An MCP server is a supervised subprocess, so its configuration is explicit and
nothing is inferred from the environment:

```yaml
sources:
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
```

Websearch is not a separate mechanism: it is an MCP server whose id is the
reserved `websearch`, which is what keeps it one of the four closed-world sources
rather than a fifth. A generic server may not claim that id.

Three rules hold for every server. The catalog is **pinned** at construction, so
a server that grows a tool later cannot silently widen what the agent may do.
Risk classification is **operator policy**: a server describes its tools but does
not get to say how dangerous they are, and any tool not named in
`read_only_tools` is treated as unknown-effects. And the server's working
directory is never the agent's workspace, so it cannot run inside the tree under
repair.

Wired today: **skills**, **memory**, **MCP** and **websearch**. Streaming input
is NOT reachable from the worker — see [`docs/LIMITATIONS.md`](LIMITATIONS.md).

### Budgets

A profile can put a ceiling on unattended work:

```yaml
budgets:
  model_calls: 40
  wall_clock_seconds: 900
```

These two are ENFORCED, and enforced by the worker rather than by the run itself:
model calls are counted from the effect journal, wall clock from the occurrence
record the worker opened at claim time. Neither number is reachable from a task,
model output or a workspace file, so a run cannot widen its own ceiling.

Exhaustion is terminal for that occurrence: it stops, records a durable
`budget_exhaustions` entry visible in `tamoz status --json`, and does not resume
on the next poll. Raising the ceiling and re-queueing is the deliberate way to
continue.

The other budget keys (`cost_usd`, `input_tokens`, `output_tokens`, `steps`) are
recorded and pinned but NOT enforced — see [`docs/LIMITATIONS.md`](LIMITATIONS.md).

### What may run without you

A trusted profile can add an `unattended` section. It is a separate axis from
`tools`: `tools.allowed` is what the agent may ever do on this project, and
`unattended` is what a worker may do with nobody watching.

```yaml
tools:
  allowed: [list_directory, read_file, search_text, apply_patch]
unattended:
  read_only: [list_directory, read_file, search_text]
  reconcilable: [apply_patch]
  forbidden: []
```

Anything the section does not preauthorize pauses durably and waits for a human,
even though no human is present — that is the whole point. `forbidden` wins over
every other list, so a tool named there can never run unattended regardless of
what else claims it. A profile with no `unattended` section preauthorizes
nothing.

Because the two situations have different tool surfaces, a profile that is used
unattended pins a second digest, `policy.unattended_catalog_digest`, alongside
`policy.tool_catalog_digest`. A session whose catalog matches neither is refused.

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz approve REQUEST_ID
```

Approval records a decision; it does not execute anything. The worker picks the
decision up on its next pass and resumes the same occurrence. An approval answers
exactly one occurrence and never carries to the next.

## Trusted profiles

A profile stores project authority OUTSIDE the repository being worked on, so a
file in an untrusted checkout can suggest configuration but never become
executable authority. It pins the canonical root, the named checks, the model
roles, the budgets and a policy digest.

```bash
rbenv exec bundle exec tamoz profile preview ./tamoz.suggested.yml
```

```bash
rbenv exec bundle exec tamoz profile import ./tamoz.suggested.yml
```

An imported profile is inert until you activate it, and a changed profile
re-prompts rather than silently taking effect on an existing thread.

## Verifying a release candidate

```bash
rbenv exec ruby script/release_rehearsal
```

This clones the current commit into a temporary directory, provisions the
pinned toolchain, installs offline, runs the full gate in both locales, runs the
scorecard, installs every packaged gem in isolation, exercises durable
restore/resume, and writes [`RELEASE_REHEARSAL.md`](RELEASE_REHEARSAL.md).

```bash
rbenv exec bundle exec ruby script/generate_requirements_audit --jobs 4
```

This runs every named test in the requirements manifest and regenerates
[`REQUIREMENTS_AUDIT.md`](REQUIREMENTS_AUDIT.md). A row is `pass` only because
its test executed and passed in that run.
