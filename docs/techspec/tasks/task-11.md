# Task 11: Migrar `runner.rb` → estágios 6-7 do Executor (RubyLLM intacto, `max_tool_calls` no hook)

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [03-command-bus-executor.md](../03-command-bus-executor.md)
> **Status:** ✅ DONE
> **Complexity:** Med

---

## Objective

Migrar a lógica RubyLLM da Fase 0 (`Runner#build_chat`, `#seed_history`, `#wire_callbacks`) **intacta** para os estágios 5-7 do `Executor`, conforme a tabela do doc 03 §4.2 — acrescentando apenas `meta` nos eventos (D5) e o contador `max_tool_calls` (doc 03 §6/L6) — e migrar `SkillCatalog` e `Tools::LoadSkill` para o namespace `Harness` sem mudança de lógica.

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 10 | `Executor` esqueleto: fiber por task, `TaskActor` (mailbox `cancel`), estados, `running?`, `EventStream` | ⬜ TODO |

## Context

Restrição inegociável nº 1 (doc 00 §5): **RubyLLM First** — chat/streaming/tool-loop/retries nunca reimplementados. O `runner.rb` da Fase 0 já respeita isso ("Cola de serviço. NÃO reimplementa o loop"); esta task move essa cola para dentro do Executor **sem reescrevê-la**. O doc 00 §4 é explícito: "a lógica RubyLLM (build_chat/callbacks/seed) migra intacta para o estágio 6-7; o entorno vira estágios".

Diferenças permitidas (e obrigatórias) em relação à Fase 0, todas previstas no doc 03 §4.2:
1. `with_instructions` agora recebe o pacote do Builder (`context.system`) em vez de `SystemPrompt#build`;
2. as tools vêm da **Resolution** do Policy Engine (`allowed_tools`/`allowed_skills`) em vez de `ToolRegistry#resolve` — nesta task a Resolution chega via `TurnState`/stub (o Engine real é a task 17);
3. eventos ganham `meta` D5 (via o helper `emit` da task 10);
4. contador `max_tool_calls` no hook de tool (doc 03 §6): guard-rail contra loop infinito de tool-use — "o hook só conta e aborta", nenhum loop é dirigido.

