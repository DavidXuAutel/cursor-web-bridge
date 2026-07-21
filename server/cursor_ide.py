"""Discovery and open helpers for Cursor IDE workspace / Glass agent UI state."""

from __future__ import annotations

import json
import sqlite3
import subprocess
import time
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

CURSOR_USER = Path.home() / "Library/Application Support/Cursor/User"
STATE_DB = CURSOR_USER / "globalStorage" / "state.vscdb"
WORKSPACE_STORAGE = CURSOR_USER / "workspaceStorage"
PROJECTS_ROOT = Path.home() / ".cursor" / "projects"
EMPTY_WINDOW_ID = "empty-window"
EMPTY_WINDOW_LABEL = "空窗口"


def has_local_cursor() -> bool:
    """True when this machine has a readable local Cursor state DB."""
    return STATE_DB.is_file()


def build_push_snapshot(
    agent_limit: int = 50,
    msg_agents: int = 20,
    msg_limit: int = 40,
) -> dict[str, Any]:
    """Build a snapshot of local Cursor workspace/agents to push to a remote host."""
    workspace = get_workspace_snapshot()
    agents_data = list_agents(limit=agent_limit, detail=False)
    agents = agents_data.get("agents", [])

    messages: dict[str, Any] = {}
    for a in agents[:msg_agents]:
        aid = a.get("id")
        if not aid:
            continue
        try:
            r = read_agent_messages(aid, limit=msg_limit)
            messages[aid] = r.get("messages", [])
        except Exception:
            messages[aid] = []

    return {
        "source": "mac",
        "generated_at": time.time(),
        "workspace": workspace,
        "agents": agents,
        "selected_agent_id": agents_data.get("selected_agent_id"),
        "messages": messages,
    }


def workspace_label(workspace_id: str | None, path: str | None = None) -> str:
    if path:
        return Path(path).name
    if workspace_id == EMPTY_WINDOW_ID or not workspace_id:
        return EMPTY_WINDOW_LABEL
    return workspace_id


def _file_uri_to_path(uri: str | None) -> str | None:
    if not uri:
        return None
    if uri.startswith("file://"):
        return unquote(urlparse(uri).path)
    return uri


def _connect_ro() -> sqlite3.Connection:
    if not STATE_DB.is_file():
        raise FileNotFoundError(f"Cursor state DB not found: {STATE_DB}")
    # URI mode + immutable-ish read while Cursor holds WAL
    uri = f"file:{STATE_DB}?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=3)
    conn.row_factory = sqlite3.Row
    return conn


def _item_value(conn: sqlite3.Connection, key: str) -> str | None:
    row = conn.execute(
        "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", (key,)
    ).fetchone()
    return None if row is None else row["value"]


def list_known_workspaces() -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    if not WORKSPACE_STORAGE.is_dir():
        return items
    for d in sorted(WORKSPACE_STORAGE.iterdir()):
        if not d.is_dir():
            continue
        ws_file = d / "workspace.json"
        path = None
        if ws_file.is_file():
            try:
                data = json.loads(ws_file.read_text(encoding="utf-8"))
                path = _file_uri_to_path(data.get("folder"))
            except Exception:
                path = None
        items.append(
            {
                "id": d.name,
                "path": path,
                "label": Path(path).name if path else d.name,
            }
        )
    return items


