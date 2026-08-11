# ALMS MCP → Telegram live test

This repository now has two proofs:

- `tamoz ask` builds the configured MCP source and can execute a source-qualified ALMS tool.
- Telegram delivery follows the production boundary: `queue` → `worker` → durable outbox → `comms serve`.

The runnable harness is `script/live_alms_telegram`. It prints bounded phase markers and exits non-zero unless the worker completes and a Telegram answer row reaches `succeeded`.

## Preconditions

The operator runtime must contain:

```yaml
sources:
  mcp:
    enabled: true
    servers:
      - id: alms
        transport: http
        endpoint: "http://127.0.0.1:8001/mcp"
        read_only_tools:
          - learning.search

channels:
  telegram-ops:
    enabled: true
    profile: ops
```

Use HTTPS for a non-loopback ALMS endpoint. The loopback endpoint above assumes the managed SSH tunnel from the integration findings is already running. The Telegram surface must be configured with the real bot identity and an active conversation route; send one message to the bot first if `comms list` shows no route.

## Run

Set the model and transport credentials in the environment. Values are never printed by the harness.

```bash
export TAMOZ_PROVIDER=deepseek
export TAMOZ_MODEL=deepseek-chat
export DEEPSEEK_API_KEY='…'
export TAMOZ_TELEGRAM_BOT_TOKEN='…'

PATH="$HOME/.rbenv/shims:$PATH" bundle exec ruby script/live_alms_telegram \
  --runtime-dir ~/.tamoz
```

Use `--thread THREAD_ID` when more than one Telegram conversation is configured. Run `--preflight-only` to validate the ALMS catalog, model credential, Telegram doctor, and route without queueing work.

Expected terminal phases include `catalog_pinned`, `telegram_preflight_ok`, `delivery_queued`, `mcp_call_succeeded`, `summary_ready`, and `delivery_succeeded`. A successful result is the combination of the completed worker event and the `succeeded` Telegram outbox row; process exit `0` alone is not sufficient.
