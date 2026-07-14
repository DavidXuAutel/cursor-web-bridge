#!/usr/bin/env bash
# Run server + tunnel in background (survives terminal close).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PYTHON="${PYTHON:-$HOME/miniconda3/bin/python3}"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="$(command -v python3)"
fi

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8787}"
export PYTHONPATH="$ROOT/server"

mkdir -p "$ROOT/logs"
SERVER_PID_FILE="$ROOT/logs/server.pid"
TUNNEL_PID_FILE="$ROOT/logs/tunnel.pid"
SERVER_LOG="$ROOT/logs/server.log"
TUNNEL_LOG="$ROOT/logs/tunnel.log"

stop_one() {
  local pid_file="$1"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file")"
    kill "$pid" 2>/dev/null || true
    rm -f "$pid_file"
  fi
}

pkill -f "uvicorn main:app --host $HOST --port $PORT" 2>/dev/null || true
pkill -f "cloudflared tunnel --protocol http2 --url http://127.0.0.1:${PORT}" 2>/dev/null || true
stop_one "$SERVER_PID_FILE"
stop_one "$TUNNEL_PID_FILE"
sleep 1

echo "==> Starting server..."
nohup "$PYTHON" -m uvicorn main:app \
  --host "$HOST" --port "$PORT" \
  --app-dir "$ROOT/server" \
  >> "$SERVER_LOG" 2>&1 </dev/null &
SERVER_PID=$!
echo "$SERVER_PID" > "$SERVER_PID_FILE"
disown "$SERVER_PID" 2>/dev/null || true

for _ in $(seq 1 20); do
  if /usr/bin/curl -sf -m 2 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

CLOUDFLARED="$ROOT/bin/cloudflared"
if [[ ! -x "$CLOUDFLARED" ]]; then
  echo "cloudflared not found. Run ./start.sh --tunnel once to download it."
  exit 1
fi

echo "==> Starting tunnel..."
: > "$TUNNEL_LOG"
nohup "$CLOUDFLARED" tunnel --protocol http2 --url "http://127.0.0.1:${PORT}" \
  >> "$TUNNEL_LOG" 2>&1 </dev/null &
TUNNEL_PID=$!
echo "$TUNNEL_PID" > "$TUNNEL_PID_FILE"
disown "$TUNNEL_PID" 2>/dev/null || true

PUBLIC_URL=""
for _ in $(seq 1 45); do
  PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)"
  if [[ -n "$PUBLIC_URL" ]]; then
    if [[ -n "${BRIDGE_API_KEY:-}" ]]; then
      echo "${PUBLIC_URL}?token=${BRIDGE_API_KEY}" > "$ROOT/public_url.txt"
    else
      echo "$PUBLIC_URL" > "$ROOT/public_url.txt"
    fi
    break
  fi
  sleep 1
done

if [[ -z "$PUBLIC_URL" ]]; then
  echo "Tunnel failed to start. See $TUNNEL_LOG"
  exit 1
fi

TOKEN_QS=""
if [[ -n "${BRIDGE_API_KEY:-}" ]]; then
  TOKEN_QS="?token=${BRIDGE_API_KEY}"
fi

echo ""
echo "========================================"
echo "  公网地址: ${PUBLIC_URL}${TOKEN_QS}"
echo "  WebSocket: wss://$(echo "$PUBLIC_URL" | sed 's#https://##')/ws?token=${BRIDGE_API_KEY}"
echo "  本地地址: http://127.0.0.1:${PORT}"
echo "  日志: logs/server.log, logs/tunnel.log"
echo "  停止: ./stop.sh"
echo "========================================"
echo ""

/usr/bin/curl -sf -m 15 "${PUBLIC_URL}/api/health" >/dev/null && echo "公网健康检查: OK" || echo "公网健康检查: 等待中（稍后再试）"
