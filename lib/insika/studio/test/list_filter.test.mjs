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
