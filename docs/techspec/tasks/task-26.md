# Task 26: `Gemfile` pinado + Gemfile.lock + `Server::Boot` (plugins→stores→recovery→listen) + smoke E2E kill -9

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [07-service-platform.md](../07-service-platform.md) · [02-session-task-checkpoint.md](../02-session-task-checkpoint.md)
> **Status:** ⬜ TODO
> **Complexity:** Med

---

## Objective

Fechar a Fase 1: pinar o `Gemfile` (D9) com `Gemfile.lock` commitado,
implementar `Server::Boot` com a ordem obrigatória
plugins → stores → recovery → listen (doc 07 §4) e entregar o smoke E2E do
doc 07 §7 (Falcon + `kill -9` no meio do turno + reboot com retomada) — **o
critério de conclusão da fase inteira** (doc 00 §6).

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 13 | Handler `ResumeTask` (critério running-órfã, skip de side-effects) + integração real do Recovery | ⬜ TODO |
| 22 | Autodiscovery por gem (`Plugin.announce`, precedência workspace > gem > bundled) | ⬜ TODO |
| 24 | Rotas formais: `POST /v1/commands/:type` + açúcar, reads GET, `/v1/events` SSE, rota legada | ⬜ TODO |

## Context

É a última task do plano. O `Boot` é o que transforma os componentes das 25
tasks anteriores num serviço: o composition root (`config/wiring.rb`) monta
tudo, o `Recovery` (doc 02 §4) retoma tasks interrompidas **antes** de o
servidor aceitar qualquer request — "nunca aceita request antes do recovery"
é garantido **por construção**, porque o listen é o último passo (doc 07 §4 e
§7). O `Gemfile` pinado (D9) corrige o risco apontado no README da Fase 0: os
callbacks `before_tool_call`/`after_tool_result` quebram silenciosamente em
`ruby_llm` < 1.15.

O smoke E2E materializa o critério de conclusão da fase (doc 00 §6): "fluxo
`SendMessage` com `session_id` sobrevive a `kill -9` + reboot retomando do
checkpoint; suíte inteira verde sem chave de API". Sem este teste verde, a
Fase 1 não está concluída.

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| MODIFY | `Gemfile` (raiz do projeto) | pinagem D9 + grupo dev/test |
| CREATE | `Gemfile.lock` | `bundle lock` — passa a ser commitado (D9) |
| CREATE | `server/boot.rb` | `Harness::Server::Boot` — sequência de boot |
| MODIFY | `config.ru` | passa a chamar `Server::Boot` (doc 07 §8) |
| MODIFY | `config/wiring.rb` | expor o objeto de wiring consumido pelo Boot (backend por config, recovery construído) |
| CREATE | `spec/harness/server/boot_spec.rb` | ordem plugins→stores→recovery→listen (spies) |
| CREATE | `spec/harness/load_guard_spec.rb` | `require "harness"` não carrega `ruby_llm` (D9) |
| CREATE | `spec/e2e/smoke_resume_spec.rb` | smoke E2E kill -9 (doc 07 §7) |
| CREATE | `spec/support/smoke/config.ru` | entrada do processo do smoke (wiring de teste + Boot) |
| CREATE | `spec/support/smoke/shims/ruby_llm.rb` | fake do RubyLLM carregado via `$LOAD_PATH` no processo filho |

### Step-by-Step Instructions

#### Step 1: `Gemfile` pinado (D9) + `Gemfile.lock`

**File:** `Gemfile`

**Reference pattern from codebase**
(`docs/harness_handoff/reference-implementation/Gemfile` — o ponto de partida
sem pinagem, que esta task evolui):

```ruby
# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.2"

gem "ruby_llm"        # camada model-agnostic (o "pi-ai" do Ruby)
gem "rack"            # transporte
gem "falcon"          # servidor async — encaixe natural pro streaming SSE
```

Delta: aplicar as pinagens **exatas** do D9 (00-overview):

