// A save_artifact tool_result is a report, not debugging output — the
// toolcard below is <details> (collapsed by default; {id,url} raw is for
// debugging), so without a visible chip a freshly-generated report is
// invisible in the live transcript unless the operator happens to expand
// the right card. Found live: "gerou o artefato mas não aparece no chat".
//
// Same discipline as the sibling tests: `node --test` alone, no jsdom.

import { test } from "node:test"
import assert from "node:assert/strict"

// Plain mock node: every DOM property the real controller sets on an <a>
// created via document.createElement (className, href, target, rel,
// textContent) is just a writable field here — no accessors needed, nothing
// but plain assignment happens to them in live_transcript_controller.js.
const node = (tag, cls, text) => ({
  tag, cls, text, textContent: text || "", children: [],
  appendChild(child) { this.children.push(child); return child }
})

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

const chip = (c) => c.pushed.find((n) => n.cls === "artifact-chip")
const link = (c) => chip(c).children.find((n) => n.tag === "a")

test("a successful save_artifact result renders a visible, always-open link", () => {
  const c = build()
  c.render({
    type: "tool_result", name: "save_artifact",
    result: { id: "f513ab2a-...", url: "/studio/artifacts/f513ab2a-.../content" }
  })

  assert.ok(chip(c), "expected an artifact-chip element to be pushed")
  assert.equal(link(c).href, "/studio/artifacts/f513ab2a-.../content")
  assert.equal(link(c).textContent, "open artifact")
})

test("a failed save_artifact call (validation error) renders no chip", () => {
  const c = build()
  c.render({ type: "tool_result", name: "save_artifact", result: { error: "content is required" } })

  assert.equal(chip(c), undefined)
})

test("any OTHER tool's result never renders the artifact chip", () => {
  const c = build()
  c.render({ type: "tool_result", name: "metabase_prod", result: { data: { rows: [] } } })

  assert.equal(chip(c), undefined)
})

test("the collapsed raw-result toolcard still renders alongside the chip (debugging stays available)", () => {
  const c = build()
  c.render({
    type: "tool_result", name: "save_artifact",
    result: { id: "f513ab2a-...", url: "/studio/artifacts/f513ab2a-.../content" }
  })

  const card = c.pushed.find((n) => n.cls === "toolcard result")
  assert.ok(card, "expected the usual collapsed tool-result card to still be there")
})
