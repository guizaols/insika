// Proof for: the live-transcript SSE stream reconnects after the browser
// gives up on the socket, with a capped exponential backoff.
//
// Runs on `node --test` alone — no test framework, no jsdom, no browser. The
// controller is instantiated WITHOUT a Stimulus context (Object.create over the
// prototype): the reconnect state machine touches no DOM, only `setStatus`,
// which the harness stubs. The DOM-rendering half of the controller is out of
// scope here on purpose.
//
// Division of labour under test: EventSource retries on its OWN while the socket
// is still CONNECTING, so the controller must stay out of the way; once the
// browser closes it for good (readyState === CLOSED) nothing ever reconnects, so
// the controller takes over with the backoff.

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

  // Test helpers -----------------------------------------------------------
  connected() { this.readyState = FakeEventSource.OPEN; this.onopen() }
  dropHard() { this.readyState = FakeEventSource.CLOSED; this.onerror() } // browser gave up
  dropTransient() { this.readyState = FakeEventSource.CONNECTING; this.onerror() } // browser retries
}

globalThis.EventSource = FakeEventSource

const { default: LiveTranscript } = await import("../assets/src/controllers/live_transcript_controller.js")

// A controller instance, connected — WITHOUT touching the fake socket
// registry. Split out of build() so a test can attach a second, independent
// controller (simulating the element a Turbo Frame swap inserts) while still
// seeing every socket either one has ever opened.
function attach({ session = "sess-1", task = "" } = {}) {
  const c = Object.create(LiveTranscript.prototype)
  c.sessionValue = session
  c.taskValue = task
  c.hasStatusTarget = false
  c.statuses = []
  c.setStatus = (text) => c.statuses.push(text)
  c.connect()
  return c
}

function build(opts) {
  FakeEventSource.opened = []
  return attach(opts)
}

const live = () => FakeEventSource.opened.at(-1)
const sockets = () => FakeEventSource.opened.length

test("subscribes to /studio/events scoped to the session", () => {
  const c = build()
  assert.equal(live().url, "/studio/events?session_id=sess-1")
  assert.deepEqual(c.statuses, ["connecting…"])
  c.close()
})

test("a transient error is left to the browser — no second socket", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  const c = build()
  live().connected()
  live().dropTransient()

  t.mock.timers.tick(60_000)
  assert.equal(sockets(), 1, "controller must not race the browser's own retry")
  assert.equal(c.statuses.at(-1), "reconnecting…")
  c.close()
})

test("reconnects after a dropped stream once the browser has closed it", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  const c = build()
  live().connected()
  live().dropHard()
  assert.equal(c.statuses.at(-1), "disconnected — retrying…")

  t.mock.timers.tick(999)
  assert.equal(sockets(), 1, "must wait out the 1s backoff")

  t.mock.timers.tick(1)
  assert.equal(sockets(), 2, "a fresh socket is opened")
  assert.equal(live().url, "/studio/events?session_id=sess-1")
  c.close()
})

test("backoff doubles per failed attempt and caps at 30s", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  const c = build()
  live().connected()

  // Each drop must be waited out in full before the next socket appears.
  for (const delay of [1000, 2000, 4000, 8000, 16000, 30000, 30000]) {
    const before = sockets()
    live().dropHard()
    t.mock.timers.tick(delay - 1)
    assert.equal(sockets(), before, `still waiting out the ${delay}ms backoff`)
    t.mock.timers.tick(1)
    assert.equal(sockets(), before + 1, `retried after ${delay}ms`)
  }
  c.close()
})

test("a successful reconnect resets the backoff", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  const c = build()
  live().connected()
  live().dropHard()
  t.mock.timers.tick(1000)
  live().connected() // recovered

  live().dropHard()
  t.mock.timers.tick(1000)
  assert.equal(sockets(), 3, "backoff is back to 1s, not 2s")
  c.close()
})

test("only one reconnect is ever pending", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  const c = build()
  live().connected()
  const socket = live()
  socket.dropHard()
  socket.onerror() // a second error on the same dead socket
  socket.onerror()

  t.mock.timers.tick(1000)
  assert.equal(sockets(), 2, "duplicate errors must not fan out into sockets")
  c.close()
})

test("disconnect cancels a pending reconnect", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  const c = build()
  live().connected()
  live().dropHard()

  c.disconnect()
  t.mock.timers.tick(60_000)
  assert.equal(sockets(), 1, "a controller torn off the page must go quiet")
})

// T11 — Chats/Session's turbo-frame#session-detail swaps a whole new section
// in per row click (Turbo's default frame render: no `refresh="morph"` is set
// anywhere in this app — see session.erb), so the OLD live-transcript element
// is removed from the DOM and a BRAND NEW one is inserted for the newly
// selected session. Stimulus's own lifecycle is what "reconnects" here: it
// calls disconnect() on the outgoing controller instance and connect() on a
// separate incoming instance — there is no shared JS state, and no
// `sessionValueChanged` callback for Turbo to call instead (there isn't one
// defined), which is exactly the trap a morphed swap would fall into.
test("a Turbo Frame swap to a new session tears down the old socket and opens a fresh one scoped to the new session", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] })

  // Outgoing controller: session-detail showed "sess-1", mid-backoff after a
  // hard drop (the worst case — a pending reconnect timer in flight).
  const outgoing = build({ session: "sess-1" })
  live().connected()
  live().dropHard()
  const deadSocket = live()

  // The frame swap: Stimulus disconnects the outgoing element (Turbo removed
  // it from the DOM) and connects a fresh element for the row that was
  // clicked — a SEPARATE controller instance, never the same object. Uses
  // attach(), not build(): build() resets the fake socket registry, which
  // would hide whether the OLD socket really got closed.
  outgoing.disconnect()
  const before = sockets()
  const incoming = attach({ session: "sess-2" })

  assert.notEqual(incoming, outgoing, "the swap yields a distinct controller instance, not a mutated one")
  assert.equal(deadSocket.readyState, FakeEventSource.CLOSED, "the old session's socket is closed, not left dangling")
  assert.equal(sockets(), before + 1, "the swap opens exactly one new socket")
  assert.equal(live().url, "/studio/events?session_id=sess-2", "the new socket is scoped to the newly-selected session")
  assert.equal(live().readyState, FakeEventSource.CONNECTING, "the new socket is a fresh connection attempt")

  // The dead controller's pending reconnect must not resurrect and steal the
  // new session's socket out from under it.
  const afterSwap = sockets()
  t.mock.timers.tick(60_000)
  assert.equal(sockets(), afterSwap, "no extra socket appears — the outgoing controller's timer was cancelled by disconnect()")
  assert.equal(live().url, "/studio/events?session_id=sess-2")
  incoming.close()
})
