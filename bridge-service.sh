#!/usr/bin/env bash
set -euo pipefail
ROOT="/Users/xudazhong/Projects/cursor-web-bridge"
PLIST="$HOME/Library/LaunchAgents/com.cursor.webbridge.plist"
WATCHDOG_PLIST="$HOME/Library/LaunchAgents/com.cursor.webbridge.watchdog.plist"
IDEPUSH_PLIST="$HOME/Library/LaunchAgents/com.cursor.webbridge.idepush.plist"
LABEL="com.cursor.webbridge"
WATCHDOG_LABEL="com.cursor.webbridge.watchdog"
IDEPUSH_LABEL="com.cursor.webbridge.idepush"

case "${1:-start}" in
  start)
    chmod +x "$ROOT/scripts/run-bridge.sh" "$ROOT/scripts/health-watchdog.sh"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    launchctl bootout "gui/$(id -u)/$WATCHDOG_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$WATCHDOG_PLIST"
    echo "已启动保活服务 + 10 分钟健康巡检"
    for _ in $(seq 1 30); do
      if [[ -f "$ROOT/public_url.txt" ]]; then
        URL_LINE="$(cat "$ROOT/public_url.txt")"
        if /usr/bin/curl -sf -m 3 http://127.0.0.1:8787/api/health >/dev/null 2>&1; then
          echo "$URL_LINE"
          exit 0
        fi
      fi
      sleep 1
    done
    echo "仍在启动，请稍后查看 public_url.txt"
    ;;
  stop)
    launchctl bootout "gui/$(id -u)/$WATCHDOG_LABEL" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    "$ROOT/stop.sh" 2>/dev/null || true
    echo "已停止（含巡检）"
    ;;
  idepush)
    chmod +x "$ROOT/scripts/push-ide-snapshot.py"
    launchctl bootout "gui/$(id -u)/$IDEPUSH_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$IDEPUSH_PLIST"
    echo "已启动本机 workspace/agent 快照推送（每 30s -> 远端）"
    ;;
  idepush-stop)
    launchctl bootout "gui/$(id -u)/$IDEPUSH_LABEL" 2>/dev/null || true
    echo "已停止快照推送"
    ;;
  status)
    echo "== bridge =="
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | head -12 || echo "未运行"
    echo "== watchdog =="
    launchctl print "gui/$(id -u)/$WATCHDOG_LABEL" 2>/dev/null | head -12 || echo "未运行"
    echo "== idepush =="
    launchctl print "gui/$(id -u)/$IDEPUSH_LABEL" 2>/dev/null | head -12 || echo "未运行"
    echo "---"
    tail -5 "$ROOT/logs/idepush.log" 2>/dev/null || echo "尚无推送日志"
    echo "---"
    cat "$ROOT/public_url.txt" 2>/dev/null || echo "无公网地址"
    echo "---"
    tail -5 "$ROOT/logs/watchdog.log" 2>/dev/null || echo "尚无巡检日志"
    ;;
  url)
    cat "$ROOT/public_url.txt" 2>/dev/null || true
    ;;
  check)
    exec "$ROOT/scripts/health-watchdog.sh"
    ;;
  *)
    echo "Usage: $0 {start|stop|status|url|check|idepush|idepush-stop}"
    ;;
esac
