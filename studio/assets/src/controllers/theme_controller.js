import { Controller } from "@hotwired/stimulus"

// theme (island polish, Stage H) — light/dark/auto toggle. The theme is applied
// server-side on `<html data-theme>` (read from a cookie in the layout), so there is
// NO wrong-theme flash on load. This controller only reacts to the click: it swaps the
// attribute at runtime (no reload) and persists the cookie that the server re-reads on
// the next request. CSP-safe: no inline <script>, everything via data-action.
export default class extends Controller {
  static targets = ["opt"]

  connect() {
    this.sync(this.current())
  }

  set(event) {
    const value = event.params.value
    document.documentElement.dataset.theme = value
    // 1 year; SameSite=Lax matches the session cookie. path=/ so it applies under /studio.
    document.cookie = `harness.theme=${value}; path=/; max-age=${60 * 60 * 24 * 365}; samesite=lax`
    this.sync(value)
  }

  current() {
    return document.documentElement.dataset.theme || "auto"
  }

  sync(value) {
    this.optTargets.forEach((b) => {
      const on = b.dataset.themeValueParam === value
      b.classList.toggle("on", on)
      b.setAttribute("aria-pressed", on ? "true" : "false")
    })
  }
}
