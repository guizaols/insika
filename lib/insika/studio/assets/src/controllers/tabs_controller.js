import { Controller } from "@hotwired/stimulus"

// tabs (agent page subnav → section panels). The hash IS the state: clicking a
// tab link is a plain anchor, the browser sets location.hash, and hashchange
// syncs the panels — so tabs are linkable and back/forward work for free.
// CSP-safe: no inline JS, no click interception.
//
// A click *inside* a panel (pick a prompt file, switch config group) is a
// real Turbo Frame navigation, which reconnects this controller — but Turbo
// rewrites the frame's history URL from the fetch response, which never
// carries a #fragment, so location.hash is gone by the time connect() runs.
// `default` is the server telling us which tab that navigation landed on,
// for exactly that case; an actual hash (a real tab click, or a direct visit
// to a plain #anchor URL) always wins over it.
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { default: String }

  connect() {
    this.sync(this.openId() || this.defaultValue || (this.tabTargets[0] ? this.tabTargets[0].hash.slice(1) : ""))
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
