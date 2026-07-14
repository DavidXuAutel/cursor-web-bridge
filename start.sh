#!/usr/bin/env bash
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
TUNNEL=0

for arg in "$@"; do
  case "$arg" in
    --tunnel) TUNNEL=1 ;;
    --help|-h)
      echo "Usage: ./start.sh [--tunnel]"
      echo "  --tunnel  Start Cloudflare quick tunnel for public access"
      exit 0
      ;;
  esac
done

echo "==> Cursor Web Bridge"
echo "    Python: $PYTHON"
echo "    Local:  http://127.0.0.1:${PORT}"
echo ""

export PYTHONPATH="$ROOT/server"

cleanup() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  [[ -n "${TUNNEL_PID:-}" ]] && kill "$TUNNEL_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

"$PYTHON" -m uvicorn main:app --host "$HOST" --port "$PORT" --app-dir "$ROOT/server" &
SERVER_PID=$!

sleep 1

if [[ "$TUNNEL" -eq 1 ]]; then
  set +e
  CLOUDFLARED="$ROOT/bin/cloudflared"
  if [[ ! -x "$CLOUDFLARED" ]]; then
    echo "==> Downloading cloudflared..."
    mkdir -p "$ROOT/bin"
    ARCH="$(uname -m)"
    TMP_TGZ="$(mktemp /tmp/cloudflared.XXXXXX.tgz)"
    if [[ "$ARCH" == "arm64" ]]; then
      URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz"
    else
      URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz"
    fi
    /usr/bin/curl -fsSL "$URL" -o "$TMP_TGZ"
    tar -xzf "$TMP_TGZ" -C "$ROOT/bin"
    chmod +x "$CLOUDFLARED"
    rm -f "$TMP_TGZ"
  fi

  echo "==> Starting Cloudflare tunnel..."
  LOG_FILE="$ROOT/tunnel.log"
  "$CLOUDFLARED" tunnel --protocol http2 --url "http://127.0.0.1:${PORT}" 2>&1 | tee "$LOG_FILE" &
  TUNNEL_PID=$!

  for _ in $(seq 1 45); do
    PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_FILE" 2>/dev/null | head -1 || true)"
    if [[ -n "$PUBLIC_URL" ]]; then
      echo "$PUBLIC_URL" > "$ROOT/public_url.txt"
      echo ""
      echo "========================================"
      echo "  公网地址: $PUBLIC_URL"
      echo "  WebSocket: wss://$(echo "$PUBLIC_URL" | sed 's#https://##')/ws?token=${BRIDGE_API_KEY}"
      echo "  Bridge Key: ${BRIDGE_API_KEY}"
      echo "========================================"
      echo ""
      break
    fi
    sleep 1
  done
  set -e
fi

echo "Press Ctrl+C to stop."
wait "$SERVER_PID"
