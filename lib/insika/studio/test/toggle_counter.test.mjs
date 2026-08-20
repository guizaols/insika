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
