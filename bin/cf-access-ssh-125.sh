#!/usr/bin/env bash
# Cloudflare Access SSH proxy for cursor-125-public (offsite).
# Uses a cached Access JWT so cloudflared skips the flaky HEAD app-info roundtrip.
set -euo pipefail
CF="/Users/xudazhong/Projects/cursor-web-bridge/bin/cloudflared"
HOST="${1:-ssh-125.david-x.com}"
TOKEN="$("$CF" access token -app "https://${HOST}" 2>/dev/null | tail -1 || true)"
# Fallback: cloudflared on-disk app token (access token CLI often fails on HEAD timeout)
if [[ -z "${TOKEN}" || "${#TOKEN}" -lt 20 ]]; then
  for f in "$HOME"/.cloudflared/"${HOST}"-*-token; do
    [[ -f "$f" ]] || continue
    cand="$(tr -d '\n' <"$f")"
    if [[ ${#cand} -gt 20 ]]; then
      TOKEN="$cand"
      break
    fi
  done
fi
if [[ -z "${TOKEN}" || "${#TOKEN}" -lt 20 ]]; then
  echo "cloudflared access token empty; run: $CF access login https://${HOST}" >&2
  exit 1
fi
exec "$CF" access tcp --hostname "$HOST" --header "Cf-Access-Token: ${TOKEN}"
