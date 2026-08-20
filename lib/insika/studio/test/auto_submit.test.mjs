// auto-submit — replaces the inline onchange="this.form.submit()" idiom the
// Studio's CSP (no unsafe-inline) silently blocks. Same discipline as the
// other controller tests: `node --test` alone, no jsdom.

import { test } from "node:test"
import assert from "node:assert/strict"

const { default: AutoSubmit } = await import("../assets/src/controllers/auto_submit_controller.js")

test("submit() calls requestSubmit() on the element's form, not submit()", () => {
  const calls = []
  const form = {
    submit: () => calls.push("submit"), // must NOT be called — fires no `submit` event
    requestSubmit: () => calls.push("requestSubmit")
  }
  const c = Object.create(AutoSubmit.prototype)
  // `element` is a getter-only accessor on Stimulus's Controller base class
  // (Object.create'd instances still see it) — override it like the field
  // it would be at runtime.
  Object.defineProperty(c, "element", { value: { form }, configurable: true })

  c.submit()

  assert.deepEqual(calls, ["requestSubmit"])
})
