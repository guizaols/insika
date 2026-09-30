// model chart + filters — same discipline as the other controller tests: `node --test`
// alone, no jsdom; the DOM seams the controllers touch are plain objects.

import { test } from "node:test"
import assert from "node:assert/strict"

const { default: ModelChart, nearestIndex, tipHtml } = await import("../assets/src/controllers/model_chart_controller.js")
const { default: ModelFilters } = await import("../assets/src/controllers/model_filters_controller.js")

test("nearestIndex maps the pointer to its interval and clamps the edges", () => {
  assert.equal(nearestIndex(0, 600, 24), 0)
  assert.equal(nearestIndex(299, 600, 24), 11)
  assert.equal(nearestIndex(700, 600, 24), 23)
  assert.equal(nearestIndex(-5, 600, 24), 0)
  assert.equal(nearestIndex(10, 600, 0), -1)
})

test("tipHtml escapes every server value", () => {
  const html = tipHtml({ at: "Sep 30 · 02:00 UTC", requests: 3, rows: [{ key: "cost", label: "<b>x</b>", value: "$0.1" }], note: "a & b" })
  assert.match(html, /&lt;b&gt;x&lt;\/b&gt;/)
  assert.match(html, /a &amp; b/)
  assert.match(html, /3 req/)
  assert.equal(tipHtml(undefined), "")
})

function chart(count) {
  const nodes = [0, 1, 2].map((i) => ({ dataset: { index: String(i) }, on: false, classList: { toggle(_n, on) { nodes[i].on = on } } }))
  const cursor = { attrs: {}, on: false, setAttribute(k, v) { this.attrs[k] = v }, classList: { add() { cursor.on = true }, remove() { cursor.on = false } } }
  const tip = { hidden: true, innerHTML: "", style: {}, flipped: false, classList: { toggle(_n, on) { tip.flipped = on } } }
  const c = Object.create(ModelChart.prototype)
  Object.defineProperties(c, {
    cursorTarget: { value: cursor }, tipTarget: { value: tip },
    tipsValue: { value: Array.from({ length: count }, (_, i) => ({ at: `t${i}`, requests: i, rows: [] })) },
    countValue: { value: count }, element: { value: { querySelectorAll: () => nodes } }
  })
  return { c, nodes, cursor, tip }
}

test("show places the cursor, fills the tip and marks only that interval; hide clears it", () => {
  const { c, nodes, cursor, tip } = chart(3)
  c.show(2)
  assert.equal(cursor.attrs.x1, (2.5 / 3) * 600)
  assert.equal(tip.hidden, false)
  assert.match(tip.innerHTML, /t2/)
  assert.equal(tip.flipped, true) // right edge: the tip opens to the left
  assert.deepEqual(nodes.map((n) => n.on), [false, false, true])
  c.hide()
  assert.equal(tip.hidden, true)
  assert.equal(cursor.on, false)
  assert.deepEqual(nodes.map((n) => n.on), [false, false, false])
})

test("filters: two dates mean a custom range; a fixed period drops the dates", () => {
  const period = { value: "7d" }
  const dates = [{ value: "2026-09-01", focus() {} }, { value: "" , focus() {} }]
  const f = Object.create(ModelFilters.prototype)
  Object.defineProperties(f, { periodTarget: { value: period }, dateTargets: { value: dates } })
  f.pickDate()
  assert.equal(period.value, "7d") // one date is not a range yet
  dates[1].value = "2026-09-15"
  f.pickDate()
  assert.equal(period.value, "custom")
  period.value = "24h"
  f.pickPeriod()
  assert.deepEqual(dates.map((d) => d.value), ["", ""])
})
