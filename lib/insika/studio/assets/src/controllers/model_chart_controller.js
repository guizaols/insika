import { Controller } from "@hotwired/stimulus"

// Hover/focus layer over a server-rendered model chart (views/_model_chart.erb):
// a cursor line on the interval under the pointer, its values in a tooltip, its
// points highlighted. The SVG and the exact-values table stay the source of
// truth; this only reads `data-index` and the tips the server already formatted.

const escape = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c])

// The interval under the pointer: -1 when there is nothing to point at.
export const nearestIndex = (offsetX, width, count) =>
  count > 0 && width > 0 ? Math.min(count - 1, Math.max(0, Math.floor((offsetX / width) * count))) : -1

export function tipHtml(tip) {
  if (!tip) return ""
  const rows = (tip.rows || []).map((r) =>
    `<div class="model-tip-row"><i class="dot ${escape(r.key)}"></i><span>${escape(r.label)}</span><b>${escape(r.value)}</b></div>`).join("")
  const note = tip.note ? `<div class="model-tip-note">${escape(tip.note)}</div>` : ""
  const count = tip.requests == null ? "" : `<span>${escape(tip.requests)} req</span>`
  return `<div class="model-tip-head">${escape(tip.at)}${count}</div>${rows}${note}`
}

export default class extends Controller {
  static targets = ["body", "cursor", "tip"]
  static values = { tips: Array, count: Number }

  track(event) {
    const rect = this.bodyTarget.getBoundingClientRect()
    this.show(nearestIndex(event.clientX - rect.left, rect.width, this.countValue))
  }

  // Keyboard: a focused bar/point opens its own interval.
  focus(event) {
    const i = Number(event.target?.dataset?.index)
    if (Number.isInteger(i)) this.show(i)
  }

  hide() {
    this.index = -1
    this.tipTarget.hidden = true
    this.cursorTarget.classList.remove("on")
    this.mark(-1)
  }

  show(i) {
    if (i < 0 || i === this.index || !this.tipsValue[i]) return
    this.index = i
    const share = (i + 0.5) / this.countValue
    this.cursorTarget.setAttribute("x1", share * 600)
    this.cursorTarget.setAttribute("x2", share * 600)
    this.cursorTarget.classList.add("on")
    this.tipTarget.innerHTML = tipHtml(this.tipsValue[i])
    this.tipTarget.style.left = `${share * 100}%`
    this.tipTarget.classList.toggle("flip", share > 0.6)
    this.tipTarget.hidden = false
    this.mark(i)
  }

  mark(i) {
    this.element.querySelectorAll("[data-index]").forEach((node) => node.classList.toggle("is-active", Number(node.dataset.index) === i))
  }
}
