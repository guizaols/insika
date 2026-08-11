import { Controller } from "@hotwired/stimulus"

// list-filter — client-side search/filter over any Studio list (agents,
// skills, tools, chats). CSP-friendly: all logic lives here, no inline JS. The
// filtered list is purely presentational — the server already sent every item, we
// only toggle visibility, so there's no request and no state to lose.
//
// Markup contract:
//   <div data-controller="list-filter">
//     <input data-list-filter-target="query" data-action="input->list-filter#filter">
//     <span data-list-filter-target="count"></span>   (optional live count)
//     ...one or more...
//     <X data-list-filter-target="item" data-filter-text="menu calc"> ... </X>
//     <div data-list-filter-target="empty" hidden>No matches</div> (optional)
//   </div>
// `data-filter-text` is the haystack (falls back to the item's textContent).
export default class extends Controller {
  static targets = ["query", "item", "empty", "count"]

  connect() {
    // Reflect any pre-filled value (e.g. browser restore) on first paint.
    this.filter()
  }

  filter() {
    const q = (this.hasQueryTarget ? this.queryTarget.value : "").trim().toLowerCase()
    let shown = 0
    this.itemTargets.forEach((el) => {
      const hay = (el.dataset.filterText || el.textContent || "").toLowerCase()
      const match = q === "" || hay.includes(q)
      el.hidden = !match
      if (match) shown++
    })
    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown !== 0
    if (this.hasCountTarget) {
      const total = this.itemTargets.length
      this.countTarget.textContent = q === "" ? `${total}` : `${shown}/${total}`
    }
  }

  // Esc clears the box (bound in the view via keydown->list-filter#clear).
  clear(event) {
    if (event && event.key && event.key !== "Escape") return
    if (this.hasQueryTarget) this.queryTarget.value = ""
    this.filter()
  }
}
