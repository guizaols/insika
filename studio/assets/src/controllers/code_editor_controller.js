import { Controller } from "@hotwired/stimulus"
import { EditorView, keymap, lineNumbers } from "@codemirror/view"
import { EditorState } from "@codemirror/state"
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands"
import { markdown } from "@codemirror/lang-markdown"
import { json } from "@codemirror/lang-json"

// code-editor (island D9) — embrulha o CodeMirror 6 sobre um <textarea> (que
// continua sendo o campo submetido no form; o editor só espelha nele). O bundle
// do CodeMirror entra pelo pipeline esbuild (D8/task 13); a PÁGINA que usa este
// island (autoria de prompts/skills) chega na Etapa F — aqui ele já existe e é
// empacotado para provar que a pipeline lida com o editor.
export default class extends Controller {
  static targets = ["source"]
  static values = { language: { type: String, default: "markdown" } }

  connect() {
    if (!this.hasSourceTarget) return
    const textarea = this.sourceTarget
    textarea.style.display = "none"

    const lang = this.languageValue === "json" ? json() : markdown()
    const view = new EditorView({
      state: EditorState.create({
        doc: textarea.value,
        extensions: [
          lineNumbers(),
          history(),
          keymap.of([...defaultKeymap, ...historyKeymap]),
          lang,
          EditorView.lineWrapping,
          EditorView.updateListener.of((u) => {
            if (!u.docChanged) return
            textarea.value = view.state.doc.toString()
            // Reflete a edição como um input real: o island dirty-guard (no form)
            // depende deste evento para detectar mudança não salva no editor.
            textarea.dispatchEvent(new Event("input", { bubbles: true }))
          })
        ]
      }),
      parent: this.element
    })
    this.view = view
  }

  disconnect() {
    if (this.view) { this.view.destroy(); this.view = null }
  }
}
