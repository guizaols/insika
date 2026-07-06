---
rfc: "0000"
title: Índice & Processo de RFCs
status: Active
type: Meta
created: 2026-07-05
supersedes: []
depends_on: []
---

# RFC-0000 — Índice & Processo de RFCs

Este documento governa como as RFCs do Harness são escritas, numeradas e
evoluídas. Ele é o único ponto de entrada do repositório de RFCs.

## Índice

| RFC   | Título                        | Status      | Tipo      |
|-------|-------------------------------|-------------|-----------|
| 0000  | Índice & Processo de RFCs     | Active      | Meta      |
| 0001  | Harness Architecture          | Active      | Constituição |
| 0002  | Runtime Pipeline              | Draft       | Componente |
| 0003  | Plugin System                 | Draft       | Componente |
| 0004  | Capability Resolution         | Draft       | Componente |
| 0005  | Context Providers & Memory    | Draft       | Componente |
| 0006  | Persistence & Stores          | Draft       | Componente |
| 0007  | Control UI (Operator Frontend)| Draft       | Componente |

Documento vivo (fora do processo de RFC): `BACKLOG.md` — roadmap, status de
implementação e mapeamento com o código.

## Tipos de RFC

- **Meta** — governa o processo (este documento).
- **Constituição** — a arquitetura estável (RFC-0001). Muda raramente, e só por
  emenda datada (ver abaixo). Nunca é reescrita silenciosamente.
- **Componente** — detalha *um* subsistema (pipeline, plugins, capability, etc.).
  É onde a evolução acontece. A constituição aponta para ele; ele nunca duplica a
  constituição.

## Status

`Proposed` → `Draft` → `Accepted` → `Implemented` → (`Superseded` | `Deprecated`).

## Cabeçalho obrigatório

Toda RFC começa com front-matter YAML:

```yaml
---
rfc: "0002"
title: Runtime Pipeline
status: Draft
type: Componente
created: 2026-07-05
supersedes: []          # ex.: ["RFC-001.1"]
depends_on: ["0001"]    # RFCs das quais esta depende
---
```

## Regras editoriais

1. **A constituição (0001) não contém "como".** Ela declara que um componente
   existe e aponta para a RFC que o detalha. Todo detalhe de implementação
   (contratos, formatos, ordem fina) vive num Componente.
2. **Sem número de versão no título.** A identidade é o número da RFC, não a
   versão. Evolução de um Componente é uma nova RFC (ou emenda), não um "v5".
3. **Nada transitório na constituição.** Roadmap, status e mapeamento com código
   vão para `BACKLOG.md`, que é vivo e pode mudar a qualquer momento.
4. **Emendas à constituição** entram como adendo datado na seção "Histórico de
   Emendas" da 0001, preservando o texto original. Estabilidade por emenda, não
   por imutabilidade fingida.
5. **Um Componente que substitui outro** declara `supersedes` e o antigo passa a
   `Superseded`, sem ser apagado.

## Linhagem

Esta estrutura consolida e substitui os rascunhos monolíticos anteriores
(Harness v1 → v4). A v4 foi decomposta: sua arquitetura estável virou a RFC-0001;
sua pipeline (que havia absorvido o antigo RFC-001.1) virou a RFC-0002; os demais
subsistemas viraram Componentes próprios.
