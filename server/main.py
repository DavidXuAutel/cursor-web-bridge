"""Cursor Web Bridge — local Cursor API gateway with web UI."""

from __future__ import annotations

import asyncio
import json
import os
import threading
import uuid
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from bridge import (
    cursor_ide_running,
    ensure_bridge,
    list_models,
    reset_agent,
    shutdown_bridge,
    state,
    stream_chat,
)
import ide_store
from cursor_ide import (
    get_agent,
    get_workspace_snapshot,
    has_local_cursor,
    list_agents,
    read_agent_messages,
)

load_dotenv()

ROOT = Path(__file__).resolve().parent.parent
STATIC_DIR = ROOT / "static"

state.workspace = os.environ.get("CURSOR_CWD", str(ROOT.parent))
state.cursor_api_key = os.environ.get("CURSOR_API_KEY", "")
state.bridge_api_key = os.environ.get("BRIDGE_API_KEY", "")
state.default_model = os.environ.get("DEFAULT_MODEL", "composer-2.5")

app = FastAPI(
    title="Cursor Web Bridge",
    description="将本机 Cursor 本地 Agent API 暴露为 HTTP 接口，支持公网隧道访问",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def verify_bridge_key(
    authorization: str | None = Header(default=None),
    x_api_key: str | None = Header(default=None),
    token: str | None = Query(default=None),
) -> None:
    required = state.bridge_api_key
    if not required:
        return

    provided = extract_token(authorization, x_api_key, token)
    if provided != required:
        raise HTTPException(status_code=401, detail="授权失败：Bridge API Key 无效或缺失")


def extract_token(
    authorization: str | None = None,
    x_api_key: str | None = None,
    query_token: str | None = None,
) -> str | None:
    if authorization and authorization.lower().startswith("bearer "):
        return authorization[7:].strip()
    if x_api_key:
        return x_api_key.strip()
    if query_token:
        return query_token.strip()
    return None

async def iterate_stream_chat(message: str):
    queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
    loop = asyncio.get_running_loop()

    def worker() -> None:
        try:
            for chunk in stream_chat(message):
                loop.call_soon_threadsafe(queue.put_nowait, chunk)
        except Exception as exc:
            loop.call_soon_threadsafe(
                queue.put_nowait,
                {"type": "error", "content": str(exc)},
            )
        finally:
            loop.call_soon_threadsafe(queue.put_nowait, None)

    threading.Thread(target=worker, daemon=True).start()
    while True:
        chunk = await queue.get()
        if chunk is None:
            break
        yield chunk


class ConfigUpdate(BaseModel):
    cursor_api_key: str | None = None
    workspace: str | None = None
    default_model: str | None = None


class ChatRequest(BaseModel):
    message: str = Field(min_length=1)
    model: str | None = None
    new_session: bool = False


class OpenAIChatRequest(BaseModel):
    model: str | None = None
    messages: list[dict[str, Any]]
    stream: bool = False


@app.on_event("startup")
async def startup() -> None:
    # Bridge 延迟初始化，避免启动时阻塞事件循环导致全站无响应
    pass


@app.on_event("shutdown")
async def shutdown() -> None:
    shutdown_bridge()


@app.get("/")
async def index() -> HTMLResponse:
    html = (STATIC_DIR / "index.html").read_text(encoding="utf-8")
    boot = {
        "bridgeKey": state.bridge_api_key,
        "hasCursorKey": bool(state.cursor_api_key or os.environ.get("CURSOR_API_KEY")),
        "workspace": state.workspace,
        "defaultModel": state.default_model,
    }
    inject = (
        f'<script>window.__CWB_BOOT__={json.dumps(boot, ensure_ascii=False)};</script>'
    )
    html = html.replace("</head>", f"{inject}\n</head>", 1)
    return HTMLResponse(html)


@app.get("/api/health")
async def health() -> dict[str, Any]:
    return {"status": "ok"}


@app.get("/api/status")
async def status(_: None = Depends(verify_bridge_key)) -> dict[str, Any]:
    bridge_ok = state.client is not None
    if not bridge_ok:
        try:
            ensure_bridge()
            bridge_ok = True
        except Exception as exc:
            state.last_error = str(exc)

    ide_workspace = None
    selected_agent = None
    try:
        snap = get_workspace_snapshot() if has_local_cursor() else ide_store.get_workspace()
        ide_workspace = snap.get("selected_workspace")
        selected_agent = {
            "id": snap.get("selected_agent_id"),
            "name": (snap.get("selected_workspace") or {}).get("agent_name"),
            "workspace_path": (snap.get("selected_workspace") or {}).get("path"),
        }
    except Exception as exc:
        state.last_error = str(exc)

    return {
        "bridge_connected": bridge_ok,
        "cursor_ide_running": cursor_ide_running(),
        "workspace": state.workspace,
        "ide_workspace": ide_workspace,
        "selected_agent": selected_agent,
        "default_model": state.default_model,
        "has_cursor_api_key": bool(state.cursor_api_key or os.environ.get("CURSOR_API_KEY")),
        "has_bridge_api_key": bool(state.bridge_api_key),
        "active_agent_id": state.active_agent_id,
        "last_error": state.last_error,
    }


@app.get("/api/workspace")
async def workspace(_: None = Depends(verify_bridge_key)) -> dict[str, Any]:
    try:
        if has_local_cursor():
            snap = get_workspace_snapshot()
            snap["source"] = "local"
        else:
            snap = ide_store.get_workspace()
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    snap["bridge_workspace"] = state.workspace
    return snap


@app.get("/api/agents")
async def agents(
    limit: int = 50,
    detail: bool = False,
    _: None = Depends(verify_bridge_key),
) -> dict[str, Any]:
    limit = max(1, min(limit, 200))
    try:
        if has_local_cursor():
            return list_agents(limit=limit, detail=detail)
        return ide_store.get_agents(limit=limit)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.get("/api/agents/{agent_id}")
async def agent_detail(
    agent_id: str,
    _: None = Depends(verify_bridge_key),
) -> dict[str, Any]:
    item = get_agent(agent_id) if has_local_cursor() else ide_store.get_agent(agent_id)
    if item is None:
        raise HTTPException(status_code=404, detail="agent not found")
    return item


@app.get("/api/agents/{agent_id}/messages")
async def agent_messages(
    agent_id: str,
    limit: int = 80,
    _: None = Depends(verify_bridge_key),
) -> dict[str, Any]:
    limit = max(1, min(limit, 200))
    if has_local_cursor():
        data = read_agent_messages(agent_id, limit=limit)
    else:
        data = ide_store.get_messages(agent_id, limit=limit)
    if data.get("error") == "agent not found":
        raise HTTPException(status_code=404, detail="agent not found")
    return data


@app.post("/api/ide/snapshot")
async def ide_snapshot_push(
    payload: dict[str, Any],
    _: None = Depends(verify_bridge_key),
) -> dict[str, Any]:
    snap = ide_store.set_snapshot(payload)
    return {
        "status": "ok",
        "agents": len(snap.get("agents") or []),
        "received_at": snap.get("received_at"),
    }


@app.post("/api/config")
async def update_config(
    body: ConfigUpdate,
    _: None = Depends(verify_bridge_key),
) -> dict[str, str]:
    changed = False

    if body.cursor_api_key is not None:
        state.cursor_api_key = body.cursor_api_key.strip()
        changed = True

    if body.workspace is not None:
        workspace = body.workspace.strip()
        if not os.path.isdir(workspace):
            raise HTTPException(status_code=400, detail=f"工作目录不存在: {workspace}")
        state.workspace = workspace
        shutdown_bridge()
        changed = True

    if body.default_model is not None:
        state.default_model = body.default_model.strip()
        changed = True

    if changed:
        reset_agent()
        try:
            ensure_bridge()
        except Exception as exc:
            state.last_error = str(exc)

    return {"status": "ok"}


@app.get("/api/models")
async def models(_: None = Depends(verify_bridge_key)) -> dict[str, Any]:
    try:
        items = list_models()
        return {"data": items}
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/chat", response_model=None)
async def chat(
    body: ChatRequest,
    _: None = Depends(verify_bridge_key),
) -> Response:
    if body.model:
        state.default_model = body.model
    if body.new_session:
        reset_agent()

    def event_stream():
        try:
            for chunk in stream_chat(body.message):
                yield f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n"
        except Exception as exc:
            state.last_error = str(exc)
            yield f"data: {json.dumps({'type': 'error', 'content': str(exc)}, ensure_ascii=False)}\n\n"

    return StreamingResponse(event_stream(), media_type="text/event-stream")


@app.websocket("/ws")
async def websocket_chat(websocket: WebSocket) -> None:
    token = (websocket.query_params.get("token") or "").strip()
    # Ellipsis / truncated share URLs must not pass
    if state.bridge_api_key:
        bad = (not token) or ("…" in token) or ("⋯" in token) or token == "..."
        if bad or token != state.bridge_api_key:
            await websocket.close(code=1008, reason="Unauthorized")
            return

    await websocket.accept()
    closed = False

    async def safe_send(payload: dict[str, Any]) -> bool:
        nonlocal closed
        if closed:
            return False
        try:
            await websocket.send_json(payload)
            return True
        except Exception:
            closed = True
            return False

    try:
        while True:
            data = await websocket.receive_json()
            msg_type = data.get("type", "chat")

            if msg_type == "ping":
                await safe_send({"type": "pong"})
                continue

            if msg_type == "status":
                bridge_ok = state.client is not None
                if not bridge_ok:
                    try:
                        ensure_bridge()
                        bridge_ok = True
                    except Exception as exc:
                        state.last_error = str(exc)
                await safe_send(
                    {
                        "type": "status",
                        "bridge_connected": bridge_ok,
                        "cursor_ide_running": cursor_ide_running(),
                        "workspace": state.workspace,
                        "default_model": state.default_model,
                        "has_cursor_api_key": bool(
                            state.cursor_api_key or os.environ.get("CURSOR_API_KEY")
                        ),
                        "active_agent_id": state.active_agent_id,
                        "last_error": state.last_error,
                    }
                )
                continue

            if msg_type == "models":
                try:
                    items = list_models()
                    await safe_send({"type": "models", "data": items})
                except Exception as exc:
                    await safe_send({"type": "error", "content": str(exc)})
                continue

            if msg_type == "config":
                if data.get("cursor_api_key"):
                    state.cursor_api_key = str(data["cursor_api_key"]).strip()
                if data.get("workspace"):
                    workspace = str(data["workspace"]).strip()
                    if not os.path.isdir(workspace):
                        await safe_send(
                            {"type": "error", "content": f"工作目录不存在: {workspace}"}
                        )
                        continue
                    state.workspace = workspace
                    shutdown_bridge()
                if data.get("default_model"):
                    state.default_model = str(data["default_model"]).strip()
                reset_agent()
                try:
                    ensure_bridge()
                except Exception as exc:
                    state.last_error = str(exc)
                await safe_send({"type": "config_saved"})
                continue

            if msg_type != "chat":
                await safe_send(
                    {"type": "error", "content": f"未知消息类型: {msg_type}"}
                )
                continue

            message = str(data.get("message", "")).strip()
            if not message:
                await safe_send({"type": "error", "content": "message 不能为空"})
                continue

            if data.get("model"):
                state.default_model = str(data["model"])
            if data.get("new_session"):
                reset_agent()

            try:
                async for chunk in iterate_stream_chat(message):
                    if not await safe_send(chunk):
                        break
            except Exception as exc:
                state.last_error = str(exc)
                await safe_send({"type": "error", "content": str(exc)})
    except WebSocketDisconnect:
        closed = True
        return
    except Exception as exc:
        state.last_error = str(exc)
        await safe_send({"type": "error", "content": str(exc)})


@app.post("/api/v1/chat/completions", response_model=None)
async def openai_chat(
    body: OpenAIChatRequest,
    _: None = Depends(verify_bridge_key),
) -> Response:
    user_messages = [m.get("content", "") for m in body.messages if m.get("role") == "user"]
    if not user_messages:
        raise HTTPException(status_code=400, detail="messages 中需要至少一条 user 消息")

    prompt = user_messages[-1]
    if isinstance(prompt, list):
        prompt = " ".join(
            part.get("text", "") if isinstance(part, dict) else str(part)
            for part in prompt
        )

    if body.model:
        state.default_model = body.model

    if not body.stream:
        text_parts: list[str] = []
        final_status = "finished"
        run_id = str(uuid.uuid4())
        try:
            for chunk in stream_chat(str(prompt)):
                if chunk.get("type") == "text":
                    text_parts.append(chunk.get("content", ""))
                elif chunk.get("type") == "done":
                    final_status = chunk.get("status", "finished")
                    run_id = chunk.get("run_id", run_id)
        except Exception as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc

        return JSONResponse(
            {
                "id": f"chatcmpl-{run_id}",
                "object": "chat.completion",
                "model": state.default_model,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "".join(text_parts)},
                        "finish_reason": "stop" if final_status == "finished" else final_status,
                    }
                ],
            }
        )

    def openai_stream():
        completion_id = f"chatcmpl-{uuid.uuid4()}"
        try:
            for chunk in stream_chat(str(prompt)):
                if chunk.get("type") == "text":
                    payload = {
                        "id": completion_id,
                        "object": "chat.completion.chunk",
                        "model": state.default_model,
                        "choices": [
                            {
                                "index": 0,
                                "delta": {"content": chunk.get("content", "")},
                                "finish_reason": None,
                            }
                        ],
                    }
                    yield f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"
                elif chunk.get("type") == "done":
                    payload = {
                        "id": completion_id,
                        "object": "chat.completion.chunk",
                        "model": state.default_model,
                        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                    }
                    yield f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"
            yield "data: [DONE]\n\n"
        except Exception as exc:
            state.last_error = str(exc)
            err = {"error": {"message": str(exc), "type": "server_error"}}
            yield f"data: {json.dumps(err, ensure_ascii=False)}\n\n"

    return StreamingResponse(openai_stream(), media_type="text/event-stream")


@app.get("/api/v1/models")
async def openai_models(_: None = Depends(verify_bridge_key)) -> dict[str, Any]:
    try:
        items = list_models()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return {
        "object": "list",
        "data": [
            {"id": item["id"], "object": "model", "owned_by": "cursor"}
            for item in items
        ],
    }


if STATIC_DIR.is_dir():
    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
