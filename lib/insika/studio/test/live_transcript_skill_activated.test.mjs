// A skill can now reach the prompt by TWO paths, and the card must not claim the
// wrong one:
//
//   tool    — the model called load_skill; the event carries a singular `name`.
//   context — a provider injected the bodies (triggers/skills_eager); the event
//             carries `skills` — {name, reason} each — and NO tool call happened.
//
// The context path arrived when progressive disclosure was turned off, and it
// initially rendered nothing at all — an active skill looked identical to an
// absent one. Rendering it as `load_skill(...)` would be the other failure:
// inventing a call the transcript never made. And a bare list of NAMES was the
// third: it says something was injected without saying which one the operator
// triggered, which is the question they were asking all along.
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
  createTextNode: (text) => node("#text", null, text),
  // no #chip-icons sprite in this harness: chipIcon() must cope with its absence
  getElementById: () => null
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

test("the context path names the shared reason and counts the skills", () => {
  const c = build()
  c.render({
    type: "skill_activated",
    skills: [{ name: "gift-concierge", reason: "eager" }, { name: "prisma-line-expert", reason: "eager" }],
    source: "context"
  })

  assert.equal(label(c), "skills · eager (2)")
  assert.match(body(c).text, /gift-concierge/)
  assert.match(body(c).text, /prisma-line-expert/)
})

// The whole point of the reason: it says WHICH PHRASE fired, so the operator can go
// and edit that `triggers:` line.
test("a trigger reason carries the matched phrase into the body", () => {
  const c = build()
  c.render({ type: "skill_activated", skills: [{ name: "gift-concierge", reason: "trigger:presente" }] })

  assert.equal(label(c), "skills · trigger (1)")
  assert.match(body(c).text, /gift-concierge · trigger:presente/)
})

// A turn CAN mix, which is exactly why the single per-turn mode this replaced was
// wrong: the agent's eager set plus whatever this message triggered.
test("mixed reasons in one turn are labelled mixed, and each line keeps its own", () => {
  const c = build()
  c.render({
    type: "skill_activated",
    skills: [{ name: "formato", reason: "eager" }, { name: "presente", reason: "trigger:presente" }]
  })

  assert.equal(label(c), "skills · mixed (2)")
  assert.match(body(c).text, /formato · eager/)
  assert.match(body(c).text, /presente · trigger:presente/)
})

test("it never claims a load_skill call on the context path", () => {
  const c = build()
  c.render({ type: "skill_activated", skills: [{ name: "mapa", reason: "eager" }] })

  assert.doesNotMatch(label(c), /load_skill/)
})

test("a context event whose skills carry no reason still renders instead of vanishing", () => {
  const c = build()
  c.render({ type: "skill_activated", skills: [{ name: "mapa" }] })

  assert.equal(label(c), "skills · context (1)")
  assert.match(body(c).text, /mapa/)
})
