import { Controller } from "@hotwired/stimulus"
import { renderMarkdown } from "../markdown.js"

// live-transcript (island D9) — subscribes to the SSE stream from /v1/events (same
// origin, no auth header: it's the consumer API) and renders the turn live: text
// deltas become an assistant bubble (rendered as Markdown, §11 A1);
// tool_call/tool_result/skill become collapsible tool-cards (§11 A2). Reuses the
// event protocol already proven in /admin (#24), packaged as a Stimulus controller
// (strict CSP 'self' — no inline <script>).
//
// Curation (§11 A1): bookkeeping events get no bubble. The success terminal
// (:task_completed) is NOT ignored — it just becomes the status pill (below).
const IGNORED = new Set(["task_started", "checkpoint_created"])

// Ceiling for the SSE reconnect backoff (§12 A3): 1s→2s→…→30s, then steady.
const RECONNECT_MAX = 30000

export default class extends Controller {
  static targets = ["stream", "empty", "status"]
  static values = { session: String, task: String }

  connect() {
    this.current = null      // streaming assistant bubble's .content node (or null)
    this.currentText = ""    // accumulated Markdown source for that bubble
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
    const url = "/v1/events" + (params.toString() ? "?" + params.toString() : "")

    this.setStatus("connecting…", "warn")
    this.es = new EventSource(url)
    this.es.onopen = () => { this.backoff = 1000; this.setStatus("connected", "ok") }
    this.es.onerror = () => this.onError()
    this.es.onmessage = (e) => {
      try { this.render(JSON.parse(e.data)) } catch (_) { this.push(this.chipText(e.data)) }
    }
  }

  // SSE error handling (§12 A3). EventSource retries on its own ONLY while the
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

  // A <pre> payload wrapped with a copy-to-clipboard affordance (§12 A4). The
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
    this.currentText = ""
  }

  // Compact "1.2k in · 340 out · model" chip from the terminal event's usage
  // (§11 A5). usage is the shape produced by Executor#usage_of: input_tokens,
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

    switch (ev.type) {
      case "content": {
        if (!this.current) {
          const msg = this.el("div", "msg assistant")
          msg.appendChild(this.el("div", "who", "A"))
          const b = this.el("div", "bubble")
          const tag = this.el("div", "role-tag", "assistant")
          const stamp = this.time(ev.meta && ev.meta.at)
          if (stamp) { tag.appendChild(document.createTextNode(" · ")); tag.appendChild(stamp) }
          b.appendChild(tag)
          this.current = this.el("div", "content md")
          b.appendChild(this.current)
          msg.appendChild(b)
          this.currentText = ""
          this.push(msg)
        }
        this.currentText += ev.delta || ""
        this.scheduleMarkdown()
        break
      }
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
      case "skill_activated":
        this.finishBubble()
        this.push(this.toolcard("skill", "↑", "load_skill(" + (ev.name || "") + ")", null))
        break
      case "guardrail_blocked":
        // RFC-0009: input short-circuited with a safe reply (the assistant bubble
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
        // chip (§11 A5). The bubble already IS the outcome; the chip is the cost.
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
