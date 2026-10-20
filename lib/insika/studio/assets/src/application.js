// Studio bundle entry — esbuild packages this + Stimulus + Turbo +
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
import TabsController from "./controllers/tabs_controller"
import AutoSubmitController from "./controllers/auto_submit_controller"
import TransportFieldsController from "./controllers/transport_fields_controller"
import LiveHomeController from "./controllers/live_home_controller"
import LiveFloorController from "./controllers/live_floor_controller"
import ActiveLinkController from "./controllers/active_link_controller"
import ModelChartController from "./controllers/model_chart_controller"
import ModelFiltersController from "./controllers/model_filters_controller"
import ColResizeController from "./controllers/col_resize_controller"
import PaletteController from "./controllers/palette_controller"

const application = Application.start()
application.register("live-transcript", LiveTranscriptController)
application.register("clipboard", ClipboardController)
application.register("markdown", MarkdownController)
application.register("code-editor", CodeEditorController)
application.register("dirty-guard", DirtyGuardController)
application.register("theme", ThemeController)
application.register("list-filter", ListFilterController)
application.register("toggle-counter", ToggleCounterController)
application.register("tabs", TabsController)
application.register("auto-submit", AutoSubmitController)
application.register("transport-fields", TransportFieldsController)
application.register("live-home", LiveHomeController)
application.register("live-floor", LiveFloorController)
application.register("active-link", ActiveLinkController)
application.register("model-chart", ModelChartController)
application.register("model-filters", ModelFiltersController)
application.register("col-resize", ColResizeController)
application.register("palette", PaletteController)

window.Stimulus = application

// Transcript stamps are rendered server-side in UTC; show them in the viewer's zone,
// matching the live stamps (live_transcript_controller#time).
const localizeStamps = () => document.querySelectorAll("time.stamp[datetime]").forEach((t) => {
  const d = new Date(t.getAttribute("datetime"))
  if (!isNaN(d.getTime())) t.textContent = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
})
document.addEventListener("turbo:load", localizeStamps)
document.addEventListener("turbo:frame-load", localizeStamps)
