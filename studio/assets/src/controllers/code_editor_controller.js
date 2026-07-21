import { Controller } from "@hotwired/stimulus"
import { EditorView, keymap, lineNumbers } from "@codemirror/view"
import { EditorState } from "@codemirror/state"
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands"
import { syntaxHighlighting, defaultHighlightStyle } from "@codemirror/language"
import { markdown } from "@codemirror/lang-markdown"
import { json } from "@codemirror/lang-json"
import { renderMarkdown } from "../markdown"

// code-editor (island D9) — wraps CodeMirror 6 over a <textarea> (which stays the
// field the form submits; the editor only mirrors into it). Bundled through esbuild;
// CodeMirror injects its styles via adoptedStyleSheets (constructable stylesheets),
// which are NOT subject to the strict `style-src 'self'` CSP — so no unsafe-inline.
//
// §3.2 additions: markdown syntax highlighting, Cmd/Ctrl+S to save (submits the
// closest form), and — when `data-code-editor-preview-value="true"` — an
// Edit/Preview toggle that renders the markdown with a tiny dependency-free renderer.
export default class extends Controller {
  static targets = ["source"]
  static values = {
    language: { type: String, default: "markdown" },
    preview: { type: Boolean, default: false }
  }

  connect() {
    if (!this.hasSourceTarget) return
    const textarea = this.sourceTarget
    // Defensive: a stale Turbo snapshot may still carry CodeMirror's generated
    // DOM (editor, toolbar, preview) from before it was cached. Strip it so we
    // always mount from the pristine <textarea> — never double-mount.
    this.cleanupDom()
    textarea.style.display = "none"

    // CodeMirror (style-mod) injects a <style> for its base theme + syntax highlight.
    // Under the strict `style-src 'self'` CSP that <style> is blocked unless it carries
    // the per-request nonce the server put on both the header and this meta tag.
    const nonce = document.querySelector('meta[name="csp-nonce"]')?.content || ""

    const isMarkdown = this.languageValue !== "json"
    const lang = isMarkdown ? markdown() : json()

    // Cmd/Ctrl+S saves without leaving the keyboard — the reference's editor UX.
    const saveKeymap = keymap.of([{
      key: "Mod-s",
      preventDefault: true,
      run: () => { this.save(); return true }
    }])

    const view = new EditorView({
      state: EditorState.create({
        doc: textarea.value,
        extensions: [
          EditorView.cspNonce.of(nonce),
          lineNumbers(),
          history(),
          saveKeymap,
          keymap.of([...defaultKeymap, ...historyKeymap]),
          lang,
          syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
          EditorView.lineWrapping,
          EditorView.updateListener.of((u) => {
            if (!u.docChanged) return
            textarea.value = view.state.doc.toString()
            // Reflect the edit as a real input event: the dirty-guard island (on the
            // form) relies on it to detect unsaved changes made inside the editor.
            textarea.dispatchEvent(new Event("input", { bubbles: true }))
          })
        ]
      }),
      parent: this.element
    })
    this.view = view

    if (this.previewValue && isMarkdown) this.mountPreview()

    // Turbo Drive snapshots the DOM on navigation and restores it on the way
    // back. If CodeMirror's generated DOM is left in place, the restored snapshot
    // double-mounts / renders broken until a hard reload. Tear back down to the
    // pristine <textarea> right before Turbo caches — so both the snapshot and
    // the next connect() start clean.
    this.beforeCache = () => this.teardown()
    document.addEventListener("turbo:before-cache", this.beforeCache)
  }

  // Edit/Preview toggle: a non-submitting toolbar button + a rendered pane. The
  // editor and the pane never show at once; toggling re-renders from the live doc.
  mountPreview() {
    const bar = document.createElement("div")
    bar.className = "editor-toolbar"
    const toggle = document.createElement("button")
    toggle.type = "button"
    toggle.className = "btn ghost editor-toggle"
    toggle.textContent = "Preview"
    bar.appendChild(toggle)
    this.element.prepend(bar)

    const pane = document.createElement("div")
    pane.className = "markdown-preview"
    pane.hidden = true
    this.element.appendChild(pane)

    this.toolbar = bar
    this.pane = pane
    this.editorDom = this.view.dom
    toggle.addEventListener("click", () => {
      const showPreview = pane.hidden
      if (showPreview) pane.innerHTML = renderMarkdown(this.view.state.doc.toString())
      pane.hidden = !showPreview
      this.editorDom.hidden = showPreview
      toggle.textContent = showPreview ? "Edit" : "Preview"
      toggle.classList.toggle("is-active", showPreview)
    })
  }

  // Push the editor's content to the textarea and submit the owning form.
  save() {
    if (this.view) this.sourceTarget.value = this.view.state.doc.toString()
    const form = this.element.closest("form")
    if (form) form.requestSubmit ? form.requestSubmit() : form.submit()
  }

  // Restore the pristine DOM (destroy CodeMirror, drop the toolbar/preview, show
  // the textarea). Idempotent — safe to call from before-cache and disconnect.
  teardown() {
    if (this.view) { this.view.destroy(); this.view = null }
    this.cleanupDom()
    if (this.hasSourceTarget) this.sourceTarget.style.display = ""
  }

  // Remove any CodeMirror-generated siblings (editor dom, toolbar, preview pane),
  // whether from this instance or a restored Turbo snapshot.
  cleanupDom() {
    if (this.toolbar) { this.toolbar.remove(); this.toolbar = null }
    if (this.pane) { this.pane.remove(); this.pane = null }
    this.element.querySelectorAll(":scope > .cm-editor, :scope > .editor-toolbar, :scope > .markdown-preview")
      .forEach((n) => n.remove())
  }

  disconnect() {
    if (this.beforeCache) { document.removeEventListener("turbo:before-cache", this.beforeCache); this.beforeCache = null }
    this.teardown()
  }
}
