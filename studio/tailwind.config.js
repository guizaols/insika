/** @type {import('tailwindcss').Config} */
// Tailwind do Studio (D8). O produto usa classes semânticas de componente
// (@layer components em application.css), então o JIT gera pouco além do
// preflight/base — os globs abaixo cobrem utilitários eventuais usados nas views.
module.exports = {
  content: [
    "./views/**/*.erb",
    "./assets/src/**/*.js"
  ],
  theme: { extend: {} },
  plugins: []
}
