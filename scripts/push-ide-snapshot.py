#!/usr/bin/env python3
"""Collect the local Cursor workspace/agent state and push it to the remote bridge.

Runs on the Mac (which has the local Cursor state DB) and POSTs a snapshot to the
remote service on 10.229.20.125, so the web UI served from Linux mirrors this
machine's workspace and agent list.

Env overrides:
  PUSH_TARGETS   comma-separated base URLs (default LAN then public tunnel)
  BRIDGE_API_KEY bearer key (default read from project .env)
  PUSH_INTERVAL  seconds between pushes when run with --loop (default 30)
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "server"))

import cursor_ide  # noqa: E402


def load_env_key() -> str:
    key = os.environ.get("BRIDGE_API_KEY")
    if key:
        return key.strip()
    env_file = ROOT / ".env"
    try:
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("BRIDGE_API_KEY="):
                return line.split("=", 1)[1].strip()
    except Exception:
        pass
    return ""


def targets() -> list[str]:
    raw = os.environ.get("PUSH_TARGETS")
    if raw:
        return [t.strip().rstrip("/") for t in raw.split(",") if t.strip()]
    return [
        "http://10.229.20.125:8787",
        "https://cursor.david-x.com",
    ]


def push_once(key: str) -> bool:
    if not cursor_ide.has_local_cursor():
        print("[push] no local Cursor state DB; skipping", flush=True)
        return False

    snapshot = cursor_ide.build_push_snapshot()
    body = json.dumps(snapshot, ensure_ascii=False).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {key}",
    }

    for base in targets():
        url = f"{base}/api/ide/snapshot"
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                text = resp.read().decode("utf-8", "replace")
                print(f"[push] {url} -> {resp.status} {text}", flush=True)
                return True
        except urllib.error.HTTPError as exc:
            print(f"[push] {url} -> HTTP {exc.code} {exc.reason}", flush=True)
        except Exception as exc:
            print(f"[push] {url} -> {exc}", flush=True)
    return False


def main() -> int:
    key = load_env_key()
    if not key:
        print("[push] missing BRIDGE_API_KEY", flush=True)
        return 2

    if "--loop" in sys.argv:
        interval = float(os.environ.get("PUSH_INTERVAL", "30"))
        while True:
            try:
                push_once(key)
            except Exception as exc:
                print(f"[push] loop error: {exc}", flush=True)
            time.sleep(interval)

    return 0 if push_once(key) else 1


if __name__ == "__main__":
    raise SystemExit(main())
