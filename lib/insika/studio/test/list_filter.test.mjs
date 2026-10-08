import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import ListFilter from "../assets/src/controllers/list_filter_controller.js"

test("hidden tools override the checkbox label display rule", () => {
  const css = readFileSync(new URL("../assets/src/application.css", import.meta.url), "utf8")
  assert.match(css, /\.tool-grid \.tool-check\[hidden\]\s*\{\s*display:none;/)
})

test("tool filtering opens matches, hides empty groups and preserves selections and collapse state", () => {
  const sql = { dataset: { filterText: "MCP: metabase execute_sql" }, checked: true }
  const http = { dataset: { filterText: "HTTP tools metabase_prod" }, checked: false }
  const groups = [sql, http].map(item => ({ open: false, contains: node => node === item }))
  const c = Object.create(ListFilter.prototype)
  Object.defineProperty(c, "element", { value: { toggleAttribute() {} } })
  Object.assign(c, { hasQueryTarget: true, queryTarget: { value: "EXECUTE_SQL" },
    itemTargets: [sql, http], groupTargets: groups, hasEmptyTarget: true,
    emptyTarget: {}, hasCountTarget: false })
  c.filter()
  assert.equal(groups[0].open, true)
  assert.equal(groups[1].hidden, true)
  assert.equal(sql.checked, true)
  assert.equal(http.checked, false)
  c.queryTarget.value = "missing"
  c.filter()
  assert.equal(c.emptyTarget.hidden, false)
  c.queryTarget.value = "MCP: metabase"
  c.filter()
  assert.equal(sql.hidden, false)
  assert.equal(http.hidden, true)
  c.clear({ key: "Escape" })
  assert.equal(groups[0].open, false)
  assert.equal(groups[1].hidden, false)
  assert.equal(http.hidden, false)
})

test("marks the element as filtering while a query is typed", () => {
  const attrs = new Set()
  const element = { toggleAttribute: (name, on) => (on ? attrs.add(name) : attrs.delete(name)) }
  const c = Object.create(ListFilter.prototype)
  Object.defineProperty(c, "element", { value: element }) // Stimulus exposes element as a getter
  Object.assign(c, { hasQueryTarget: true, queryTarget: { value: "cart" },
    itemTargets: [], groupTargets: [], hasEmptyTarget: false, hasCountTarget: false })
  c.filter()
  assert.equal(attrs.has("data-filtering"), true)
  c.clear({ key: "Escape" })
  assert.equal(attrs.has("data-filtering"), false)
})

test("enabled-only CSS hides unchecked tools unless filtering", () => {
  const css = readFileSync(new URL("../assets/src/application.css", import.meta.url), "utf8")
  assert.match(css, /\.only-on-scope:has\(#only-on:checked\):not\(\[data-filtering\]\) \.tool-check:not\(:has\(input:checked\)\)/)
})
