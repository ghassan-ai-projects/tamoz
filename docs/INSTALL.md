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
| `tamoz-sqlite` | The durable adapter: checkpoints, inbox, effects, leases | `tamoz-graph`, `tamoz-scheduler`, `tamoz-stream`, `sqlite3` |
| `tamoz-tools` | The workspace toolbox and the skills compiler | `tamoz-core` |
| `tamoz-agent` | The deliberative agent runtime and the `tamoz` CLI | `tamoz-graph`, `tamoz-tools` |
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

A worker never answers a question on your behalf. Work that needs an approval
pauses durably and is reported by `status`; being headless is not a reason to
proceed.

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz status --json
```

The runtime directory carries unattended authority, so Tamoz refuses to use one
that is readable or writable by group or others.

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
