#!/usr/bin/env bash
# Company LAN (default): SSH into 125 and start Cursor Agent CLI.
# Offsite fallback: SSH_HOST=cursor-125-public ./scripts/start-agent-125.sh
set -euo pipefail

SSH_HOST="${SSH_HOST:-cursor-125}"
REMOTE_ROOT="${REMOTE_ROOT:-/home/yao/Projects/cursor-web-bridge}"
HANDOFF="${HANDOFF:-docs/handoffs/2026-07-24-cursor-125-cli-handoff.md}"
AGENT_MODEL="${AGENT_MODEL:-composer-2.5-fast}"

if ! command -v ssh >/dev/null 2>&1; then
  echo "缺少 ssh"
  exit 1
fi

quoted_args=()
for arg in "$@"; do
  quoted_args+=("$(printf '%q' "$arg")")
done
remote_agent_args="${quoted_args[*]-}"

echo "==> 连接 ${SSH_HOST} 并启动 125 上的 Cursor Agent"
echo "    项目: ${REMOTE_ROOT}"
echo "    模型: ${AGENT_MODEL}"
if [[ "$SSH_HOST" == *public* ]]; then
  echo "    提示: 公网路径，首次或 Access 过期时会弹出浏览器登录"
fi

exec ssh -t "$SSH_HOST" "export PATH=\"\$HOME/.local/bin:\$PATH\"
cd $(printf '%q' "$REMOTE_ROOT") || {
  echo \"找不到项目目录: $(printf '%q' "$REMOTE_ROOT")\" >&2
  exit 1
}
if ! command -v agent >/dev/null 2>&1; then
  echo \"125 上未找到 agent，请先安装 Cursor CLI\" >&2
  exit 1
fi
agent status || true
echo
echo \"交接文档: $(printf '%q' "$HANDOFF")\"
echo
exec agent --trust --model $(printf '%q' "$AGENT_MODEL") ${remote_agent_args}" \
  -- "$@"
