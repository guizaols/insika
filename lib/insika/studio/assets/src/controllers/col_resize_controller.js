import { Controller } from "@hotwired/stimulus"

// col-resize — a drag handle between two miller columns. It resizes the pane
// on one side of it (`side`: "prev", the default, or "next") by setting that
// pane's --pane-w, which the CSS reads as its flex-basis. The width is a
// per-viewer convenience, so it lives in localStorage under `key`; storage
// failing (private window, blocked) just means the default width.
const MIN = 200
const STEP = 16

export default class extends Controller {
  static values = { key: String, side: { type: String, default: "prev" } }

  connect() {
    const saved = Number(read(this.storageKey))
    if (saved) this.apply(saved)
  }

  start(event) {
    if (event.button !== 0) return
    event.preventDefault()
    const startX = event.clientX
    const startW = this.pane.getBoundingClientRect().width
    const sign = this.sideValue === "next" ? -1 : 1
    const move = (e) => this.apply(startW + sign * (e.clientX - startX))
    const up = () => {
      window.removeEventListener("pointermove", move)
      window.removeEventListener("pointerup", up)
      document.body.classList.remove("col-resizing")
      this.save()
    }
    document.body.classList.add("col-resizing")
    window.addEventListener("pointermove", move)
    window.addEventListener("pointerup", up)
  }

  key(event) {
    const dir = { ArrowLeft: -1, ArrowRight: 1 }[event.key]
    if (!dir) return
    event.preventDefault()
    const sign = this.sideValue === "next" ? -1 : 1
    this.apply(this.pane.getBoundingClientRect().width + dir * sign * STEP)
    this.save()
  }

  reset() {
    this.pane.style.removeProperty("--pane-w")
    write(this.storageKey, null)
  }

  apply(width) {
    const max = Math.max(MIN, (this.element.parentElement?.getBoundingClientRect().width || 0) * 0.6)
    this.width = Math.round(Math.min(max, Math.max(MIN, width)))
    this.pane.style.setProperty("--pane-w", `${this.width}px`)
  }

  save() {
    if (this.width) write(this.storageKey, String(this.width))
  }

  get pane() {
    return this.sideValue === "next" ? this.element.nextElementSibling : this.element.previousElementSibling
  }

  get storageKey() {
    return `insika.col.${this.keyValue}`
  }
}

function read(key) {
  try { return localStorage.getItem(key) } catch { return null }
}

function write(key, value) {
  try {
    if (value === null) localStorage.removeItem(key)
    else localStorage.setItem(key, value)
  } catch { /* storage blocked: the width just isn't remembered */ }
}
