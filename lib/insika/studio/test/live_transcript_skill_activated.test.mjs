// A skill can now reach the prompt by TWO paths, and the card must not claim the
// wrong one:
//
//   tool    — the model called load_skill; the event carries a singular `name`.
//   context — a provider injected the bodies (triggers/skills_eager); the event
//             carries `names` + `mode`, and NO tool call happened.
//
// The context path arrived when progressive disclosure was turned off, and it
// initially rendered nothing at all — an active skill looked identical to an
// absent one. Rendering it as `load_skill(...)` would be the other failure:
// inventing a call the transcript never made.
//
// Same discipline as the sibling tests: `node --test` alone, no jsdom.

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
  createTextNode: (text) => node("#text", null, text)
}
globalThis.EventSource = class { constructor() {} close() {} }
globalThis.requestAnimationFrame = () => 1
globalThis.cancelAnimationFrame = () => {}

const { default: LiveTranscript } = await import("../assets/src/controllers/live_transcript_controller.js")

function build() {
  const c = Object.create(LiveTranscript.prototype)
  c.pushed = []
  c.el = (tag, cls, text) => node(tag, cls, text)
  c.push = (n) => c.pushed.push(n)
  c.pre = (body) => node("pre", null, typeof body === "string" ? body : JSON.stringify(body))
  c.finishBubble = () => {}
  c.finishThinking = () => {}
  c.setStatus = () => {}
  return c
}

// toolcard(cls, arrow, label, body) builds <details><summary>…; the label is the
// <strong> the operator actually reads.
const card = (c) => c.pushed.find((n) => n.cls === "toolcard skill")
const label = (c) => {
  const summary = card(c).children[0]
  return summary.children.find((n) => n.tag === "strong").text
}
const body = (c) => card(c).children.find((n) => n.tag === "pre")

test("the tool path still renders as the load_skill call it was", () => {
  const c = build()
  c.render({ type: "skill_activated", name: "gift-concierge" })

  assert.equal(label(c), "load_skill(gift-concierge)")
})

test("the context path names the mode and counts the skills", () => {
  const c = build()
  c.render({
    type: "skill_activated",
    names: ["gift-concierge", "natura-line-expert"],
    mode: "eager",
    source: "context"
  })

  assert.equal(label(c), "skills · eager (2)")
  assert.match(body(c).text, /gift-concierge/)
  assert.match(body(c).text, /natura-line-expert/)
})

test("it never claims a load_skill call on the context path", () => {
  const c = build()
  c.render({ type: "skill_activated", names: ["mapa"], mode: "trigger" })

  assert.doesNotMatch(label(c), /load_skill/)
  assert.equal(label(c), "skills · trigger (1)")
})

test("a context event without a mode still renders instead of vanishing", () => {
  const c = build()
  c.render({ type: "skill_activated", names: ["mapa"] })

  assert.equal(label(c), "skills · context (1)")
})
