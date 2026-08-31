# SSH Access to 10.229.20.125 via Cloudflare Tunnel + Access

**Date:** 2026-07-24  
**Status:** Approved

## Goal

Allow SSH login to lab machine `10.229.20.125` (user `yao`) from the public internet at home, without opening inbound ports on the lab network.

## Constraints

- Reuse the existing named tunnel `cursor-web-bridge` (`3c6d63d3-9b8b-4b2b-bd3f-0189a20945e6`) already serving `cursor.david-x.com`.
- Do not create a separate tunnel for SSH (an unused tunnel named `ssh` may exist; leave it alone).
- Protect the SSH hostname with Cloudflare Access email allowlist.
- Keep local SSH key authentication on 125 (`cursor_webbridge_125` / existing keys).
- Do not touch Franka robot network (`10.229.66.70` Desk/shopFloor).

## Design

### Public hostname

- `ssh-125.david-x.com` → existing tunnel CNAME → `ssh://127.0.0.1:22` on 125

### Tunnel ingress (on 125)

```yaml
tunnel: 3c6d63d3-9b8b-4b2b-bd3f-0189a20945e6
credentials-file: /home/yao/.cloudflared/3c6d63d3-9b8b-4b2b-bd3f-0189a20945e6.json

ingress:
  - hostname: cursor.david-x.com
    service: http://127.0.0.1:8787
  - hostname: ssh-125.david-x.com
    service: ssh://127.0.0.1:22
  - service: http_status:404
```

### Cloudflare Access

- Application type: Self-hosted (SSH / non-HTTP)
- Application domain: `ssh-125.david-x.com`
- Session duration: 24 hours
- Allow emails:
  - `xudazhong@autel.com`
  - `13238077823@163.com`

### Home client

SSH config host alias (example `cursor-125-public`):

```
Host cursor-125-public
  HostName ssh-125.david-x.com
  User yao
  IdentityFile ~/.ssh/cursor_webbridge_125
  IdentitiesOnly yes
  ProxyCommand /Users/xudazhong/Projects/cursor-web-bridge/bin/cloudflared access ssh --hostname %h
```

First connect opens a browser for Access login; subsequent connects reuse the Access session until expiry.

### Persistence

- Tunnel continues to run via existing `cursor-web-bridge` bridge/tunnel process on 125.
- After config change, restart only the cloudflared tunnel process (keep HTTP bridge up if possible).

## Non-goals

- Browser-rendered SSH terminal
- Exposing additional lab services
- Replacing local LAN SSH (`cursor-125` / `10.229.20.125`)

## Success criteria

1. From home (or any public network): `ssh cursor-125-public` succeeds after Access email login.
2. Unauthorized emails cannot pass Access.
3. Existing `https://cursor.david-x.com` health remains OK.
4. LAN `ssh cursor-125` still works.
