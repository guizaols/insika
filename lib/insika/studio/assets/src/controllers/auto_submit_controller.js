import { Controller } from "@hotwired/stimulus"

// auto-submit — a filter <select>/<input> that submits its form on change,
// without an inline `onchange="this.form.submit()"` handler (blocked by the
// Studio's CSP: 'self', no unsafe-inline — inline event-handler attributes
// count as inline script). `requestSubmit()`, not `submit()`: only the
// former fires a real `submit` event, which is what Turbo listens for to
// turn this into a normal Drive visit (URL + history updated) instead of a
// full-page reload.
export default class extends Controller {
  submit() {
    this.element.form.requestSubmit()
  }
}
