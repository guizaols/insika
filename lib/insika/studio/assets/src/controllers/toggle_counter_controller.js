import { Controller } from "@hotwired/stimulus"

// toggle-counter — the per-agent tool group. Shows a live `N/N on` counter
// and reflects the group's three states, matching the agent-studio reference:
//   • master "all tools" ON  → allowlist is open (nil); the per-tool grid is moot,
//     so it's dimmed and the counter reads "all".
//   • master OFF             → the counter reads checked/total and the grid is live.
//   • locked (denied) tools  → rendered disabled by the view (deny always wins); they
//     never count toward "on" and can't be toggled.
// A 4th state — every box off ("none") — was already reachable (uncheck "all",
// then every tool by hand) but not a one-click affordance; #selectNone is that
// button's handler. It does not submit — Save tools still does, same as flipping
// checkboxes by hand.
// CSP-friendly: no inline JS. Purely presentational — the checkbox values are what
// the form submits; this only computes the label and the dimmed affordance.
export default class extends Controller {
  static targets = ["all", "tool", "count", "grid"]

  connect() { this.update() }

  // "none" button: closes the open allowlist (if any) and unchecks every
  // unlocked tool. A locked (denied) box has no allow-state to clear, so it is
  // left untouched — same rule #update already applies.
  selectNone() {
    if (this.hasAllTarget) this.allTarget.checked = false
    this.toolTargets.forEach((t) => {
      if (t.dataset.locked !== "true") t.checked = false
    })
    this.update()
  }

  update() {
    const open = this.hasAllTarget && this.allTarget.checked
    const total = this.toolTargets.length
    const on = this.toolTargets.filter((t) => t.checked && !t.disabled).length

    if (this.hasCountTarget) {
      this.countTarget.textContent = open ? "all" : `${on}/${total} on`
    }
    if (this.hasGridTarget) {
      this.gridTarget.classList.toggle("is-open", open)
    }
    // When the allowlist is open, the individual boxes don't decide anything —
    // disable them so the operator isn't misled into thinking a subset applies.
    this.toolTargets.forEach((t) => {
      if (t.dataset.locked === "true") return // locked stays locked regardless
      t.disabled = open
    })
  }
}
