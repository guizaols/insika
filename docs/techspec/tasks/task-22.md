# Task 22: Autodiscovery por gem — `Plugin.announce` + precedência workspace > gem > bundled

> **Jira:** — (sem ticket)
> **Task Plan:** [tasks.md](./tasks.md)
> **Tech Spec:** [00-overview.md](../00-overview.md) · [06-registries-plugin-autodiscovery.md](../06-registries-plugin-autodiscovery.md)
> **Status:** ✅ DONE
> **Complexity:** Low

---

## Objective

Implementar o boot hook estilo Railtie (`Harness::Plugin.announce`/`announced_roots` — doc 06 L1) e a regra de habilitação/precedência consolidada: `workspace/plugins` > roots anunciados por gem (ordem de `announce`) > bundled, com gem default-enabled e desabilitável por `disabled:` (doc 06 §3, L2).

## Dependencies

| Task | Title | Status |
|------|-------|--------|
| 21 | `Plugin::Loader` estendido (manifesto novo, config_schema, rollback, RegistrationAPI) | ⬜ TODO |

(Grafo do tasks.md: `22 → 21`.)

## Context

Doc 06 §2-§4, RFC-0003 §2. O mecanismo é deliberadamente **explícito e barato** (L1 — nada de scan de LOAD_PATH ou de gems instaladas): uma gem de plugin chama, no load do seu `lib/`:

```ruby
Harness::Plugin.announce(File.expand_path("../plugin", __dir__))
```

Como o `require` do Gemfile acontece **antes** do composition root rodar (doc 06 §4, passo 1), os roots anunciados já estão acumulados quando `config/wiring.rb` monta o `Loader`. A precedência fica clara por construção (responde RFC-0003 §9.1): a ordem é a de `require` das gems, e workspace sempre ganha.

Habilitação (L2, RFC-0003 §5 literal): instalar uma gem é ato intencional do operador → **gem anunciada é default-enabled**, desabilitável por `disabled: [ids]` no wiring; bundled vem "de fábrica" → continua exigindo `enabled:` explícito (Fase 0).

Esta task fecha a Etapa F do lado de plugins; a task 26 consome tudo no `Server::Boot` (plugins → recovery → listen).

## Implementation Details

### Files to Touch

| Action | File Path | Description |
|--------|-----------|-------------|
| CREATE | `lib/harness/plugin.rb` | Módulo `Harness::Plugin` com `announce`/`announced_roots` (acumulador pré-boot) |
| MODIFY | `lib/harness/plugin/loader.rb` | Regra de habilitação por classe de root (`announced_roots:`/`disabled:`) |
| MODIFY | `lib/harness.rb` | `require_relative "harness/plugin"` (antes do loader) |
| MODIFY | `config/wiring.rb` | Compõe `roots: [workspace, *announced, *bundled]` e passa `disabled:` |
| CREATE | `spec/harness/plugin_spec.rb` | `announce`/`announced_roots` |
| MODIFY | `spec/harness/plugin/loader_spec.rb` | Casos de precedência workspace > gem > bundled e habilitação de gem |

### Step-by-Step Instructions

#### Step 1: `Harness::Plugin.announce` / `.announced_roots`

**File:** `lib/harness/plugin.rb`

O arquivo precisa ser **mínimo e sem dependências** — ele é carregado por gems de terceiros no load do `lib/` delas, possivelmente antes de qualquer outra coisa do Harness:

```ruby
# frozen_string_literal: true

module Harness
  # Boot hook por gem (RFC-0003 §2, doc 06 L1 — estilo Railtie):
  # a gem chama Harness::Plugin.announce(root) no load do seu lib/;
  # o composition root consome announced_roots ao montar o Loader.
  module Plugin
    @announced_roots = []

    class << self
      # Acumula roots ANTES do boot, na ordem de require das gems.
      def announce(root)
        root = File.expand_path(root.to_s)
        @announced_roots << root unless @announced_roots.include?(root)
        root
      end

      # Consumido pelo composition root (config/wiring.rb).
      def announced_roots
        @announced_roots.dup.freeze
      end

      # Suporte de teste: o acumulador é estado de processo.
      def reset_announced!
        @announced_roots = []
      end
    end
  end
end
```

- `announce` preserva a **ordem de chamada** (que é a ordem de `require` do Gemfile — é ela que define a precedência entre gems, doc 06 §3) e deduplica por path expandido (announce repetido é no-op).
- `announced_roots` devolve cópia congelada — ninguém muta o acumulador por fora.
- `Loader` (task 21) já vive em `lib/harness/plugin/loader.rb` sob o mesmo módulo — garanta que `lib/harness/plugin.rb` não requer o loader (o hook precisa carregar sozinho) e que `lib/harness.rb` requer os dois.

