import { test } from "node:test"
import assert from "node:assert/strict"
import { step } from "../assets/src/controllers/palette_controller.js"

test("arrow keys wrap around the visible matches", () => {
  assert.equal(step(0, 1, 3), 1)
  assert.equal(step(2, 1, 3), 0)
  assert.equal(step(0, -1, 3), 2)
  assert.equal(step(-1, 1, 3), 1 % 3)
  assert.equal(step(0, 1, 0), -1)
})
