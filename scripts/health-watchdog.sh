#!/usr/bin/env bash
# Health watchdog: check cursor-web-bridge every run; restart if unhealthy.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8787}"
HOSTNAME="${CLOUDFLARE_HOSTNAME:-cursor.david-x.com}"
LOG="$ROOT/logs/watchdog.log"
LOCK="$ROOT/logs/watchdog.lock"
COOLDOWN_FILE="$ROOT/logs/watchdog.cooldown"
COOLDOWN_SECS=300  # avoid restart loops within 5 minutes

mkdir -p "$ROOT/logs"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
HOSTNAME="${CLOUDFLARE_HOSTNAME:-$HOSTNAME}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

acquire_lock() {
  if [[ -f "$LOCK" ]]; then
    local old_pid
    old_pid="$(cat "$LOCK" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      log "skip: another watchdog run in progress (pid=$old_pid)"
      exit 0
    fi
  fi
  echo $$ > "$LOCK"
}

release_lock() {
  rm -f "$LOCK"
}
trap release_lock EXIT

in_cooldown() {
  if [[ ! -f "$COOLDOWN_FILE" ]]; then
    return 1
  fi
  local last now
  last="$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  (( now - last < COOLDOWN_SECS ))
}

mark_cooldown() {
  date +%s > "$COOLDOWN_FILE"
}

local_ok() {
  /usr/bin/curl -sf -m 5 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1
}

public_ok() {
  [[ -z "$HOSTNAME" ]] && return 0
  /usr/bin/curl -sf -m 10 "https://${HOSTNAME}/api/health" >/dev/null 2>&1
}

process_ok() {
  pgrep -f "uvicorn main:app --host .* --port ${PORT}" >/dev/null 2>&1 \
    && pgrep -f "cloudflared tunnel" >/dev/null 2>&1
}

restart_service() {
  local reason="$1"
  if in_cooldown; then
    log "unhealthy ($reason) but in cooldown, skip restart"
    return 0
  fi

  log "UNHEALTHY: $reason — restarting service"
  mark_cooldown

  # Prefer launchd kickstart to keep KeepAlive ownership
  if launchctl print "gui/$(id -u)/com.cursor.webbridge" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/com.cursor.webbridge" 2>>"$LOG" || true
  else
    "$ROOT/bridge-service.sh" start >>"$LOG" 2>&1 || true
  fi

  # Wait and re-check
  local i
  for i in $(seq 1 30); do
    if local_ok && process_ok; then
      log "restart OK (local healthy after ${i}s)"
      if public_ok; then
        log "public https://${HOSTNAME}/api/health OK"
      else
        log "warn: local OK but public https://${HOSTNAME} not ready yet"
      fi
      return 0
    fi
    sleep 1
  done
  log "ERROR: still unhealthy after restart"
  return 1
}

acquire_lock

reasons=()
local_ok || reasons+=("local /api/health failed")
process_ok || reasons+=("uvicorn/cloudflared process missing")

if [[ ${#reasons[@]} -eq 0 ]]; then
  if public_ok; then
    log "ok: local+public healthy"
  else
    # Public failure alone can be DNS/CDN blip — don't restart if local is fine
    log "ok: local healthy; public https://${HOSTNAME} check failed (no restart)"
  fi
  exit 0
fi

restart_service "$(IFS='; '; echo "${reasons[*]}")"
exit $?
