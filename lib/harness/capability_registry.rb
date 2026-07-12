# frozen_string_literal: true

module Harness
  # Guarda temporário — as classes definitivas vivem em errors.rb (carregado
  # ANTES deste arquivo em lib/harness.rb). Se já existirem, este bloco é pulado
  # (nenhuma colisão, nada a remover depois).
  unless defined?(Harness::CapabilityUnavailable)
    class CapabilityError < Error; end

    class CapabilityUnavailable < CapabilityError
      def initialize(capability:)
        super("capability '#{capability}' sem provider disponível")
      end
    end

    class CapabilityAmbiguous < CapabilityError
      attr_reader :candidates

      def initialize(capability:, candidates:)
        @candidates = candidates
        super("capability '#{capability}' ambígua entre #{candidates.size} candidatos")
      end
    end
  end

  # Resolução intenção→implementação. INDIREÇÃO pura: NÃO herda
  # de `Registry` (que guarda executáveis) — guarda `Provider`s (metadados de
  # resolução) e devolve o `impl_name` que OUTRO registry instancia. Imutável
  # pós-boot por construção (só o boot/loader registra), como o `Registry`.
  class CapabilityRegistry
    Provider = Data.define(:capability, :impl_name, :kind, :plugin, :priority, :available)
    #   kind:      :tool | :workflow
    #   priority:  Integer | nil (nil = mais baixo; herda precedência de plugin)
    #   available: callable -> bool (default -> { true }; nunca nil num Provider registrado)

    def initialize
      # capability(Symbol) -> [Provider], na ordem de registro (proxy de announce)
      @providers = Hash.new { |h, k| h[k] = [] }
    end

    # Ao contrário do `Registry#register`, NÃO há "primeiro vence": registrar a
    # mesma capability mais de uma vez é o caso normal (providers concorrendo) —
    # a dedup/desempate acontece no `resolve`, não aqui.
    def register(capability, impl_name:, kind:, plugin: nil, priority: nil, available: nil)
      unless %i[tool workflow].include?(kind)
        raise ArgumentError, "kind inválido: #{kind.inspect} (use :tool ou :workflow)"
      end

      if kind == :workflow
        warn "[capability_registry] '#{capability}' registrada com kind: :workflow — " \
             "exposição ao agente adiada (L5)"
      end

      @providers[capability.to_sym] << Provider.new(
        capability: capability.to_sym, impl_name: impl_name.to_s, kind: kind,
        plugin: plugin&.to_s, priority: priority, available: available || -> { true }
      )
      self
    end

    def providers(capability) = @providers[capability.to_sym].dup

    def capabilities = @providers.keys

    # Rollback do Loader, simétrico ao `Registry#deregister_plugin`. Remove
    # só os Providers do plugin; capabilities sem provider restante somem de
    # `capabilities` (limpa a chave para o Hash.new-com-bloco não recriá-la vazia).
    def deregister_plugin(plugin_id)
      @providers.each_value { |list| list.delete_if { |p| p.plugin == plugin_id.to_s } }
      @providers.delete_if { |_cap, list| list.empty? }
      nil
    end

    # -> Provider escolhido | raise CapabilityUnavailable | raise CapabilityAmbiguous.
    # PURO e determinístico: mesmo input → mesma escolha ou mesmo erro. Sem
    # IO além do `available.call` do próprio Provider. Emite `:capability_resolved`
    # quando `event_stream:` presente (auditoria).
    def resolve(capability, profile:, context: {}, event_stream: nil)
      candidates = providers(capability)
      candidates = candidates.select { |p| p.available.call }
      candidates = apply_deny(candidates, profile)

      raise CapabilityUnavailable.new(capability: capability) if candidates.empty?

      chosen = pick_top(candidates, capability)
      event_stream&.emit(Harness::Event.new(
                           type: :capability_resolved,
                           data: {
                             capability: capability.to_sym,
                             chosen: chosen.impl_name,
                             candidates: candidates.map do |p|
                               { impl_name: p.impl_name, plugin: p.plugin, priority: p.priority }
                             end
                           }
                         ))
      chosen
    end

    private

    # Resolução aplica SÓ `tools_deny` sobre `impl_name` (deny SEMPRE vence) — NÃO
    # aplica `tools_allow`: o grant para usar a capability é
    # listá-la em `profile.capabilities`, conferido pelo Executor ANTES
    # de chamar `resolve`. Reusar `tools_allow` filtraria para fora um provider de
    # um agente que lista só a capability (não o impl cru). Pinning por-agente de
    # provider (`capability_providers`) é evolução.
    def apply_deny(candidates, profile)
      deny = Array(profile.tools_deny).map(&:to_s)
      candidates.reject { |p| deny.include?(p.impl_name) }
    end

    # `priority` desc primária, `nil` como o MAIS BAIXO possível (abaixo de
    # qualquer Integer, inclusive negativo — não normalizar para 0, que colidiria
    # com `priority: 0` explícito). Desempate por precedência de plugin (ordem de
    # registro, proxy de announce): plugins diferentes sempre
    # desempatam; mesmo plugin (nil incluso) empatado = CapabilityAmbiguous.
    def pick_top(candidates, capability)
      indexed = providers(capability).each_with_index.to_h { |p, i| [p, i] }

      rank = ->(p) { p.priority.nil? ? [0, 0] : [1, p.priority] }
      top_rank = candidates.map(&rank).max
      top = candidates.select { |p| rank.call(p) == top_rank }

      return top.first if top.size == 1

      groups = top.group_by(&:plugin).values
      if groups.any? { |g| g.size > 1 }
        raise CapabilityAmbiguous.new(capability: capability, candidates: top)
      end

      groups.min_by { |g| indexed[g.first] }.first
    end
  end
end
