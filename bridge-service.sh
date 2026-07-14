#!/usr/bin/env bash
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/com.cursor.webbridge.plist"
LABEL="com.cursor.webbridge"

case "${1:-start}" in
  start)
    chmod +x /Users/xudazhong/Projects/cursor-web-bridge/scripts/run-bridge.sh
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "已启动保活服务，等待公网地址..."
    for _ in $(seq 1 30); do
      if [[ -f /Users/xudazhong/Projects/cursor-web-bridge/public_url.txt ]]; then
        URL_LINE="$(cat /Users/xudazhong/Projects/cursor-web-bridge/public_url.txt)"
        # 确认服务已就绪
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
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    /Users/xudazhong/Projects/cursor-web-bridge/stop.sh 2>/dev/null || true
    echo "已停止"
    ;;
  status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | head -20 || echo "未运行"
    echo "---"
    cat /Users/xudazhong/Projects/cursor-web-bridge/public_url.txt 2>/dev/null || echo "无公网地址"
    ;;
  url)
    cat /Users/xudazhong/Projects/cursor-web-bridge/public_url.txt 2>/dev/null || true
    ;;
  *)
    echo "Usage: $0 {start|stop|status|url}"
    ;;
esac
