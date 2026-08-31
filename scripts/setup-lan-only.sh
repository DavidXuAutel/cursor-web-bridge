#!/usr/bin/env bash
# Revert cursor-web-bridge tunnel to HTTP-only (company LAN SSH direct to 10.229.20.125).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-3c6d63d3-9b8b-4b2b-bd3f-0189a20945e6}"
HTTP_HOSTNAME="${CLOUDFLARE_HOSTNAME:-cursor.david-x.com}"
REMOTE_HOST="${REMOTE_HOST:-cursor-125}"
REMOTE_ROOT="${REMOTE_ROOT:-/home/yao/Projects/cursor-web-bridge}"
REMOTE_CRED="/home/yao/.cloudflared/${TUNNEL_ID}.json"

cat > "$ROOT/config/cloudflared.yml" <<EOF
# Cloudflare Named Tunnel — runs on 10.229.20.125
# HTTP-only (company LAN). Public SSH: scripts/setup-ssh-125-access.sh

tunnel: ${TUNNEL_ID}
credentials-file: ${REMOTE_CRED}

ingress:
  - hostname: ${HTTP_HOSTNAME}
    service: http://127.0.0.1:8787
  - service: http_status:404
EOF

echo "==> 同步 HTTP-only 配置到 ${REMOTE_HOST}:${REMOTE_ROOT}/config/cloudflared.yml"
if scp -o BatchMode=yes -o ConnectTimeout=12 "$ROOT/config/cloudflared.yml" \
  "${REMOTE_HOST}:${REMOTE_ROOT}/config/cloudflared.yml"; then
  echo "==> 重启 125 上的 named tunnel（保留 uvicorn）"
  ssh -o BatchMode=yes -o ConnectTimeout=12 "$REMOTE_HOST" bash -s <<EOF
set -euo pipefail
ROOT="${REMOTE_ROOT}"
CLOUDFLARED="\$ROOT/bin/cloudflared"
mkdir -p "\$ROOT/logs"
pkill -f "cloudflared tunnel --config" 2>/dev/null || true
pkill -f "cloudflared tunnel run" 2>/dev/null || true
sleep 1
nohup "\$CLOUDFLARED" tunnel --config "\$ROOT/config/cloudflared.yml" run \
  >> "\$ROOT/logs/tunnel.log" 2>&1 &
echo "cloudflared pid=\$!"
sleep 2
pgrep -af "cloudflared tunnel" | head -5
grep -E 'hostname:|service:' "\$ROOT/config/cloudflared.yml"
EOF
else
  echo "WARN: LAN scp/ssh 到 ${REMOTE_HOST} 失败" >&2
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    echo "==> 尝试 Cloudflare API 远程推送 HTTP-only ingress..."
    INCLUDE_SSH=0 "$ROOT/scripts/push-tunnel-config-api.sh"
  else
    echo "    请连公司网后重跑: $ROOT/scripts/setup-lan-only.sh" >&2
    exit 1
  fi
fi

echo ""
echo "=========================================="
echo "  已切回公司内网模式"
echo "=========================================="
echo "HTTP Bridge: https://${HTTP_HOSTNAME}"
echo "SSH:         ssh cursor-125  (10.229.20.125，直连)"
echo "Agent:       ./scripts/start-agent-125.sh"
echo ""
echo "恢复公网 SSH: ./scripts/setup-ssh-125-access.sh"
