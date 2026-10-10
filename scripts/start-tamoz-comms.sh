#!/usr/bin/env bash
# start-tamoz-comms.sh
# Launch every channel's gateway and the worker with `tamoz start`; this script
# is a thin launcher for operators who keep it in their history, and it loads
# `.env` (KEY = value) for the secrets.
#
#   ./scripts/start-tamoz-comms.sh --runtime-dir PATH
#
# Ctrl-C stops every process. Configure the channel once first with:
#   tamoz --runtime-dir PATH setup --workspace DIR && tamoz --runtime-dir PATH channel add telegram
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="$HOME/.rbenv/shims:/usr/bin:/bin:/usr/sbin:/sbin"

exec bundle exec ruby gems/tamoz-agent-cli/exe/tamoz "$@" start --env-file .env
