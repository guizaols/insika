import { Controller } from "@hotwired/stimulus"
import { renderMarkdown } from "../markdown.js"

// live-transcript (island) — subscribes to the SSE stream from /studio/events (same
// origin; EventSource cannot send a Bearer, so the stream rides the Studio's session
// cookie instead of the machine-facing /v1) and renders the turn live: text
// deltas become an assistant bubble (rendered as Markdown);
// tool_call/tool_result/skill become collapsible tool-cards. Reuses the
// event protocol already proven in /admin (#24), packaged as a Stimulus controller
// (strict CSP 'self' — no inline <script>).
//
// Curation: bookkeeping events get no bubble. The success terminal
// (:task_completed) is NOT ignored — it just becomes the status pill (below).
const IGNORED = new Set(["task_started", "checkpoint_created"])

// Ceiling for the SSE reconnect backoff: 1s→2s→…→30s, then steady.
const RECONNECT_MAX = 30000

export default class extends Controller {
  static targets = ["stream", "empty", "status"]
  static values = { session: String, task: String }

  connect() {
    this.current = null      // streaming assistant bubble's .content node (or null)
    this.currentBubble = null // its .bubble wrapper (draft ⇄ answer styling)
    this.currentTag = null    // its .role-tag node
    this.currentStamp = null  // the <time> node, re-appended when the tag is relabelled
    this.currentText = ""    // accumulated Markdown source for that bubble
    this.thinkingPre = null  // open thinking card's <pre> node (or null)
    this.raf = null
    this.backoff = 1000      // reconnect delay, doubles per attempt up to RECONNECT_MAX
    this.reconnectTimer = null
    if (this.sessionValue || this.taskValue) this.open()
  }

  disconnect() {
    this.close()
    if (this.raf) { cancelAnimationFrame(this.raf); this.raf = null }
  }

  open() {
    this.close()
    const params = new URLSearchParams()
    if (this.taskValue) params.set("task_id", this.taskValue)
    if (this.sessionValue) params.set("session_id", this.sessionValue)
    const url = "/studio/events" + (params.toString() ? "?" + params.toString() : "")

    this.setStatus("connecting…", "warn")
    this.es = new EventSource(url)
    this.es.onopen = () => { this.backoff = 1000; this.setStatus("connected", "ok") }
    this.es.onerror = () => this.onError()
    this.es.onmessage = (e) => {
      try { this.render(JSON.parse(e.data)) } catch (_) { this.push(this.chipText(e.data)) }
    }
  }

  // SSE error handling. EventSource retries on its own ONLY while the
  // socket is still CONNECTING; once the browser gives up (readyState === CLOSED)
  // it never reconnects. So we let the browser own the transient case and step in
  // with a capped exponential backoff (1s→30s) once it has closed for good.
  onError() {
    if (this.es && this.es.readyState === EventSource.CONNECTING) {
      this.setStatus("reconnecting…", "warn")
      return
    }
    this.setStatus("disconnected — retrying…", "err")
    this.scheduleReconnect()
  }

