// live-floor: the pure event → card-state fold and the ticker label. The DOM
// half (paint/newCard/pushTicker) only writes what these return.

import { test } from "node:test"
import assert from "node:assert/strict"

const { cardState, tickerLabel } = await import("../assets/src/controllers/live_floor_controller.js")

const fold = (events) => events.reduce((s, ev) => cardState(s, ev, 1), undefined)

test("a turn writes until its terminal, collecting this turn's tools", () => {
  const running = fold([{ type: "task_started" }, { type: "tool_call", name: "menu" }, { type: "intermediate" }])
  assert.equal(running.writing, true)
  assert.deepEqual(running.tools, ["menu"])

  const done = cardState(running, { type: "task_completed" }, 2)
  assert.equal(done.writing, false)
  assert.deepEqual(done.tools, ["menu"]) // the last turn's tools stay visible
  assert.equal(done.at, 2)
})

test("a new turn clears the tools; only the last three are shown", () => {
  const s = fold([{ type: "tool_call", name: "a" }, { type: "tool_call", name: "b" },
    { type: "tool_call", name: "c" }, { type: "tool_call", name: "d" }])
  assert.deepEqual(s.tools, ["b", "c", "d"])
  assert.deepEqual(cardState(s, { type: "task_started" }).tools, [])
})

test("a guardrail flag sticks past the end of the turn", () => {
  const s = fold([{ type: "task_started" }, { type: "guardrail_flagged", category: "pii" }, { type: "task_failed" }])
  assert.equal(s.flagged, true)
  assert.equal(s.writing, false)
  assert.equal(fold([{ type: "guardrail_blocked" }]).flagged, true)
})

test("unknown types only stamp the time", () => {
  const s = cardState({ writing: true, tools: ["x"], flagged: false, at: 0 }, { type: "session_created" }, 5)
  assert.deepEqual(s, { writing: true, tools: ["x"], flagged: false, at: 5 })
})

test("ticker: type plus tool name or guardrail category; deltas stay out", () => {
  assert.equal(tickerLabel({ type: "tool_call", name: "menu" }), "tool_call · menu")
  assert.equal(tickerLabel({ type: "guardrail_flagged", category: "pii" }), "guardrail_flagged · pii")
  assert.equal(tickerLabel({ type: "task_completed" }), "task_completed")
  assert.equal(tickerLabel({ type: "intermediate", delta: "oi" }), null)
  assert.equal(tickerLabel({ type: "llm_usage" }), null)
})
