// agent-picker — the type-to-search combobox behind _agent_picker.erb. Same
// discipline as the other controller tests: `node --test` alone, no jsdom.

import { test } from "node:test"
import assert from "node:assert/strict"

const { default: AgentPicker } = await import("../assets/src/controllers/agent_picker_controller.js")

const option = (value) => {
  const attrs = {}
  const classes = new Set()
  return {
    dataset: { value }, id: `opt-${value || "all"}`, hidden: false,
    setAttribute: (k, v) => { attrs[k] = v }, attrs,
    classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c) }, classes
  }
}

function picker({ value = "", autoSubmit = false } = {}) {
  const submits = []
  const events = []
  const input = {
    value, attrs: {},
    setAttribute(k, v) { this.attrs[k] = v },
    removeAttribute(k) { delete this.attrs[k] },
    dispatchEvent: (e) => events.push(e.type),
    form: { requestSubmit: () => submits.push("requestSubmit") }
  }
  const options = ["", "agent-store-heineken", "agent-store-supersul", "demo"].map(option)
  const c = Object.create(AgentPicker.prototype)
  Object.defineProperty(c, "element", { value: { contains: () => false } })
  Object.assign(c, { inputTarget: input, listTarget: { hidden: true }, optionTargets: options,
    hasEmptyTarget: true, emptyTarget: { hidden: true }, autoSubmitValue: autoSubmit })
  return { c, input, options, submits, events }
}

test("focus lists every agent even when a value is already picked", () => {
  const { c, options } = picker({ value: "demo" })
  c.open()
  assert.equal(options.every((o) => !o.hidden), true)
  assert.equal(options[3].attrs["aria-selected"], "true")
})

test("typing filters by substring and hides the all row", () => {
  const { c, input, options } = picker()
  input.value = "SUPER"
  c.type()
  assert.deepEqual(options.filter((o) => !o.hidden).map((o) => o.dataset.value), ["agent-store-supersul"])
  input.value = "nothing"
  c.type()
  assert.equal(c.emptyTarget.hidden, false)
})

test("arrows move the active option and Enter picks it without submitting the typed text", () => {
  const { c, input, events, submits } = picker()
  input.value = "store"
  c.type()
  const key = (k) => { let prevented = false; c.key({ key: k, preventDefault: () => { prevented = true } }); return prevented }
  key("ArrowDown"); key("ArrowDown")
  assert.equal(key("Enter"), true)
  assert.equal(input.value, "agent-store-supersul")
  assert.equal(c.listTarget.hidden, true)
  assert.deepEqual(events, ["change"])
  assert.deepEqual(submits, [])
})

test("auto-submit filters submit on pick and on clearing the box", () => {
  const { c, input, options, submits } = picker({ value: "demo", autoSubmit: true })
  c.pick(options[1])
  assert.equal(input.value, "agent-store-heineken")
  input.value = ""
  c.cleared()
  assert.deepEqual(submits, ["requestSubmit", "requestSubmit"])
})

test("Enter with no active option is left to the form", () => {
  const { c } = picker()
  c.open()
  let prevented = false
  c.key({ key: "Enter", preventDefault: () => { prevented = true } })
  assert.equal(prevented, false)
})