```ruby
# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.2"

gem "ruby_llm", ">= 1.15"     # before_tool_call/after_tool_result exigem 1.15+
gem "async", "~> 2.0"
gem "falcon", "~> 0.47"       # servidor (apenas em harness-server)
gem "sqlite3", "~> 2.0"       # apenas backend SQLite
gem "rack", "~> 3.0"          # apenas em harness-server

group :development, :test do
  gem "rspec"
end
```

- Rodar `bundle install` / `bundle lock` e **commitar o `Gemfile.lock`** (D9:
  "Gemfile.lock passa a ser commitado").
- O grupo dev/test não é pinado pelo D9 — use a versão estável corrente do
  RSpec. `Rack::MockRequest` vem do próprio `rack` (não precisa de
  `rack-test`).
- Os comentários "apenas em harness-server" documentam a fronteira para a
  futura separação de gems — não criar gemspecs nesta fase.

#### Step 2: Guard de load-time — núcleo não requer `ruby_llm`

**File:** `spec/harness/load_guard_spec.rb`

D9: "o núcleo (`lib/`) não requer `ruby_llm` em load-time fora dos pontos de
integração (Executor, LoadSkill) — mantém a regra de testabilidade sem RubyLLM
(handoff §6)". Como a gem agora está sempre no bundle, a regra vira um teste:

- Spec que roda `ruby -Ilib -e 'require "harness"; exit(defined?(RubyLLM) ? 1 : 0)'`
  num subprocesso (via `system`/`Open3`) e espera exit 0 — carregar o núcleo
  não pode arrastar `RubyLLM` (os requires no Executor/LoadSkill são lazy,
  doc 03 §7).

#### Step 3: `Server::Boot` — ordem obrigatória

**File:** `server/boot.rb`

Interface do doc 07 §2 e fluxo do §4:

```ruby
class Boot
  def initialize(wiring)
  def call                      # plugins → stores → recovery.run → listen
end
```

```
boot (ordem obrigatória):
  wiring (plugins/registries/catalogs) → stores → Recovery.run (doc 02 §4)
  → Falcon listen                        # nunca aceita request antes do recovery
```

Implementação:

1. **`wiring`** é um objeto/Struct exposto pelo `config/wiring.rb` com passos
   nomeados — p.ex. `load_plugins` (constrói o `Plugin::Loader` com
   `roots: [workspace, *Plugin.announced_roots, *bundled]` e chama
   `load_all`, doc 06 §4; single-fiber, doc 06 §5), `build_stores` (backend
   Memory ou SQLite conforme config + os 3 stores de domínio + bus/executor/
   app), `recovery` (instância de `Harness::Recovery`, doc 02 §2) e `app`
   (a `Server::App` da task 24). Refatore o wiring atual para expor esses
   passos sem quebrar as constantes-atalho.
2. **`Boot#call`** executa, nesta ordem e sem paralelismo:
   `wiring.load_plugins` → `wiring.build_stores` → `wiring.recovery.run`
   (dentro do reactor — `Sync { ... }` se não houver um corrente) → devolve o
   Rack app pronto para o listen. O **listen é o último passo e não pertence
   ao Boot**: quem serve é o Falcon (`falcon serve` carrega o `config.ru`
   inteiro — incluindo o recovery — **antes** de servir requests). Assim,
   "request antes do recovery" é impossível por construção: não existe socket
   servindo antes de `#call` retornar.
3. `Recovery.run` retorna `{resumed:, failed:}` (doc 02 §2) — logar o sumário
   no boot (stdout simples; não inventar logger).
4. Falha do próprio store no boot (arquivo corrompido) → **abortar o processo**
   com mensagem clara (doc 02 §6: subir sem durabilidade seria pior que não
   subir). Falha ao retomar **uma** task não derruba o boot (a task vai a
   `:failed` — já é comportamento do Recovery, task 8/13).

#### Step 4: `config.ru` chama o Boot

**File:** `config.ru`

**Reference pattern from codebase**
(`docs/harness_handoff/reference-implementation/config.ru` — Fase 0):

