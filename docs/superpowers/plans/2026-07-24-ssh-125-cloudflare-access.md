# SSH-125 Cloudflare Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose `yao@10.229.20.125` SSH over `ssh-125.david-x.com` using the existing `cursor-web-bridge` Cloudflare Tunnel, protected by Access for two emails.

**Architecture:** Add an SSH ingress hostname on the existing named tunnel; create DNS CNAME; create Cloudflare Access self-hosted app with email allowlist; configure Mac SSH ProxyCommand via `cloudflared access ssh`; restart tunnel on 125 and verify LAN + public paths.

**Tech Stack:** cloudflared, Cloudflare Zero Trust Access, OpenSSH, bash scripts under `cursor-web-bridge`.

## Global Constraints

- Reuse tunnel ID `3c6d63d3-9b8b-4b2b-bd3f-0189a20945e6` / name `cursor-web-bridge`.
- Hostname: `ssh-125.david-x.com`.
- Access emails only: `xudazhong@autel.com`, `13238077823@163.com`.
- Session duration: 24 hours.
- Do not modify Franka / `10.229.66.70` robot network.
- Keep existing HTTP route `cursor.david-x.com` → `http://127.0.0.1:8787`.

---

### Task 1: Update tunnel config templates and local mirror

**Files:**
- Modify: `config/cloudflared.yml.template`
- Modify: `config/cloudflared.yml`
- Create: `scripts/setup-ssh-125-access.sh`
- Create: `docs/ssh-125-home-client.md`

**Interfaces:**
- Consumes: existing tunnel ID/credentials path pattern
- Produces: ingress with both HTTP and SSH hostnames; helper script for DNS/route + client SSH snippet

- [ ] **Step 1: Update `config/cloudflared.yml.template`**

```yaml
# Cloudflare Named Tunnel 配置
# 由 setup-cloudflare-tunnel.sh / setup-ssh-125-access.sh 维护

tunnel: REPLACE_TUNNEL_ID
credentials-file: REPLACE_CREDENTIALS_FILE

ingress:
  - hostname: REPLACE_HOSTNAME
    service: http://127.0.0.1:8787
  - hostname: REPLACE_SSH_HOSTNAME
    service: ssh://127.0.0.1:22
  - service: http_status:404
```

- [ ] **Step 2: Update local `config/cloudflared.yml`** to concrete values for Mac mirror (credentials path stays Mac path for reference; 125 uses Linux path).

- [ ] **Step 3: Add `scripts/setup-ssh-125-access.sh`** that:
  1. Runs `cloudflared tunnel route dns cursor-web-bridge ssh-125.david-x.com`
  2. Prints Zero Trust dashboard steps / Access JSON body for the two emails
  3. Prints the Mac `~/.ssh/config` Host block
  4. Syncs `cloudflared.yml` to 125 and restarts tunnel there

- [ ] **Step 4: Commit config + script**

```bash
git add config/cloudflared.yml.template config/cloudflared.yml scripts/setup-ssh-125-access.sh docs/ssh-125-home-client.md docs/superpowers/specs/2026-07-24-ssh-125-cloudflare-access-design.md docs/superpowers/plans/2026-07-24-ssh-125-cloudflare-access.md
git commit -m "feat: add SSH Access hostname on cursor-web-bridge tunnel"
```

---

### Task 2: Provision DNS + deploy config to 125 + restart tunnel

**Files:**
- Modify on 125: `/home/yao/Projects/cursor-web-bridge/config/cloudflared.yml`
- Runtime: cloudflared process on 125

**Interfaces:**
- Consumes: Task 1 config
- Produces: live SSH route on tunnel; DNS CNAME for `ssh-125.david-x.com`

- [ ] **Step 1: Route DNS**

```bash
./bin/cloudflared tunnel route dns cursor-web-bridge ssh-125.david-x.com
```

Expected: CNAME created (or already exists).

- [ ] **Step 2: Push YAML to 125** with Linux credentials path `/home/yao/.cloudflared/3c6d63d3-9b8b-4b2b-bd3f-0189a20945e6.json`.

- [ ] **Step 3: Restart only cloudflared on 125** (preserve uvicorn if possible via existing restart-tunnel / bridge scripts).

- [ ] **Step 4: Verify HTTP still healthy**

```bash
curl -sf -m 15 'https://cursor.david-x.com/api/health'
```

Expected: HTTP 200 / OK body.

---

### Task 3: Create Cloudflare Access application

**Files:** none in repo (Zero Trust dashboard / API)

**Interfaces:**
- Consumes: hostname `ssh-125.david-x.com`
- Produces: Access app + allow policy for the two emails, 24h session

- [ ] **Step 1: Create Access self-hosted app** for `ssh-125.david-x.com` (dashboard Zero Trust → Access → Applications, or API if token available).

- [ ] **Step 2: Policy Allow include emails:**
  - `xudazhong@autel.com`
  - `13238077823@163.com`
  Session duration: 24 hours.

- [ ] **Step 3: Confirm identity providers include One-time PIN / email login** so both addresses can authenticate.

---

### Task 4: Configure home SSH client and verify end-to-end

**Files:**
- Modify: `~/.ssh/config` (add `cursor-125-public` Host)

**Interfaces:**
- Consumes: Access app + tunnel SSH ingress
- Produces: working `ssh cursor-125-public`

- [ ] **Step 1: Append Host block to `~/.ssh/config`** using `bin/cloudflared` ProxyCommand.

- [ ] **Step 2: Test LAN path still works**

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 cursor-125 'hostname; whoami'
```

Expected: `yao-System-Product-Name` / `yao`.

- [ ] **Step 3: Test public path**

```bash
ssh -o ConnectTimeout=30 cursor-125-public 'hostname; whoami'
```

Expected: browser Access login once, then same hostname/user.

- [ ] **Step 4: Commit any remaining docs; record verification results in the plan checkboxes.**
