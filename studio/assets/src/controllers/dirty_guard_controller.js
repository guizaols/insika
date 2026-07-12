import { Controller } from "@hotwired/stimulus"

// dirty-guard (island polish, Etapa H) — evita perder edição não salva. Marca o
// form como "sujo" ao primeiro input/change; se o operador tentar sair (fechar
// aba, recarregar ou navegar via Turbo) com edição pendente, confirma antes.
// O submit limpa o estado (o POST/redirect que segue não deve disparar o aviso).
//
// O island code-editor (CodeMirror) reflete no <textarea> e dispara um evento
// `input` sintético — por isso o listener no nível do form captura edições no
// editor, não só nos <input> nativos.
export default class extends Controller {
  connect() {
    this.dirty = false
    this.markDirty = () => { this.dirty = true }
    this.clear = () => { this.dirty = false }
    this.onBeforeUnload = (e) => {
      if (!this.dirty) return
      e.preventDefault()
      e.returnValue = "" // exigido por alguns navegadores para mostrar o prompt nativo
    }
    this.onVisit = (e) => {
      if (this.dirty && !window.confirm("Há alterações não salvas. Sair mesmo assim?")) {
        e.preventDefault()
      }
    }

    this.element.addEventListener("input", this.markDirty)
    this.element.addEventListener("change", this.markDirty)
    this.element.addEventListener("submit", this.clear)
    window.addEventListener("beforeunload", this.onBeforeUnload)
    document.addEventListener("turbo:before-visit", this.onVisit)
  }

  disconnect() {
    this.element.removeEventListener("input", this.markDirty)
    this.element.removeEventListener("change", this.markDirty)
    this.element.removeEventListener("submit", this.clear)
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    document.removeEventListener("turbo:before-visit", this.onVisit)
  }
}
