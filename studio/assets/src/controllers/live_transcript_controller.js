import { Controller } from "@hotwired/stimulus"

// live-transcript (island D9) — assina o SSE de /v1/events (mesma origem, sem
// header de auth: é a API do consumidor) e renderiza o turno ao vivo: deltas de
// texto viram bolha do assistente; tool_call/tool_result/skill viram tool-cards.
// Reusa o protocolo de eventos já provado no /admin (#24), agora empacotado como
// controller Stimulus (CSP estrita 'self' — nada de <script> inline).
export default class extends Controller {
  static targets = ["stream", "empty", "status"]
  static values = { session: String, task: String }

  connect() {
    this.current = null
    if (this.sessionValue || this.taskValue) this.open()
  }

  disconnect() {
    this.close()
  }

  open() {
    this.close()
    const params = new URLSearchParams()
    if (this.taskValue) params.set("task_id", this.taskValue)
    if (this.sessionValue) params.set("session_id", this.sessionValue)
    const url = "/v1/events" + (params.toString() ? "?" + params.toString() : "")

    this.setStatus("connecting…", "warn")
    this.es = new EventSource(url)
    this.es.onopen = () => this.setStatus("connected", "ok")
    this.es.onerror = () => this.setStatus("disconnected", "err")
    this.es.onmessage = (e) => {
      try { this.render(JSON.parse(e.data)) } catch (_) { this.push(this.chipText(e.data)) }
    }
  }

  close() {
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

  pre(obj) {
    const p = this.el("pre")
    p.textContent = typeof obj === "string" ? obj : JSON.stringify(obj, null, 2)
    return p
  }

  push(node) {
    if (this.hasEmptyTarget) this.emptyTarget.style.display = "none"
    this.streamTarget.appendChild(node)
    node.scrollIntoView({ block: "end" })
  }

  toolcard(kind, arrow, title, body) {
    const c = this.el("div", "toolcard " + kind)
    const h = this.el("div", "h")
    h.appendChild(this.el("span", "arrow", arrow))
    h.appendChild(this.el("strong", null, title))
    c.appendChild(h)
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

  render(ev) {
    switch (ev.type) {
      case "content":
        if (!this.current) {
          const msg = this.el("div", "msg assistant")
          msg.appendChild(this.el("div", "who", "A"))
          const b = this.el("div", "bubble")
          this.current = this.el("div", "content", "")
          b.appendChild(this.current)
          msg.appendChild(b)
          this.push(msg)
        }
        this.current.textContent += ev.delta || ""
        break
      case "tool_call":
        this.current = null
        this.push(this.toolcard("", "→", (ev.name || "tool") + "(…)", ev.arguments))
        break
      case "tool_result":
        this.push(this.toolcard("result", "←", ev.name || "tool", ev.result))
        break
      case "skill_activated":
        this.push(this.toolcard("skill", "↑", "load_skill(" + (ev.name || "") + ")", null))
        break
      case "done":
      case "task_failed":
      case "task_cancelled":
        this.current = null
        this.push(this.chip(ev))
        this.setStatus("turn finished", "info")
        break
      default:
        this.current = null
        this.push(this.chip(ev))
    }
  }
}
