import { Controller } from "@hotwired/stimulus"

// dirty-guard (island polish) — prevents losing unsaved edits. Marks the
// form as "dirty" on the first input/change; if the operator tries to leave (close
// the tab, reload, or navigate via Turbo) with a pending edit, it confirms first.
// Submitting clears the state (the POST/redirect that follows must not trigger the warning).
//
// The code-editor island (CodeMirror) reflects into the <textarea> and dispatches a
// synthetic `input` event — so the form-level listener captures edits in the editor,
// not just in native <input>s.
export default class extends Controller {
  connect() {
    this.dirty = false
    this.markDirty = () => { this.dirty = true }
    this.clear = () => { this.dirty = false }
    this.onBeforeUnload = (e) => {
      if (!this.dirty) return
      e.preventDefault()
      e.returnValue = "" // required by some browsers to show the native prompt
    }
    this.onVisit = (e) => {
      if (this.dirty && !window.confirm("You have unsaved changes. Leave anyway?")) {
        e.preventDefault()
      }
    }

    this.element.addEventListener("input", this.markDirty)
    this.element.addEventListener("change", this.markDirty)
    this.element.addEventListener("submit", this.clear)
    window.addEventListener("beforeunload", this.onBeforeUnload)
    document.addEventListener("turbo:before-visit", this.onVisit)
  }

  disconnect() {
    this.element.removeEventListener("input", this.markDirty)
    this.element.removeEventListener("change", this.markDirty)
    this.element.removeEventListener("submit", this.clear)
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    document.removeEventListener("turbo:before-visit", this.onVisit)
  }
}
