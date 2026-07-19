// Tiny, dependency-free Markdown → HTML renderer for the editor's Preview pane
// (§3.2). NOT a spec-complete parser — it covers what agent prompts / SKILL.md use:
// ATX headings, fenced + inline code, bold/italic, links, blockquotes, hr, and
// ordered/unordered lists. It exists so we don't pull a Node markdown dependency
// into a "no front-end framework" studio.
//
// Safety: every fragment is HTML-escaped BEFORE any markup is applied, and link
// hrefs are scheme-checked (javascript:/data: rejected). Content is admin-authored,
// but escaping keeps a stray "<script>" in a prompt from executing in the preview.

const escapeHtml = (s) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;")

const safeHref = (url) => {
  const u = url.trim()
  // Allow relative, anchor, http(s), mailto; block everything else (js:, data:…).
  if (/^(https?:|mailto:|#|\/|\.\/|\.\.\/)/i.test(u)) return escapeHtml(u)
  if (!/:/.test(u)) return escapeHtml(u) // scheme-less (relative) is fine
  return "#"
}

// Inline spans, applied to already-escaped text. Order matters: code first (its
// content must not be re-processed), then links, then emphasis.
function inline(text) {
  let out = text
  out = out.replace(/`([^`]+)`/g, (_, c) => `<code>${c}</code>`)
  out = out.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, url) => `<a href="${safeHref(url)}">${label}</a>`)
  out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
  out = out.replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>")
  out = out.replace(/_([^_\n]+)_/g, "<em>$1</em>")
  return out
}

export function renderMarkdown(src) {
  const lines = String(src).replace(/\r\n?/g, "\n").split("\n")
  const html = []
  let i = 0
  let listType = null // "ul" | "ol" | null

  const closeList = () => { if (listType) { html.push(`</${listType}>`); listType = null } }

  while (i < lines.length) {
    const line = lines[i]

    // Fenced code block ```lang … ```
    const fence = line.match(/^```(.*)$/)
    if (fence) {
      closeList()
      const buf = []
      i++
      while (i < lines.length && !/^```/.test(lines[i])) { buf.push(lines[i]); i++ }
      i++ // consume closing fence
      html.push(`<pre><code>${escapeHtml(buf.join("\n"))}</code></pre>`)
      continue
    }

    // Blank line: paragraph/list separator.
    if (/^\s*$/.test(line)) { closeList(); i++; continue }

    // Horizontal rule.
    if (/^\s*([-*_])\1{2,}\s*$/.test(line)) { closeList(); html.push("<hr>"); i++; continue }

    // ATX heading (# … ######).
    const h = line.match(/^(#{1,6})\s+(.*)$/)
    if (h) {
      closeList()
      const level = h[1].length
      html.push(`<h${level}>${inline(escapeHtml(h[2]))}</h${level}>`)
      i++
      continue
    }

    // Blockquote (one level).
    if (/^>\s?/.test(line)) {
      closeList()
      const buf = []
      while (i < lines.length && /^>\s?/.test(lines[i])) { buf.push(lines[i].replace(/^>\s?/, "")); i++ }
      html.push(`<blockquote>${inline(escapeHtml(buf.join(" ")))}</blockquote>`)
      continue
    }

    // Unordered list item.
    const ul = line.match(/^\s*[-*+]\s+(.*)$/)
    if (ul) {
      if (listType !== "ul") { closeList(); html.push("<ul>"); listType = "ul" }
      html.push(`<li>${inline(escapeHtml(ul[1]))}</li>`)
      i++
      continue
    }

    // Ordered list item.
    const ol = line.match(/^\s*\d+[.)]\s+(.*)$/)
    if (ol) {
      if (listType !== "ol") { closeList(); html.push("<ol>"); listType = "ol" }
      html.push(`<li>${inline(escapeHtml(ol[1]))}</li>`)
      i++
      continue
    }

    // Paragraph: gather consecutive plain lines.
    closeList()
    const para = [line]
    i++
    while (i < lines.length && !/^\s*$/.test(lines[i]) &&
           !/^(#{1,6}\s|>|```|\s*[-*+]\s|\s*\d+[.)]\s)/.test(lines[i])) {
      para.push(lines[i]); i++
    }
    html.push(`<p>${inline(escapeHtml(para.join("\n"))).replace(/\n/g, "<br>")}</p>`)
  }

  closeList()
  return html.join("\n")
}
