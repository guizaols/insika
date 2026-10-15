import { Controller } from "@hotwired/stimulus"

// palette — the ⌘K / Ctrl+K jump box. The server renders every destination
// (pages, agents) into a <dialog>; `list-filter` on the same element does the
// matching, this controller only opens it and moves the highlight. Enter
// follows the highlighted link, so Turbo handles the visit like any click.
export const step = (current, delta, length) =>
  length === 0 ? -1 : (Math.max(current, 0) + delta + length) % length

export default class extends Controller {
  static targets = ["dialog", "query", "item"]

  connect() {
    this.onKey = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault()
        this.open()
      }
    }
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
  }

  open() {
    if (this.dialogTarget.open) return
    this.queryTarget.value = ""
    this.queryTarget.dispatchEvent(new Event("input"))
    this.dialogTarget.showModal()
    this.queryTarget.focus()
    this.highlight(0)
  }

  close() {
    this.dialogTarget.close()
  }

  // input event: the list just re-filtered, start from the first match.
  reset() {
    this.highlight(0)
  }

  key(event) {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      this.highlight(step(this.index, event.key === "ArrowDown" ? 1 : -1, this.visible().length))
    } else if (event.key === "Enter") {
      const link = this.visible()[this.index]
      if (link) {
        event.preventDefault()
        this.close()
        link.click()
      }
    }
  }

  visible() {
    return this.itemTargets.filter((el) => !el.hidden)
  }

  highlight(i) {
    const list = this.visible()
    this.index = list.length ? Math.min(i, list.length - 1) : -1
    this.itemTargets.forEach((el) => el.removeAttribute("aria-selected"))
    const el = list[this.index]
    if (el) {
      el.setAttribute("aria-selected", "true")
      el.scrollIntoView({ block: "nearest" })
    }
  }
}
