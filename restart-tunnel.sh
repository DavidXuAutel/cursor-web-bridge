#!/usr/bin/env bash
# Restart only the Cloudflare quick tunnel (keeps the local server running).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PORT="${PORT:-8787}"
BRIDGE_API_KEY="${BRIDGE_API_KEY:-}"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

pkill -f "cloudflared tunnel --url http://127.0.0.1:${PORT}" 2>/dev/null || true
sleep 1

LOG_FILE="$ROOT/tunnel.log"
"$ROOT/bin/cloudflared" tunnel --protocol http2 --url "http://127.0.0.1:${PORT}" > "$LOG_FILE" 2>&1 &
TUNNEL_PID=$!

for _ in $(seq 1 45); do
  PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_FILE" 2>/dev/null | head -1 || true)"
  if [[ -n "$PUBLIC_URL" ]]; then
    echo "$PUBLIC_URL" > "$ROOT/public_url.txt"
    echo "公网地址: $PUBLIC_URL"
    if [[ -n "${BRIDGE_API_KEY:-}" ]]; then
      echo "带鉴权: ${PUBLIC_URL}/?token=${BRIDGE_API_KEY}"
      echo "WebSocket: wss://$(echo "$PUBLIC_URL" | sed 's#https://##')/ws?token=${BRIDGE_API_KEY}"
    fi
    exit 0
  fi
  sleep 1
done

echo "隧道启动超时，请查看 $LOG_FILE"
kill "$TUNNEL_PID" 2>/dev/null || true
exit 1
