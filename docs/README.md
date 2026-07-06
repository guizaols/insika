# Harness — Pacote de Handoff

Este pacote contém tudo o que é necessário para gerar um **techspec de
implementação** do Harness — uma Agent Runtime Platform standalone construída
sobre RubyLLM, no modelo do OpenClaw.

## O que tem aqui

```
harness_handoff/
├── README.md                     ← você está aqui (orientação)
├── HANDOFF-TECHSPEC.md           ← o brief de delegação (LEIA ISTO)
├── rfcs/                         ← a especificação arquitetural (o "quê" e "porquê")
│   ├── RFC-0000-index-and-process.md      (índice + regras do processo de RFC)
│   ├── RFC-0001-harness-architecture.md   (CONSTITUIÇÃO — estável)
│   ├── RFC-0002-runtime-pipeline.md
│   ├── RFC-0003-plugin-system.md
│   ├── RFC-0004-capability-resolution.md
│   ├── RFC-0005-context-providers-and-memory.md
│   ├── RFC-0006-persistence-and-stores.md
│   ├── RFC-0007-control-ui.md
│   └── BACKLOG.md                          (roadmap + status + mapa p/ código — vivo)
└── reference-implementation/     ← o código da Fase 0 (já existe e roda)
    └── (o agent_runtime: Ruby puro + endpoint SSE + skills/tools/plugins)
```

## Como ler, na ordem

1. **RFC-0000** — entenda o processo e o índice.
2. **RFC-0001** — a constituição: visão, princípios, 4 plataformas, modelo
   conceitual. É o contrato imutável que o techspec **não pode violar**.
3. **RFC-0002 a 0007** — cada subsistema em detalhe (pipeline, plugins,
   capability, contexto/memória, persistência, control UI).
4. **BACKLOG.md** — o que está feito (Fase 0), o que falta (Fase 1/2/3), e o mapa
   de cada conceito para o arquivo do `reference-implementation`.
5. **reference-implementation/** — o código que já materializa a Fase 0.

## O que fazer com isto

Ler o **HANDOFF-TECHSPEC.md**. Ele é o brief pronto para delegar a geração do
techspec — a um engenheiro ou a um agente de IA (Claude Code, etc.). Contém o
escopo, os contratos exigidos, as restrições inegociáveis e um prompt pronto para
colar.

## Contexto de uma linha

RubyLLM é a inteligência (chat, tools, agents). Harness é a operação (pipeline,
sessões, tasks, plugins, persistência, API). O Harness roda como serviço
standalone; o Agent.Shop o consome por HTTP, exatamente como consome o OpenClaw
hoje.
