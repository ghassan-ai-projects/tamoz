#!/usr/bin/env bash
# start-tamoz-comms.sh
# Launch the tamoz Telegram gateway + worker so tamoz can talk to ALMS over MCP.
# Usage: ./scripts/start-tamoz-comms.sh [--stop]
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="$HOME/.rbenv/shims:/usr/bin:/bin:/usr/sbin:/sbin"

# Load .env. Format seen in this repo: "KEY = value" (spaces around =, values are
# bare, no quotes). Handles trailing space in the key name and preserves the value
# as-is (stripping surrounding whitespace but not quote characters, since values
# here are unquoted).
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
export TAMOZ_RUNTIME_DIR

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
  pkill -f "$PWD/gems/tamoz-agent/exe/tamoz.*comms serve" 2>/dev/null || true
  pkill -f "$PWD/gems/tamoz-agent/exe/tamoz.*worker" 2>/dev/null || true
  echo "done."
}

start_one() {
  local name="$1"; shift
  local log="$1"; shift
  # Fully detach: double-fork via a subshell + nohup + disown. The redirected
  # stdin means it never blocks on a tty, and nohup keeps it after this shell.
  ( nohup "$@" > "$log" 2>&1 < /dev/null & )
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
  "$HOME/.rbenv/versions/3.3.11/bin/ruby" "$EXE" \
  --runtime-dir "$TAMOZ_RUNTIME_DIR" \
  --provider "$TAMOZ_PROVIDER" --model "$TAMOZ_MODEL" \
  comms serve --surface telegram-ops

start_one "worker" "$WORKER_LOG" \
  "$HOME/.rbenv/versions/3.3.11/bin/ruby" "$EXE" \
  --runtime-dir "$TAMOZ_RUNTIME_DIR" \
  --provider "$TAMOZ_PROVIDER" --model "$TAMOZ_MODEL" \
  worker --concurrency 1

echo
echo "Waiting 8s to verify they stay up..."
sleep 8
echo "Gateway process: $(pgrep -f 'comms serve' >/dev/null && echo RUNNING || echo DOWN)"
echo "Worker  process: $(pgrep -f 'worker' >/dev/null && echo RUNNING || echo DOWN)"
echo "-- gateway log --"; tail -5 "$GATEWAY_LOG" 2>/dev/null || true
echo "-- worker log --"; tail -5 "$WORKER_LOG" 2>/dev/null || true
echo
echo "Done. Chat with @tamoz_agent_bot to test ALMS MCP."
