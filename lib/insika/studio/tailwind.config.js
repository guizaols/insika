/** @type {import('tailwindcss').Config} */
// Studio's Tailwind. The product uses semantic component classes
// (@layer components in application.css), so the JIT generates little beyond
// preflight/base — the globs below cover the occasional utilities used in the views.
module.exports = {
  content: [
    "./views/**/*.erb",
    "./assets/src/**/*.js"
  ],
  theme: { extend: {} },
  safelist: [
    { pattern: /^avatar-h\d+$/ },
    // CodeMirror creates these at runtime, outside Tailwind's source scan.
    "cm-editor", "cm-focused", "cm-content", "cm-gutters", "cm-activeLine",
    "cm-activeLineGutter", "cm-selectionBackground", "cm-scroller"
  ],
  plugins: []
}
