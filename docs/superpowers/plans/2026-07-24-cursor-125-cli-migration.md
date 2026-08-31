# Cursor 125 CLI Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the current `cursor-web-bridge` project context to machine 125 and continue work with Cursor CLI there, without overwriting the existing Cursor Desktop data on 125.

**Architecture:** Capture a credential-free handoff document in-repo, rsync the working tree to `/home/yao/Projects/cursor-web-bridge` with a timestamped backup and exclude rules, then install/verify Cursor CLI on 125 and use the handoff document as the continuation context.

**Tech Stack:** OpenSSH (`cursor-125-public`), rsync, Cursor CLI (`agent`), Markdown docs under `docs/`.

## Global Constraints

- Do not overwrite `~/.config/Cursor` or `~/.cursor` on 125.
- Do not sync secrets: `.env`, `.cursor_api_key`, SSH private keys, Cloudflare credentials, Access tokens.
- Keep Franka robot network untouched (`10.229.66.70`).
- Prefer SSH over Cloudflare Access (`cursor-125-public`).
- Treat Desktop chat continuity as best-effort via handoff docs, not automatic sync.

---

### Task 1: Write migration design and handoff docs

**Files:**
- Create: `docs/superpowers/specs/2026-07-24-cursor-125-migration-design.md`
- Create: `docs/superpowers/plans/2026-07-24-cursor-125-cli-migration.md`
- Create: `docs/handoffs/2026-07-24-cursor-125-cli-handoff.md`

**Interfaces:**
- Consumes: current SSH Access setup and local uncommitted work
- Produces: approved design, executable plan, and CLI continuation context

- [x] **Step 1: Write design and plan docs**
- [x] **Step 2: Write handoff summarizing completed SSH Access work and next CLI steps**
- [x] **Step 3: Keep secrets out of docs**

---

### Task 2: Backup and sync project tree to 125

**Files:**
- Sync: local `/Users/xudazhong/Projects/cursor-web-bridge` → `/home/yao/Projects/cursor-web-bridge`
- Backup on 125: `/home/yao/Projects/cursor-web-bridge.bak-<timestamp>`

**Interfaces:**
- Consumes: local working tree
- Produces: matching project files on 125 without Cursor user-data overwrite

- [x] **Step 1: Create timestamped backup of remote project directory** (`/home/yao/Projects/cursor-web-bridge.bak-20260724-223908`)
- [x] **Step 2: rsync with excludes for `.env`, `.venv`, `__pycache__`, logs, secrets**
- [x] **Step 3: Verify key files exist remotely, especially the handoff doc**

---

### Task 3: Install or verify Cursor CLI on 125

**Files:**
- Runtime: `/home/yao/.local/bin/agent`

**Interfaces:**
- Consumes: network access from 125 to Cursor services
- Produces: `agent` binary and authentication status

- [x] **Step 1: Check whether `agent` already exists** (missing → install)
- [x] **Step 2: Install CLI if missing via official installer** (`2026.07.23-e383d2b`)
- [x] **Step 3: Run `agent --version` and `agent status`** (`Not logged in`)
- [x] **Step 4: If not logged in, start `NO_OPEN_BROWSER=1 agent login` and hand URL to user** (logged in as `xudazhong@autel.com`)

---

### Task 4: Verify CLI can continue from handoff

**Files:**
- Read: `docs/handoffs/2026-07-24-cursor-125-cli-handoff.md`

**Interfaces:**
- Consumes: synced repo + authenticated CLI
- Produces: verified continuation path for home SSH use

- [x] **Step 1: Confirm remote project path and handoff readability**
- [x] **Step 2: Confirm `agent status` shows logged-in account** (`xudazhong@autel.com`)
- [x] **Step 3: Document exact home-to-125 continuation commands**
