# Handoff: Continue on 125 with Cursor CLI

**Date:** 2026-07-24  
**Source machine:** Mac (`/Users/xudazhong/Projects/cursor-web-bridge`)  
**Target machine:** `10.229.20.125` / `ssh-125.david-x.com` (`/home/yao/Projects/cursor-web-bridge`)  
**Target user:** `yao`

## Why this handoff exists

Local Cursor Desktop chat history is not reliably portable to Linux Cursor Desktop or Cursor CLI. This document is the stable continuation context.

## Already completed

1. Public SSH to 125 is available via Cloudflare Tunnel + Access:
   - Hostname: `ssh-125.david-x.com`
   - Access allowlist: `xudazhong@autel.com`, `13238077823@163.com`
   - Home SSH alias: `cursor-125-public`
2. End-to-end verification succeeded:
   - `hostname` → `yao-System-Product-Name`
   - `whoami` → `yao`
   - `SSH_OK`
3. Repo work for SSH Access is present locally and should be synced to 125:
   - `config/cloudflared.yml.template` adds SSH ingress
   - `scripts/setup-ssh-125-access.sh`
   - `docs/ssh-125-home-client.md`
   - `docs/superpowers/specs/2026-07-24-ssh-125-cloudflare-access-design.md`
   - `docs/superpowers/plans/2026-07-24-ssh-125-cloudflare-access.md`

## Current local workspace state at migration time

- Branch: `main` tracking `origin/main`
- Recent tip: `6b74024 Add IDE workspace/agent mirror with remote push and mobile UI.`
- Uncommitted / untracked items expected in the sync:
  - modified: `config/cloudflared.yml.template`
  - untracked: `docs/`
  - untracked: `scripts/setup-ssh-125-access.sh`
- Note: remote target directory previously existed and was **not** a git repository. Migration syncs the working tree; initializing git on 125 is optional and not required for CLI continuation.

## What was intentionally not migrated

- macOS Cursor Desktop app data
- Linux Cursor Desktop app data / existing `~/.cursor` contents on 125
- Secrets: `.env`, `.cursor_api_key`, Cloudflare credential JSON, SSH private keys, Access tokens

## Continue on 125

From home:

```bash
ssh cursor-125-public
cd ~/Projects/cursor-web-bridge
export PATH="$HOME/.local/bin:$PATH"
agent status
agent
```

First prompt recommendation for the new CLI session:

```text
Read docs/handoffs/2026-07-24-cursor-125-cli-handoff.md and continue from there.
Public SSH Access for 125 is already working. Prefer Cursor CLI on 125 so AI traffic exits from 125.
Do not overwrite ~/.config/Cursor or ~/.cursor. Do not touch Franka / 10.229.66.70 robot network.
```

## Optional checks after login

```bash
agent ls
agent --mode=ask "Summarize the current SSH Access setup from the docs in this repo."
```

If `agent` is not logged in:

```bash
NO_OPEN_BROWSER=1 agent login
```

Open the printed URL on any device that can complete Cursor login, then re-run `agent status`.

## Next useful work after migration

1. Confirm CLI login on 125.
2. Decide whether to initialize git in `/home/yao/Projects/cursor-web-bridge` or keep it as a synced working tree.
3. Keep using `ssh cursor-125-public` from home when local Cursor Desktop networking is unreliable.
