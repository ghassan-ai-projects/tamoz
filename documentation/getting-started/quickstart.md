# Quickstart

The golden path: clone Tamoz, verify the gate, ask a read-only question, then
let it make a reviewed change. You should get value within ten minutes.

Current version: `0.1.0.alpha.1` (pre-release).

Full system requirements are on [`install.md`](install.md).

## 1. Clone and install

```bash
git clone https://github.com/ghassan-ai-projects/tamoz.git
cd tamoz
rbenv exec bundle install
```

## 2. Verify the gate

The whole test suite must be green before you trust anything else:

```bash
rbenv exec bundle exec rake ci
```

`rake ci` runs design validation, a syntax pass over every source file, and the
test suite.

## 3. Configure a model

Tamoz needs a model provider. The OpenAI-compatible path is two environment
variables:

```bash
export OPENAI_API_KEY="..."
export TAMOZ_MODEL="gpt-5-mini"
```

For another provider, set the provider and model explicitly; the credential
stays in the provider's normal environment variable:

```bash
export DEEPSEEK_API_KEY="..."
export TAMOZ_PROVIDER="deepseek" TAMOZ_MODEL="deepseek-v4-flash"
```

## 4. Ask a read-only question

Read-only is the default. Nothing is written without `--allow-changes`, and
nothing is written without an approval you granted:

```bash
rbenv exec bundle exec tamoz --root . "Explain the persistence boundary and cite local files"
```

The agent discovers the workspace, drafts and reviews a plan, runs its tools,
and reports. Without `--allow-changes` it can only read.

## 5. The approved change loop

To let it change files, opt in and configure the check it must satisfy. The
model can choose to run the `test` check; it can never alter that command's
arguments:

```bash
rbenv exec bundle exec tamoz --root . --allow-changes \
  --check 'test=rbenv exec bundle exec rake test' \
  "Fix the failing test"
```

The flow is: discovery reads, a separately reviewed action plan, an exact diff
shown before approval, a digest-bound atomic patch, and the configured
verification command. A failed check becomes evidence for up to two newly
reviewed repairs with fresh approvals; a repeated action or a repeated failure
stops safely rather than looping.

## Next steps

- Make sessions durable across `kill -9`: [`sessions.md`](sessions.md).
- Run work unattended (queue, schedule, worker): [`install.md`](install.md).
- Talk to it over Telegram: [`../guides/telegram.md`](../guides/telegram.md).
- The honest list of what is not there yet: [`../limitations.md`](../limitations.md).
