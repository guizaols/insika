// Insika web widget.
//
// One <script> tag, no framework, no build step, no dependency:
//
//   <script src="https://agents.example.com/channels/web/asset/widget.js"
//           data-agent="support" data-title="Ask us anything" defer></script>
//
// Everything it needs it reads off its own tag: the agent, the chrome text, and
// the engine's base URL (derived from this file's own src, so an adopter never
// configures a host twice). Theming is a block of CSS custom properties — set
// them on :root and they win, because they are declared on the widget root with
// var(..., fallback).
//
// The one design decision worth stating: a message POST is NEVER retried. It is
// the request that runs a turn, so re-sending it costs a second LLM call and can
// put a second answer in front of the customer. A dropped stream shows what
// arrived plus a failure note, and the person decides whether to ask again. The
// backoff below is for minting a session — the only call here that is safe to
// repeat.
(function () {
  "use strict";

  var script = document.currentScript;
  if (!script) return;

  var base = new URL(script.src, window.location.href).href.replace(/\/channels\/[^/]+\/asset\/[^/]*$/, "");
  var channel = (script.src.match(/\/channels\/([^/]+)\/asset\//) || [])[1] || "web";
  var agent = script.dataset.agent || "";
  var title = script.dataset.title || "Chat";
  var placeholder = script.dataset.placeholder || "Type a message…";
  var greeting = script.dataset.greeting || "";
  var storageKey = "insika:" + channel + ":" + agent + ":session";

  if (!agent) {
    console.error("[insika] the widget needs data-agent on its <script> tag");
    return;
  }

  // --- chrome ---------------------------------------------------------

  var CSS = [
    ".insika-w{position:fixed;right:var(--insika-offset,20px);bottom:var(--insika-offset,20px);z-index:2147483000;",
    "font-family:var(--insika-font,system-ui,-apple-system,Segoe UI,Roboto,sans-serif);font-size:15px;line-height:1.5}",
    ".insika-b{width:56px;height:56px;border-radius:50%;border:0;cursor:pointer;display:block;margin-left:auto;",
    "background:var(--insika-accent,#1f2937);color:var(--insika-on-accent,#fff);font-size:24px;",
    "box-shadow:0 6px 24px rgba(0,0,0,.22)}",
    ".insika-p{display:none;flex-direction:column;width:min(380px,calc(100vw - 40px));height:min(560px,calc(100vh - 120px));",
    "margin-bottom:12px;border-radius:14px;overflow:hidden;background:var(--insika-bg,#fff);color:var(--insika-fg,#111827);",
    "border:1px solid var(--insika-border,rgba(0,0,0,.12));box-shadow:0 12px 48px rgba(0,0,0,.24)}",
    ".insika-w.open .insika-p{display:flex}",
    ".insika-h{padding:12px 14px;font-weight:600;background:var(--insika-accent,#1f2937);color:var(--insika-on-accent,#fff);",
    "display:flex;align-items:center;justify-content:space-between}",
    ".insika-x{background:none;border:0;color:inherit;font-size:20px;cursor:pointer;line-height:1;padding:0 2px}",
    ".insika-log{flex:1;overflow-y:auto;padding:14px;display:flex;flex-direction:column;gap:10px}",
    ".insika-m{max-width:85%;padding:9px 12px;border-radius:12px;white-space:pre-wrap;overflow-wrap:anywhere}",
    ".insika-m.user{align-self:flex-end;background:var(--insika-accent,#1f2937);color:var(--insika-on-accent,#fff)}",
    ".insika-m.agent{align-self:flex-start;background:var(--insika-muted,#f3f4f6);color:var(--insika-fg,#111827)}",
    ".insika-m.note{align-self:center;font-size:13px;opacity:.7;background:none;padding:2px}",
    ".insika-f{display:flex;gap:8px;padding:10px;border-top:1px solid var(--insika-border,rgba(0,0,0,.12))}",
    ".insika-f input{flex:1;min-width:0;padding:9px 11px;border-radius:9px;font:inherit;color:inherit;background:transparent;",
    "border:1px solid var(--insika-border,rgba(0,0,0,.18))}",
    ".insika-f button{padding:9px 14px;border:0;border-radius:9px;cursor:pointer;font:inherit;",
    "background:var(--insika-accent,#1f2937);color:var(--insika-on-accent,#fff)}",
    ".insika-f button[disabled]{opacity:.5;cursor:default}"
  ].join("");

  var style = document.createElement("style");
  style.textContent = CSS;
  document.head.appendChild(style);

  var root = el("div", "insika-w");
  var panel = el("div", "insika-p");
  var header = el("div", "insika-h");
  var log = el("div", "insika-log");
  var form = document.createElement("form");
  var input = document.createElement("input");
  var send = document.createElement("button");
  var bubble = el("button", "insika-b");

  header.appendChild(text("span", title));
  var close = el("button", "insika-x");
  close.type = "button";
  close.textContent = "×";
  close.setAttribute("aria-label", "Close");
  header.appendChild(close);

  form.className = "insika-f";
  input.type = "text";
  input.placeholder = placeholder;
  input.setAttribute("aria-label", placeholder);
  send.type = "submit";
  send.textContent = "Send";
  form.appendChild(input);
  form.appendChild(send);

  panel.appendChild(header);
  panel.appendChild(log);
  panel.appendChild(form);

  bubble.type = "button";
  bubble.textContent = "💬";
  bubble.setAttribute("aria-label", title);

  root.appendChild(panel);
  root.appendChild(bubble);
  document.body.appendChild(root);

  if (greeting) say("agent", greeting);

  bubble.addEventListener("click", toggle);
  close.addEventListener("click", toggle);
  form.addEventListener("submit", function (e) {
    e.preventDefault();
    var value = input.value.trim();
    if (!value || busy) return;
    input.value = "";
    ask(value);
  });

  function toggle() {
    root.classList.toggle("open");
    if (root.classList.contains("open")) input.focus();
  }

  // --- the turn -------------------------------------------------------

  var busy = false;

  function ask(message) {
    busy = true;
    send.disabled = true;
    say("user", message);

    var bubbleEl = null;
    var note = null;

    session()
      .then(function (id) {
        return fetch(base + "/channels/" + channel + "/messages", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ agent: agent, session_id: id, message: message })
        });
      })
      .then(function (res) {
        // An unknown session id (the store was wiped, the id expired) is the one
        // recoverable failure: drop ours and let the next message mint a new one.
        if (res.status === 404) {
          forget();
          throw new Error("session expired — please send that again");
        }
        if (!res.ok || !res.body) throw new Error("the assistant is unavailable right now");
        return read(res.body.getReader(), function (event, data) {
          if (event === "delta" && data.delta) {
            if (note) { note.remove(); note = null; }
            if (!bubbleEl) bubbleEl = say("agent", "");
            bubbleEl.textContent += data.delta;
            log.scrollTop = log.scrollHeight;
          } else if (event === "working" && !bubbleEl && !note) {
            note = say("note", "working…");
          } else if (event === "error") {
            if (note) { note.remove(); note = null; }
            throw new Error(data.message || "something went wrong");
          }
        });
      })
      .catch(function (err) {
        if (note) note.remove();
        say("note", err.message || "something went wrong");
      })
      .finally(function () {
        busy = false;
        send.disabled = false;
        input.focus();
      });
  }

  // The engine issues the session id; we only ever store the one it gave us
  // (a client that proposes its own id on a public endpoint is
  // one enumeration away from reading someone else's conversation).
  function session() {
    var saved = remembered;
    if (saved) return Promise.resolve(saved);

    return mint(0).then(function (id) {
      remember(id);
      return id;
    });
  }

  // localStorage THROWS (not returns null) in a sandboxed iframe, in Safari's
  // private mode and wherever site data is blocked. Reading it unguarded would
  // throw out of `ask` before the .catch is attached, leaving the send button
  // disabled forever. So the conversation degrades to in-memory instead: it lives
  // for the page, which is worse than remembering and much better than frozen.
  var remembered = read_storage();

  function read_storage() {
    try { return localStorage.getItem(storageKey); } catch (e) { return null; }
  }

  function remember(id) {
    remembered = id;
    try { localStorage.setItem(storageKey, id); } catch (e) { /* in-memory only */ }
  }

  function forget() {
    remembered = null;
    try { localStorage.removeItem(storageKey); } catch (e) { /* in-memory only */ }
  }

  // 1s → 30s backoff, one attempt in flight, the same discipline the Studio's
  // live transcript uses. Safe to repeat because minting has no side effect the
  // customer can see: the worst case is an unused empty session.
  function mint(attempt) {
    return fetch(base + "/channels/" + channel + "/sessions", { method: "POST" })
      .then(function (res) {
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json();
      })
      .then(function (body) {
        if (!body.session_id) throw new Error("no session id");
        return body.session_id;
      })
      .catch(function (err) {
        if (attempt >= 4) throw new Error("cannot reach the assistant right now");
        var wait = Math.min(30000, 1000 * Math.pow(2, attempt));
        return delay(wait).then(function () { return mint(attempt + 1); });
      });
  }

  // Minimal SSE reader over fetch — EventSource cannot POST, and the turn is a
  // POST. Frames are `event: <name>\ndata: <json>\n\n`; anything else is skipped,
  // so a frame added later cannot break an old widget.
  function read(reader, onEvent) {
    var decoder = new TextDecoder();
    var buffer = "";

    return reader.read().then(function step(chunk) {
      if (chunk.done) return;
      buffer += decoder.decode(chunk.value, { stream: true });

      var parts = buffer.split("\n\n");
      buffer = parts.pop();
      parts.forEach(function (frame) {
        var name = (frame.match(/^event: (.+)$/m) || [])[1];
        var raw = (frame.match(/^data: (.*)$/m) || [])[1];
        if (!name) return;
        var data = {};
        try { data = raw ? JSON.parse(raw) : {}; } catch (e) { return; }
        onEvent(name, data);
      });

      return reader.read().then(step);
    });
  }

  // --- helpers --------------------------------------------------------

  function say(kind, content) {
    var node = el("div", "insika-m " + kind);
    node.textContent = content;
    log.appendChild(node);
    log.scrollTop = log.scrollHeight;
    return node;
  }

  function el(tag, className) {
    var node = document.createElement(tag);
    node.className = className;
    return node;
  }

  function text(tag, content) {
    var node = document.createElement(tag);
    node.textContent = content;
    return node;
  }

  function delay(ms) {
    return new Promise(function (resolve) { setTimeout(resolve, ms); });
  }
})();
