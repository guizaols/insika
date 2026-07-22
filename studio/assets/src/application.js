// Studio bundle entry (D8) — esbuild packages this + Stimulus + Turbo +
// CodeMirror into assets/dist/application.js (same-origin, CSP 'self'). `ruby serve`
// serves the checked-in dist; Node is only needed to (re)build the front-end.
import { Application } from "@hotwired/stimulus"
import "@hotwired/turbo"

import LiveTranscriptController from "./controllers/live_transcript_controller"
import ClipboardController from "./controllers/clipboard_controller"
import MarkdownController from "./controllers/markdown_controller"
import CodeEditorController from "./controllers/code_editor_controller"
import DirtyGuardController from "./controllers/dirty_guard_controller"
import ThemeController from "./controllers/theme_controller"
import ListFilterController from "./controllers/list_filter_controller"
import ToggleCounterController from "./controllers/toggle_counter_controller"

const application = Application.start()
application.register("live-transcript", LiveTranscriptController)
application.register("clipboard", ClipboardController)
application.register("markdown", MarkdownController)
application.register("code-editor", CodeEditorController)
application.register("dirty-guard", DirtyGuardController)
application.register("theme", ThemeController)
application.register("list-filter", ListFilterController)
application.register("toggle-counter", ToggleCounterController)

window.Stimulus = application
