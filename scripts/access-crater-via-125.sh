#!/usr/bin/env bash
# Access ai-crater.autel.com from offsite via 125 SOCKS tunnel.
# Does NOT change system network settings (no networksetup / /etc/hosts).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH_HOST="${SSH_HOST:-cursor-125-public}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
URL="${URL:-https://ai-crater.autel.com/auth?redirect=%2Fportal%2Fjobs%2Finter}"
PID_FILE="/tmp/socks125-${SOCKS_PORT}.pid"
LOG_FILE="/tmp/socks125-${SOCKS_PORT}.log"
CHROME_DIR="${CHROME_DIR:-$HOME/.chrome-socks-125}"

usage() {
  cat <<EOF
Usage: $0 [start|stop|status|open|test]

  start   Start SOCKS tunnel on 127.0.0.1:${SOCKS_PORT} via ${SSH_HOST}
  stop    Stop local SOCKS tunnel only (does not touch system proxy)
  status  Show tunnel + quick crater probe
  open    start + open browser with SOCKS (Chrome/Edge/Arc/Brave)
  test    curl crater via local SOCKS

Example:
  $0 open
  $0 stop
EOF
}

start_tunnel() {
  if lsof -nP -iTCP:"${SOCKS_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "SOCKS already listening on 127.0.0.1:${SOCKS_PORT}"
    return 0
  fi
  echo "==> Starting SOCKS via ${SSH_HOST} -> 127.0.0.1:${SOCKS_PORT}"
  nohup ssh -D "${SOCKS_PORT}" -N \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o TCPKeepAlive=yes \
    -o BatchMode=yes \
    -o ConnectTimeout=30 \
    "${SSH_HOST}" >>"${LOG_FILE}" 2>&1 &
  echo $! >"${PID_FILE}"
  for _ in $(seq 1 15); do
    if lsof -nP -iTCP:"${SOCKS_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "SOCKS up (pid=$(cat "${PID_FILE}"))"
      return 0
    fi
    sleep 1
  done
  echo "SOCKS failed; see ${LOG_FILE}" >&2
  tail -5 "${LOG_FILE}" >&2 || true
  return 1
}

stop_tunnel() {
  if [[ -f "${PID_FILE}" ]]; then
    kill "$(cat "${PID_FILE}")" 2>/dev/null || true
    rm -f "${PID_FILE}"
  fi
  pkill -f "ssh -D ${SOCKS_PORT} .*${SSH_HOST}" 2>/dev/null || true
  echo "SOCKS stopped (system proxy untouched)"
}

test_crater() {
  curl -sS -o /dev/null -w "crater via socks=%{http_code} time=%{time_total}s\n" -m 25 \
    --socks5-hostname "127.0.0.1:${SOCKS_PORT}" \
    "${URL}"
}

open_browser() {
  start_tunnel
  local proxy="socks5://127.0.0.1:${SOCKS_PORT}"
  local rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1"
  if [[ -d "/Applications/Google Chrome.app" ]]; then
    open -na "Google Chrome" --args \
      --user-data-dir="${CHROME_DIR}" \
      --proxy-server="${proxy}" \
      --host-resolver-rules="${rules}" \
      "${URL}"
    echo "Opened Chrome (isolated profile, SOCKS only in this window)"
  elif [[ -d "/Applications/Microsoft Edge.app" ]]; then
    open -na "Microsoft Edge" --args \
      --user-data-dir="${HOME}/.edge-socks-125" \
      --proxy-server="${proxy}" \
      --host-resolver-rules="${rules}" \
      "${URL}"
    echo "Opened Edge (isolated profile)"
  elif [[ -d "/Applications/Arc.app" ]]; then
    open -na "Arc" --args \
      --user-data-dir="${HOME}/.arc-socks-125" \
      --proxy-server="${proxy}" \
      --host-resolver-rules="${rules}" \
      "${URL}"
    echo "Opened Arc (isolated profile)"
  elif [[ -d "/Applications/Brave Browser.app" ]]; then
    open -na "Brave Browser" --args \
      --user-data-dir="${HOME}/.brave-socks-125" \
      --proxy-server="${proxy}" \
      --host-resolver-rules="${rules}" \
      "${URL}"
    echo "Opened Brave (isolated profile)"
  else
    echo "No Chromium browser found."
    echo "Manual: browser extension -> SOCKS5 127.0.0.1:${SOCKS_PORT}, then open:"
    echo "  ${URL}"
    test_crater
  fi
}

cmd="${1:-open}"
case "$cmd" in
  start) start_tunnel ;;
  stop) stop_tunnel ;;
  status)
    lsof -nP -iTCP:"${SOCKS_PORT}" -sTCP:LISTEN 2>/dev/null || echo "SOCKS down"
    test_crater 2>/dev/null || echo "crater test skipped (start tunnel first)"
    ;;
  test) test_crater ;;
  open) open_browser ;;
  -h|--help|help) usage ;;
  *) echo "Unknown: $cmd" >&2; usage; exit 1 ;;
esac
