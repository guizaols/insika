import { Controller } from "@hotwired/stimulus"

// transport-fields — the MCP instance form (RFC-0040 PR4): shows only the
// fields the selected transport actually uses (stdio -> command/args/env,
// http/sse -> url/headers). Pure show/hide — the hidden inputs are not
// disabled, so switching transport and back never loses typed text, and the
// form still submits every field regardless of what's visible (McpStore
// stores them all either way). CSP-safe: no inline JS.
export default class extends Controller {
  static targets = ["select", "stdio", "http"]

  connect() { this.sync() }

  sync() {
    const isStdio = this.selectTarget.value === "stdio"
    this.stdioTargets.forEach((el) => { el.hidden = !isStdio })
    this.httpTargets.forEach((el) => { el.hidden = isStdio })
  }
}
