// col-resize — drag handle between miller columns. `node --test` alone, no jsdom.

import { test } from "node:test"
import assert from "node:assert/strict"

const { default: ColResize } = await import("../assets/src/controllers/col_resize_controller.js")

function build(side, parentWidth = 1000) {
  const props = {}
  const pane = { style: { setProperty: (k, v) => (props[k] = v), removeProperty: (k) => delete props[k] } }
  const element = {
    parentElement: { getBoundingClientRect: () => ({ width: parentWidth }) },
    previousElementSibling: side === "prev" ? pane : null,
    nextElementSibling: side === "next" ? pane : null
  }
  const c = Object.create(ColResize.prototype)
  Object.defineProperty(c, "element", { value: element, configurable: true })
  Object.defineProperty(c, "sideValue", { value: side, configurable: true })
  return { c, props }
}

test("apply() clamps the width between 200px and 60% of the row", () => {
  const { c, props } = build("prev")
  c.apply(50)
  assert.equal(props["--pane-w"], "200px")
  c.apply(900)
  assert.equal(props["--pane-w"], "600px")
  c.apply(333.4)
  assert.equal(props["--pane-w"], "333px")
})

test("the handle resizes the pane on its configured side", () => {
  assert.ok(build("prev").c.pane)
  assert.ok(build("next").c.pane)
  assert.notEqual(build("next").c.pane, build("next").c.element.previousElementSibling)
})
