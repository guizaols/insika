# HANDOFF — Brief para Geração do Techspec

Este documento é o **brief de delegação**. Entregue-o (junto com o resto do
pacote) a um engenheiro ou a um agente de IA para produzir o **techspec de
implementação** do Harness. Ele diz *o que* gerar, *com base em quê*, *sob quais
restrições* e *em que ordem*.

---

## 1. Objetivo

Produzir um **techspec de implementação da Fase 1** do Harness — a camada entre a
arquitetura (os RFCs) e o código. O techspec deve ser detalhado o suficiente para
um desenvolvedor Ruby implementar sem precisar tomar decisões arquiteturais
novas: todas as decisões grandes já estão nos RFCs.

RFC = "o quê e porquê". Techspec = "como, exatamente". Código = a implementação.

## 2. Insumos (tudo neste pacote)

- **`rfcs/`** — a especificação arquitetural. **Fonte da verdade.**
  A **RFC-0001 é a constituição**: o techspec não pode contrariá-la.
- **`reference-implementation/`** — a Fase 0 já implementada e testada
  (`agent_runtime`). O techspec deve **evoluir este código**, não recomeçar.
- **`rfcs/BACKLOG.md`** — mostra o que está feito e o mapa conceito→arquivo.

## 3. Escopo do techspec (Fase 1)

Implementar a **pipeline canônica (RFC-0002)** end-to-end sobre a base da Fase 0.
Ordem de dependência recomendada (o techspec deve segui-la):

1. **Persistence & Stores (RFC-0006)** — interface `Store` + backends Memory e
   SQLite. É a dependência de tudo; hoje o sistema é stateless.
2. **Session / Task / Checkpoint** sobre os stores — incluindo recuperação no boot.
3. **Command Bus + Runtime Executor (RFC-0002)** — evoluindo o `runner.rb` atual
   de um loop linear para a pipeline por estágios.
4. **Context Builder + Context Providers (RFC-0005)** — evoluindo o
   `system_prompt.rb` para providers plugáveis com orçamento de tokens.
5. **Policy Engine + Middleware + Lifecycle Hooks (RFC-0002)** — os estágios de
   política, modificação e wrappers before/after.
6. **Registries restantes** (Workflow, Prompt, Policy) e **autodiscovery de
   plugin por gem (RFC-0003)**.
7. **Service Platform** — formalizar HTTP/SSE (o endpoint já existe) e o esqueleto
   do Control UI (RFC-0007) pode ficar para o fim da fase.

Fica **fora** da Fase 1 (não incluir no techspec agora): Actor mailbox completa,
Capability Resolution (RFC-0004), Tool Search, memória semântica, e o Control UI
completo — são Fase 2.

## 4. Estrutura obrigatória do techspec

Para **cada** componente do escopo, o techspec deve conter:

1. **Objetivo e fronteira** — o que faz e o que explicitamente não faz.
2. **Interfaces públicas** — assinaturas Ruby exatas (classes, métodos,
   parâmetros, tipos de retorno). Os RFCs já trazem esboços; refine-os.
3. **Modelos de dados / schemas** — chaves de store, formato de checkpoint,
   estrutura de Command/Event/ContextFragment.
4. **Fluxo de controle** — como o componente participa da pipeline (RFC-0002),
   passo a passo.
5. **Concorrência** — pontos Async/Fibers, fan-out, o que nunca bloqueia o reactor.
6. **Erros e timeouts** — propagação, retomada, cancelamento cooperativo.
7. **Estratégia de testes** — o que testar e como (ver §6).
8. **Evolução a partir da Fase 0** — quais arquivos do `reference-implementation`
   são estendidos/substituídos, e o caminho de migração.
9. **Decisões locais** — qualquer escolha não coberta pelos RFCs, registrada
   explicitamente com justificativa.

## 5. Restrições inegociáveis (da constituição — RFC-0001)

O techspec **deve** respeitar, e rejeitar qualquer design que viole:

- **RubyLLM First** — nunca reimplementar chat, streaming, tool calling, agents,
  workflows, embeddings, MCP ou instrumentation. Usar RubyLLM para tudo isso.
- **Uma única pipeline** — nenhum fluxo de execução paralelo; toda feature estende
  estágios da pipeline canônica.
