// The provider's reasoning (:thinking) in the live transcript: ONE collapsed card
// per run of consecutive deltas — not one card per delta, which is what a naive
// switch-case would produce out of a stream of dozens of tokens.
//
// Same discipline as live_transcript_reconnect.test.mjs: `node --test` alone, no
// jsdom. The controller is built over the prototype and the two DOM seams it
// touches here (`this.el`, `document.createElement`) are stubbed with plain
// objects that record appendChild/textContent — enough to assert the card count
// and the accumulated text without pulling in a DOM.

import { test } from "node:test"
import assert from "node:assert/strict"

const node = (tag, cls, text) => ({
  tag, cls, text, children: [], textContent: "", attrs: {},
  appendChild(child) { this.children.push(child); return child },
  setAttribute(k, v) { this.attrs[k] = v }
})

globalThis.document = { createElement: (tag) => node(tag, null, null) }
globalThis.EventSource = class { constructor() {} close() {} }
globalThis.requestAnimationFrame = () => 1 // never painted: no DOM to paint into
globalThis.cancelAnimationFrame = () => {}

const { default: LiveTranscript } = await import("../assets/src/controllers/live_transcript_controller.js")

function build() {
  const c = Object.create(LiveTranscript.prototype)
  c.thinkingPre = null
  c.pushed = []
  c.bubblesFinished = 0
  c.el = (tag, cls, text) => node(tag, cls, text)
  c.push = (n) => c.pushed.push(n)
  c.finishBubble = () => { c.bubblesFinished++ }
  c.setStatus = () => {}
  return c
}

const cards = (c) => c.pushed.filter((n) => n.cls === "toolcard thinking")

test("consecutive thinking deltas accumulate into a single card", () => {
  const c = build()
  c.render({ type: "thinking", delta: "o cliente quer trufas; " })
  c.render({ type: "thinking", delta: "vou buscar no catálogo" })

  assert.equal(cards(c).length, 1, "a card per delta would be unreadable")
  assert.equal(c.thinkingPre.textContent, "o cliente quer trufas; vou buscar no catálogo")
})

test("the card is collapsed and labelled — reasoning is not the answer", () => {
  const c = build()
  c.render({ type: "thinking", delta: "hmm" })

  const card = cards(c)[0]
  assert.equal(card.tag, "details")
  assert.ok(!("open" in card), "must not be opened by default")
  const summary = card.children[0]
  assert.deepEqual(summary.children.map((n) => n.text), ["…", "thinking"])
})

test("a non-thinking event closes the card: the next run opens a fresh one", () => {
  const c = build()
  c.render({ type: "thinking", delta: "primeiro" })
  c.render({ type: "tool_call", name: "search_products", arguments: {} })
  c.render({ type: "thinking", delta: "segundo" })

  const [first, second] = cards(c)
  assert.equal(cards(c).length, 2)
  assert.equal(first.children[1].textContent, "primeiro")
  assert.equal(second.children[1].textContent, "segundo")
})

test("an open thinking card does not swallow the assistant bubble", () => {
  const c = build()
  c.render({ type: "thinking", delta: "pensando" })
  assert.equal(c.bubblesFinished, 1, "opening the card flushes any streaming bubble")

  c.render({ type: "content", delta: "Temos sim!" })
  assert.equal(c.thinkingPre, null, "content must detach the thinking cursor")
})
