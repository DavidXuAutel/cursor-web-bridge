#!/usr/bin/env bash
# 一次性配置 Cloudflare Named Tunnel（固定域名，约 ¥50-80/年域名费）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLOUDFLARED="${CLOUDFLARED:-$ROOT/bin/cloudflared}"
CONFIG_DIR="$ROOT/config"
CRED_DIR="$HOME/.cloudflared"

echo "=========================================="
echo "  Cloudflare Named Tunnel 配置向导"
echo "=========================================="
echo ""
echo "前置条件："
echo "  1. 已有域名（如 example.com，约 ¥50-80/年）"
echo "  2. 域名 DNS 已托管到 Cloudflare（免费）"
echo "  3. 已注册 Cloudflare 账号 https://dash.cloudflare.com"
echo ""

if [[ ! -x "$CLOUDFLARED" ]]; then
  echo "正在下载 cloudflared..."
  mkdir -p "$ROOT/bin"
  ARCH="$(uname -m)"
  if [[ "$ARCH" == "arm64" ]]; then
    URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz"
  else
    URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz"
  fi
  TMP="$(mktemp /tmp/cloudflared.XXXXXX.tgz)"
  /usr/bin/curl -fsSL "$URL" -o "$TMP"
  tar -xzf "$TMP" -C "$ROOT/bin"
  chmod +x "$CLOUDFLARED"
  rm -f "$TMP"
fi

HOSTNAME="${1:-}"
TUNNEL_NAME="${2:-cursor-web-bridge}"

if [[ -z "$HOSTNAME" ]]; then
  read -r -p "请输入完整子域名（如 cursor-bridge.example.com）: " HOSTNAME
fi
if [[ -z "$HOSTNAME" ]]; then
  echo "域名不能为空"
  exit 1
fi

if [[ -z "${2:-}" ]]; then
  read -r -p "隧道名称 [$TUNNEL_NAME]: " input_name || true
  TUNNEL_NAME="${input_name:-$TUNNEL_NAME}"
fi

echo "将使用主机名: $HOSTNAME"
echo "隧道名称:     $TUNNEL_NAME"

echo ""
echo "步骤 1/4: 登录 Cloudflare（浏览器会打开）..."
"$CLOUDFLARED" tunnel login

echo ""
echo "步骤 2/4: 创建隧道 $TUNNEL_NAME ..."
if "$CLOUDFLARED" tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
  echo "隧道已存在，跳过创建"
else
  "$CLOUDFLARED" tunnel create "$TUNNEL_NAME"
fi

TUNNEL_ID="$("$CLOUDFLARED" tunnel list 2>/dev/null | awk -v name="$TUNNEL_NAME" '$0 ~ name {print $1; exit}')"
if [[ -z "$TUNNEL_ID" ]]; then
  echo "无法获取隧道 ID，请检查 cloudflared tunnel list"
  exit 1
fi
echo "隧道 ID: $TUNNEL_ID"

CRED_FILE="$CRED_DIR/${TUNNEL_ID}.json"
if [[ ! -f "$CRED_FILE" ]]; then
  echo "凭证文件不存在: $CRED_FILE"
  exit 1
fi

echo ""
echo "步骤 3/4: 绑定 DNS $HOSTNAME ..."
"$CLOUDFLARED" tunnel route dns "$TUNNEL_NAME" "$HOSTNAME" || {
  echo "DNS 绑定失败。若记录已存在，可在 Cloudflare DNS 面板手动添加 CNAME："
  echo "  $HOSTNAME -> ${TUNNEL_ID}.cfargotunnel.com"
}

echo ""
echo "步骤 4/4: 生成配置文件..."
mkdir -p "$CONFIG_DIR"
sed \
  -e "s|REPLACE_TUNNEL_ID|$TUNNEL_ID|g" \
  -e "s|REPLACE_CREDENTIALS_FILE|$CRED_FILE|g" \
  -e "s|REPLACE_HOSTNAME|$HOSTNAME|g" \
  "$CONFIG_DIR/cloudflared.yml.template" > "$CONFIG_DIR/cloudflared.yml"

# 写入 .env 隧道配置
ENV_FILE="$ROOT/.env"
touch "$ENV_FILE"
grep -v '^TUNNEL_MODE=' "$ENV_FILE" 2>/dev/null | grep -v '^CLOUDFLARE_HOSTNAME=' | grep -v '^CLOUDFLARE_TUNNEL_NAME=' > "$ENV_FILE.tmp" || true
mv "$ENV_FILE.tmp" "$ENV_FILE"
{
  echo "TUNNEL_MODE=named"
  echo "CLOUDFLARE_HOSTNAME=$HOSTNAME"
  echo "CLOUDFLARE_TUNNEL_NAME=$TUNNEL_NAME"
} >> "$ENV_FILE"

PUBLIC_URL="https://${HOSTNAME}"
if grep -q '^BRIDGE_API_KEY=' "$ENV_FILE"; then
  TOKEN="$(grep '^BRIDGE_API_KEY=' "$ENV_FILE" | cut -d= -f2-)"
  if [[ -n "$TOKEN" ]]; then
    PUBLIC_URL="${PUBLIC_URL}?token=${TOKEN}"
  fi
fi
echo "$PUBLIC_URL" > "$ROOT/public_url.txt"

echo ""
echo "=========================================="
echo "  配置完成！"
echo "=========================================="
echo ""
echo "  固定公网地址: $PUBLIC_URL"
echo "  配置文件:     $CONFIG_DIR/cloudflared.yml"
echo ""
echo "重启服务使配置生效："
echo "  $ROOT/bridge-service.sh stop"
echo "  $ROOT/bridge-service.sh start"
echo ""
echo "验证："
echo "  curl https://${HOSTNAME}/api/health"
echo ""
