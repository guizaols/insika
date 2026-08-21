// transport-fields — the MCP form's stdio-vs-http field toggle. Same
// discipline as the other controller tests: `node --test` alone, no jsdom.

import { test } from "node:test"
import assert from "node:assert/strict"

const { default: TransportFields } = await import("../assets/src/controllers/transport_fields_controller.js")

function build(value, stdioEls, httpEls) {
  const c = Object.create(TransportFields.prototype)
  c.selectTarget = { value }
  c.stdioTargets = stdioEls
  c.httpTargets = httpEls
  return c
}

test("stdio transport shows the stdio fields and hides the http ones", () => {
  const stdio = [{ hidden: true }]
  const http = [{ hidden: false }]
  build("stdio", stdio, http).sync()
  assert.equal(stdio[0].hidden, false)
  assert.equal(http[0].hidden, true)
})

test("http transport shows the http fields and hides the stdio ones", () => {
  const stdio = [{ hidden: false }]
  const http = [{ hidden: true }]
  build("http", stdio, http).sync()
  assert.equal(stdio[0].hidden, true)
  assert.equal(http[0].hidden, false)
})

test("sse is http-like: same fields as http", () => {
  const stdio = [{ hidden: false }]
  const http = [{ hidden: true }]
  build("sse", stdio, http).sync()
  assert.equal(stdio[0].hidden, true)
  assert.equal(http[0].hidden, false)
})
