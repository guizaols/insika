import { Controller } from "@hotwired/stimulus"
import { renderMarkdown } from "../markdown.js"

// markdown — renders a server-emitted plain-text bubble as Markdown once
// on connect. The source is the element's textContent (ERB already escaped it into
// the DOM); markdown.js re-escapes every fragment before applying markup, so the
// re-render is safe under the strict CSP ('self', no inline). The live-transcript
// controller renders its own streaming bubbles directly — this is only for the
// server-rendered history/echo bubbles.
export default class extends Controller {
  connect() {
    this.element.innerHTML = renderMarkdown(this.element.textContent)
  }
}