```ruby
# frozen_string_literal: true

require_relative "app/server"

# Rode com Falcon (async/streaming de verdade):
#   bundle exec falcon serve -b http://0.0.0.0:9292
run APP
```

Delta (doc 07 §8: "`config.ru` → chama `Server::Boot` (que executa o recovery
antes do `run`)"):

```ruby
# frozen_string_literal: true

require_relative "config/wiring"
require_relative "server/boot"

# Rode com Falcon (async/streaming de verdade):
#   bundle exec falcon serve -b http://0.0.0.0:9292
# O Boot executa plugins → stores → recovery ANTES do run — nenhum request
# é servido antes do recovery terminar (doc 07 §4).
run Harness::Server::Boot.new(WIRING).call
```

#### Step 5: Spec de ordem do Boot (spies)

**File:** `spec/harness/server/boot_spec.rb`

Wiring duplo cujos passos registram a ordem num array compartilhado
(`calls << :plugins` etc.); `recovery` duplo idem. Verificar
`[:plugins, :stores, :recovery]` na ordem exata e que `#call` só retorna o app
**depois** do recovery (doc 07 §7: "ordem plugins→recovery→listen (spies)").
Cobrir também: recovery levanta `StoreError` → Boot aborta (não retorna app);
recovery com uma task `:failed` → boot segue.

#### Step 6: Integração — Falcon em porta efêmera, listen por último

**File:** `spec/e2e/smoke_resume_spec.rb` (primeiro cenário) — doc 07 §7:
"request antes do fim do recovery é impossível por construção (listen é o
último passo — teste de integração com Falcon em porta efêmera)".

- Escolher porta livre no teste (abrir `TCPServer.new("127.0.0.1", 0)`, ler a
  porta, fechar) e subir o processo:
  `Process.spawn(env, "bundle", "exec", "falcon", "serve", "--bind",
  "http://127.0.0.1:#{port}", chdir: raiz_do_smoke)` usando o
  `spec/support/smoke/config.ru`.
- Com um recovery instrumentado (o wiring do smoke grava um marker file ao
  fim do `Recovery.run`), verificar: enquanto o socket não aceita conexões, o
  marker pode não existir; **na primeira resposta HTTP bem-sucedida o marker
  já existe** (recovery terminou antes do primeiro request servido).
- Encerrar o processo ao final (`ensure` com `Process.kill` + `wait`).

#### Step 7: Smoke E2E — `kill -9` no meio do turno + reboot + retomada

**Files:** `spec/e2e/smoke_resume_spec.rb`, `spec/support/smoke/config.ru`,
`spec/support/smoke/shims/ruby_llm.rb`

O cenário literal do doc 07 §7 (CI, **sem API key**): "subir Falcon +
RubyLLM mockado; `POST /v1/messages` com `session_id`; matar o processo no
meio de um turno; subir de novo; verificar task retomada".

**Mock do RubyLLM em processo separado** — o fake vive em
`spec/support/smoke/shims/ruby_llm.rb` e é carregado no filho via
`RUBYOPT=-I spec/support/smoke/shims` (o `require "ruby_llm"` lazy do
Executor resolve para o shim). O shim define o subconjunto usado pelo
Executor (task 11/12 — **confira no código real**: `RubyLLM.configure`,
`RubyLLM.chat`/`.with_instructions`/`.with_tools`/`.ask` com bloco de chunks
e callbacks `before_tool_call`/`after_tool_result`). Comportamento
roteirizado por ENV/arquivo de controle:

- **Modo "trava"** (1º boot): `ask` emite um chunk de conteúdo, grava um
  marker file `turn_started` e **bloqueia** (loop com sleep async curto
  esperando um arquivo que nunca chega) — janela determinística para o kill.
- **Modo "completa"** (2º boot, sinalizado por ENV `SMOKE_MODE=complete` ou
  pela existência de outro arquivo): `ask` emite os chunks e retorna resposta
  final imediatamente.