É a **única** task da Etapa C que toca `ruby_llm` — e o require é **lazy** (D9: o núcleo não requer `ruby_llm` em load-time fora dos pontos de integração; doc 03 §7: "o require de `ruby_llm` fica confinado ao Executor e é lazy").

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/skill_catalog.rb` | migração da Fase 0, só troca `AgentRuntime` → `Harness` (doc 00 §4: "migra sem mudança de lógica") |
| CREATE | `lib/harness/tools/load_skill.rb` | migração da Fase 0, idem; `require "ruby_llm"` continua NESTE arquivo, que só é carregado lazy |
| MODIFY | `lib/harness/executor.rb` | métodos privados dos estágios 5-7: `create_chat`, `configure_chat`, `seed_history`, `wire_callbacks` |
| MODIFY | `lib/harness.rb` | `require_relative "harness/skill_catalog"`; **NÃO** requerer `tools/load_skill` (puxaria ruby_llm em load-time) |
| CREATE | `spec/support/ruby_llm_stub.rb` | shim mínimo do namespace `RubyLLM` quando a gem não está instalada |
| CREATE | `spec/support/fake_chat.rb` | duplo de chat com a superfície usada (with_instructions/with_tools/add_message/callbacks/ask) |
| CREATE | `spec/harness/skill_catalog_spec.rb` | paridade com a Fase 0 (effective/format_for_prompt/precedência) |
| CREATE | `spec/harness/tools/load_skill_spec.rb` | allowlist, não-encontrada, corpo |
| CREATE | `spec/harness/executor_chat_spec.rb` | estágios 5-7 contra o fake chat |

### Step-by-Step Instructions

#### Step 1: migrar `SkillCatalog` (inalterado)

**File:** `lib/harness/skill_catalog.rb`

Copiar `reference-implementation/lib/agent_runtime/skill_catalog.rb` trocando apenas o módulo para `Harness`. Zero mudança de lógica (doc 00 §4). Ele é dependência do Executor (`skill_catalog:` no construtor, doc 03 §2) e do estágio 3 (`skill_catalog.effective(profile.skills)` como `candidate_skills`, usado na task 12).

#### Step 2: migrar `Tools::LoadSkill` (inalterado)

**File:** `lib/harness/tools/load_skill.rb`

Copiar `reference-implementation/lib/agent_runtime/tools/load_skill.rb` trocando o módulo para `Harness`. O arquivo mantém `require "ruby_llm"` no topo (a classe herda de `RubyLLM::Tool`), por isso **não entra** em `lib/harness.rb` — quem o carrega é o Executor, lazy, dentro de `create_chat` (Step 3).

**Reference pattern from codebase** (`reference-implementation/lib/agent_runtime/tools/load_skill.rb` — migra assim, só o módulo muda):
```ruby
class LoadSkill < RubyLLM::Tool
  description "Carrega as instruções completas (SKILL.md) de uma skill pelo nome"
  param :name, desc: "Nome exato da skill, conforme listado em <available_skills>"

  def initialize(catalog, allowed_names)
    @catalog = catalog
    @allowed = Array(allowed_names).map(&:to_s)
    super()
  end

  def execute(name:)
    return { error: "skill '#{name}' não disponível para este agente" } unless @allowed.include?(name.to_s)

    skill = @catalog.find(name)
    return { error: "skill '#{name}' não encontrada" } unless skill

    skill.body
  end
end
```

#### Step 3: estágios 5-6 no Executor — `create_chat` + `configure_chat`

**File:** `lib/harness/executor.rb`

Mapa da migração (tabela do doc 03 §4.2, linha a linha):

| Trecho do `Runner` (Fase 0) | Vai para | Mudança |
|---|---|---|
| `RubyLLM.chat(model:, provider:, assume_model_exists:)` | `Executor#create_chat` | nenhuma; require lazy |
| `chat.with_instructions(prompt)` | `Executor#configure_chat` | o prompt vem de `state.context.system` (Builder), não de `@system_prompt.build` |
| `tools = @registry.resolve(profile)` | **NÃO migra** | substituído por `state.allowed_tools` (Resolution — decisão de policy, doc 05; até a task 17, stub) |
| `tools << Tools::LoadSkill.new(@catalog, allowed_skill_names)` | `Executor#configure_chat` | mantida como **tool de sistema fora da allowlist**, agora com `resolution.allowed_skills` |
| `chat.with_tools(*tools)` | `Executor#configure_chat` | nenhuma |
| `seed_history` | `Executor#seed_history` (estágio 5) | nenhuma; o histórico vem do contexto/checkpoint |
| `wire_callbacks` | `Executor#wire_callbacks` (estágio 7) | inalterado + `meta` (D5) + contador `max_tool_calls` |

Implementação:

```ruby
private

# ÚNICO ponto que toca a gem (D9): require lazy, confinado.
def create_chat(profile)
  require "ruby_llm"
  require_relative "tools/load_skill"
  RubyLLM.chat(
    model: profile.model,
    provider: profile.provider,
    assume_model_exists: !profile.provider.nil?
  )
end

# Estágio 5: monta o chat com o contexto do estágio 2 e as tools do estágio 3
# (doc 03 §4). `state` é o TurnState (doc 03 §3; classe criada na task 12 —
# até lá os specs usam um Struct com a mesma superfície).
def configure_chat(chat, state)
  system = state.context.system.to_s
  chat.with_instructions(system) unless system.empty?

  # load_skill é default de sistema (fora da allowlist), senão o
  # progressive disclosure quebra — comportamento preservado da Fase 0
  # (doc 03 §4.2). allowed_skills vem da RESOLUTION (policy), não do
  # provider de contexto (doc 04 §2, provider Skill).
  tools = Array(state.allowed_tools).dup
  skill_names = Array(state.allowed_skills).map { |s| s.respond_to?(:name) ? s.name : s.to_s }
  tools << Tools::LoadSkill.new(@skill_catalog, skill_names) unless skill_names.empty?
  chat.with_tools(*tools) unless tools.empty?

  chat
end
```

