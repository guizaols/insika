// toggle-counter — the tools matrix's "all/none/mixed" affordance. Same
// discipline as the other controller tests: `node --test` alone, no jsdom.

import { test } from "node:test"
import assert from "node:assert/strict"

const { default: ToggleCounter } = await import("../assets/src/controllers/toggle_counter_controller.js")

const mkTool = (checked, locked = false) => ({ checked, disabled: locked, dataset: { locked: String(locked) } })

function build(all, tools) {
  const c = Object.create(ToggleCounter.prototype)
  c.hasAllTarget = !!all
  c.allTarget = all || {}
  c.toolTargets = tools
  c.hasCountTarget = true
  c.countTarget = { textContent: "" }
  c.hasGridTarget = true
  c.gridTarget = { classList: { toggle: () => {} } }
  return c
}

test("selectNone unchecks every unlocked tool and the all-switch", () => {
  const all = { checked: true }
  const a = mkTool(true), b = mkTool(true)
  const c = build(all, [a, b])
  c.selectNone()
  assert.equal(all.checked, false)
  assert.equal(a.checked, false)
  assert.equal(b.checked, false)
  assert.equal(c.countTarget.textContent, "0/2 on")
})

test("selectNone leaves a locked (denied) tool's checked state untouched", () => {
  const all = { checked: false }
  const open = mkTool(true)
  const locked = mkTool(false, true)
  const c = build(all, [open, locked])
  c.selectNone()
  assert.equal(open.checked, false)
  assert.equal(locked.checked, false) // was already false — untouched either way
  assert.equal(locked.disabled, true) // deny still wins, still disabled
})

test("update() reports \"none\" state as 0/total, not \"all\"", () => {
  const all = { checked: false }
  const a = mkTool(false), b = mkTool(false)
  const c = build(all, [a, b])
  c.update()
  assert.equal(c.countTarget.textContent, "0/2 on")
})

test("section actions preserve other sections and locked tools, including filtered tools", () => {
  const all = { checked: true }
  const a = mkTool(true), hidden = mkTool(true), locked = mkTool(false, true), other = mkTool(true)
  const section = [a, hidden, locked]
  const c = build(all, [...section, other])
  c.update()
  const button = { dataset: { checked: "false" }, closest: () => ({ contains: t => section.includes(t) }) }
  c.selectSection({ currentTarget: button })
  assert.equal(all.checked, false)
  assert.equal(a.checked, false)
  assert.equal(hidden.checked, false)
  assert.equal(other.checked, true)
  assert.equal(c.countTarget.textContent, "1/4 on")
  button.dataset.checked = "true"
  c.selectSection({ currentTarget: button })
  assert.equal(a.checked, true)
  assert.equal(hidden.checked, true)
  assert.equal(locked.checked, false)
  assert.equal(locked.disabled, true)
  assert.equal(other.checked, true)
  assert.equal(c.countTarget.textContent, "3/4 on")
})
