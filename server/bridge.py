"""Cursor SDK bridge lifecycle manager."""

from __future__ import annotations

import os
import subprocess
import threading
from contextlib import contextmanager
from dataclasses import dataclass, field
from typing import Any, Iterator

from cursor_sdk import Agent, CursorClient, LocalAgentOptions


@dataclass
class BridgeState:
    workspace: str = ""
    cursor_api_key: str = ""
    bridge_api_key: str = ""
    default_model: str = "composer-2.5"
    client: CursorClient | None = None
    active_agent: Agent | None = None
    active_agent_id: str | None = None
    lock: threading.Lock = field(default_factory=threading.Lock)
    last_error: str | None = None


state = BridgeState()


def cursor_ide_running() -> bool:
    try:
        for pattern in ("Cursor", "cursor"):
            result = subprocess.run(
                ["pgrep", "-if", pattern],
                capture_output=True,
                timeout=3,
            )
            if result.returncode == 0 and result.stdout.strip():
                return True
        return False
    except Exception:
        return False


def ensure_bridge() -> CursorClient:
    with state.lock:
        if state.client is not None:
            return state.client

        workspace = state.workspace or os.getcwd()
        client = CursorClient.launch_bridge(workspace=workspace)
        state.client = client
        state.workspace = workspace
        state.last_error = None
        return client


def shutdown_bridge() -> None:
    with state.lock:
        if state.active_agent is not None:
            try:
                state.active_agent.close()
            except Exception:
                pass
            state.active_agent = None
            state.active_agent_id = None

        if state.client is not None:
            try:
                state.client.close()
            except Exception:
                pass
            state.client = None


def get_or_create_agent() -> Agent:
    api_key = state.cursor_api_key or os.environ.get("CURSOR_API_KEY", "")
    if not api_key:
        raise ValueError("CURSOR_API_KEY 未配置，请在设置中填写或在 .env 中设置")

    with state.lock:
        if state.active_agent is not None:
            return state.active_agent
        workspace = state.workspace or os.getcwd()
        model = state.default_model

    # Never call ensure_bridge/create_agent while holding state.lock (deadlock).
    client = ensure_bridge()
    agent = client.create_agent(
        model=model,
        api_key=api_key,
        local=LocalAgentOptions(cwd=workspace),
    )

    with state.lock:
        if state.active_agent is not None:
            try:
                agent.close()
            except Exception:
                pass
            return state.active_agent
        state.active_agent = agent
        state.active_agent_id = getattr(agent, "agent_id", None)
        return agent


def reset_agent() -> None:
    with state.lock:
        if state.active_agent is not None:
            try:
                state.active_agent.close()
            except Exception:
                pass
        state.active_agent = None
        state.active_agent_id = None


def list_models() -> list[dict[str, Any]]:
    api_key = state.cursor_api_key or os.environ.get("CURSOR_API_KEY", "")
    if not api_key:
        raise ValueError("CURSOR_API_KEY 未配置")

    client = ensure_bridge()
    models = client.list_models(api_key=api_key)
    return [{"id": m.id, "name": getattr(m, "name", m.id)} for m in models]


def stream_chat(message: str) -> Iterator[dict[str, Any]]:
    agent = get_or_create_agent()
    run = agent.send(message)

    yield {"type": "run_started", "run_id": run.run_id}

    for event in run.messages():
        event_type = getattr(event, "type", None)
        if event_type == "assistant":
            msg = getattr(event, "message", None)
            if msg is not None:
                for block in getattr(msg, "content", []):
                    block_type = getattr(block, "type", None)
                    if block_type == "text":
                        text = getattr(block, "text", "")
                        if text:
                            yield {"type": "text", "content": text}
                    elif block_type == "thinking":
                        text = getattr(block, "text", "")
                        if text:
                            yield {"type": "thinking", "content": text}
        elif event_type == "tool_call":
            yield {
                "type": "tool_call",
                "name": getattr(event, "name", "unknown"),
                "status": getattr(event, "status", "pending"),
            }
        elif event_type in ("status", "run_status"):
            yield {
                "type": "status",
                "status": getattr(event, "status", str(event)),
            }

    result = run.wait()
    yield {
        "type": "done",
        "status": result.status,
        "run_id": result.id if hasattr(result, "id") else run.run_id,
    }


@contextmanager
def temporary_api_key(api_key: str):
    previous = state.cursor_api_key
    state.cursor_api_key = api_key
    try:
        yield
    finally:
        state.cursor_api_key = previous
