const STORAGE_KEYS = {
  bridgeKey: "cwb_bridge_key",
  cursorKey: "cwb_cursor_key",
  workspace: "cwb_workspace",
};

const els = {
  bridgeDot: document.getElementById("bridgeDot"),
  bridgeStatus: document.getElementById("bridgeStatus"),
  cursorDot: document.getElementById("cursorDot"),
  cursorStatus: document.getElementById("cursorStatus"),
  messages: document.getElementById("messages"),
  chatForm: document.getElementById("chatForm"),
  messageInput: document.getElementById("messageInput"),
  modelSelect: document.getElementById("modelSelect"),
  sendBtn: document.getElementById("sendBtn"),
  newSessionBtn: document.getElementById("newSessionBtn"),
  bridgeKeyInput: document.getElementById("bridgeKeyInput"),
  cursorKeyInput: document.getElementById("cursorKeyInput"),
  workspaceInput: document.getElementById("workspaceInput"),
  saveConfigBtn: document.getElementById("saveConfigBtn"),
  baseUrl: document.getElementById("baseUrl"),
  wsUrl: document.getElementById("wsUrl"),
};

let ws = null;
let wsReady = false;
let pendingMessages = [];
let reconnectTimer = null;
let sendTimeout = null;
let chatInFlight = false;

function bridgeKey() {
  return els.bridgeKeyInput.value.trim();
}

function setSending(busy) {
  chatInFlight = busy;
  els.sendBtn.disabled = busy;
  if (sendTimeout) {
    clearTimeout(sendTimeout);
    sendTimeout = null;
  }
  if (busy) {
    // Prevent stuck disabled button if stream never finishes
    sendTimeout = setTimeout(() => {
      if (chatInFlight) {
        appendMessage("system", "回复超时，可重新发送。若仍无响应请点「新会话」。");
        setSending(false);
      }
    }, 180000);
  }
}

function wsEndpoint() {
  const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
  const token = bridgeKey();
  const qs = token ? `?token=${encodeURIComponent(token)}` : "";
  return `${proto}//${window.location.host}/ws${qs}`;
}

function authHeaders() {
  const headers = { "Content-Type": "application/json" };
  const key = bridgeKey();
  if (key) headers.Authorization = `Bearer ${key}`;
  return headers;
}

function loadSettings() {
  const params = new URLSearchParams(window.location.search);
  const urlToken = params.get("token");
  const boot = window.__CWB_BOOT__ || {};

  els.bridgeKeyInput.value =
    urlToken ||
    localStorage.getItem(STORAGE_KEYS.bridgeKey) ||
    boot.bridgeKey ||
    "";
  els.cursorKeyInput.value = localStorage.getItem(STORAGE_KEYS.cursorKey) || "";
  els.workspaceInput.value =
    localStorage.getItem(STORAGE_KEYS.workspace) || boot.workspace || "";
  els.baseUrl.textContent = window.location.origin;
  els.wsUrl.textContent = wsEndpoint();

  if (urlToken || boot.bridgeKey) {
    localStorage.setItem(STORAGE_KEYS.bridgeKey, bridgeKey());
  }
  if (boot.workspace && !localStorage.getItem(STORAGE_KEYS.workspace)) {
    localStorage.setItem(STORAGE_KEYS.workspace, boot.workspace);
  }
}

function saveSettings() {
  localStorage.setItem(STORAGE_KEYS.bridgeKey, bridgeKey());
  localStorage.setItem(STORAGE_KEYS.cursorKey, els.cursorKeyInput.value.trim());
  localStorage.setItem(STORAGE_KEYS.workspace, els.workspaceInput.value.trim());
  els.wsUrl.textContent = wsEndpoint();
}

function appendMessage(role, text) {
  const div = document.createElement("div");
  div.className = `msg ${role}`;
  div.textContent = text;
  els.messages.appendChild(div);
  els.messages.scrollTop = els.messages.scrollHeight;
  return div;
}