def live_workspace_ids() -> set[str]:
    """Best-effort: parse Cursor fileWatcher process args for open workspace IDs."""
    ids: set[str] = set()
    try:
        result = subprocess.run(
            ["pgrep", "-lf", "fileWatcher"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        for line in result.stdout.splitlines():
            # fileWatcher [2:<workspaceId>]
            if "fileWatcher [" in line and ":" in line:
                try:
                    part = line.split("fileWatcher [", 1)[1]
                    inner = part.split("]", 1)[0]
                    wid = inner.split(":", 1)[1].strip()
                    if wid:
                        ids.add(wid)
                except Exception:
                    continue
    except Exception:
        pass
    return ids


def _workspace_path_from_header(header: dict[str, Any], known: dict[str, str]) -> str | None:
    wi = header.get("workspaceIdentifier") or {}
    uri = wi.get("uri") or {}
    if isinstance(uri, dict) and uri.get("fsPath"):
        return uri["fsPath"]
    if isinstance(uri, str):
        return _file_uri_to_path(uri)
    wid = wi.get("id") or header.get("workspaceId")
    if wid and wid in known:
        return known[wid]
    return None


def _ui_status(header: dict[str, Any], detail: dict[str, Any] | None = None) -> str:
    if header.get("isDraft"):
        return "draft"
    if header.get("isArchived"):
        return "archived"
    if header.get("hasBlockingPendingActions"):
        return "needs_attention"
    if detail:
        gen = detail.get("generatingBubbleIds") or []
        if gen:
            return "running"
        status = detail.get("status")
        if status == "completed":
            return "done"
        if status == "aborted":
            return "aborted"
    return "idle"


def _transcript_path(composer_id: str, workspace_path: str | None, workspace_id: str | None) -> str | None:
    candidates: list[Path] = []
    if workspace_path:
        encoded = str(Path(workspace_path)).lstrip("/").replace("/", "-")
        candidates.append(PROJECTS_ROOT / encoded / "agent-transcripts" / composer_id)
    if workspace_id == "empty-window" or not workspace_path:
        candidates.append(PROJECTS_ROOT / "empty-window" / "agent-transcripts" / composer_id)
    for base in candidates:
        jsonl = base / f"{composer_id}.jsonl"
        if jsonl.is_file():
            return str(jsonl)
    return None


def _composer_detail(conn: sqlite3.Connection, composer_id: str) -> dict[str, Any] | None:
    """Fetch lightweight fields from composerData blob if present."""
    try:
        row = conn.execute(
            "SELECT value FROM cursorDiskKV WHERE key = ? LIMIT 1",
            (f"composerData:{composer_id}",),
        ).fetchone()
    except sqlite3.Error:
        return None
    if row is None:
        return None
    try:
        raw = row["value"]
        if isinstance(raw, memoryview):
            raw = raw.tobytes()
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", errors="replace")
        data = json.loads(raw)
        return {
            "status": data.get("status"),
            "generatingBubbleIds": data.get("generatingBubbleIds") or [],
            "model": ((data.get("modelConfig") or {}).get("modelName")),
            "unified_mode": data.get("unifiedMode"),
        }
    except Exception:
        return None


def get_selected_agent_id(conn: sqlite3.Connection | None = None) -> str | None:
    own = False
    if conn is None:
        conn = _connect_ro()
        own = True
    try:
        return _item_value(conn, "cursor/glass.selectedAgent")
    finally:
        if own:
            conn.close()


def get_workspace_snapshot() -> dict[str, Any]:
    known = list_known_workspaces()
    known_map = {w["id"]: w["path"] for w in known if w.get("path")}
    live = live_workspace_ids()

    layout = None
    selected_id = None
    selected_workspace: dict[str, Any] = {"id": None, "path": None, "label": None}

    try:
        with _connect_ro() as conn:
            layout = _item_value(conn, "cursor/unifiedAppLayout")
            selected_id = _item_value(conn, "cursor/glass.selectedAgent")
            if selected_id:
                row = conn.execute(
                    "SELECT value, workspaceId FROM composerHeaders WHERE composerId = ? LIMIT 1",
                    (selected_id,),
                ).fetchone()
                if row is not None:
                    header = json.loads(row["value"])
                    wid = (header.get("workspaceIdentifier") or {}).get("id") or row["workspaceId"]
                    path = _workspace_path_from_header(header, known_map)
                    selected_workspace = {
                        "id": wid,
                        "path": path,
                        "label": workspace_label(wid, path),
                        "agent_id": selected_id,
                        "agent_name": header.get("name") or "",
                    }
    except Exception as exc:
        return {
            "layout": layout,
            "selected_agent_id": selected_id,
            "selected_workspace": selected_workspace,
            "open_workspaces": [],
            "known_workspaces": known,
            "error": str(exc),
        }

    open_workspaces = []
    for w in known:
        item = {
            **w,
            "label": workspace_label(w.get("id"), w.get("path")),
            "live": w["id"] in live,
        }
        if item["live"] or w["id"] == selected_workspace.get("id"):
            open_workspaces.append(item)

    # Also include live IDs that have no workspace.json (e.g. empty-window)
    for wid in live:
        if not any(w["id"] == wid for w in open_workspaces):
            open_workspaces.append(
                {
                    "id": wid,
                    "path": known_map.get(wid),
                    "label": workspace_label(wid, known_map.get(wid)),
                    "live": True,
                }
            )

    return {
        "layout": layout,
        "selected_agent_id": selected_id,
        "selected_workspace": selected_workspace,
        "open_workspaces": open_workspaces,
        "known_workspaces": known,
        "error": None,
    }


def list_agents(limit: int = 50, detail: bool = False) -> dict[str, Any]:
    known = {w["id"]: w["path"] for w in list_known_workspaces() if w.get("path")}
    selected_id = None
    agents: list[dict[str, Any]] = []

    try:
        with _connect_ro() as conn:
            selected_id = _item_value(conn, "cursor/glass.selectedAgent")
            rows = conn.execute(
                """
                SELECT composerId, workspaceId, createdAt, lastUpdatedAt,
                       isArchived, isSubagent, recency, value
                FROM composerHeaders
                WHERE COALESCE(isSubagent, 0) = 0
                ORDER BY COALESCE(recency, lastUpdatedAt, createdAt) DESC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()

            for row in rows:
                try:
                    header = json.loads(row["value"])
                except Exception:
                    header = {}
                composer_id = row["composerId"]
                workspace_id = (
                    (header.get("workspaceIdentifier") or {}).get("id")
                    or row["workspaceId"]
                )
                workspace_path = _workspace_path_from_header(header, known)
                detail_data = None
                if detail or composer_id == selected_id:
                    detail_data = _composer_detail(conn, composer_id)

                agents.append(
                    {
                        "id": composer_id,
                        "name": header.get("name") or "(untitled)",
                        "subtitle": header.get("subtitle") or "",
                        "workspace_id": workspace_id,
                        "workspace_path": workspace_path,
                        "workspace_label": workspace_label(workspace_id, workspace_path),
                        "unified_mode": header.get("unifiedMode")
                        or (detail_data or {}).get("unified_mode"),
                        "status": (detail_data or {}).get("status"),
                        "ui_status": _ui_status(header, detail_data),
                        "model": (detail_data or {}).get("model"),
                        "is_archived": bool(row["isArchived"] or header.get("isArchived")),
                        "is_draft": bool(header.get("isDraft")),
                        "has_blocking_pending_actions": bool(
                            header.get("hasBlockingPendingActions")
                        ),
                        "has_unread_messages": bool(header.get("hasUnreadMessages")),
                        "selected": composer_id == selected_id,
                        "created_at": row["createdAt"] or header.get("createdAt"),
                        "updated_at": row["lastUpdatedAt"] or header.get("lastUpdatedAt"),
                        "transcript_path": _transcript_path(
                            composer_id, workspace_path, workspace_id
                        ),
                    }
                )
    except Exception as exc:
        return {
            "selected_agent_id": selected_id,
            "agents": agents,
            "count": len(agents),
            "error": str(exc),
        }

    return {
        "selected_agent_id": selected_id,
        "agents": agents,
        "count": len(agents),
        "error": None,
    }


def get_agent(composer_id: str) -> dict[str, Any] | None:
    known = {w["id"]: w["path"] for w in list_known_workspaces() if w.get("path")}
    try:
        with _connect_ro() as conn:
            selected_id = _item_value(conn, "cursor/glass.selectedAgent")
            row = conn.execute(
                """
                SELECT composerId, workspaceId, createdAt, lastUpdatedAt,
                       isArchived, value
                FROM composerHeaders WHERE composerId = ? LIMIT 1
                """,
                (composer_id,),
            ).fetchone()
            if row is None:
                return None
            header = json.loads(row["value"])
            detail_data = _composer_detail(conn, composer_id)
            workspace_id = (
                (header.get("workspaceIdentifier") or {}).get("id") or row["workspaceId"]
            )
            workspace_path = _workspace_path_from_header(header, known)
            return {
                "id": composer_id,
                "name": header.get("name") or "(untitled)",
                "subtitle": header.get("subtitle") or "",
                "workspace_id": workspace_id,
                "workspace_path": workspace_path,
                "workspace_label": workspace_label(workspace_id, workspace_path),
                "unified_mode": header.get("unifiedMode")
                or (detail_data or {}).get("unified_mode"),
                "status": (detail_data or {}).get("status"),
                "ui_status": _ui_status(header, detail_data),
                "model": (detail_data or {}).get("model"),
                "is_archived": bool(row["isArchived"] or header.get("isArchived")),
                "is_draft": bool(header.get("isDraft")),
                "has_blocking_pending_actions": bool(
                    header.get("hasBlockingPendingActions")
                ),
                "selected": composer_id == selected_id,
                "created_at": row["createdAt"] or header.get("createdAt"),
                "updated_at": row["lastUpdatedAt"] or header.get("lastUpdatedAt"),
                "transcript_path": _transcript_path(
                    composer_id, workspace_path, workspace_id
                ),
                "header": header,
                "detail": detail_data,
            }
    except Exception:
        return None


def _extract_message_text(evt: dict[str, Any]) -> str | None:
    role = evt.get("role")
    if role not in ("user", "assistant", "system"):
        return None

    raw = evt.get("message") if "message" in evt else evt.get("content")
    if raw is None:
        raw = evt.get("text")

    if isinstance(raw, dict):
        raw = raw.get("content", raw.get("text"))

    if isinstance(raw, list):
        parts: list[str] = []
        for p in raw:
            if isinstance(p, dict):
                if p.get("type") == "text" and p.get("text"):
                    parts.append(str(p["text"]))
                elif p.get("text"):
                    parts.append(str(p["text"]))
            elif p:
                parts.append(str(p))
        text = "\n".join(parts).strip()
        return text or None

    if raw is None:
        return None
    text = str(raw).strip()
    return text or None


def read_agent_messages(composer_id: str, limit: int = 80) -> dict[str, Any]:
    """Read transcript messages for an agent (best-effort from .jsonl)."""
    agent = get_agent(composer_id)
    if agent is None:
        return {"agent_id": composer_id, "messages": [], "error": "agent not found"}

    path = agent.get("transcript_path")
    messages: list[dict[str, Any]] = []
    if path and Path(path).is_file():
        try:
            lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
            for line in lines[-max(limit * 4, limit):]:
                line = line.strip()
                if not line:
                    continue
                try:
                    evt = json.loads(line)
                except Exception:
                    continue
                content = _extract_message_text(evt)
                if not content:
                    continue
                # Drop internal timestamp/user_query wrappers for display brevity
                if content.startswith("<timestamp>") and "<user_query>" in content:
                    try:
                        content = content.split("<user_query>", 1)[1]
                        content = content.split("</user_query>", 1)[0].strip()
                    except Exception:
                        pass
                messages.append(
                    {
                        "role": evt.get("role"),
                        "content": content[:8000],
                        "timestamp": evt.get("timestamp") or evt.get("createdAt"),
                    }
                )
            messages = messages[-limit:]
        except Exception as exc:
            return {
                "agent": agent,
                "messages": [],
                "error": f"failed to read transcript: {exc}",
            }

    return {"agent": agent, "messages": messages, "error": None}
