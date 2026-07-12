# Task Plan: Harness Fase 2 (fatia B) — Capability Registry + Tool Search

> **Tech Spec:** [00-overview.md](../00-overview.md) + [P2B-01](../P2B-01-capability-registry.md) · [P2B-02](../P2B-02-tool-search.md)
> **Gerado:** 2026-07-10
> **Progress:** 5/12 tasks complete (PR 1 / Etapa A ✅)
> **Base:** Fase 2-A completa (main @ merge PR #13)

---

## Tasks

| # | Task | File | Componente | Status | Complexity | Spec |
|---|------|------|-----------|--------|------------|------|
| 1 | `CapabilityRegistry` + `Provider` + resolução determinística + `:capability_resolved` | [task-01.md](./task-01.md) | P2B-01 | ✅ DONE | High | 0004 §4-§5, L1/L2/L4 |
| 2 | `CapabilityError`/`Unavailable`/`Ambiguous` + `Capability::ResolvedTool` | [task-02.md](./task-02.md) | P2B-01 | ✅ DONE | Low | 0004 §5, D4/L7 |
| 3 | `AgentProfile.capabilities` (allowlist opt-in) | [task-03.md](./task-03.md) | P2B-01 | ✅ DONE | Low | 0004 §6, L3 |
| 4 | Ativar `contracts.capabilities` no `PluginLoader` + `register_capability` | [task-04.md](./task-04.md) | P2B-01 | ✅ DONE | Med | 0004 §3, L6 |
| 5 | Executor: capability assembly (resolve por `profile.capabilities` → join pós-Policy → `rescue :capability` → wrap `ResolvedTool` + Envelope por `impl_name`) | [task-05.md](./task-05.md) | P2B-01 | ✅ DONE | High | 0004 §7, D1/D3/D4 |
| 6 | `ToolCatalog` (name+description + `search` puro + `format_for_prompt`) | [task-06.md](./task-06.md) | P2B-02 | ⬜ TODO | Med | 0005 §5, L3 |
| 7 | `AgentProfile.tools_deferred` (allowlist searchable-not-wired) | [task-07.md](./task-07.md) | P2B-02 | ⬜ TODO | Low | 0005 §5, L1/L2 |
| 8 | `Context::Providers::ToolSearch` (fragmento `<available_tools>`) | [task-08.md](./task-08.md) | P2B-02 | ⬜ TODO | Med | 0005 §2/§5, L4 |
| 9 | `Tools::ToolSearch` builtin: matcher + promoção `chat.with_tools` mid-loop + `:tool_search` | [task-09.md](./task-09.md) | P2B-02 | ⬜ TODO | High | 0005 §5, D6/L5 |
| 10 | Executor `configure_chat`: partição eager/deferred + `ToolSearch` de sistema (catálogo vem do provider, task 8) | [task-10.md](./task-10.md) | P2B-02 | ⬜ TODO | Med | 0005 §5, L6 |
| 11 | Wiring (`CAPABILITY_REGISTRY`+`TOOL_CATALOG`+provider) + catálogo de eventos D5 (`:capability_resolved`/`:tool_search`) | [task-11.md](./task-11.md) | P2B-01/02 | ⬜ TODO | Low | 00 D7 |
| 12 | Smoke E2E fatia B: resolução por priority/ambíguo/indisponível + promoção deferred no turno | [task-12.md](./task-12.md) | P2B-01..02 | ⬜ TODO | Med | 00 §"Critério" |

### Status Legend
- ⬜ TODO — Not started
- 🟡 IN PROGRESS — Being worked on
- ✅ DONE — Completed and tested
- ⛔ BLOCKED — Waiting on dependency

> **Nota (não criar os arquivos agora):** os `task-NN.md` são gerados sob demanda
> por `/create-task {NN}` — este plano só cria o índice (regra do skill).

---

## Dependency Graph

```
Etapa A — Capability Registry (P2B-01)  [✅ PR 1]
Task 1  → —                         (CapabilityRegistry, puro)
Task 2  → —                         (errors + ResolvedTool)
Task 3  → —                         (AgentProfile.capabilities)
Task 4  → 1                         (loader usa o registry)
Task 5  → 1, 2, 3, 4                (Executor junta tudo de A)

Etapa B — Tool Search (P2B-02)
Task 6  → —                         (ToolCatalog, só ToolRegistry da Fase 1)
Task 7  → —                         (AgentProfile.tools_deferred)
Task 8  → 6                         (Context Provider: catálogo de tools_deferred, estágio 2)
Task 9  → 6                         (builtin usa o catálogo + promove)
Task 10 → 6, 7, 8, 9               (Executor: partição eager/deferred + cabeia tool_search)

Etapa C — Integração / eventos / E2E
Task 11 → 5, 10                     (wiring de ambos + D5)
Task 12 → 5, 10, 11                 (smoke E2E)
```

Etapas **A e B são independentes** e andam em paralelo (A toca
capability/loader; B toca catalog/search). C fecha por cima.

⚠️ **Coordenação de arquivo compartilhado** (mesma disciplina da Fase 1, PRs
paralelos que tocam o mesmo arquivo):
- `agent_profile.rb` — tasks **3** (A) e **7** (B) adicionam um campo cada.
- `executor.rb` — task **5** (A) edita `run_pipeline`/`execute` (join de capability
  pós-Policy); task **10** (B) edita `configure_chat` (partição eager/deferred).
  Áreas distintas do mesmo arquivo — merge com atenção; sequenciar 5 antes de 10.

---

## Summary

- **Total tasks:** 12
- **Estimated total complexity:** Med-High (3 High: tasks 1, 5, 9; 4 Med; 5 Low)
- **Suggested PR grouping** (1 PR por etapa, como nas fatias anteriores):
  - **PR 1 — Etapa A** (tasks 1–5) ✅ **DONE**: Capability Registry + resolução
    determinística + ativação de `contracts.capabilities` + capability assembly no
    Executor. Suíte verde (731 exemplos).
  - **PR 2 — Etapa B** (tasks 6–10): Tool Catalog + Tool Search (provider + builtin)
    + partição eager/deferred no Executor.
  - **PR 3 — Etapa C** (tasks 11–12): wiring + catálogo de eventos + smoke E2E.

### Cobertura da tech spec
- **P2B-01** (capability): registry+resolução (1), erros+ResolvedTool (2), profile
  (3), loader/manifesto (4), Executor assembly (5). Decisões D1–D4/L1–L7 cobertas.
- **P2B-02** (tool search): catálogo (6), profile (7), provider (8), builtin (9),
  Executor partição (10). Decisões D5/D6/L1–L7 cobertas.
- **Transversal:** wiring + eventos D5 (11); critérios de conclusão 1–4 (12).

### Decisões de arquitetura baked-in (ver overview D1–D7 + P2B L-decisions)
1. **Promoção mid-loop RESOLVIDA (D6):** rodou-se o `ruby_llm` 1.16.0 real — a
   promoção via `chat.with_tools` dentro de um `execute` propaga no round seguinte
   do mesmo `ask`. Task 9 promove **no mesmo turno**; smoke (task 12) é 1 turno.
2. **Autorização de capability = `profile.capabilities` (D1/L3):** a resolução
   aplica só deny+availability+priority (não `tools_allow`); capability tools são
   juntadas ao tool set **após a Policy** (não passam pela `ToolAllowlist`) —
   `tools_allow` RAW não as estica/encolhe. Pinning por-agente de provider adiado.
3. **Tool Search sem violar "Runtime não monta prompt" (D5/D4):** o catálogo
   `<available_tools>` vem do `Context::Providers::ToolSearch` (task 8, ATIVO, lê
   `profile.tools_deferred` no estágio 2 — sem seam `vars`); `configure_chat` só
   cabeia a tool `tool_search`.
4. **Nome estável de tool de sistema (D2/L7):** `ToolSearch#name = "tool_search"`;
   **corrige junto o bug latente do `LoadSkill`** (`def name = "load_skill"`) —
   `RubyLLM::Tool#name` deriva do nome da classe (`harness--tools--...`), verificado.
5. **Wrap de capability em `run_pipeline`, não `configure_chat` (D4):** o
   `ToolEnvelope` já roda no estágio 3; `ToolEnvelope` passa a chavear
   side-effect/approval por `impl_name` (task 5 tocou `tool_envelope.rb`).

### Concerns ainda abertos (não bloqueiam; ver Notas das tasks)
- **Sem call-site de `PluginLoader` em produção** (dívida da task 26 da Fase 1):
  task 11 deixa `CAPABILITY_REGISTRY` pronta + comentário-ponte; capabilities de
  plugin só carregam quando a task 26 construir o loader (só specs o constroem hoje).
- **`ContextRequest` sem `:vars`** (seam pré-existente Fase 1): não é mais problema
  para a fatia B — o provider (task 8) usa `request.profile.tools_deferred`, não `vars`.

### Nota de ferramentas (PR 1)
- **Rubocop não faz parte deste projeto** (sem `.rubocop.yml`, fora do bundle) — o
  item "Rubocop limpo" das DoDs não é aplicável aqui; o gate real é a suíte RSpec.
