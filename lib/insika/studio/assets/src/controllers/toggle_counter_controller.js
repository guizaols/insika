import { Controller } from "@hotwired/stimulus"

// toggle-counter — the per-agent tool group. Shows a live `N/N on` counter
// and reflects the group's three states, matching the agent-studio reference:
//   • master "all tools" ON  → allowlist is open (nil); the per-tool grid is moot,
//     so it's dimmed and the counter reads "all".
//   • master OFF             → the counter reads checked/total and the grid is live.
//   • locked (denied) tools  → rendered disabled by the view (deny always wins); they
//     never count toward "on" and can't be toggled.
// CSP-friendly: no inline JS. Purely presentational — the checkbox values are what
// the form submits; this only computes the label and the dimmed affordance.
export default class extends Controller {
  static targets = ["all", "tool", "count", "grid"]

  connect() { this.update() }

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
