#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PORT="${PORT:-8787}"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

stop_pid_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    kill "$(cat "$f")" 2>/dev/null || true
    rm -f "$f"
  fi
}

stop_pid_file "$ROOT/logs/server.pid"
stop_pid_file "$ROOT/logs/tunnel.pid"
pkill -f "uvicorn main:app --host" 2>/dev/null || true
pkill -f "cloudflared tunnel --protocol http2 --url http://127.0.0.1:${PORT}" 2>/dev/null || true
echo "已停止 Cursor Web Bridge"
