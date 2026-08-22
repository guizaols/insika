// live-home: the overview's live layer — the "active now"
// window, the recent-conversations feed and the presence dots, all driven off
// /studio/events.
//
// Same discipline as the live_transcript_* tests: `node --test` alone, no
// jsdom. The controller is built over the prototype; the state machine
// (apply/render) is exercised with stub targets that record textContent,
// classList toggles and DOM mutations. The SSE/reconnect half reuses the
// FakeEventSource harness proven in live_transcript_reconnect.test.mjs.

import { test, mock } from "node:test"
import assert from "node:assert/strict"

class FakeEventSource {
  static CONNECTING = 0
  static OPEN = 1
  static CLOSED = 2
  static opened = []

  constructor(url) {
    this.url = url
    this.readyState = FakeEventSource.CONNECTING
    FakeEventSource.opened.push(this)
  }

  close() { this.readyState = FakeEventSource.CLOSED }
}

globalThis.EventSource = FakeEventSource
globalThis.setInterval = () => 1 // the decay ticker: never fires in tests
globalThis.clearInterval = () => {}

// prependRow() builds DOM for a session the server didn't render — a minimal
// createElement stub covers it (plain objects; append/appendChild record).
const el = (tag) => ({
  tag, className: "", textContent: "", dataset: {},
  appendChild(child) { (this.children ||= []).push(child); return child },
  append(...children) { children.forEach((c) => this.appendChild(c)) },
  querySelector: () => null // DOM rows carry no dot/sub in this harness
})
globalThis.document = { createElement: (tag) => el(tag) }

const { default: LiveHome } = await import("../assets/src/controllers/live_home_controller.js")

// A recording stub of a feed row: dataset + the two nodes the controller
// touches (the .presence dot and the .convo-sub label).
const row = (sid, sub = "3 msg · 2min") => {
  const r = {
    dataset: { sessionId: sid },
    classes: new Set(),
    prependCalls: 0,
    sub: { textContent: sub },
    dot: {
      classes: new Set(),
      classList: { toggle: (name, on) => (on ? r.dot.classes.add(name) : r.dot.classes.delete(name)) }
    },
    querySelector: (sel) => (sel === ".presence" ? r.dot : sel === ".convo-sub" ? r.sub : null)
  }
  r.classList = { toggle: (name, on) => (on ? r.classes.add(name) : r.classes.delete(name)) }
  return r
}

// The <ul data-live-home-target="list"> stub. prepend MOVES a node (DOM
// semantics), so an already-present row is re-inserted, never duplicated.
const list = (rows) => ({
  rows,
  querySelectorAll: (sel) => (sel === "[data-session-id]" ? rows : []),
  prepend: (n) => {
    const i = rows.indexOf(n)
    if (i >= 0) rows.splice(i, 1)
    rows.unshift(n)
  }
})

function build({ active = 0, rows = [] } = {}) {
  const c = Object.create(LiveHome.prototype)
  c.activeValue = active
  c.hasCountTarget = true
  c.countTarget = { textContent: String(active), closest: () => null }
  c.hasAgoTarget = false
  c.hasListTarget = rows.length >= 0
  c.hasPlaceholderTarget = false
  c.listTarget = list(rows)
  FakeEventSource.opened = []
  c.connect()
  return c
}

test("subscribes to the unscoped /studio/events channel", () => {
  const c = build()
  assert.equal(FakeEventSource.opened.length, 1)
  assert.equal(FakeEventSource.opened[0].url, "/studio/events")
  c.disconnect()
})

test("the server baseline shows until the first event; then the window rules", () => {
  const c = build({ active: 3 })
  assert.equal(c.countTarget.textContent, "3")
  c.apply({ type: "task_started", meta: { session_id: "s1" } })
  assert.equal(c.countTarget.textContent, "1", "one tracked session is active")
  c.apply({ type: "content", delta: "oi", meta: { session_id: "s2" } })
  assert.equal(c.countTarget.textContent, "2")
  c.disconnect()
})

