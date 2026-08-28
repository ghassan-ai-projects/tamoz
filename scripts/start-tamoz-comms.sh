#!/usr/bin/env bash
# start-tamoz-comms.sh
# Launch the tamoz Telegram gateway + worker so tamoz can talk to ALMS over MCP.
# Usage: ./scripts/start-tamoz-comms.sh [--stop]
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="$HOME/.rbenv/shims:/usr/bin:/bin:/usr/sbin:/sbin"

# Load .env WITHOUT exporting wholesale: C7 (PLAN_ADR049 Phase 6) gives each
# child exactly its own environment via `env -i`, so the whole file must
# never reach a process. The parent may hold the values; the children get
# only their allowlists.
# Format seen in this repo: "KEY = value" (spaces around =, values are
# bare, no quotes). Handles trailing space in the key name and preserves the
# value as-is (stripping surrounding whitespace but not quote characters,
# since values here are unquoted).
load_env() {
  local file="$1"
  [ -f "$file" ] || return 0
  local name val line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    [[ "$line" == *=* ]] || continue
    name="${line%%=*}"
    name="${name//[[:space:]]/}"          # drop spaces in key ("KEY " -> "KEY")
    val="${line#*=}"
    val="${val%$'\r'}"                    # strip trailing CR
    # trim leading/trailing whitespace around value
    val="${val#" "}"
    val="${val#"\t"}"
    val="${val%" "}"
    val="${val%"\t"}"
    # strip one layer of matching quotes if present
    if [[ "$val" =~ ^\"(.*)\"$ ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ "$val" =~ ^'(.*)'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    export "$name=$val"
  done < "$file"
}
load_env .env

: "${TAMOZ_RUNTIME_DIR:=$HOME/.tamoz}"
: "${TAMOZ_MODEL:=deepseek-chat}"
: "${TAMOZ_PROVIDER:=deepseek}"
: "${TAMOZ_TELEGRAM_SURFACE:=telegram-ops}"
export TAMOZ_RUNTIME_DIR TAMOZ_MODEL TAMOZ_PROVIDER TAMOZ_TELEGRAM_SURFACE

RUBY_BIN="${TAMOZ_RUBY_BIN:-$(command -v ruby || true)}"
if [ -z "$RUBY_BIN" ] || [ ! -x "$RUBY_BIN" ]; then
  echo "ERROR: Ruby is not available. Add the project Ruby to PATH or set TAMOZ_RUBY_BIN."
  exit 1
fi

if ! command -v bundle >/dev/null 2>&1; then
  echo "ERROR: Bundler is not available for the project Ruby."
  exit 1
fi

# Build the bundle load path so plain `ruby <exe>` finds tamoz gems.
RUBYLIB="$(bundle exec ruby -e 'puts $LOAD_PATH.reject{|p| p=="/"||p==""}.join(":")')"
GEM_HOME="$(bundle exec ruby -e 'require "rubygems"; puts Gem.dir')"
GEM_PATH="$(bundle exec ruby -e 'require "rubygems"; puts Gem.path.join(":")')"
export RUBYLIB GEM_HOME GEM_PATH

EXE="$PWD/gems/tamoz-agent/exe/tamoz"
GATEWAY_LOG=/tmp/tamoz_gateway.log
WORKER_LOG=/tmp/tamoz_worker.log

stop_all() {
  echo "Stopping tamoz gateway + worker..."
  # Match by runtime dir + subcommand, NOT the repo exe path: a worker started
  # from the installed gem binstub (or a different checkout) would otherwise
  # survive --stop and keep processing (or hot-looping) against the same DB.
  pkill -f "tamoz.*--runtime-dir $TAMOZ_RUNTIME_DIR.*comms serve" 2>/dev/null || true
  pkill -f "tamoz.*--runtime-dir $TAMOZ_RUNTIME_DIR.*worker" 2>/dev/null || true
  echo "done."
}

start_one() {
  local name="$1"; shift
  local log="$1"; shift
  # Env entries come before `--`, the command after it.
  local envs=()
  while [ "${1:-}" != "--" ]; do
    envs+=("$1"); shift
  done
  shift
  # Fully detach: double-fork via a subshell + nohup + disown. The redirected
  # stdin means it never blocks on a tty, and nohup keeps it after this shell.
  ( nohup env -i "${envs[@]}" "$@" > "$log" 2>&1 < /dev/null & )
  echo "$name started (log: $log)"
}

if [ "${1:-}" = "--stop" ]; then
  stop_all
  exit 0
fi

# Preflight: use the operator's configured ALMS endpoint. The endpoint is
# deliberately not duplicated here, so local network details stay local.
alms_endpoint() {
  if [ -n "${TAMOZ_ALMS_MCP_ENDPOINT:-}" ]; then
    printf '%s\n' "$TAMOZ_ALMS_MCP_ENDPOINT"
    return 0
  fi

  local config="$TAMOZ_RUNTIME_DIR/config.yaml"
  [ -f "$config" ] || return 1
  bundle exec ruby -rpsych -e '
    document = Psych.safe_load_file(ARGV.fetch(0), permitted_classes: [], aliases: false)
    server = Array(document.dig("sources", "mcp", "servers")).find { |entry| entry.is_a?(Hash) && entry["id"] == "alms" }
    puts server.fetch("endpoint")
  ' "$config"
}

ALMS_MCP_ENDPOINT="$(alms_endpoint 2>/dev/null || true)"
if [ -z "$ALMS_MCP_ENDPOINT" ]; then
  echo "WARNING: no ALMS MCP endpoint is configured in the runtime config."
  echo "Continuing anyway (gateway will run, but ALMS calls will fail)."
elif ! curl -sf -m 4 -X POST "$ALMS_MCP_ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' >/dev/null 2>&1; then
  echo "WARNING: configured ALMS MCP endpoint is not reachable."
  echo "Continuing anyway (gateway will run, but ALMS calls will fail)."
else
  echo "ALMS MCP preflight succeeded using the configured endpoint."
fi

stop_all
sleep 1

start_one "gateway" "$GATEWAY_LOG" \
  "PATH=$PATH" "HOME=$HOME" "LANG=${LANG:-C}" "LC_ALL=${LC_ALL:-}" \
  "TMPDIR=${TMPDIR:-/tmp}" "GEM_HOME=$GEM_HOME" "GEM_PATH=$GEM_PATH" \
  "RUBYLIB=$RUBYLIB" "TAMOZ_RUNTIME_DIR=$TAMOZ_RUNTIME_DIR" \
  "TAMOZ_TELEGRAM_SURFACE=$TAMOZ_TELEGRAM_SURFACE" \
  "TAMOZ_TELEGRAM_BOT_TOKEN=$TAMOZ_TELEGRAM_BOT_TOKEN" \
  -- \
  "$RUBY_BIN" "$EXE" \
  --runtime-dir "$TAMOZ_RUNTIME_DIR" \
  --provider "$TAMOZ_PROVIDER" --model "$TAMOZ_MODEL" \
  comms serve --surface "$TAMOZ_TELEGRAM_SURFACE"

# A fresh runtime DB is migrated by whichever process opens it first; the
# worker starting simultaneously would race that migration and die on a lock.
# Let the gateway finish first, then start the worker.
sleep 2

start_one "worker" "$WORKER_LOG" \
  "PATH=$PATH" "HOME=$HOME" "LANG=${LANG:-C}" "LC_ALL=${LC_ALL:-}" \
  "TMPDIR=${TMPDIR:-/tmp}" "GEM_HOME=$GEM_HOME" "GEM_PATH=$GEM_PATH" \
  "RUBYLIB=$RUBYLIB" "TAMOZ_RUNTIME_DIR=$TAMOZ_RUNTIME_DIR" \
  "TAMOZ_PROVIDER=$TAMOZ_PROVIDER" "TAMOZ_MODEL=$TAMOZ_MODEL" \
  "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY" \
  "TAMOZ_ALMS_MCP_ENDPOINT=$ALMS_MCP_ENDPOINT" \
  -- \
  "$RUBY_BIN" "$EXE" \
  --runtime-dir "$TAMOZ_RUNTIME_DIR" \
  --provider "$TAMOZ_PROVIDER" --model "$TAMOZ_MODEL" \
  worker --concurrency 1 --experimental-routing

echo
echo "Waiting 8s to verify they stay up..."
sleep 8
gateway_up="$(pgrep -f "tamoz.*--runtime-dir $TAMOZ_RUNTIME_DIR.*comms serve" | head -1)"
worker_up="$(pgrep -f "tamoz.*--runtime-dir $TAMOZ_RUNTIME_DIR.*worker" | head -1)"
echo "Gateway process: $([ -n "$gateway_up" ] && echo RUNNING || echo DOWN)"
echo "Worker  process: $([ -n "$worker_up" ] && echo RUNNING || echo DOWN)"
echo "-- gateway log --"; tail -5 "$GATEWAY_LOG" 2>/dev/null || true
echo "-- worker log --"; tail -5 "$WORKER_LOG" 2>/dev/null || true
if [ -z "$worker_up" ] || [ -z "$gateway_up" ]; then
  echo
  echo "ERROR: a tamoz process did not stay up (see the logs above)."
  echo "A worker that dies at startup usually cannot build the MCP session"
  echo "(e.g. ALMS unreachable from this process context)."
  exit 1
fi
echo
echo "Done. Chat with @tamoz_agent_bot to test ALMS MCP."
