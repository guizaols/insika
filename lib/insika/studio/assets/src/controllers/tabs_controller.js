import { Controller } from "@hotwired/stimulus"

// tabs (agent page subnav → section panels). The hash IS the state: clicking a
// tab link is a plain anchor, the browser sets location.hash, and hashchange
// syncs the panels — so tabs are linkable and back/forward work for free.
// CSP-safe: no inline JS, no click interception.
export default class extends Controller {
  static targets = ["tab", "panel"]

  connect() {
    this.sync(this.openId() || (this.tabTargets[0] ? this.tabTargets[0].hash.slice(1) : ""))
    window.addEventListener("hashchange", this.onHash)
  }

  disconnect() {
    window.removeEventListener("hashchange", this.onHash)
  }

  onHash = () => this.sync(this.openId())

  // The current hash only counts when it names one of the panels (a stray
  // #anchor from elsewhere must not hide every section).
  openId() {
    const h = location.hash.slice(1)
    return this.panelTargets.some((p) => p.id === h) ? h : null
  }

  sync(id) {
    this.panelTargets.forEach((p) => { p.hidden = p.id !== id })
    this.tabTargets.forEach((t) => {
      const on = t.hash.slice(1) === id
      t.classList.toggle("on", on)
      t.setAttribute("aria-current", on ? "page" : "false")
    })
  }
}
