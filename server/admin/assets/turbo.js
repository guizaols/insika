// PLACEHOLDER — substitua pelo Turbo real vendored (hotwired/turbo, UMD/ESM
// minificado) neste caminho. O harness-server o serve em /admin/assets/turbo.js
// (P2-04 L1: sem pipeline de build, sem CDN — a CSP `script-src 'self'` exige
// mesma origem). Sem o Turbo real, o painel DEGRADA graciosamente: os <form>
// POSTam normalmente e o servidor responde 303 redirect (edge case 5). Com o
// Turbo real, as respostas text/vnd.turbo-stream.html atualizam fragmentos ao
// vivo.
console.info("[harness/admin] Turbo placeholder — vendor hotwired/turbo aqui.");
