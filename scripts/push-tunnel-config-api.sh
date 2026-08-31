#!/usr/bin/env bash
# Push named-tunnel ingress to Cloudflare (remote config). Works without LAN SSH to 125.
# Requires: CLOUDFLARE_API_TOKEN with Tunnel Write / Zero Trust Connectors Write.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-be7f851a060da74507fab7adcdd83940}"
TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-3c6d63d3-9b8b-4b2b-bd3f-0189a20945e6}"
HTTP_HOSTNAME="${CLOUDFLARE_HOSTNAME:-cursor.david-x.com}"
SSH_HOSTNAME="${CLOUDFLARE_SSH_HOSTNAME:-ssh-125.david-x.com}"
SSH110_HOSTNAME="${CLOUDFLARE_SSH110_HOSTNAME:-ssh-110.david-x.com}"
SSH110_TARGET="${CLOUDFLARE_SSH110_TARGET:-ssh://10.229.20.110:22}"
INCLUDE_SSH="${INCLUDE_SSH:-1}"
INCLUDE_SSH110="${INCLUDE_SSH110:-0}"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "缺少 CLOUDFLARE_API_TOKEN（需 Tunnel Write 权限）" >&2
  exit 1
fi

ingress_items=("{\"hostname\": \"${HTTP_HOSTNAME}\", \"service\": \"http://127.0.0.1:8787\"}")
if [[ "$INCLUDE_SSH" == "1" ]]; then
  ingress_items+=("{\"hostname\": \"${SSH_HOSTNAME}\", \"service\": \"ssh://127.0.0.1:22\"}")
fi
if [[ "$INCLUDE_SSH110" == "1" ]]; then
  ingress_items+=("{\"hostname\": \"${SSH110_HOSTNAME}\", \"service\": \"${SSH110_TARGET}\"}")
fi
ingress_items+=("{\"service\": \"http_status:404\"}")

INGRESS_JSON="["
for i in "${!ingress_items[@]}"; do
  [[ "$i" -gt 0 ]] && INGRESS_JSON+=", "
  INGRESS_JSON+="${ingress_items[$i]}"
done
INGRESS_JSON+="]"

payload=$(INGRESS_JSON="$INGRESS_JSON" python3 - <<'PY'
import json, os
ingress = json.loads(os.environ["INGRESS_JSON"])
print(json.dumps({"config": {"ingress": ingress}}))
PY
)

echo "==> PUT tunnel configuration (include_ssh=${INCLUDE_SSH} include_ssh110=${INCLUDE_SSH110})"
resp=$(curl -sS -m 30 -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "$payload")

echo "$resp" | python3 -m json.tool 2>/dev/null || echo "$resp"

if ! echo "$resp" | python3 -c 'import json,sys; r=json.load(sys.stdin); sys.exit(0 if r.get("success") else 1)'; then
  echo "Cloudflare API 更新失败" >&2
  exit 1
fi

echo "==> 远程 ingress 已推送；125 上 cloudflared 通常会在 ~30s 内生效（远程管理模式）"
echo "    若仍不生效，需在 125 上同步 config/cloudflared.yml 并重启 tunnel（需 LAN 或已有 SSH）"
