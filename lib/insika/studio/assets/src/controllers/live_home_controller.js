import { Controller } from "@hotwired/stimulus"

// live-home — the overview stays honest after load, over the
// SAME SSE channel the live transcript uses (/studio/events, unscoped — the
// channel is already multi-client). Three live surfaces:
//
//   · the "active now" badge: conversations touched in the last 5 minutes —
//     the exact definition the server renders — plus "· Ns ago" since the
//     last event seen. The server number is the baseline until the first
//     event arrives; from then on the window is tracked client-side and
//     decays on a 5s tick.
//   · the recent-conversations feed: the session an event belongs to is
//     promoted to the head (or prepended when the server didn't know it).
//   · a presence dot per conversation, lit while that session is inside the
//     window.
//
// The server-rendered numbers are never recomputed here — this layer only
// reacts. apply() is pure state; render() is the only DOM writer, so the
// state machine runs headless in node --test (see test/live_home.test.mjs).

// Ceiling for the SSE reconnect backoff: 1s→2s→…→30s, then steady.
const RECONNECT_MAX = 30000
// "Touched" window — matches render_home's `active_now` (sessions touched in
// the last 5 minutes) so the live counter and the server baseline agree.
const WINDOW_MS = 5 * 60 * 1000
const TICK_MS = 5000

export default class extends Controller {
  static targets = ["count", "list", "placeholder", "ago"]
  static values = { active: Number }

  connect() {
    this.touched = new Map() // session id → epoch ms of its last event
    this.lastEventAt = null  // epoch ms of the last event seen (any session)
    this.live = false        // false = still showing the server baseline
    this.backoff = 1000
    this.reconnectTimer = null
    this.tick = setInterval(() => this.render(), TICK_MS)
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

  // EventSource retries on its own while the socket is still CONNECTING; once
  // the browser gives up (readyState === CLOSED) it never reconnects, so we
  // step in with the capped backoff. Same discipline as live_transcript.
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

  // One event: stamp the session and the clock, then repaint. Bookkeeping
  // events carry session ids too — for presence, a checkpoint is activity.
  apply(ev) {
    const sid = ev.meta && ev.meta.session_id
    if (!sid) return

    const now = Date.now()
    this.lastEventAt = now
    this.live = true
    this.touched.set(sid, now)
    this.decay(now)
    this.touch(sid)
    this.render()
  }

  // Drop sessions whose last event fell out of the window.
  decay(now = Date.now()) {
    for (const [sid, at] of this.touched) {
      if (now - at > WINDOW_MS) this.touched.delete(sid)
    }
  }
  // The feed's rows, in DOM order. Iteration + dataset comparison instead of
  // an attribute selector with the id interpolated — a session id is
  // user-supplied text and must never enter a selector.
  rows() {
    return this.hasListTarget ? [...this.listTarget.querySelectorAll("[data-session-id]")] : []
  }

  rowFor(sid) {
    return this.rows().find((r) => r.dataset.sessionId === sid) || null
  }

  touch(sid) {
    const row = this.rowFor(sid)
    if (row) {
      this.listTarget.prepend(row) // most recent first
      this.refreshSub(row)
    } else {
      this.prependRow(sid)
    }
  }

  // "· just now" on the promoted row — the visible half of "the feed updates
  // within 2s of a turn completing" (the server-stamped age is stale by now).
  // Only the LAST "·" segment is the age; the leading "N msg" part stays.
  refreshSub(row) {
    const sub = row.querySelector(".convo-sub")
    if (!sub) return
    const parts = sub.textContent.split("·")
    if (parts.length > 1) {
      parts[parts.length - 1] = " just now"
      sub.textContent = parts.join("·")
    }
  }

  // A conversation the server didn't know about: build its row here — the
  // same markup home.erb renders, avatar hue included (avatar_class mirrored:
  // UTF-8 byte sum mod 10).
  prependRow(sid) {
    if (!this.hasListTarget) return
    if (this.hasPlaceholderTarget) this.placeholderTarget.remove()

    const li = document.createElement("li")
    li.dataset.sessionId = sid
    const a = document.createElement("a")
    a.href = "/studio/sessions/" + encodeURIComponent(sid)
    const av = document.createElement("span")
    av.className = "avatar sm " + this.avatarClass(sid)
    av.textContent = sid.slice(0, 2).toUpperCase()
    const main = document.createElement("span")
    main.className = "convo-main"
    const id = document.createElement("span")
    id.className = "convo-id mono"
    id.textContent = sid.slice(0, 20)
    const sub = document.createElement("span")
    sub.className = "convo-sub"
    sub.textContent = "live · just now"
    main.append(id, sub)
    const dot = document.createElement("span")
    dot.className = "presence"
    a.append(av, main, dot)
    li.appendChild(a)
    this.listTarget.prepend(li)
  }

  avatarClass(sid) {
    let sum = 0
    for (const b of new TextEncoder().encode(sid)) sum += b
    return "avatar-h" + (sum % 10)
  }

  activeCount(now = Date.now()) {
    this.decay(now)
    return this.live ? this.touched.size : (this.activeValue || 0)
  }

  // "· 48s ago" — time since the last event seen; null before the first one.
  agoLabel(now = Date.now()) {
    if (!this.lastEventAt) return null
    const secs = Math.max(0, Math.round((now - this.lastEventAt) / 1000))
    if (secs < 10) return "just now"
    if (secs < 60) return `${secs}s ago`
    const mins = Math.round(secs / 60)
    return `${mins}m ago`
  }

  // The only DOM writer.
  render() {
    const now = Date.now()
    if (this.hasCountTarget) {
      const n = this.activeCount(now)
      this.countTarget.textContent = String(n)
      const badge = this.countTarget.closest(".live-badge")
      if (badge) badge.classList.toggle("hot", n > 0)
    }
    const ago = this.agoLabel(now)
    if (ago && this.hasAgoTarget) this.agoTarget.textContent = "· " + ago
    for (const row of this.rows()) {
      const dot = row.querySelector(".presence")
      if (dot) dot.classList.toggle("present", this.touched.has(row.dataset.sessionId))
    }
  }
}