- `state.allowed_tools` são **instâncias** prontas (doc 05 §4: "o Executor instancia SÓ as permitidas"; o modelo nunca enxerga tool negada — igual Fase 0).
- Normalizar `allowed_skills` para nomes (a Fase 0 fazia `eff_skills.map(&:name)`), aceitando tanto objetos `Skill` quanto strings — a Resolution do doc 05 não fixa o shape.

**Reference pattern from codebase** (`reference-implementation/lib/agent_runtime/runner.rb` — o original que deve permanecer reconhecível):
```ruby
def build_chat(profile, eff_skills, allowed_skill_names)
  chat = RubyLLM.chat(
    model: profile.model,
    provider: profile.provider,
    assume_model_exists: !profile.provider.nil?
  )

  prompt = @system_prompt.build(
    skills_block: @catalog.format_for_prompt(eff_skills)
  )
  chat.with_instructions(prompt) unless prompt.empty?

  # load_skill é default de sistema (fora da allowlist), senão o
  # progressive disclosure quebra. Demais tools vêm do registry.
  tools = @registry.resolve(profile)
  tools << Tools::LoadSkill.new(@catalog, allowed_skill_names) unless allowed_skill_names.empty?
  chat.with_tools(*tools) unless tools.empty?

  chat
end
```

#### Step 4: estágio 5 — `seed_history` (intacto)

**File:** `lib/harness/executor.rb`

```ruby
# Estágio 5: histórico vem do contexto/checkpoint (doc 03 §4.2). O shape
# {role:, content:} é o mesmo que a Fase 0 já consome (doc 02 §8).
def seed_history(chat, messages)
  Array(messages).each do |m|
    chat.add_message(role: (m[:role] || m["role"]).to_sym,
                     content: m[:content] || m["content"])
  end
end
```

**Reference pattern from codebase** (`reference-implementation/lib/agent_runtime/runner.rb`):
```ruby
def seed_history(chat, history)
  history.each do |m|
    chat.add_message(role: m[:role].to_sym, content: m[:content])
  end
end
```
(A tolerância a chaves string é a única adição: mensagens persistidas voltam do JSON dos stores, doc 02 §3.)

#### Step 5: estágio 7 — `wire_callbacks` (intacto + meta + contador)

**File:** `lib/harness/executor.rb`

```ruby
# Estágio 7: callbacks aditivos do RubyLLM (v1.15+, D9) viram eventos com
# meta (D5). load_skill vira :skill_activated — inalterado da Fase 0.
def wire_callbacks(chat, state)
  tool_calls = 0
  max_tool_calls = state.profile.limits[:max_tool_calls] || 50   # D6
  last_tool_name = nil

  chat.before_tool_call do |tool_call|
    # Guard-rail de loop de tool-use (doc 03 §6/L6): o loop é do RubyLLM;
    # aqui só CONTAMOS e abortamos — nunca dirigimos roundtrips.
    tool_calls += 1
    if tool_calls > max_tool_calls
      raise TimeoutError.new("limite de tool calls excedido (#{max_tool_calls})",
                             stage: :tool_limit)
    end

    last_tool_name = tool_call.name.to_s
    if last_tool_name == "load_skill"
      args = tool_call.arguments || {}
      emit(:skill_activated, { name: args["name"] || args[:name] }, task: state.task)
    else
      emit(:tool_call, { name: tool_call.name, arguments: tool_call.arguments },
           task: state.task)
    end
  end

  chat.after_tool_result do |result|
    emit(:tool_result, { name: last_tool_name, result: result.to_s }, task: state.task)
  end
end
```

