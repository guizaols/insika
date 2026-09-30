import { Controller } from "@hotwired/stimulus"

// Models toolbar: the date fields show only for "Custom range" (CSS :has), and
// the two stay consistent — filling both dates means a custom range, choosing a
// fixed period drops the dates (the server ignores them then anyway).
export default class extends Controller {
  static targets = ["period", "date"]

  pickDate() {
    if (this.dateTargets.every((d) => d.value)) this.periodTarget.value = "custom"
  }

  pickPeriod() {
    if (this.periodTarget.value === "custom") return this.dateTargets[0]?.focus()
    this.dateTargets.forEach((d) => { d.value = "" })
  }
}