test("a turn completing keeps the conversation in the window (presence, not flight)", () => {
  const c = build()
  c.apply({ type: "task_started", meta: { session_id: "s1" } })
  c.apply({ type: "task_completed", meta: { session_id: "s1" } })
  assert.equal(c.countTarget.textContent, "1", "just-finished is still recently active")
  assert.ok(c.touched.has("s1"))
  c.disconnect()
})

test("the window decays: a session older than 5 minutes stops counting", () => {
  const c = build()
  c.apply({ type: "task_started", meta: { session_id: "s1" } })
  // Simulate the passage of time; the (stubbed) 5s ticker would call render().
  c.touched.set("s1", Date.now() - 6 * 60 * 1000)
  assert.equal(c.activeCount(), 0)
  c.render()
  assert.equal(c.countTarget.textContent, "0")
  c.disconnect()
})

test("a known session is promoted to the head of the feed with a fresh age", () => {
  const r1 = row("s1")
  const r2 = row("s2")
  const c = build({ rows: [r1, r2] })
  c.apply({ type: "task_started", meta: { session_id: "s1" } })
  assert.equal(c.listTarget.rows[0], r1, "the touched row moves to the head")
  assert.match(r1.sub.textContent, /just now/)
  assert.equal(c.listTarget.rows.length, 2, "promotion never duplicates a row")
  c.disconnect()
})

test("an unknown session is prepended as a new row", () => {
  const c = build({ rows: [row("s1")] })
  c.apply({ type: "task_started", meta: { session_id: "brand-new" } })
  assert.equal(c.listTarget.rows.length, 2)
  assert.equal(c.listTarget.rows[0].dataset.sessionId, "brand-new")
  assert.ok(c.countTarget.textContent === "1")
  c.disconnect()
})

test("presence dots track the window per session", () => {
  const r1 = row("s1")
  const r2 = row("s2")
  const c = build({ rows: [r1, r2] })
  c.apply({ type: "task_started", meta: { session_id: "s2" } })
  assert.ok(!r1.dot.classes.has("present"), "untouched session stays dark")
  assert.ok(r2.dot.classes.has("present"), "the active session lights up")
  c.disconnect()
})

test("events without a session id change nothing", () => {
  const c = build({ active: 2 })
  c.apply({ type: "provider_warning", data: {} })
  assert.equal(c.countTarget.textContent, "2")
  assert.equal(c.listTarget.rows.length, 0)
  c.disconnect()
})

test("the ago label reads from the last event seen", () => {
  const c = build()
  assert.equal(c.agoLabel(), null, "nothing before the first event")
  c.apply({ type: "task_started", meta: { session_id: "s1" } })
  assert.equal(c.agoLabel(), "just now")
  c.lastEventAt = Date.now() - 48_000
  assert.equal(c.agoLabel(), "48s ago")
  c.lastEventAt = Date.now() - 125_000
  assert.equal(c.agoLabel(), "2m ago")
  c.disconnect()
})

test("a dropped stream reconnects with the capped backoff", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  const c = build()
  const socket = FakeEventSource.opened[0]
  socket.readyState = FakeEventSource.CLOSED
  socket.onerror()

  t.mock.timers.tick(999)
  assert.equal(FakeEventSource.opened.length, 1, "must wait out the 1s backoff")
  t.mock.timers.tick(1)
  assert.equal(FakeEventSource.opened.length, 2, "a fresh socket is opened")
  assert.equal(FakeEventSource.opened[1].url, "/studio/events")
  c.disconnect()
})

test("disconnect closes the socket and cancels a pending reconnect", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  const c = build()
  const socket = FakeEventSource.opened[0]
  socket.readyState = FakeEventSource.CLOSED
  socket.onerror()
  c.disconnect()
  t.mock.timers.tick(60_000)
  assert.equal(FakeEventSource.opened.length, 1, "a torn-off page must go quiet")
})
