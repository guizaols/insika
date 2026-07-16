# Fase 6 · Etapa D — Provisionamento por pack

> Fecha as tasks **7** (importador de pack) e **8** (API de provisionamento).
> Decisões: §4 D4; requisitos F6/F7, NF1/NF2. Base: Etapas A–C mergeadas.

## 1. O que é um pack (genérico, NF1)

`Harness::Pack` (`lib/harness/pack.rb`) é a forma **portátil** de um agente —
nada cita achei-b2b, o pack É o contrato:

```
config: Hash   # manifesto: attrs de AgentProfile.build (id/model/provider/
               #   limits/metadata{store_id}/tools_deferred/…). id+model obrigatórios.
files:  {"IDENTITY.md" => "...", "SOUL.md" => "...", ...}   # prompt files
skills: {"escalation-to-human" => "<SKILL.md>", ...}         # 1 por skill
tools:  [ {ToolDefinition hash}, ... ]                        # data-tools
```

Duas origens:
- **`Pack.from_h(hash)`** — o wire JSON da API de provisionamento (task 8).
- **`Pack.from_dir(path)`** — pasta em disco conforme `docs/prompt-base/06`:
  `agent.config.json` + `*.md` na raiz + `skills/<nome>/SKILL.md` + `tools/*.json`.

## 2. Importador (task 7, D4/F6)

`Harness::PackImporter` (`bus:`, `profiles:`) lê um `Pack` e emite os Commands de
autoria **já existentes** — não escreve em store direto (mesma disciplina do
transporte):

| Passo | Command | Por quê |
|-------|---------|---------|
| 1 | `create_agent` **ou** `update_agent` | upsert por presença no ProfileSource |
| 2 | `write_agent_file` × arquivo | grava o `.md` e registra em `prompt_files` |
| 3 | `write_skill` × skill | grava o `SKILL.md` global + reload do catálogo |
| 4 | `write_data_tool` × tool | grava a data-tool + reload do overlay/catálogo |

**Ordem:** `create_agent` antes dos `write_agent_file` (o arquivo exige o agente).

**Allowlists autoritativas do pack** (isolamento por loja + NF2): o importador
deriva e SETA no profile — `prompt_files` = os `.md` do pack; `skills` = os dirs
de `skills/`; `tools_allow` = `config.tools_allow ∪ nomes das tools do pack`.
Assim o agente só enxerga o que é do próprio pack, e **re-provisionar remove o
que saiu** (sem drift). Os nomes de tool vêm do pack → prompts↔tools consistentes
por construção (NF2).

**Idempotente:** re-importar o mesmo pack reconcilia (arquivos/skills/tools
reescritos; sem duplicar `prompt_files`). Um turno em andamento mantém o profile
que já capturou.

## 3. API de provisionamento (task 8, D4/F7)

Sob o **mesmo Bearer** do `/v1/responses` (`gateway_token`, fail-closed). É a
"fachada fina" que o `GatewayClient`/`ProvisionStore` do achei-b2b aciona
(Open Q #3):

| Rota | Ação |
|------|------|
| `POST /v1/agents` | body = pack JSON → `PackImporter#import` → `200 { agent_id, created, files, skills, tools }` |
| `DELETE /v1/agents/:id` | `PackImporter#delete` → `200 { agent_id, deleted }` (404 se ausente) |

- Corpo lido com **chaves string** (`parse_raw_body`): nomes de arquivo/skill do
  pack são dado, não viram símbolos.
- `provisioner: nil` no `App` ⇒ rotas respondem **404** (opt-in, como o A2A).
- Erros dos Commands (id/model ausente → 422; agente ausente no delete → 404)
  propagam pelo `rescue` central do `#call`.

## 4. O que NÃO entrou (escopo)
- **Deploy no Railway (task 9) — DESCARTADO** (decisão do produto: este motor não
  vai pro Railway). O provisionamento funciona em qualquer deployment do harness.
- Remoção seletiva de skills/tools no `delete` (são globais/compartilhados —
  trabalho de operador); o delete remove só o agente.
- CLI de import de pasta: `Pack.from_dir` já existe e é testado; um wrapper de
  linha de comando é trivial e fica para quando for preciso.