**Reference pattern from codebase:** não há análogo na Fase 0 (componente novo — o gap do RFC-0003 §8). O estilo de módulo-com-estado segue as convenções dos arquivos da Fase 0 (`# frozen_string_literal: true`, comentários em português, stdlib apenas).

#### Step 2: Habilitação por classe de root no Loader

**File:** `lib/harness/plugin/loader.rb`

Estender o `initialize` com dois kwargs de default vazio (materialização de §3/L2 — ver Notes sobre a assinatura de §2):

```ruby
def initialize(roots:, registries:, enabled:, event_stream:,
               announced_roots: [], disabled: [])
```

- `roots:` continua a lista plana ordenada por precedência (doc 06 §4: `[workspace, *announced, *bundled]`) — a mecânica "primeiro root vence" da task 21 não muda.
- `announced_roots:` identifica quais desses roots vieram de `announce` (o wiring passa `Harness::Plugin.announced_roots`); `disabled:` é a lista de ids desabilitados pelo operador (RFC-0003 §5).
- Substituir o gate `next unless @enabled.include?(id)` (task 21) por um predicado:

```ruby
# Habilitação (doc 06 §3, L2): gem anunciada é default-enabled,
# desabilitável por disabled:; workspace e bundled exigem enabled
# explícito (regra Fase 0).
def enabled?(id, manifest_file)
  if announced?(manifest_file)
    !@disabled.include?(id)
  else
    @enabled.include?(id)
  end
end

def announced?(manifest_file)
  @announced_roots.any? { |root| manifest_file.start_with?("#{root}#{File::SEPARATOR}") || File.dirname(manifest_file) == root }
end
```

- `disabled:` também vale como veto absoluto: um id em `disabled` não carrega nem se estiver em `enabled` (deny vence — mesma filosofia das allowlists, D6).
- Normalizar `@disabled`/`@enabled` com `map(&:to_s)` (Fase 0 já fazia com `enabled`).

#### Step 3: Wiring

**File:** `config/wiring.rb`

Compor os roots na ordem consolidada do doc 06 §3-§4 e passar a classificação:

```ruby
# 1. gems já carregadas chamaram Plugin.announce(root) (require do Gemfile)
announced = Harness::Plugin.announced_roots

loader = Harness::Plugin::Loader.new(
  roots: [File.join(ROOT, "plugins"), *announced, *BUNDLED_PLUGIN_ROOTS],
  registries: REGISTRIES,
  enabled: %w[weather],          # bundled: opt-in explícito (Fase 0)
  disabled: [],                  # gems: default-enabled; operador veta aqui
  announced_roots: announced,
  event_stream: EVENT_STREAM
)
```

`workspace/plugins` é o `plugins/` do repositório (maior precedência); `BUNDLED_PLUGIN_ROOTS` são os que vêm "de fábrica" com a gem do Harness (na Fase 1, pode ser vazio ou o mesmo dir de exemplos — siga o que a task 26 consolidar no boot). Os catálogos continuam sendo construídos com os dirs retornados por `load_all` (precedência workspace > plugin — doc 06 §4, passo 4).

### Edge Cases to Handle

1. **`announce` do mesmo root duas vezes** → deduplica (no-op); ordem do primeiro announce preservada.
2. **Mesmo `id` em workspace E em gem anunciada** → workspace vence (primeiro root da lista, mecânica da task 21). Idem gem vs bundled: a gem vence (vem antes na lista).
3. **Gem anunciada com id em `disabled:`** → não carrega; sem warn (é decisão explícita do operador, não erro).
4. **Id em `enabled:` E `disabled:`** → não carrega (veto vence).
5. **Root anunciado que não existe no filesystem** → `Dir.glob` vazio, sem erro (gem mal empacotada não derruba o boot).
6. **Root anunciado que é prefixo textual de outro path** (ex.: `/x/plug` vs `/x/plugin-foo`) → o `announced?` compara com separador (`start_with?("#{root}/")`), não prefixo cru.
7. **Nenhuma gem anunciou nada** → `announced_roots == []`; comportamento idêntico à task 21 (retrocompatível).
8. **Ordem de announce entre duas gems com o mesmo id** → a que foi `require`-ada primeiro vence (L1: a ordem é a de require).

## Testing

### Unit Tests

**File:** `spec/harness/plugin_spec.rb`

| Test Case | Description | Expected |
|-----------|-------------|----------|
| announce acumula | 2 announces | `announced_roots` na ordem de chamada |
| announce deduplica | mesmo root 2x | 1 entrada |
| announce expande path | root relativo | path absoluto em `announced_roots` |
| announced_roots congelado | tentar mutar o retorno | `FrozenError` / acumulador intacto |
| reset_announced! | após announces | lista vazia |

