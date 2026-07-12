import { Controller } from "@hotwired/stimulus"

// theme (island polish, Etapa H) — toggle claro/escuro/auto. O tema é aplicado
// server-side em `<html data-theme>` (lido de um cookie no layout), então NÃO há
// flash de tema errado no load. Este controller só reage ao clique: troca o
// atributo em runtime (sem reload) e persiste o cookie que o servidor relê no
// próximo request. CSP-safe: nada de <script> inline, tudo via data-action.
export default class extends Controller {
  static targets = ["opt"]

  connect() {
    this.sync(this.current())
  }

  set(event) {
    const value = event.params.value
    document.documentElement.dataset.theme = value
    // 1 ano; SameSite=Lax casa com o cookie de sessão. path=/ para valer sob /studio.
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
