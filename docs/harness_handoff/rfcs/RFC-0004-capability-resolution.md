---
rfc: "0004"
title: Capability Resolution
status: Draft
type: Componente
created: 2026-07-05
supersedes: []
depends_on: ["0001", "0002", "0003"]
---

# RFC-0004 — Capability Resolution

> Detalha a resolução intenção→implementação declarada na RFC-0001. Camada
> **opcional** sobre o Tool/Workflow Registry: agentes podem referenciar uma
> *capability* (`:browse`) em vez de uma tool concreta, e o runtime resolve qual
> implementação atende, de forma **determinística**.

## 1. Motivação

Uma capability (`browse`, `search`, `send_email`) pode ter várias
implementações — dois plugins de browser, dois provedores de busca. Referenciar a
intenção em vez da implementação:

- desacopla o agente do plugin concreto (troca-se a implementação sem tocar no agente);
- permite política por agente ("este agente pode `browse`, mas com o browser X");
- habilita fallback quando uma implementação está indisponível.

O risco é resolução mágica/imprevisível. Por isso a regra central: **resolução
sempre determinística e auditável; empate = erro de configuração, nunca escolha
silenciosa.**

## 2. Modelo

Uma **Capability** é um nome de intenção. Um **Provider** é uma implementação
concreta (uma Tool ou um Workflow) que declara satisfazer aquela capability, com
metadados de resolução.

```
Capability :browse
   ├── Provider  { impl: BrowseTool,        plugin: "browser",     priority: 100 }
   └── Provider  { impl: HeadlessBrowseTool, plugin: "browser-lite", priority: 50 }
```

Capability é **indireção**, não executável em si — resolve para algo do Registry.

## 3. Declaração

Via manifesto de plugin (RFC-0003, `contracts.capabilities`) + registro no entry:

```ruby
def self.register(api)
  api.register_tool       "browse", BrowseTool
  api.register_capability :browse, tool: "browse", priority: 100
  # ou para workflow:
  api.register_capability :research, workflow: "research"
end
```

`priority` é opcional; default herda a precedência do plugin (RFC-0003 §5). Um
provider pode declarar checagens de disponibilidade (`requires:` bins/env, ou um
lambda `available?`).

## 4. Capability Registry — contrato

```ruby
module Harness
  class CapabilityRegistry
    Provider = Data.define(:capability, :impl_name, :kind, :plugin, :priority, :available)
    #   kind: :tool | :workflow
    #   available: callable -> bool  (default: -> { true })

    def register(capability, impl_name:, kind:, plugin: nil, priority: nil, available: nil)
    def providers(capability)               # -> [Provider], todos os candidatos
    def resolve(capability, profile:, context: {})  # -> impl concreta ou erro
  end
end
```

## 5. Algoritmo de resolução (determinístico)

Dado `capability`, `profile` (RFC-0001 política por agente) e `context`:

1. **Candidatos.** Reúne todos os Providers registrados para a capability.
2. **Disponibilidade.** Remove os cujo `available?` é falso (bin/env ausente,
   health check falho).
3. **Política.** Aplica allow/deny do agente sobre o `impl_name` de cada
   candidato (mesma semântica de tools: deny sempre vence; allow não-vazia é o
   conjunto final).
4. **Ordenação.** Ordena por `priority` desc; empate de priority quebra por
   precedência de plugin (RFC-0003); empate persistente é tratado no passo 6.
5. **Seleção.**
   - 1 candidato no topo → **resolve**.
   - 0 candidatos → **fallback** (se o agente declarou um) ou **erro explícito**
     `CapabilityUnavailable`.
   - >1 candidato com priority idêntica no topo → **erro de configuração**
     `CapabilityAmbiguous`, listando os candidatos. Nunca escolhe em silêncio.
6. **Auditoria.** Emite `CapabilityResolved { capability, chosen, candidates }`
   no Event Stream (RFC-0002 §7.4).

Resolução é **pura e cacheável por (capability, profile)** dentro de um turno.

## 6. Uso pelo agente

Um AgentProfile pode listar capabilities ao lado (ou no lugar) de tools:

```ruby
capabilities: [:browse, :search]
```

No estágio de montagem de tools do turno (RFC-0002, entre Context e Policy), cada
capability é resolvida para a impl concreta, que é então exposta ao modelo sob um
**nome estável** (o nome da capability, não o da impl) — assim o prompt/skill
referencia `browse` de forma consistente, independentemente de qual browser
resolveu. O Policy Engine ainda roda sobre o resultado concreto.

## 7. Interação com a pipeline

```
Context Builder → [Capability Resolution] → Policy Engine → Middleware → Runtime
```

Resolução acontece **depois** do contexto (precisa saber capabilities pedidas) e
**antes** do Policy Engine finalizar o conjunto de tools (a política ainda filtra
o resultado). É um sub-passo da montagem de tools, não um estágio novo — respeita
"uma pipeline".

## 8. Faseamento

- **Fase 2 (entrada):** registry + resolução por priority/precedência + eventos.
  Provar com 2–3 capabilities reais (ex.: `search`, `browse`).
- **Fase 2 (evolução):** seleção por custo/latência, fallback em cadeia,
  capability versionada.

Até a Fase 2, agentes referenciam tools/workflows por nome; nada aqui é
pré-requisito do núcleo.

## 9. Questões em Aberto

1. Desempate além de priority/precedência (custo? latência? saúde histórica?).
2. Capability versionada (`browse@2`) e compatibilidade.
3. Fallback: automático em cadeia vs explícito por agente.
4. Resolução por-turno vs por-sessão (cache e invalidação).