function connectWebSocket() {
  if (ws) {
    ws.onclose = null;
    try {
      ws.close();
    } catch (_) {
      /* ignore */
    }
  }

  wsReady = false;
  const endpoint = wsEndpoint();
  ws = new WebSocket(endpoint);

  ws.onopen = () => {
    wsReady = true;
    els.bridgeDot.className = "dot ok";
    els.bridgeStatus.textContent = "WebSocket 已连接";
    ws.send(JSON.stringify({ type: "status" }));
    ws.send(JSON.stringify({ type: "models" }));
    for (const msg of pendingMessages) ws.send(JSON.stringify(msg));
    pendingMessages = [];
  };

  ws.onmessage = (event) => {
    const payload = JSON.parse(event.data);
    handleWsPayload(payload);
  };

  ws.onclose = (event) => {
    wsReady = false;
    els.bridgeDot.className = "dot warn";
    if (event.code === 1008) {
      els.bridgeStatus.textContent = "鉴权失败，请检查 Bridge API Key";
    } else {
      els.bridgeStatus.textContent = `WebSocket 断开 (${event.code})，使用 HTTP 回退`;
    }
    if (chatInFlight) {
      appendMessage("system", "连接中断，可改用 HTTP 重新发送。");
      setSending(false);
    }
    refreshStatusHttp();
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(connectWebSocket, 5000);
  };

  ws.onerror = () => {
    wsReady = false;
    els.bridgeStatus.textContent = "WebSocket 连接失败，使用 HTTP 回退";
    if (chatInFlight) setSending(false);
    refreshStatusHttp();
  };
}

async function refreshStatusHttp() {
  try {
    const res = await api("/api/status");
    const data = await res.json();
    els.bridgeDot.className = `dot ${data.bridge_connected ? "ok" : "err"}`;
    if (!wsReady) {
      els.bridgeStatus.textContent = data.bridge_connected
        ? "HTTP 已连接（WebSocket 回退）"
        : "Bridge 未连接";
    }
    els.cursorDot.className = `dot ${data.cursor_ide_running ? "ok" : "warn"}`;
    els.cursorStatus.textContent = data.cursor_ide_running
      ? "Cursor 运行中"
      : "Cursor 未运行";
    if (data.workspace && !els.workspaceInput.value) {
      els.workspaceInput.value = data.workspace;
    }
  } catch {
    els.bridgeDot.className = "dot err";
    if (!wsReady) {
      els.bridgeStatus.textContent = bridgeKey()
        ? "鉴权失败，请检查 Bridge API Key"
        : "请填写 Bridge API Key";
    }
    els.cursorDot.className = "dot warn";
    els.cursorStatus.textContent = "状态未知（待鉴权）";
  }
}

async function loadModelsHttp() {
  try {
    const res = await api("/api/models");
    const data = await res.json();
    els.modelSelect.innerHTML = "";
    for (const model of data.data || []) {
      const opt = document.createElement("option");
      opt.value = model.id;
      opt.textContent = model.name || model.id;
      els.modelSelect.appendChild(opt);
    }
    // Prefer composer-2.5 when available
    const preferred = "composer-2.5";
    if ([...els.modelSelect.options].some((o) => o.value === preferred)) {
      els.modelSelect.value = preferred;
    }
  } catch {
    if (!els.modelSelect.options.length) {
      const opt = document.createElement("option");
      opt.value = "composer-2.5";
      opt.textContent = "composer-2.5";
      els.modelSelect.appendChild(opt);
    }
  }
}

function wsSend(payload) {
  if (wsReady && ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(payload));
  } else {
    pendingMessages.push(payload);
    connectWebSocket();
  }
}

function handleWsPayload(payload) {
  if (payload.type === "status") {
    els.bridgeDot.className = `dot ${payload.bridge_connected ? "ok" : "err"}`;
    els.bridgeStatus.textContent = payload.bridge_connected
      ? "Bridge 已连接"
      : "Bridge 未连接";
    els.cursorDot.className = `dot ${payload.cursor_ide_running ? "ok" : "warn"}`;
    els.cursorStatus.textContent = payload.cursor_ide_running
      ? "Cursor 运行中"
      : "Cursor 未运行";
    if (payload.workspace && !els.workspaceInput.value) {
      els.workspaceInput.value = payload.workspace;
    }
    return;
  }

  if (payload.type === "models") {
    els.modelSelect.innerHTML = "";
    for (const model of payload.data || []) {
      const opt = document.createElement("option");
      opt.value = model.id;
      opt.textContent = model.name || model.id;
      els.modelSelect.appendChild(opt);
    }
    if (!els.modelSelect.options.length) {
      const opt = document.createElement("option");
      opt.value = "composer-2.5";
      opt.textContent = "composer-2.5";
      els.modelSelect.appendChild(opt);
    }
    const preferred = "composer-2.5";
    if ([...els.modelSelect.options].some((o) => o.value === preferred)) {
      els.modelSelect.value = preferred;
    }
    return;
  }

  if (payload.type === "config_saved") {
    appendMessage("system", "连接配置已更新");
    wsSend({ type: "status" });
    wsSend({ type: "models" });
    return;
  }

  if (payload.type === "run_started") {
    appendMessage("system", "Agent 正在思考...");
    return;
  }

  if (payload.type === "text") {
    window._assistantEl = window._assistantEl || appendMessage("assistant", "");
    window._assistantText = (window._assistantText || "") + payload.content;
    window._assistantEl.textContent = window._assistantText;
    return;
  }

  if (payload.type === "thinking") {
    appendMessage("thinking", payload.content);
    return;
  }

  if (payload.type === "tool_call") {
    appendMessage("tool", `[工具] ${payload.name} (${payload.status})`);
    return;
  }

  if (payload.type === "done") {
    window._assistantEl = null;
    window._assistantText = "";
    setSending(false);
    return;
  }

  if (payload.type === "error") {
    appendMessage("system", `错误: ${payload.content}`);
    setSending(false);
  }
}

