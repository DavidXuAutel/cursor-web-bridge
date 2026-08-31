#!/usr/bin/env bash
# Route this Mac's Claude API egress through the public internet and back:
#
#   Claude client  ->  localhost:$NEWPORT
#                  ->  (SSH over Cloudflare / ssh-125.david-x.com)  [公网]
#                  ->  yao@10.229.20.125                            [125]
#                  ->  reverse tunnel back to this Mac's proxy      [this Mac Claude api]
#                  ->  https://llmapi.autel.com
#
# The final hop is the proxy the Claude Desktop app spawns on 127.0.0.1 — its port
# AND its srt:<password> are regenerated on every app restart, so we read them LIVE
# from the environment instead of hardcoding. Re-run this script after any app restart.
#
# Run this in a NORMAL terminal (NOT inside Claude Code's sandbox), from a shell that
# has the Claude proxy env vars (i.e. a terminal launched by / inheriting the app env).
set -euo pipefail

ROOT="$HOME/Projects/cursor-web-bridge"
REMOTE="${REMOTE:-cursor-125-public}"   # ~/.ssh/config alias -> ssh-125.david-x.com via cloudflared
NEWPORT="${NEWPORT:-59000}"             # new local proxy port the client should point at
REMOTE_BIND="${REMOTE_BIND:-58650}"     # loopback port on 125 that maps back to this Mac's proxy

# 1) Parse the LIVE proxy the Claude app injected -----------------------------
SRC_PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
if [[ -z "$SRC_PROXY" ]]; then
  echo "ERROR: no HTTPS_PROXY in env. Launch this from a shell with the Claude app proxy env." >&2
  exit 1
fi
noscheme="${SRC_PROXY#http://}"
CREDS="${noscheme%@*}"                  # e.g. srt:c7b2...
HOSTPORT="${noscheme##*@}"              # e.g. localhost:58637
LOCAL_PROXY_PORT="${HOSTPORT##*:}"      # e.g. 58637
echo "Live app proxy : $SRC_PROXY"
echo "  creds=$CREDS  local_proxy_port=$LOCAL_PROXY_PORT"

# 2) Ensure the public SSH ingress exists on the Cloudflare tunnel (idempotent) -
echo "==> Ensuring ssh-125.david-x.com ingress is enabled on the tunnel"
"$ROOT/scripts/setup-ssh-125-access.sh"

# 3) Verify public SSH works over the tunnel ----------------------------------
echo "==> Verifying public SSH ($REMOTE)"
ssh -o BatchMode=yes -o ConnectTimeout=20 "$REMOTE" 'echo SSH_OK; hostname; whoami'

# 4) Build the forward chain --------------------------------------------------
#    -R  125:localhost:$REMOTE_BIND      ->  this Mac's live proxy port
#    -L  thisMac:$NEWPORT                ->  125:localhost:$REMOTE_BIND (the reverse leg)
echo "==> Tearing down any prior tunnel to $REMOTE"
pkill -f "ssh -N.*$REMOTE" 2>/dev/null || true
sleep 1
echo "==> Establishing forward chain (NEWPORT=$NEWPORT REMOTE_BIND=$REMOTE_BIND)"
ssh -N -f \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -R "${REMOTE_BIND}:localhost:${LOCAL_PROXY_PORT}" \
  -L "${NEWPORT}:localhost:${REMOTE_BIND}" \
  "$REMOTE"

# 5) Prove the full loop reaches the API --------------------------------------
NEW_PROXY="http://${CREDS}@localhost:${NEWPORT}"
echo "==> Testing loop: $NEW_PROXY -> https://llmapi.autel.com"
code="$(curl -sS -o /dev/null -w '%{http_code}' -x "$NEW_PROXY" https://llmapi.autel.com/ || echo 000)"
echo "    HTTP $code (any non-000 response = the Mac->125->Mac loop works)"

cat <<EOF

==========================================================
 Tunnel up. Point your Claude client at:

   export HTTPS_PROXY="$NEW_PROXY"
   export HTTP_PROXY="$NEW_PROXY"

 e.g. launch the CLI in a plain terminal:
   HTTPS_PROXY="$NEW_PROXY" HTTP_PROXY="$NEW_PROXY" claude

 (Keep the Desktop app open so its proxy on :$LOCAL_PROXY_PORT stays alive.)
 To tear down:  pkill -f "ssh -N.*$REMOTE"
==========================================================
EOF