- **Standalone / Ruby puro** — o núcleo (`lib/`) não depende de Rails. Sem
  ActiveSupport no núcleo (Event Stream próprio; bridge de observabilidade é
  plugin opt-in).
- **Sem job runner externo** — nada de Solid Queue/Sidekiq. Durabilidade = stores
  plugáveis + recuperação no boot.
- **Async/Fibers, sem threads** — modelo de concorrência único (Falcon + Async);
  threads só na exceção CPU-bound isolada.
- **Catalog ↔ Registry** — conteúdo não-executável em Catalogs; executável em
  Registries.
- **Convention over Configuration** — skills seguem AgentSkills/SKILL.md.
- **Context fora do Runtime** — o Runtime nunca monta prompt.
- **Middleware modifica, Hooks alteram, Events observam** — três papéis distintos.

## 6. Estratégia de testes esperada

- Núcleo (`lib/`) testável **sem RubyLLM instalado nem chaves de API** (a Fase 0
  já faz isso: partes puras rodam isolado). Prefira essa separação.
- Stores: testes de contrato reutilizáveis entre backends (Memory e SQLite passam
  na mesma suíte).
- Pipeline: testes de cada estágio isolado + um teste de integração do fluxo
  Command→Response com um provider RubyLLM mockado.
- Determinismo: capability/policy/resolução devem ter testes de caso de empate e
  de negação.

## 7. Decisões ainda em aberto (o techspec deve resolvê-las ou sinalizá-las)

Listadas nos RFCs e no BACKLOG. As que impactam a Fase 1:

- **Stateless vs stateful como default da API** (BACKLOG). Recomendação dos RFCs:
  núcleo stateless com sessão persistida opcional.
- **Conjunto mínimo de Commands** (RFC-0002 §10).
- **Consistência multi-processo dos stores** (RFC-0006 §6): last-write-wins vs
  lease/lock.
- **Nome/namespace do projeto** (RFC-0001 §8) — não bloqueia a Fase 1, mas decida
  antes de publicar gem.

Onde o techspec precisar decidir, deve **registrar a decisão e o motivo**, não
deixar implícito.

## 8. Formato de entrega do techspec

- Um documento por componente do escopo (§3), ou um documento único com uma seção
  por componente — desde que cada um tenha as 9 partes da §4.
- Markdown, com blocos de código Ruby para as interfaces.
- Referenciar os RFCs por número (ex.: "conforme RFC-0006 §5").
- Terminar com um **plano de implementação** ordenado (issues/tarefas) derivado da
  ordem de dependência da §3.

## 9. Prompt pronto para delegar a um agente de IA

Copie o bloco abaixo e forneça junto com este pacote:

> Você é um engenheiro de plataforma sênior em Ruby. Gere o **techspec de
> implementação da Fase 1** do Harness a partir deste pacote.
>
> Leia primeiro `README.md`, depois `HANDOFF-TECHSPEC.md`, depois todos os
> arquivos em `rfcs/` (a `RFC-0001` é a constituição e não pode ser violada), e
> inspecione `reference-implementation/` (a Fase 0 já implementada, que você deve
> evoluir — não recomeçar).
>
> Produza o techspec seguindo **exatamente** a estrutura da seção 4 do
> `HANDOFF-TECHSPEC.md`, para os componentes no escopo da seção 3, na ordem de
> dependência indicada. Respeite todas as restrições inegociáveis da seção 5.
> Onde precisar decidir algo em aberto (seção 7), registre a decisão e a
> justificativa. Especifique interfaces Ruby com assinaturas exatas, schemas de
> store, formato de checkpoint, e o fluxo de cada estágio da pipeline.
>
> Não implemente Fase 2 (Actor mailbox completa, Capability Resolution, Tool
> Search, memória semântica, Control UI completo). Termine com um plano de
> implementação ordenado em tarefas.
>
> O núcleo deve permanecer Ruby puro (sem Rails), Async/Fibers, sem job runner
> externo, com uma única pipeline de execução. Não reimplemente nada que seja do
> RubyLLM.

## 10. Definição de "pronto" do techspec

O techspec está pronto quando um desenvolvedor Ruby consegue, lendo-o, implementar
a Fase 1 sem precisar reabrir os RFCs para decisões de design — só para contexto.
Toda interface está assinada, todo schema está definido, toda decisão em aberto
relevante à Fase 1 está resolvida e justificada, e há um plano de tarefas
ordenado.
