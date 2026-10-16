import { Controller } from "@hotwired/stimulus"

// live-floor — the Live page's cards and event ticker, over the same
// unscoped /studio/events channel live_home reads. The server renders each
// card's baseline (presence, flag); this layer only reacts:
//
//   · a card's state (cardState, pure) moves with its session's events:
//     tool chips of the running turn, "agent is writing…" until the turn
//     ends, the flag once a guardrail fires. Its card jumps to the front.
//   · the ticker lists the latest events, newest first, deltas left out.
//
// cardState/tickerLabel are exported and tested headless
// (test/live_floor.test.mjs); paint() is the only DOM writer per card.

// Ceiling for the SSE reconnect backoff: 1s→2s→…→30s, then steady.
const RECONNECT_MAX = 30000
// Same 5-minute "touched" window as session_fresh? on the server.
const WINDOW_MS = 5 * 60 * 1000
const TICK_MS = 5000
const TOOLS_SHOWN = 3
const TICKER_MAX = 30
// Streaming deltas and model diagnostics: too many and too small for a ticker.
const QUIET = new Set(["thinking", "intermediate", "llm_request", "llm_usage", "ttft", "checkpoint_created"])

// One event folded into a card's state. Unknown types only stamp the time.
export function cardState(prev, ev, now = Date.now()) {
  const s = { writing: false, tools: [], flagged: false, ...prev, at: now }
  switch (ev.type) {
    case "task_started":
      return { ...s, writing: true, tools: [] }
    case "thinking":
    case "intermediate":
    case "content":
      return { ...s, writing: true }
    case "tool_call":
      return { ...s, writing: true, tools: [...s.tools, ev.name || "tool"].slice(-TOOLS_SHOWN) }
    case "guardrail_flagged":
    case "guardrail_blocked":
      return { ...s, flagged: true }
    case "task_completed":
    case "task_failed":
    case "task_cancelled":
      return { ...s, writing: false }
    default:
      return s
  }
}

// "tool_call · menu", "guardrail_flagged · sexual", "task_completed"; null for
// the quiet types.
export function tickerLabel(ev) {
  if (!ev || !ev.type || QUIET.has(ev.type)) return null
  const detail = ev.name || ev.category
  return detail ? `${ev.type} · ${detail}` : ev.type
}

export default class extends Controller {
  static targets = ["grid", "placeholder", "ticker", "waiting"]
  // Filtered by agent (?agent=): events carry no agent, so only the cards
  // already on the page move; other sessions are left out of grid and ticker.
  static values = { scoped: Boolean }

  connect() {
    this.states = new Map() // session id → cardState
    this.backoff = 1000
    this.reconnectTimer = null
    this.tick = setInterval(() => this.decay(), TICK_MS)
    this.open()
  }

  disconnect() {
    this.close()
    if (this.tick) { clearInterval(this.tick); this.tick = null }
  }

  open() {
    this.close()
    this.es = new EventSource("/studio/events")
    this.es.onopen = () => { this.backoff = 1000 }
    this.es.onerror = () => this.onError()
    this.es.onmessage = (e) => {
      try { this.apply(JSON.parse(e.data)) } catch (_) { /* not JSON: ignore */ }
    }
  }

  // Same discipline as live_home: the browser owns the CONNECTING retry; once
  // it gives up (CLOSED) we step in with the capped backoff.
  onError() {
    if (this.es && this.es.readyState === EventSource.CONNECTING) return
    this.scheduleReconnect()
  }

  scheduleReconnect() {
    if (this.reconnectTimer) return // one pending attempt at a time
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

  apply(ev) {
    const sid = ev.meta && ev.meta.session_id
    if (this.scopedValue && !(sid && this.cardFor(sid))) return
    const label = tickerLabel(ev)
    if (label) this.pushTicker(sid, label, ev.meta && ev.meta.at)
    if (!sid) return

    const now = Date.now()
    const state = cardState(this.states.get(sid), ev, now)
    this.states.set(sid, state)
    const card = this.cardFor(sid) || this.newCard(sid)
    if (!card) return
    this.gridTarget.prepend(card) // most recent first
    this.paint(card, state, now)
  }

  // Iteration + dataset comparison, never a selector with the id in it — a
  // session id is user-supplied text (same rule as live_home).
  cardFor(sid) {
    if (!this.hasGridTarget) return null
    return [...this.gridTarget.querySelectorAll("[data-session-id]")].find((c) => c.dataset.sessionId === sid) || null
  }

  paint(card, state, now = Date.now()) {
    card.classList.toggle("writing", state.writing)
    if (state.flagged) card.classList.add("flagged") // the server's flag never clears
    const dot = card.querySelector(".presence")
    if (dot) dot.classList.toggle("present", now - state.at <= WINDOW_MS)
    const tools = card.querySelector(".live-tools")
    if (tools) tools.replaceChildren(...state.tools.map((name) => this.el("span", "pill plain mono", name)))
  }

  // The presence dots of the cards this page saw move fall dark after 5 min.
  decay(now = Date.now()) {
    for (const [sid, state] of this.states) {
      const dot = this.cardFor(sid)?.querySelector(".presence")
      if (dot) dot.classList.toggle("present", now - state.at <= WINDOW_MS)
    }
  }

  // A conversation the server didn't render: the same card shape, with the
  // session id standing in for the customer until a reload names it.
  newCard(sid) {
    if (!this.hasGridTarget) return null
    if (this.hasPlaceholderTarget) this.placeholderTarget.remove()
    const a = this.el("a", "card live-card")
    a.href = "/studio/sessions/" + encodeURIComponent(sid)
    a.dataset.sessionId = sid
    const top = this.el("div", "live-card-top")
    top.append(this.el("span", "convo-id mono", sid.slice(0, 20)), this.el("span", "presence"))
    const foot = this.el("div", "live-card-foot")
    foot.append(this.el("span", "pill err live-flag", "flagged"), this.el("span", "live-tools"),
      this.el("span", "live-writing", "agent is writing…"))
    a.append(top, this.el("p", "live-preview", "new conversation"), foot)
    return a
  }

  pushTicker(sid, label, at) {
    if (!this.hasTickerTarget) return
    if (this.hasWaitingTarget) this.waitingTarget.remove()
    const li = this.el("li")
    const d = at ? new Date(at) : new Date()
    li.append(this.el("time", null, isNaN(d.getTime()) ? "" : d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })))
    if (sid) {
      const a = this.el("a", null, sid.slice(0, 20))
      a.href = "/studio/sessions/" + encodeURIComponent(sid)
      li.append(a)
    }
    li.append(this.el("span", null, label))
    this.tickerTarget.prepend(li)
    while (this.tickerTarget.children.length > TICKER_MAX) this.tickerTarget.lastElementChild.remove()
  }

  el(tag, cls, text) {
    const e = document.createElement(tag)
    if (cls) e.className = cls
    if (text != null) e.textContent = text
    return e
  }
}
