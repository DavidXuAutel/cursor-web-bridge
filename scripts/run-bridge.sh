#!/usr/bin/env bash
# Start uvicorn + cloudflared (named tunnel or quick tunnel)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PYTHON="${PYTHON:-$ROOT/.venv/bin/python3}"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="${HOME}/miniconda3/bin/python3"
fi
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="$(command -v python3)"
fi
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8787}"
TUNNEL_MODE="${TUNNEL_MODE:-quick}"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

export PYTHONPATH="$ROOT/server"
mkdir -p "$ROOT/logs"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

write_public_url() {
  local base_url="$1"
  if [[ -n "${BRIDGE_API_KEY:-}" ]]; then
    echo "${base_url}?token=${BRIDGE_API_KEY}" > "$ROOT/logs/public_url.txt"
    echo "${base_url}?token=${BRIDGE_API_KEY}" > "$ROOT/public_url.txt"
  else
    echo "$base_url" > "$ROOT/logs/public_url.txt"
    echo "$base_url" > "$ROOT/public_url.txt"
  fi
  log "public url: $base_url"
}

cleanup() {
  log "stopping..."
  [[ -n "${UV_PID:-}" ]] && kill "$UV_PID" 2>/dev/null || true
  [[ -n "${CF_PID:-}" ]] && kill "$CF_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

pkill -f "uvicorn main:app --host" 2>/dev/null || true
pkill -f "cloudflared tunnel --protocol http2 --url http://127.0.0.1:${PORT}" 2>/dev/null || true
pkill -f "cloudflared tunnel run" 2>/dev/null || true
pkill -f "cloudflared tunnel --config" 2>/dev/null || true
sleep 1

log "starting uvicorn on :${PORT}"
"$PYTHON" -m uvicorn main:app \
  --host "$HOST" --port "$PORT" \
  --app-dir "$ROOT/server" \
  >> "$ROOT/logs/server.log" 2>&1 &
UV_PID=$!

for _ in $(seq 1 30); do
  if /usr/bin/curl -sf -m 2 "http://127.0.0.1:${PORT}/api/health" >/dev/null; then
    log "uvicorn ready"
    break
  fi
  sleep 0.5
done

CLOUDFLARED="$ROOT/bin/cloudflared"
if [[ ! -x "$CLOUDFLARED" ]]; then
  log "cloudflared missing"
  wait "$UV_PID"
  exit 1
fi

: > "$ROOT/logs/tunnel.log"

if [[ "$TUNNEL_MODE" == "named" && -f "$ROOT/config/cloudflared.yml" ]]; then
  log "starting named cloudflare tunnel"
  write_public_url "https://${CLOUDFLARE_HOSTNAME:-unknown}"
  "$CLOUDFLARED" tunnel --config "$ROOT/config/cloudflared.yml" run \
    >> "$ROOT/logs/tunnel.log" 2>&1 &
  CF_PID=$!
else
  if [[ "$TUNNEL_MODE" == "named" ]]; then
    log "named tunnel config missing, falling back to quick tunnel"
    log "run: $ROOT/scripts/setup-cloudflare-tunnel.sh"
  fi
  log "starting quick cloudflare tunnel"
  "$CLOUDFLARED" tunnel --protocol http2 --url "http://127.0.0.1:${PORT}" \
    >> "$ROOT/logs/tunnel.log" 2>&1 &
  CF_PID=$!

  for _ in $(seq 1 60); do
    PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$ROOT/logs/tunnel.log" 2>/dev/null | head -1 || true)"
    if [[ -n "$PUBLIC_URL" ]]; then
      write_public_url "$PUBLIC_URL"
      break
    fi
    sleep 1
  done
fi

while true; do
  if ! kill -0 "$UV_PID" 2>/dev/null; then
    log "uvicorn exited"
    exit 1
  fi
  if ! kill -0 "$CF_PID" 2>/dev/null; then
    log "cloudflared exited"
    exit 1
  fi
  sleep 5
done
