// Entry do bundle do Studio (D8) — esbuild empacota isto + Stimulus + Turbo +
// CodeMirror em assets/dist/application.js (same-origin, CSP 'self'). `ruby serve`
// serve o dist versionado; Node só é preciso para (re)buildar o front.
import { Application } from "@hotwired/stimulus"
import "@hotwired/turbo"

import LiveTranscriptController from "./controllers/live_transcript_controller"
import CodeEditorController from "./controllers/code_editor_controller"

const application = Application.start()
application.register("live-transcript", LiveTranscriptController)
application.register("code-editor", CodeEditorController)

window.Stimulus = application
