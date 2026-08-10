import { Controller } from "@hotwired/stimulus"

// clipboard (§12 A4) — copy a value to the clipboard with brief inline feedback.
// CSP-safe: the behavior lives in the bundle and is wired via data-action, never
// an inline handler. The text comes either from a static value
// (data-clipboard-text-value) or, when absent, from a source target's
// textContent (data-clipboard-target="source"). The button target
// (data-clipboard-target="button") is the element that flashes "copied!".
export default class extends Controller {
  static targets = ["button", "source"]
  static values = { text: String }

  copy() {
    const text = this.hasTextValue && this.textValue !== ""
      ? this.textValue
      : (this.hasSourceTarget ? this.sourceTarget.textContent : "")
    if (!text) return
    this.write(text).then(() => this.flash("copied!")).catch(() => this.flash("copy failed"))
  }

  // Prefer the async Clipboard API; fall back to a hidden-textarea + execCommand
  // for non-secure contexts (e.g. plain-http local runs) where it is unavailable.
  write(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text)
    }
    return new Promise((resolve, reject) => {
      try {
        const ta = document.createElement("textarea")
        ta.value = text
        ta.setAttribute("readonly", "")
        ta.style.position = "fixed"
        ta.style.left = "-9999px"
        document.body.appendChild(ta)
        ta.select()
        const ok = document.execCommand("copy")
        document.body.removeChild(ta)
        ok ? resolve() : reject(new Error("execCommand copy rejected"))
      } catch (e) { reject(e) }
    })
  }

  flash(label) {
    if (!this.hasButtonTarget) return
    const btn = this.buttonTarget
    if (btn.dataset.copyRestore == null) btn.dataset.copyRestore = btn.textContent
    btn.textContent = label
    btn.classList.add("copied")
    clearTimeout(this._t)
    this._t = setTimeout(() => {
      btn.textContent = btn.dataset.copyRestore
      btn.classList.remove("copied")
    }, 1200)
  }

  disconnect() { clearTimeout(this._t) }
}