  scheduleReconnect() {
    if (this.reconnectTimer) return   // one pending attempt at a time
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null
      this.open()
    }, this.backoff)
    this.backoff = Math.min(this.backoff * 2, RECONNECT_MAX)
  }

  close() {
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null }
    if (this.es) { this.es.close(); this.es = null }
  }

  setStatus(text, cls) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.className = "pill " + cls
  }

  el(tag, cls, text) {
    const e = document.createElement(tag)
    if (cls) e.className = cls
    if (text != null) e.textContent = text
    return e
  }

  // A <pre> payload wrapped with a copy-to-clipboard affordance. The
  // wrapper declares the `clipboard` controller so Stimulus wires the button on
  // insertion — CSP-safe, no inline handlers. Same markup contract the server
  // uses for the trace <pre> blocks in session.erb.
  pre(obj) {
    const text = typeof obj === "string" ? obj : JSON.stringify(obj, null, 2)
    const p = this.el("pre")
    p.textContent = text

    const wrap = this.el("div", "copywrap")
    wrap.setAttribute("data-controller", "clipboard")
    wrap.setAttribute("data-clipboard-text-value", text)
    const btn = this.el("button", "copy-btn", "copy")
    btn.type = "button"
    btn.setAttribute("data-clipboard-target", "button")
    btn.setAttribute("data-action", "clipboard#copy")
    wrap.appendChild(btn)
    wrap.appendChild(p)
    return wrap
  }

  push(node) {
    if (this.hasEmptyTarget) this.emptyTarget.hidden = true
    this.streamTarget.appendChild(node)
    node.scrollIntoView({ block: "end" })
  }

  // "HH:MM" <time> node from an ISO8601 stamp (ev.meta.at). null = absent/invalid.
  time(iso) {
    if (!iso) return null
    const d = new Date(iso)
    if (isNaN(d.getTime())) return null
    const t = this.el("time", "stamp", d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }))
    t.setAttribute("datetime", iso)
    return t
  }

  // One-line "(args…)" for a collapsed tool-call summary; body keeps the full JSON.
  argsPreview(args) {
    if (args == null) return "(…)"
    let s
    try { s = typeof args === "string" ? args : JSON.stringify(args) } catch (_) { s = String(args) }
    s = s.replace(/\s+/g, " ").trim()
    return "(" + (s.length > 60 ? s.slice(0, 60) + "…" : s) + ")"
  }

  // Collapsible tool card: <details> with a summary (arrow + title + optional
  // ok/err badge) and the raw payload in a <pre> body.
  toolcard(kind, arrow, title, body, badge) {
    const c = this.el("details", "toolcard " + kind)
    const s = document.createElement("summary")
    s.appendChild(this.el("span", "arrow", arrow))
    s.appendChild(this.el("strong", null, title))
    if (badge) s.appendChild(this.el("span", "badge " + badge.cls, badge.text))
    c.appendChild(s)
    if (body != null) c.appendChild(this.pre(body))
    return c
  }

  chip(ev) {
    const c = this.el("div", "toolcard muted-card")
    const h = this.el("div", "h")
    h.appendChild(this.el("strong", null, ev.type))
    const meta = ev.meta || {}
    const tag = meta.task_id || meta.session_id
    if (tag) h.appendChild(this.el("span", "muted", " · " + tag))
    c.appendChild(h)
    return c
  }

  chipText(text) {
    const c = this.el("div", "toolcard muted-card")
    c.appendChild(this.el("div", "h", text))
    return c
  }

  // Opens the assistant bubble if none is streaming, and sets whether it is a draft
  // (:intermediate — dashed and dimmed, labelled so nobody reads it as delivered) or
  // the answer (:content). One bubble serves both: the answer's text arrives as the
  // same deltas that drafted it, so :content promotes what is already on screen.
  appendDelta(ev, draft) {
    if (!this.current) {
      const msg = this.el("div", "msg assistant")
      msg.appendChild(this.el("div", "who", "A"))
      const b = this.el("div", "bubble")
      this.currentTag = this.el("div", "role-tag")
      const stamp = this.time(ev.meta && ev.meta.at)
      b.appendChild(this.currentTag)
      this.current = this.el("div", "content md")
      b.appendChild(this.current)
      msg.appendChild(b)
      this.currentBubble = b
      this.currentStamp = stamp
      this.currentText = ""
      this.push(msg)
    }
    this.currentBubble.classList.toggle("draft", draft)
    this.currentTag.textContent = draft ? "intermediate · not sent" : "assistant"
    if (this.currentStamp) {
      this.currentTag.appendChild(document.createTextNode(" · "))
      this.currentTag.appendChild(this.currentStamp)
    }
  }

  // Re-render the streaming bubble as Markdown, throttled to one paint per frame.
  scheduleMarkdown() {
    if (this.raf) return
    this.raf = requestAnimationFrame(() => {
      this.raf = null
      if (this.current) this.current.innerHTML = renderMarkdown(this.currentText)
    })
  }

  // Finalize the open assistant bubble (flush pending Markdown) and detach the
  // cursor so the next content/tool event starts fresh.
  finishBubble() {
    if (this.raf) { cancelAnimationFrame(this.raf); this.raf = null }
    if (this.current) this.current.innerHTML = renderMarkdown(this.currentText)
    this.current = null
    this.currentBubble = null
    this.currentTag = null
    this.currentStamp = null
    this.currentText = ""
  }

  // The provider's reasoning (:thinking deltas). ONE collapsed card per run of
  // consecutive deltas — a card per delta would be unreadable — closed by default:
  // it's the deliberation, not the answer. The card is the whole point of the event
  // (it never reaches the customer through /v1/responses), so the operator can open
  // it and see why the turn searched what it searched.
  appendThinking(delta) {
    if (!this.thinkingPre) {
      this.finishBubble()
      const card = this.el("details", "toolcard thinking")
      const s = document.createElement("summary")
      s.appendChild(this.el("span", "arrow", "…"))
      s.appendChild(this.el("strong", null, "thinking"))
      card.appendChild(s)
      this.thinkingPre = this.el("pre")
      card.appendChild(this.thinkingPre)
      this.push(card)
    }
    this.thinkingPre.textContent += delta
  }

  // Detach the thinking cursor so the next run of deltas opens a fresh card.
  finishThinking() {
    this.thinkingPre = null
  }

  // Compact "1.2k in · 340 out · model" chip from the terminal event's usage
  // usage is the shape produced by Executor#usage_of: input_tokens,
  // output_tokens, optional cached_tokens, model. Renders nothing when the
  // provider reported no counts (usage nil — e.g. workflow turns, FakeChat).
  renderUsage(usage) {
    if (!usage) return
    const parts = []
    if (usage.input_tokens != null) parts.push(`${this.fmtTokens(usage.input_tokens)} in`)
    if (usage.output_tokens != null) parts.push(`${this.fmtTokens(usage.output_tokens)} out`)
    if (usage.cached_tokens) parts.push(`${this.fmtTokens(usage.cached_tokens)} cached`)
    if (usage.model) parts.push(usage.model)
    if (!parts.length) return
    this.push(this.el("div", "usage-chip", parts.join(" · ")))
  }

  // 1234 -> "1.2k", 980 -> "980". Keeps the chip short for large token counts.
  fmtTokens(n) {
    const v = Number(n) || 0
    return v >= 1000 ? `${(v / 1000).toFixed(1).replace(/\.0$/, "")}k` : String(v)
  }

  render(ev) {
    if (IGNORED.has(ev.type)) return
    if (ev.type !== "thinking") this.finishThinking()

    switch (ev.type) {
      case "thinking":
        this.appendThinking(ev.delta || "")
        break
      case "intermediate":
        // Live text that is NOT yet the answer: the model narrating the tool loop,
        // or reasoning in prose. The customer never receives it (/v1/responses drops
        // the frame) — the operator does, which is the whole point of the event.
        this.appendDelta(ev, true)
        this.currentText += ev.delta || ""
        this.scheduleMarkdown()
        break
      case "content":
        // The answer, published whole when its message ended. It arrives right after
        // its own :intermediate deltas, so promote that bubble in place (replace, do
        // not append) instead of printing the same text twice.
        this.appendDelta(ev, false)
        this.currentText = ev.delta || ""
        this.scheduleMarkdown()
        break
      case "tool_call":
        this.finishBubble()
        this.push(this.toolcard("", "→", (ev.name || "tool") + this.argsPreview(ev.arguments), ev.arguments))
        break
      case "tool_result": {
        const ok = !(ev.result && typeof ev.result === "object" && "error" in ev.result)
        this.push(this.toolcard("result", "←", ev.name || "tool", ev.result,
          { cls: ok ? "ok" : "err", text: ok ? "ok" : "error" }))
        break
      }
      // Two activation paths, and the card must not claim the wrong one. The TOOL
      // path carries a singular `name` (the model called load_skill). The CONTEXT
      // path carries `names` + `mode` (a provider injected the bodies, no call
      // happened) — rendering that as `load_skill(...)` would invent a tool call.
      case "skill_activated":
        this.finishBubble()
        if (Array.isArray(ev.names)) {
          this.push(this.toolcard("skill", "↑",
            `skills · ${ev.mode || "context"} (${ev.names.length})`, ev.names.join("\n")))
        } else {
          this.push(this.toolcard("skill", "↑", "load_skill(" + (ev.name || "") + ")", null))
        }
        break
      case "guardrail_blocked":
        // input short-circuited with a safe reply (the assistant bubble
        // follows via :content). Distinct card — audit at a glance.
        this.finishBubble()
        this.push(this.toolcard("guardrail", "⛔", "guardrail blocked · " + (ev.category || "?"),
          [ev.source, ev.action, ev.detail].filter(Boolean).join(" · ") || null))
        break
      case "guardrail_flagged":
        this.finishBubble()
        this.push(this.toolcard("guardrail", "⚑", "guardrail flagged · " + (ev.category || "?"),
          [ev.source, ev.detail].filter(Boolean).join(" · ") || null))
        break
      case "task_completed":
        // Success terminal: finalize the bubble, then a compact tokens/model
        // chip. The bubble already IS the outcome; the chip is the cost.
        this.finishBubble()
        this.renderUsage(ev.usage)
        this.setStatus("turn finished", "info")
        break
      case "task_failed":
      case "task_cancelled":
        this.finishBubble()
        this.push(this.chip(ev))
        this.setStatus("turn finished", "info")
        break
      default:
        this.finishBubble()
        this.push(this.chip(ev))
    }
  }
}
