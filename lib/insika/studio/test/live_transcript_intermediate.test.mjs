// in the live transcript: `:intermediate` is model text that did NOT become
// the answer (narration before a tool call, reasoning in prose), and `:content` is
// the answer. `/v1/responses` drops the first and translates the second — the
// Studio shows BOTH, because seeing what was suppressed is the operator's whole
// reason to be here, but they must never look alike.
//
// Same discipline as the sibling tests: `node --test` alone, no jsdom. The
// controller is built over the prototype and the DOM seams it touches are stubbed
// with plain objects that record class toggles and text.

import { test } from "node:test"
import assert from "node:assert/strict"

const node = (tag, cls, text) => {
  const n = {
    tag, cls, text, children: [], textContent: "", attrs: {}, classes: new Set(),
    appendChild(child) { this.children.push(child); return child },
    setAttribute(k, v) { this.attrs[k] = v }
  }
  n.classList = { toggle: (name, on) => (on ? n.classes.add(name) : n.classes.delete(name)) }
  return n
}

globalThis.document = {
  createElement: (tag) => node(tag, null, null),
  createTextNode: (text) => node("#text", null, text),
  // no #chip-icons sprite in this harness: chipIcon() must cope with its absence
  getElementById: () => null
}
globalThis.EventSource = class { constructor() {} close() {} }
globalThis.requestAnimationFrame = () => 1 // never painted: no DOM to paint into
globalThis.cancelAnimationFrame = () => {}

const { default: LiveTranscript } = await import("../assets/src/controllers/live_transcript_controller.js")

function build() {
  const c = Object.create(LiveTranscript.prototype)
  c.current = null
  c.currentText = ""
  c.thinkingPre = null
  c.pushed = []
  c.el = (tag, cls, text) => node(tag, cls, text)
  c.push = (n) => c.pushed.push(n)
  c.setStatus = () => {}
  c.renderUsage = () => {}
  return c
}

const bubbles = (c) => c.pushed.filter((n) => n.cls === "msg assistant")

test("intermediate deltas stream into ONE bubble, marked as not sent", () => {
  const c = build()
  c.render({ type: "intermediate", delta: "Deixa eu buscar " })
  c.render({ type: "intermediate", delta: "opções pra você." })

  assert.equal(bubbles(c).length, 1, "a bubble per delta would be unreadable")
  assert.equal(c.currentText, "Deixa eu buscar opções pra você.")
  assert.ok(c.currentBubble.classes.has("draft"), "must not look like a delivered message")
  assert.equal(c.currentTag.textContent, "intermediate · not sent")
})

test("content promotes the bubble in place instead of printing the text twice", () => {
  const c = build()
  c.render({ type: "intermediate", delta: "Temos sim!" })
  c.render({ type: "content", delta: "Temos sim!" })

  assert.equal(bubbles(c).length, 1, "the answer arrives as the deltas that drafted it")
  assert.equal(c.currentText, "Temos sim!", "replaced, not appended")
  assert.ok(!c.currentBubble.classes.has("draft"))
  assert.equal(c.currentTag.textContent, "assistant")
})

test("a tool call closes the draft, and the answer opens a fresh bubble", () => {
  const c = build()
  c.render({ type: "intermediate", delta: "Deixa eu buscar." })
  c.render({ type: "tool_call", name: "search_products", arguments: {} })
  c.render({ type: "intermediate", delta: "Achei três opções." })
  c.render({ type: "content", delta: "Achei três opções." })

  const [narration, answer] = bubbles(c)
  assert.equal(bubbles(c).length, 2)
  assert.ok(narration.children[1].classes.has("draft"), "the pre-tool text stays marked as not sent")
  assert.ok(!answer.children[1].classes.has("draft"))
})

test("content with no draft (a guardrail's safe reply) still renders as the answer", () => {
  const c = build()
  c.render({ type: "content", delta: "Não posso te ajudar com isso." })

  assert.equal(bubbles(c).length, 1)
  assert.ok(!c.currentBubble.classes.has("draft"))
  assert.equal(c.currentText, "Não posso te ajudar com isso.")
})