(Usar `Harness::Plugin.reset_announced!` em `before` — o acumulador é estado de processo.)

**File:** `spec/harness/plugin/loader_spec.rb` (casos novos — doc 06 §7; "gem" simulada = announce manual de fixture em tmpdir)

| Test Case | Description | Expected |
|-----------|-------------|----------|
| gem default-enabled | plugin em root anunciado, id fora de `enabled:` | carrega |
| disabled de gem | mesmo cenário + id em `disabled:` | não carrega |
| bundled continua opt-in | plugin em root não-anunciado, fora de `enabled:` | não carrega (regra Fase 0) |
| workspace > gem | mesmo id nos dois roots | versão do workspace registrada |
| gem > bundled | mesmo id nos dois | versão da gem registrada |
| ordem de announce | mesmo id em duas "gems" | a anunciada primeiro vence |
| veto absoluto | id em `enabled:` e `disabled:` | não carrega |
| root anunciado inexistente | path sem dir | load_all sem erro |
| retrocompat | `announced_roots:`/`disabled:` omitidos | comportamento da task 21 intacto |

### Integration Tests (if applicable)

Não nesta task. O fluxo real "gem no Gemfile → require → announce → boot" é coberto pelo smoke E2E da task 26 (`Server::Boot`: plugins → recovery → listen), que depende desta.

## Definition of Done

- [ ] `Harness::Plugin.announce`/`.announced_roots` conforme doc 06 §2, carregável isoladamente (sem requerer o resto do Harness)
- [ ] Precedência consolidada: workspace > gem (ordem de announce) > bundled (doc 06 §3)
- [ ] Gem anunciada default-enabled; `disabled: [ids]` desabilita; bundled/workspace seguem exigindo `enabled:` (L2)
- [ ] `config/wiring.rb` compõe os roots e a classificação
- [ ] Todos os testes passando; **suíte roda sem `ruby_llm` instalado e sem API key**
- [ ] Sem erros de lint
- [ ] Código revisado

## Notes

- **Aviso de drift:** Gerado antes da implementação de qualquer task. Se dependências já estiverem implementadas quando você pegar esta task, leia o código real — ele prevalece sobre o estado planejado aqui.
- **Assinatura do Loader:** o doc 06 §2 lista só `roots:, registries:, enabled:, event_stream:`; os kwargs `announced_roots:`/`disabled:` são a materialização inevitável de §3/L2 (o Loader precisa distinguir classe de root para aplicar habilitação distinta). Defaults vazios mantêm a assinatura de §2 válida. Lacuna registrada — se a revisão preferir outra forma (ex.: roots estruturados), é mudança local.
- **Habilitação de workspace:** o doc 06 §3 só distingue "bundled exige enabled" e "gem default-enabled"; para workspace mantivemos a regra Fase 0 (exige `enabled:`, como bundled) — é a leitura conservadora. Registrar no PR se preferir workspace default-enabled.
- `reset_announced!` é suporte de teste (o acumulador é global de processo); não usar em código de produção.
- Não implementar scan de LOAD_PATH/gems instaladas — explicitamente rejeitado pela L1.

---

## Conclusão

- **Concluído em:** 2026-07-09
- **Implementado por:** Claude (execução automatizada)
- **Testes:** 12 novos (5 plugin + 7 loader de habilitação por classe de root), 528 na suíte inteira, 0 falhas, 0 regressões
- **Arquivos criados:** `lib/harness/plugin.rb`, `spec/harness/plugin_spec.rb`
- **Arquivos modificados:** `lib/harness/plugin/loader.rb` (initialize + enabled?/announced?), `lib/harness.rb` (require plugin antes do loader), `spec/harness/plugin/loader_spec.rb`
- **Observações / decisões tomadas:**
  - `Harness::Plugin.announce`/`announced_roots`/`reset_announced!` num arquivo mínimo (sem requerer o loader — a gem carrega o hook sozinha). `announce` preserva ordem de require e deduplica por path expandido; `announced_roots` congelado.
  - `Loader#enabled?(id, plugin_dir)`: `disabled:` é veto absoluto (deny vence, D6); root anunciado → default-enabled; workspace/bundled → `enabled:` explícito (Fase 0). `announced?` compara com separador (não prefixo cru) e expande paths dos dois lados.
  - Assinatura do Loader ganhou `announced_roots:`/`disabled:` (defaults vazios → retrocompat com a task 21 / assinatura §2 válida). Lacuna registrada (materialização de §3/L2).
  - **Workspace mantém regra Fase 0** (`enabled:`), leitura conservadora do doc 06 §3 (que só fala de bundled vs gem).
  - `config/wiring.rb` NÃO tocado (não existe; consolidação no boot é da task 26).
