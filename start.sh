#!/usr/bin/env bash
set -euo pipefail

# SMAXr — start script for Unix (Linux, macOS, WSL)
# Loads .env (if present), then runs the agent.

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# Load .env
if [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null
  . ./.env
  set +a
else
  echo "[WARNING] .env not found — copy .env.example to .env" >&2
fi

# Required env sanity
: "${TELEGRAM_BOT_TOKEN:?ERROR: TELEGRAM_BOT_TOKEN not set. Add it to .env}"
: "${OPENCODE_API_KEY:?ERROR: OPENCODE_API_KEY not set. Add it to .env}"

# Defaults
export SMAXR_MODEL="${SMAXR_MODEL:-deepseek-v4-flash}"
export MIX_ENV="${MIX_ENV:-dev}"

if [ -n "${SOCKS_PROXY:-}" ]; then
  echo "[$(date)] Proxy: $SOCKS_PROXY"
else
  echo "[$(date)] No SOCKS_PROXY set"
fi

echo "[$(date)] Starting SMAXr with model $SMAXR_MODEL..."
echo

# Run the agent
exec elixir --sname smaxr@"$(hostname)" -S mix run --no-halt
