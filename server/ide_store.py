"""Store for IDE workspace/agent snapshots pushed from a machine running Cursor.

The remote (Linux) host has no local Cursor state DB, so a collector on the Mac
periodically POSTs a snapshot here. Endpoints then serve this cached snapshot
whenever the local Cursor DB is unavailable.
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path
from typing import Any

_ROOT = Path(__file__).resolve().parent.parent
_SNAP_FILE = _ROOT / "logs" / "ide_snapshot.json"
_lock = threading.Lock()
_data: dict[str, Any] | None = None


def _load() -> dict[str, Any]:
    global _data
    if _data is None:
        try:
            _data = json.loads(_SNAP_FILE.read_text(encoding="utf-8"))
        except Exception:
            _data = {}
    return _data


def set_snapshot(payload: dict[str, Any]) -> dict[str, Any]:
    global _data
    with _lock:
        snap = dict(payload or {})
        snap["received_at"] = time.time()
        _data = snap
        try:
            _SNAP_FILE.parent.mkdir(parents=True, exist_ok=True)
            _SNAP_FILE.write_text(
                json.dumps(snap, ensure_ascii=False), encoding="utf-8"
            )
        except Exception:
            pass
    return snap


def get_snapshot() -> dict[str, Any]:
    with _lock:
        return dict(_load() or {})


def snapshot_meta() -> dict[str, Any]:
    snap = get_snapshot()
    if not snap:
        return {"source": "pushed", "available": False}
    now = time.time()
    ref = snap.get("received_at") or snap.get("generated_at") or now
    return {
        "source": "pushed",
        "available": True,
        "origin": snap.get("source"),
        "generated_at": snap.get("generated_at"),
        "received_at": snap.get("received_at"),
        "age_seconds": round(now - ref, 1),
    }


def get_workspace() -> dict[str, Any]:
    snap = get_snapshot()
    ws = snap.get("workspace") or {
        "layout": None,
        "selected_agent_id": None,
        "selected_workspace": {"id": None, "path": None, "label": None},
        "open_workspaces": [],
        "known_workspaces": [],
        "error": None,
    }
    ws = dict(ws)
    ws["snapshot"] = snapshot_meta()
    return ws


def get_agents(limit: int = 50) -> dict[str, Any]:
    snap = get_snapshot()
    agents = (snap.get("agents") or [])[:limit]
    return {
        "selected_agent_id": snap.get("selected_agent_id"),
        "agents": agents,
        "count": len(agents),
        "error": None,
        "snapshot": snapshot_meta(),
    }


def get_agent(agent_id: str) -> dict[str, Any] | None:
    snap = get_snapshot()
    for a in snap.get("agents") or []:
        if a.get("id") == agent_id:
            return a
    return None


def get_messages(agent_id: str, limit: int = 80) -> dict[str, Any]:
    snap = get_snapshot()
    agent = get_agent(agent_id)
    if agent is None:
        return {"agent_id": agent_id, "messages": [], "error": "agent not found"}
    msgs = (snap.get("messages") or {}).get(agent_id) or []
    return {
        "agent": agent,
        "messages": msgs[-limit:],
        "error": None,
        "snapshot": snapshot_meta(),
    }
