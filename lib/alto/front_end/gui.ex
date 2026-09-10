defmodule Alto.FrontEnd.Gui do
  @moduledoc """
  The built-in single-page GUI served by `Alto.Listeners.WebServer`.

  One static page, no build step and no external assets: it speaks the same
  front-end protocol over a same-origin WebSocket (`GET /ws`), attaching to
  all runs, streaming model deltas and tool activity, answering approval
  requests, and starting or cancelling runs from the browser. The server's
  origin check is what makes serving this page safe.
  """

  @spec html() :: String.t()
  def html do
    ~S"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Alto</title>
    <style>
      :root {
        --bg: #10141a; --panel: #171d26; --panel2: #1d2530; --border: #2a3340;
        --text: #d7dee8; --dim: #7d8b9e; --accent: #4da3ff; --ok: #3ecf8e;
        --err: #ff6b6b; --warn: #f0b429;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0; background: var(--bg); color: var(--text);
        font: 14px/1.5 ui-sans-serif, system-ui, "Segoe UI", sans-serif;
        height: 100vh; display: flex; flex-direction: column;
      }
      header {
        display: flex; align-items: center; gap: 12px; padding: 10px 16px;
        background: var(--panel); border-bottom: 1px solid var(--border);
      }
      header h1 { font-size: 16px; margin: 0; letter-spacing: 1px; }
      #status { font-size: 12px; color: var(--dim); }
      #status .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%;
        background: var(--err); margin-right: 6px; vertical-align: middle; }
      #status.on .dot { background: var(--ok); }
      #topbar { margin-left: auto; display: flex; gap: 8px; align-items: center; }
      input, textarea, button, select {
        background: var(--panel2); color: var(--text); border: 1px solid var(--border);
        border-radius: 6px; padding: 7px 10px; font: inherit;
      }
      button { cursor: pointer; }
      button:hover { border-color: var(--accent); }
      button.primary { background: var(--accent); border-color: var(--accent); color: #0b1119; font-weight: 600; }
      button.danger { background: transparent; border-color: var(--err); color: var(--err); }
      button:disabled { opacity: 0.5; cursor: default; }
      #runs { flex: 1; overflow-y: auto; padding: 16px; display: flex; flex-direction: column; gap: 16px; }
      .run { background: var(--panel); border: 1px solid var(--border); border-radius: 10px;
        display: flex; flex-direction: column; min-height: 120px; }
      .run > .head { display: flex; align-items: center; gap: 10px; padding: 8px 14px;
        border-bottom: 1px solid var(--border); font-size: 12px; color: var(--dim); }
      .run > .head .id { font-family: ui-monospace, monospace; color: var(--text); }
      .run > .stream { flex: 1; overflow-y: auto; padding: 12px 14px; display: flex;
        flex-direction: column; gap: 8px; max-height: 60vh; }
      .bubble { white-space: pre-wrap; word-break: break-word; }
      .assistant { background: var(--panel2); border-radius: 8px; padding: 8px 12px; }
      .marker { color: var(--dim); font-size: 12px; }
      .tool { font-size: 12px; background: var(--panel2); border: 1px solid var(--border);
        border-radius: 6px; padding: 4px 10px; align-self: flex-start; }
      .tool.failed { border-color: var(--err); color: var(--err); }
      .tool details { margin-top: 4px; }
      .tool pre { max-width: 70vw; overflow-x: auto; font-size: 11px; color: var(--dim); margin: 4px 0 0; }
      .approval { border: 1px solid var(--warn); border-radius: 8px; padding: 10px 12px; }
      .approval.resolved { border-color: var(--border); opacity: 0.75; }
      .approval h3 { margin: 0 0 6px; font-size: 13px; color: var(--warn); }
      .approval.resolved h3 { color: var(--dim); }
      .approval pre { background: var(--bg); border-radius: 6px; padding: 8px;
        font-size: 11px; overflow-x: auto; max-width: 70vw; }
      .approval .actions { display: flex; gap: 8px; margin-top: 8px; }
      .result { border-radius: 8px; padding: 8px 12px; font-weight: 600; }
      .result.ok { background: rgba(62,207,142,0.12); color: var(--ok); }
      .result.bad { background: rgba(255,107,107,0.12); color: var(--err); }
      footer { display: flex; gap: 8px; padding: 12px 16px; background: var(--panel);
        border-top: 1px solid var(--border); }
      #task { flex: 1; resize: none; height: 44px; }
      #config { width: 160px; }
    </style>
    </head>
    <body>
      <header>
        <h1>ALTO</h1>
        <span id="status"><span class="dot"></span>connecting…</span>
        <div id="topbar">
          <input id="config" value="default" title="Server-side configuration name">
          <button id="cancel" class="danger" disabled>Cancel run</button>
        </div>
      </header>
      <div id="runs"></div>
      <footer>
        <textarea id="task" placeholder="Describe the task… (Ctrl+Enter to start)"></textarea>
        <button id="start" class="primary">Start run</button>
      </footer>
      <script>
      "use strict";
      const $ = (id) => document.getElementById(id);
      const runsPane = $("runs");
      let ws = null, nextCommandId = 1, activeRunId = null, runSeq = 0;
      const pending = new Map(); // command id -> resolver

      function setStatus(on, text) {
        $("status").className = on ? "on" : "";
        $("status").innerHTML = '<span class="dot"></span>' + text;
      }

      function send(obj) {
        obj.v = 1;
        obj.id = "gui-" + nextCommandId++;
        const promise = new Promise((resolve) => pending.set(obj.id, resolve));
        ws.send(JSON.stringify(obj));
        return promise;
      }

      function esc(text) { return text; } // rendering uses textContent only

      function runPane(runId) {
        let pane = document.getElementById("run-" + runId);
        if (pane) return pane;
        pane = document.createElement("section");
        pane.className = "run";
        pane.id = "run-" + runId;
        const head = document.createElement("div");
        head.className = "head";
        head.textContent = "run ";
        const idSpan = document.createElement("span");
        idSpan.className = "id";
        idSpan.textContent = runId;
        head.appendChild(idSpan);
        pane.appendChild(head);
        const stream = document.createElement("div");
        stream.className = "stream";
        pane.appendChild(stream);
        runsPane.appendChild(pane);
        pane.scrollIntoView({ block: "nearest" });
        return pane;
      }

      function streamOf(runId) { return runPane(runId).querySelector(".stream"); }

      function appendText(runId, text) {
        const stream = streamOf(runId);
        let bubble = stream.lastElementChild;
        if (!bubble || bubble.className !== "bubble assistant") {
          bubble = document.createElement("div");
          bubble.className = "bubble assistant";
          stream.appendChild(bubble);
        }
        bubble.textContent += text;
        stream.scrollIntoView({ block: "end" });
      }

      function marker(runId, text) {
        const el = document.createElement("div");
        el.className = "marker";
        el.textContent = text;
        streamOf(runId).appendChild(el);
      }

      function pretty(value) {
        try { return JSON.stringify(value, null, 2); }
        catch (e) { return String(value); }
      }

      function toolChip(runId, callId, name, failed, detail) {
        const chip = document.createElement("details");
        chip.className = "tool" + (failed ? " failed" : "");
        chip.dataset.callId = callId || "";
        const summary = document.createElement("summary");
        summary.textContent = (failed ? "✗ " : "· ") + name + (callId ? " (" + callId + ")" : "");
        chip.appendChild(summary);
        if (detail != null) {
          const pre = document.createElement("pre");
          pre.textContent = detail;
          chip.appendChild(pre);
        }
        streamOf(runId).appendChild(chip);
        streamOf(runId).scrollIntoView({ block: "end" });
        return chip;
      }

      function approvalCard(runId, request) {
        const card = document.createElement("div");
        card.className = "approval";
        card.id = "approval-" + runId + "-" + (request.id || "");
        const title = document.createElement("h3");
        title.textContent = "Approval required: " + request.tool;
        card.appendChild(title);
        const pre = document.createElement("pre");
        pre.textContent = pretty({ arguments: request.arguments, details: request.details });
        card.appendChild(pre);
        const actions = document.createElement("div");
        actions.className = "actions";
        const approve = document.createElement("button");
        approve.className = "primary";
        approve.textContent = "Approve";
        approve.onclick = () => decide(request.id, "approve");
        const deny = document.createElement("button");
        deny.className = "danger";
        deny.textContent = "Deny";
        deny.onclick = () => {
          const reason = prompt("Deny reason:", "user denied");
          decide(request.id, { deny: reason || "user denied" });
        };
        actions.appendChild(approve);
        actions.appendChild(deny);
        card.appendChild(actions);
        streamOf(runId).appendChild(card);
        streamOf(runId).scrollIntoView({ block: "end" });
      }

      function resolveCard(runId, requestId, state) {
        const card = document.getElementById("approval-" + runId + "-" + (requestId || ""));
        if (card) {
          card.className = "approval resolved";
          const buttons = card.querySelectorAll("button");
          buttons.forEach((b) => (b.disabled = true));
          const head = card.querySelector("h3");
          head.textContent = "Approval " + state + ": " + requestId;
        }
      }

      async function decide(requestId, decision) {
        await send({ type: "approval_response", request_id: requestId, decision });
      }

      function resultBanner(runId, envelope) {
        const el = document.createElement("div");
        const ok = envelope.outcome === "ok";
        el.className = "result " + (ok ? "ok" : "bad");
        el.textContent = ok
          ? "Done (" + envelope.model_requests + " model requests): " + (envelope.output ?? "")
          : (envelope.outcome === "cancelled" ? "Cancelled: " : "Failed: ") +
            (envelope.reason ?? "");
        streamOf(runId).appendChild(el);
        streamOf(runId).scrollIntoView({ block: "end" });
        if (runId === activeRunId) setActiveRun(null);
      }

      function handleNotification(n) {
        if (n.type === "attached") {
          n.events.forEach((e) => handleEvent(e.run_id ?? "", e.seq, { type: e.event.type, data: e.event.data }));
          return;
        }
        if (n.type === "overflow") {
          marker(n.run_id, "— overflow (" + n.domain + "); some output was dropped —");
          return;
        }
        if (n.type === "approval_request") {
          approvalCard(n.run_id, n.request);
          return;
        }
        if (n.type === "approval_resolved") {
          const state = n.decision === "approved" ? "approved"
            : Array.isArray(n.decision?.$tuple) ? n.decision.$tuple[0]
            : "resolved";
          resolveCard(n.run_id, n.request && n.request.id, state);
          return;
        }
        if (n.type === "result") {
          resultBanner(n.run_id, n);
          return;
        }
        if (n.type === "event") {
          handleEvent(n.run_id, n.seq, n.event);
        }
      }

      function handleEvent(runId, seq, event) {
        switch (event.type) {
          case "model_started":
            marker(runId, "— model request " + (event.data && event.data.step) + " —");
            break;
          case "model_delta":
            appendText(runId, event.data.text);
            break;
          case "tool_started":
            toolChip(runId, event.data.call_id, event.data.name, false, null);
            break;
          case "tool_completed":
            {
              const chip = findChip(runId, event.data.call_id);
              if (chip) {
                const pre = document.createElement("pre");
                pre.textContent = event.data.output ?? "";
                chip.appendChild(pre);
              } else {
                toolChip(runId, event.data.call_id, event.data.name, false, event.data.output);
              }
            }
            break;
          case "tool_failed":
            {
              const chip = findChip(runId, event.data.call_id);
              const detail = pretty(event.data.error);
              if (chip) {
                chip.className = "tool failed";
                const pre = document.createElement("pre");
                pre.textContent = detail;
                chip.appendChild(pre);
              } else {
                toolChip(runId, event.data.call_id, event.data.name, true, detail);
              }
            }
            break;
          case "run_cancelled":
            marker(runId, "— run cancelled —");
            if (runId === activeRunId) setActiveRun(null);
            break;
          default:
            if (seq != null) marker(runId, "— " + event.type + " —");
        }
      }

      function findChip(runId, callId) {
        if (!callId) return null;
        return streamOf(runId).querySelector('.tool[data-call-id="' + CSS.escape(callId) + '"]');
      }

      function setActiveRun(runId) {
        activeRunId = runId;
        $("cancel").disabled = runId == null;
      }

      async function startRun() {
        const task = $("task").value.trim();
        if (!task) return;
        const reply = await send({ type: "start_run", config: $("config").value.trim() || "default", task });
        if (reply.type === "ok") {
          setActiveRun(reply.run_id);
          $("task").value = "";
        } else {
          marker("local", "could not start run: " + JSON.stringify(reply.detail ?? reply.code));
        }
      }

      function wire() {
        $("start").onclick = startRun;
        $("task").addEventListener("keydown", (e) => {
          if ((e.ctrlKey || e.metaKey) && e.key === "Enter") startRun();
        });
        $("cancel").onclick = async () => {
          if (activeRunId) await send({ type: "cancel", run_id: activeRunId, reason: "user" });
        };
      }

      function connect() {
        const proto = location.protocol === "https:" ? "wss://" : "ws://";
        ws = new WebSocket(proto + location.host + "/ws");
        ws.onopen = () => {
          setStatus(true, "connected");
          ws.send(JSON.stringify({ v: 1, type: "attach", id: "gui-attach" }));
        };
        ws.onmessage = (m) => {
          const envelope = JSON.parse(m.data);
          const resolver = pending.get(envelope.id);
          if (resolver) { pending.delete(envelope.id); resolver(envelope); }
          handleNotification(envelope);
        };
        ws.onclose = () => {
          setStatus(false, "disconnected — retrying");
          setActiveRun(null);
          setTimeout(connect, 1500);
        };
        ws.onerror = () => ws.close();
      }

      wire();
      connect();
      </script>
    </body>
    </html>
    """
  end
end
