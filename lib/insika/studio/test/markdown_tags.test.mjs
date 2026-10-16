import { test } from "node:test"
import assert from "node:assert/strict"
import { renderMarkdown } from "../assets/src/markdown.js"

test("channel markup tags are highlighted, escaped, and never rendered", () => {
  const html = renderMarkdown("<carrossel/> Achei 3 opções <b>boas</b>")
  assert.match(html, /<span class="tag-token">&lt;carrossel\/&gt;<\/span>/)
  assert.match(html, /<span class="tag-token">&lt;b&gt;<\/span>boas<span class="tag-token">&lt;\/b&gt;<\/span>/)
  assert.doesNotMatch(html, /<carrossel|<b>/)
})

test("a tag with attributes is one token", () => {
  assert.match(renderMarkdown('<vitrine_enviada formato="lista">x</vitrine_enviada>'),
    /<span class="tag-token">&lt;vitrine_enviada formato=&quot;lista&quot;&gt;<\/span>x<span class="tag-token">&lt;\/vitrine_enviada&gt;<\/span>/)
})

test("underscores in two tags on one line are not italics", () => {
  assert.doesNotMatch(renderMarkdown("<ver_mais/> e <ver_mais/>"), /<em>/)
  assert.match(renderMarkdown("_isso_ sim"), /<em>isso<\/em>/)
})

test("a tag inside inline code stays plain code", () => {
  assert.equal(renderMarkdown("use `<carrinho/>`"), "<p>use <code>&lt;carrinho/&gt;</code></p>")
})

test("comparisons are not tags", () => {
  assert.doesNotMatch(renderMarkdown("preço < 100 e > 50"), /tag-token/)
})
