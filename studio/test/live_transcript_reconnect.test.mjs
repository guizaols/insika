// Proof for §11 A3: the live-transcript SSE stream reconnects after the browser
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

function build({ session = "sess-1", task = "" } = {}) {
  const c = Object.create(LiveTranscript.prototype)
  c.sessionValue = session
  c.taskValue = task
  c.hasStatusTarget = false
  c.statuses = []
  c.setStatus = (text) => c.statuses.push(text)
  FakeEventSource.opened = []
  c.connect()
  return c
}

const live = () => FakeEventSource.opened.at(-1)
const sockets = () => FakeEventSource.opened.length

test("subscribes to /v1/events scoped to the session", () => {
  const c = build()
  assert.equal(live().url, "/v1/events?session_id=sess-1")
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
  assert.equal(live().url, "/v1/events?session_id=sess-1")
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