- Estrutura idêntica à Fase 0 (comparar com o trecho abaixo); o `emit.call(Event.new(...))` vira o helper `emit` da task 10 (que agrega `meta`).
- `:tool_result` ganha `name` (catálogo D5 exige `{ name, result }`; a Fase 0 emitia só `result`). O callback `after_tool_result` recebe só o resultado — a correlação é a variável `last_tool_name` do closure (mesmo fiber, loop sequencial do RubyLLM).
- O contador zera por turno (variável do closure — `wire_callbacks` roda uma vez por chat/turno). `TimeoutError` levantada dentro do callback derruba o `chat.ask` → capturada na captura única do topo do fiber (task 12) → task `:failed` com `stage: :tool_limit` (doc 03 §6).
- A assinatura de `TimeoutError.new(message, stage:)` é a definida na task 1 (D4, `attr_reader :stage`).

**Reference pattern from codebase** (`reference-implementation/lib/agent_runtime/runner.rb`):
```ruby
# Callbacks aditivos (v1.15+). load_skill vira :skill_activated.
def wire_callbacks(chat, emit)
  chat.before_tool_call do |tool_call|
    if tool_call.name.to_s == "load_skill"
      args = tool_call.arguments || {}
      emit.call(Event.new(:skill_activated, { name: args["name"] || args[:name] }))
    else
      emit.call(Event.new(:tool_call, { name: tool_call.name, arguments: tool_call.arguments }))
    end
  end

  chat.after_tool_result do |result|
    emit.call(Event.new(:tool_result, { result: result.to_s }))
  end
end
```

#### Step 6: shims de teste

**File:** `spec/support/ruby_llm_stub.rb`

Para a suíte rodar **sem a gem** (doc 03 §7), definir um shim de superfície de classe carregado apenas na ausência da real:

```ruby
# Carregado só se a gem não estiver presente. Define APENAS a superfície de
# classe que LoadSkill usa em load-time — nenhum comportamento de runtime é
# reimplementado (RubyLLM First não é violado: isto é andaime de teste).
begin
  require "ruby_llm"
rescue LoadError
  module RubyLLM
    class Tool
      def self.description(_text = nil); end
      def self.param(_name, **_opts); end
    end
  end
end
```

**File:** `spec/support/fake_chat.rb`

Duplo com a superfície exata usada pelo Executor: `with_instructions`, `with_tools(*tools)`, `add_message(role:, content:)`, `before_tool_call(&blk)`, `after_tool_result(&blk)`, `ask(message, &chunk_blk)`. Deve gravar tudo que recebeu (instructions, tools, messages) e permitir roteirizar `ask`: emitir N chunks (`double(content: "…")`), disparar os callbacks registrados com tool_calls roteirizados (`double(name:, arguments:, id:)`) e retornar `double(content: "final")`. Este fake é reusado pela integração da task 12.

### Edge Cases to Handle

1. `context.system` vazio → **não** chamar `with_instructions` (paridade Fase 0: `unless prompt.empty?`).
2. `allowed_skills` vazio → LoadSkill **não** é adicionada (paridade Fase 0: sem skills, sem progressive disclosure).
3. `allowed_tools` vazio E sem skills → `with_tools` não é chamado.
4. `load_skill` chamada com skill fora da allowlist → a própria tool devolve `{ error: ... }` ao modelo (não levanta — semântica RubyLLM/D4 linha Tool Execution).
5. `tool_call.arguments` com chave string ou símbolo (`args["name"] || args[:name]`) — preservar da Fase 0.
6. Exatamente `max_tool_calls` chamadas → passa; a chamada `max + 1` → `TimeoutError(stage: :tool_limit)`.
7. `profile.limits` sem `max_tool_calls` → default 50 (D6).
8. Mensagens de histórico com `role` string vinda do store → `to_sym` na borda.

