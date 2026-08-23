import { Controller } from "@hotwired/stimulus"

// active-link — keeps the "active" class on a master list in sync with which
// row was last clicked. Rows navigate a nested turbo-frame (agent-detail,
// mcp-detail) so the frame's scroll/filter state survives the click — which
// means the server only re-renders the frame, never this list, so the
// server-rendered "active" class would otherwise stay stuck on whichever row
// was current when the page last fully loaded. Toggling it here on click
// keeps it correct without re-rendering (and losing scroll on) the list.
//
// Markup contract:
//   <div data-controller="active-link">
//     <a class="drill-item" data-active-link-target="item"
//        data-action="click->active-link#select"> ... </a>
//   </div>
export default class extends Controller {
  static targets = ["item"]

  select(event) {
    const link = event.currentTarget
    this.itemTargets.forEach((el) => el.classList.toggle("active", el === link))
  }
}
