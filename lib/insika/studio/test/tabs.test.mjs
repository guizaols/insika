// tabs (agent page) — the hash is the state. Same discipline as the other
// controller tests: `node --test` alone, no jsdom. The DOM seams the controller
// touches (location.hash, classList.toggle, hidden, setAttribute,
// window.addEventListener) are stubbed with plain objects.
//
// The contract under test: exactly one panel is visible; the matching tab
// carries .on + aria-current; a foreign hash hides nothing; hashchange syncs.

import { test } from "node:test"
import assert from "node:assert/strict"

const mk = (id) => {
  const n = {
    id, hash: "#" + id, hidden: null, aria: null, classes: new Set(),
    setAttribute(k, v) { this.aria = v }
  }
  n.classList = { toggle: (name, on) => (on ? n.classes.add(name) : n.classes.delete(name)) }
  return n
}

let handlers = {}
globalThis.location = { hash: "" }
globalThis.window = {
  addEventListener: (ev, fn) => { handlers[ev] = fn },
  removeEventListener: (ev) => { delete handlers[ev] }
}

const { default: Tabs } = await import("../assets/src/controllers/tabs_controller.js")

function build(panels, tabs) {
  const c = Object.create(Tabs.prototype)
  c.panelTargets = panels
  c.tabTargets = tabs
  // Class fields don't run on Object.create'd prototypes — provide the
  // handler the same way the field would (arrow bound to the instance).
  c.onHash = () => c.sync(c.openId())
  return c
}

test("the first tab is open when the hash names nothing", () => {
  const a = mk("config"), b = mk("prompts")
  const c = build([a, b], [a, b])
  c.connect()
  assert.equal(a.hidden, false)
  assert.equal(b.hidden, true)
  assert.ok(a.classes.has("on") && a.aria === "page")
  assert.equal(b.aria, "false")
  c.disconnect()
})

test("a hash that names a panel opens exactly that panel", () => {
  globalThis.location.hash = "#skills"
  const a = mk("config"), b = mk("skills")
  const c = build([a, b], [a, b])
  c.connect()
  assert.equal(a.hidden, true)
  assert.equal(b.hidden, false)
  c.disconnect()
})

test("a foreign hash hides nothing — the first tab stays open", () => {
  globalThis.location.hash = "#somewhere-else"
  const a = mk("config"), b = mk("prompts")
  const c = build([a, b], [a, b])
  c.connect()
  assert.equal(a.hidden, false)
  assert.equal(b.hidden, true)
  c.disconnect()
})

test("hashchange re-syncs the panels (back/forward work for free)", () => {
  globalThis.location.hash = "#config"
  const a = mk("config"), b = mk("prompts")
  const c = build([a, b], [a, b])
  c.connect()
  globalThis.location.hash = "#prompts"
  handlers.hashchange()
  assert.equal(a.hidden, true)
  assert.equal(b.hidden, false)
  assert.ok(b.classes.has("on"))
  c.disconnect()
  assert.equal(handlers.hashchange, undefined) // listener removed
})