**Wiring do smoke** (`spec/support/smoke/config.ru` + wiring próprio):
backend **`Stores::SQLite`** apontando para `ENV["SMOKE_DB"]` (tmpdir do
teste) — durabilidade real é o que o kill -9 testa (ver Notes sobre o
"backend Memory" do doc 07 §7); perfil de agente apontando para o modelo
fake; sem plugins externos.

Roteiro do teste (host):

1. Porta efêmera + tmpdir; `pid1 = spawn(falcon serve ...)` com
   `SMOKE_DB=...`, `RUBYOPT=-I...shims`, modo "trava".
2. Aguardar o servidor responder (poll em `GET /v1/tasks/none` → 404, prova
   de vida).
3. `POST /v1/sessions` → captura `session_id`.
4. `POST /v1/commands/send_message` com `{agent:, message:, session_id:}` →
   **202 `{task_id}`** imediato (usar a rota genérica, não o SSE — o
   `task_id` precisa sobreviver ao kill no lado do teste).
5. Aguardar o marker `turn_started` (o turno está no meio do estágio 6).
6. `Process.kill(9, pid1)` + `Process.wait` — morte não-cooperativa; a task
   fica `running` no Task Store, órfã.
7. `pid2 = spawn(...)` mesmo `SMOKE_DB`, modo "completa". O Boot roda o
   Recovery **antes** do listen: `running_or_interrupted` acha a task órfã
   com checkpoint → `dispatch(resume_task)` (doc 02 §4); o critério
   running-órfã (`executor.running?(task_id) == false`, doc 03 §3) permite a
   retomada; side-effects registrados são pulados (task 13).
8. Poll `GET /v1/tasks/:task_id` até `status == "completed"` (timeout ~10s).
   Verificar `executions.length == 2` (attempt 1 aberta/interrompida,
   attempt 2 concluída — doc 02 §3: retry/resume abre nova entrada).
9. `GET /v1/sessions/:session_id` → transcript contém a mensagem do usuário
   **e** a resposta do assistant (o turno retomado persistiu no estágio 8).
10. `ensure`: matar `pid2`, limpar tmpdir.

Marcar o spec com tag (`:smoke`) e timeout generoso; ele roda no CI sem
nenhuma API key (critério doc 00 §6). A suíte default pode excluir a tag
localmente, mas o CI a executa.

### Edge Cases to Handle

1. **Recovery com reactor**: `Recovery.run` despacha `resume_task` que cria
   fibers de task; no load do `config.ru` pode não haver reactor corrente —
   envolver em `Sync { }` quando necessário. Atenção: se o fiber da task
   retomada for filho do `Sync`, o boot espera o turno terminar antes do
   listen — aceitável na Fase 1 (doc 07 §4 só exige recovery **antes** do
   listen; doc 02 §5 prefere não bloquear além do dispatch). Alinhe com onde
   a task 10/13 cria os fibers (ver Notes).
2. **Porta efêmera**: há corrida entre "achar porta livre" e o bind do Falcon
   — tolerável no CI; retry uma vez se o bind falhar.
3. **Kill antes do marker** / marker nunca criado → falhar o teste com
   mensagem clara (timeout de espera do marker), não travar o CI.
4. **Processos zumbis**: todo spawn com `ensure` de kill/wait — inclusive
   quando asserts falham no meio.
5. **SQLite + kill -9**: WAL (doc 01 §3) garante que o checkpoint transacional
   sobrevive; nunca matar o processo do teste host, só o filho.
6. **Boot com store corrompido** → processo aborta com mensagem clara
   (doc 02 §6); coberto no spec do Step 5.
7. **`bundle lock` em CI**: o lock commitado precisa cobrir a plataforma do
   CI (`bundle lock --add-platform x86_64-linux` se o dev estiver em macOS).

## Testing

### Unit Tests

