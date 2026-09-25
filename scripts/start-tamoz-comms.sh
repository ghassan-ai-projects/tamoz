#!/usr/bin/env bash
# start-tamoz-comms.sh
# Launch the Tamoz Telegram gateway + worker. The supported path is one setup
# and one start; this script is a thin launcher for operators who keep it in
# their history, and it loads `.env` (KEY = value) for the secrets.
#
#   ./scripts/start-tamoz-comms.sh [--runtime-dir PATH] [--provider P --model M]
#
# Ctrl-C stops both processes. Configure the channel once first with:
#   tamoz --runtime-dir PATH telegram setup
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="$HOME/.rbenv/shims:/usr/bin:/bin:/usr/sbin:/sbin"

exec bundle exec ruby gems/tamoz-agent-cli/exe/tamoz "$@" telegram start --env-file .env