## Testing

Tudo roda **sem `ruby_llm` instalado** (shim do Step 6): `create_chat` é o único método não coberto por unit (é uma linha de fábrica; coberto na integração da task 12 quando a gem está presente). Nos specs, stubar `executor.send(:create_chat, ...)`/`allow(executor).to receive(:create_chat).and_return(fake_chat)`.

### Unit Tests

**File:** `spec/harness/skill_catalog_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| effective nil/[]/[names] | semântica de allowlist da Fase 0 | todas / nenhuma / subconjunto final |
| precedência de roots | mesma skill em dois roots | primeiro root vence |
| format_for_prompt | conjunto não-vazio / vazio | bloco `<available_skills>` / `""` |
| SKILL.md sem frontmatter/name | arquivo malformado | ignorado (nil) |

**File:** `spec/harness/tools/load_skill_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| skill permitida | catálogo com a skill; nome na allowlist | retorna `skill.body` |
| fora da allowlist | nome não permitido | `{ error: "... não disponível ..." }` |
| inexistente | permitida mas ausente do catálogo | `{ error: "... não encontrada" }` |

**File:** `spec/harness/executor_chat_spec.rb` (estado do turno via Struct/duplo com `context`, `allowed_tools`, `allowed_skills`, `profile`, `task`)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| instructions do Builder | `context.system = "SOUL"` | `fake_chat.instructions == "SOUL"` |
| system vazio | `context.system = ""` | `with_instructions` não chamado |
| tools da Resolution | 2 instâncias em `allowed_tools` | `with_tools` recebeu as 2 |
| LoadSkill de sistema | `allowed_skills = ["cardapio"]` | uma `Harness::Tools::LoadSkill` a mais que `allowed_tools` |
| sem skills | `allowed_skills = []` | nenhuma LoadSkill |
| seed_history | 2 mensagens (uma com chaves string) | `add_message` chamado com roles Symbol, na ordem |
| eventos de tool | fake dispara before/after com tool `lookup` | `:tool_call {name, arguments}` e `:tool_result {name, result}` com `meta.task_id` e `seq` crescente |
| skill_activated | fake dispara before com `load_skill` | `:skill_activated {name}` (e NÃO `:tool_call`) |
| contador de tools | `limits[:max_tool_calls] = 2`; fake dispara 3 before | terceira chamada levanta `TimeoutError` com `stage == :tool_limit` |
| default do contador | limits sem a chave; 50 chamadas passam | a 51ª levanta |

### Integration Tests (if applicable)

Não nesta task — a integração com `RubyLLM.chat` (stub da gem real) é a task 12, quando o pipeline completo existe.

## Definition of Done