async function api(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: { ...authHeaders(), ...(options.headers || {}) },
  });
  if (!res.ok) {
    const detail = await res.text();
    throw new Error(detail || `HTTP ${res.status}`);
  }
  return res;
}

function sendMessage(newSession = false) {
  const message = els.messageInput.value.trim();
  if (!message) return;
  if (chatInFlight) return;

  appendMessage("user", message);
  els.messageInput.value = "";
  setSending(true);
  window._assistantEl = null;
  window._assistantText = "";

  // Prefer HTTP SSE for reliability through Cloudflare; WS still used for status.
  sendMessageHttp(message, newSession);
}

async function sendMessageHttp(message, newSession = false) {
  try {
    const res = await api("/api/chat", {
      method: "POST",
      body: JSON.stringify({
        message,
        model: els.modelSelect.value || "composer-2.5",
        new_session: newSession,
      }),
    });

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let finished = false;

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";

      for (const line of lines) {
        if (!line.startsWith("data: ")) continue;
        const payload = JSON.parse(line.slice(6));
        if (payload.type === "done" || payload.type === "error") finished = true;
        handleWsPayload(payload);
      }
    }

    if (!finished) setSending(false);
  } catch (err) {
    appendMessage("system", `发送失败: ${err.message}`);
    setSending(false);
  }
}

function saveConfig() {
  saveSettings();
  const payload = {
    type: "config",
    cursor_api_key: els.cursorKeyInput.value.trim() || undefined,
    workspace: els.workspaceInput.value.trim() || undefined,
    default_model: els.modelSelect.value || undefined,
  };

  if (wsReady && ws && ws.readyState === WebSocket.OPEN) {
    wsSend(payload);
    return;
  }

  api("/api/config", {
    method: "POST",
    body: JSON.stringify({
      cursor_api_key: payload.cursor_api_key,
      workspace: payload.workspace,
      default_model: payload.default_model,
    }),
  })
    .then(() => {
      appendMessage("system", "连接配置已更新");
      refreshStatusHttp();
      loadModelsHttp();
    })
    .catch((err) => appendMessage("system", `配置失败: ${err.message}`));
}

document.querySelectorAll(".copy-btn").forEach((btn) => {
  btn.addEventListener("click", async () => {
    const target = document.getElementById(btn.dataset.copy);
    await navigator.clipboard.writeText(target.textContent);
    btn.textContent = "已复制";
    setTimeout(() => (btn.textContent = "复制"), 1200);
  });
});

els.chatForm.addEventListener("submit", (e) => {
  e.preventDefault();
  sendMessage(false);
});

els.newSessionBtn.addEventListener("click", () => {
  els.messages.innerHTML = "";
  appendMessage("system", "已开始新会话");
  setSending(false);
  const msg = els.messageInput.value.trim();
  if (msg) sendMessage(true);
  else {
    // Reset server-side agent without sending a message
    api("/api/config", {
      method: "POST",
      body: JSON.stringify({ default_model: els.modelSelect.value || "composer-2.5" }),
    }).catch(() => {});
  }
});

els.saveConfigBtn.addEventListener("click", () => {
  try {
    saveConfig();
    appendMessage("system", "配置已保存，正在重新连接...");
  } catch (err) {
    appendMessage("system", `配置失败: ${err.message}`);
  }
});

els.bridgeKeyInput.addEventListener("change", () => {
  saveSettings();
  connectWebSocket();
});

setSending(false);
loadSettings();
connectWebSocket();
refreshStatusHttp();
loadModelsHttp();
setInterval(() => {
  if (wsReady) wsSend({ type: "ping" });
  else refreshStatusHttp();
}, 15000);