**File:** `spec/harness/server/boot_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| ordem dos passos | wiring/recovery duplos com registro de chamadas | exatamente `[:plugins, :stores, :recovery]`, app retornado depois |
| listen por último | `#call` só retorna o app após recovery | garantido pelo teste de ordem + integração (Step 6) |
| store corrompido | recovery/stores levantam `StoreError` no boot | Boot aborta (levanta/exit), app não é retornado |
| task irrecuperável | recovery retorna `{failed: [id]}` | boot segue; sumário logado |

**File:** `spec/harness/load_guard_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| núcleo sem ruby_llm | subprocesso `require "harness"` | `defined?(RubyLLM)` é nil (exit 0) |

### Integration Tests (if applicable)

**File:** `spec/e2e/smoke_resume_spec.rb` (tag `:smoke`; CI sem API key)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| recovery antes do listen | Falcon em porta efêmera + marker do recovery | primeira resposta HTTP ⇒ marker existe |
| kill -9 + reboot retoma | roteiro completo do Step 7 | task `completed` no 2º boot; `executions.length == 2` |
| transcript persistido | `GET /v1/sessions/:id` pós-retomada | mensagem do usuário + resposta do assistant no transcript |
| **critério da fase** | doc 00 §6 | fluxo `SendMessage` com `session_id` sobrevive a kill -9 + reboot retomando do checkpoint |

## Definition of Done

- [ ] `Gemfile` com as pinagens exatas do D9; `Gemfile.lock` commitado (com plataforma do CI)
- [ ] Guard verde: `require "harness"` não carrega `ruby_llm`
- [ ] `Server::Boot#call` executa plugins → stores → recovery → (app p/ listen), ordem testada com spies
- [ ] `config.ru` delega ao Boot; nenhum request servido antes do fim do recovery (integração em porta efêmera)
- [ ] Smoke E2E verde no CI **sem API key**: kill -9 no meio do turno → reboot → task retomada do checkpoint, transcript íntegro
- [ ] Suíte inteira verde sem chave de API (RubyLLM mockado só na integração) — critério de conclusão da fase (doc 00 §6)
- [ ] All tests passing
- [ ] No linting errors
- [ ] Code reviewed

## Notes

- Gerado antes da implementação de qualquer task. Se dependências já
  estiverem implementadas quando você pegar esta task, leia o código real —
  ele prevalece sobre o estado planejado aqui.
- **"Backend Memory" no doc 07 §7:** o texto do smoke menciona "Falcon +
  backend Memory", mas `kill -9` + reboot exige durabilidade em disco — o
  smoke usa `Stores::SQLite` (a paridade Memory/SQLite é garantida pela suíte
  de contrato do doc 01). Lacuna de redação registrada; o critério da fase
  (doc 00 §6, "retomando do checkpoint") é inequívoco.
- **Checkpoint do 1º turno:** o Recovery marca `:failed` task órfã **sem**
  checkpoint (doc 02 §4). Para o kill no meio do turno 1 ser retomável, o
  checkpoint do turno corrente precisa existir antes do estágio 6 (doc 02 §3:
  "o checkpoint do turno n contém o estado no início do turno n"). Verifique
  como a task 12 implementou; se o checkpoint só for gravado no estágio 8,
  este smoke expõe a lacuna — resolva com os donos das tasks 12/13 gravando o
  checkpoint inicial do turno na entrada (é pré-condição do critério da
  fase, não trabalho novo).
- **Onde nasce o fiber da retomada:** se o dispatch do `resume_task` criar o
  fiber como filho do `Sync` do boot, o turno retomado completa antes do
  listen (boot mais lento, semanticamente correto); se a task 10 criar
  fibers num reactor próprio do Executor, o boot não bloqueia (preferência
  do doc 02 §5). Ambos passam nos testes deste arquivo — siga o código real.
- O shim do RubyLLM deve espelhar a superfície que o Executor realmente usa
  (tasks 11/12) — escreva-o **depois** de ler `lib/harness/executor.rb` real.
- Convenções: `# frozen_string_literal: true`, comentários em português,
  stdlib para tudo no shim/teste (Open3, TCPServer, FileUtils).