- [ ] `configure_chat`/`seed_history`/`wire_callbacks` são reconhecivelmente o código do `runner.rb` (diff mínimo conforme tabela §4.2) — nenhum loop/streaming/retry reimplementado (RubyLLM First)
- [ ] `LoadSkill` continua tool de sistema fora da allowlist, agora construída com `resolution.allowed_skills`
- [ ] Contador `max_tool_calls` no callback de tool: excedeu → `TimeoutError(stage: :tool_limit)` (doc 03 §6/L6)
- [ ] Eventos `:tool_call`/`:tool_result`/`:skill_activated` conforme catálogo D5 (com `meta`)
- [ ] `require "ruby_llm"` aparece SOMENTE em `executor.rb#create_chat` (lazy) e `tools/load_skill.rb` (carregado lazy); `lib/harness.rb` não os alcança em load-time
- [ ] `SkillCatalog` migrado sem mudança de lógica; specs de paridade verdes
- [ ] Suíte roda **sem `ruby_llm` instalado** e sem API key (shim de teste)
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- **Migrações não listadas no tasks.md:** `skill_catalog.rb` e `tools/load_skill.rb` não têm task própria no plano, mas o doc 00 §3/§4 manda migrá-los e esta é a primeira task que os consome (o Executor recebe `skill_catalog:` e injeta a LoadSkill). Migrados aqui, sem mudança de lógica. A task 15 (provider `Skill`) e a 17 (SkillAllowlist) os reusam.
- **"Hook `before_tool`" do doc 03 §6:** a classe `Hooks` (par `before/after_tool`) só chega nas tasks 16/19. O ponto concreto de contagem na Fase 1 é o callback `before_tool_call` do RubyLLM — é onde esta task o implementa. Quando a task 19 integrar `hooks.around(:tool)`, o contador permanece nesta fronteira (mesmo instante do ciclo); não duplicar.
- **`:tool_result.name` via closure:** o callback `after_tool_result` do RubyLLM (1.15) entrega só o resultado; a correlação por `last_tool_name` assume o loop sequencial do RubyLLM (verdadeiro hoje). Se a versão pinada mudar a assinatura do callback para incluir a tool, prefira o dado oficial.
- O `system_prompt.rb` da Fase 0 **não** migra aqui: ele é substituído pelo provider `Prompt` (doc 00 §4, task 15). Até lá, o `context.system` vem do Builder stub da task 12.
- Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 21 novos (sem ruby_llm, via stub requerível), 302 na suíte inteira, 0 falhas, 0 regressões
- **Arquivos criados:** `lib/harness/skill_catalog.rb`, `lib/harness/tools/load_skill.rb`, `spec/support/stubs/ruby_llm.rb`, `spec/support/fake_chat.rb`, `spec/harness/skill_catalog_spec.rb`, `spec/harness/tools/load_skill_spec.rb`, `spec/harness/executor_chat_spec.rb`
- **Arquivos modificados:** `lib/harness/executor.rb` (estágios 5-7 privados), `lib/harness.rb` (require skill_catalog, NÃO load_skill), `spec/spec_helper.rb` (carrega support + resolve ruby_llm)
- **Observações / decisões tomadas:**
  - `SkillCatalog`/`LoadSkill` migrados da Fase 0 **sem mudança de lógica** (só `AgentRuntime → Harness`).
  - `configure_chat`/`seed_history`/`wire_callbacks` são reconhecivelmente o `runner.rb` da Fase 0 — nenhum loop/streaming/retry reimplementado (RubyLLM First). Diferenças previstas: `context.system` (Builder) no lugar de `SystemPrompt#build`; tools da Resolution (`state.allowed_tools`) no lugar de `registry.resolve`; `meta` D5 nos eventos; contador `max_tool_calls`.
  - `require "ruby_llm"` confinado a `executor.rb#create_chat` (lazy) e `tools/load_skill.rb` (carregado lazy). `lib/harness.rb` **não** os alcança em load-time — confirmado (`defined?(RubyLLM)` falso após `require "harness"`).
  - **Ajuste no andaime de teste vs. a proposta da task:** o shim originalmente proposto (`spec/support/ruby_llm_stub.rb` com `begin/rescue`) NÃO resolvia o `require "ruby_llm"` bare no topo de `load_skill.rb` (definir a constante não cria um arquivo requerível). Solução: stub **requerível** em `spec/support/stubs/ruby_llm.rb`, com o dir adicionado ao `$LOAD_PATH` pelo spec_helper **só quando a gem real está ausente** (nunca a sombreia). Descoberto pela falha de carga dos specs.
  - Contador `max_tool_calls`: default 50 (D6); excedeu → `TimeoutError(stage: :tool_limit)`; zera por turno (variável de closure do `wire_callbacks`).
  - `:tool_result` ganha `name` via `last_tool_name` do closure (loop sequencial do RubyLLM), conforme catálogo D5.
