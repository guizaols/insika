# frozen_string_literal: true

require "async"
require "time"

module Harness
  # Saída do Builder, consumida pelo Executor no estágio 5.
  #   system:       String (concatenação final p/ with_instructions)
  #   history:      [{role:, content:}] (p/ seed do chat)
  #   tool_context: String | nil
  #   fragments:    [ContextFragment] pós-corte, em ordem canônica (auditoria)
  #   budget:       { cap:, used:, evicted: [source] }
  ContextPackage = Data.define(:system, :history, :tool_context, :fragments, :budget)

  # Estágio 2 da pipeline: o Runtime NUNCA monta prompt — pede o
  # pacote ao Builder. Implementa seleção -> produção fan-out ->
  # coleta/estimativa -> orçamento com evicção -> montagem canônica.
  class ContextBuilder
    def initialize(providers:, event_stream:, hooks: Hooks.new, estimator: TokenEstimator)
      @providers = providers
      @event_stream = event_stream
      @hooks = hooks # par :prompt (task 16); Hooks vazio = no-op
      @estimator = estimator
    end

    # O par :prompt é envolvido AQUI, não no Executor: before_prompt
    # pode reescrever o ContextRequest (providers rodam com o alterado);
    # after_prompt pode reescrever o ContextPackage montado. IMPORTANTE: o
    # Executor chama só `builder.call(request)` — NÃO envolver com
    # around(:prompt) de novo (double-wrap dispararia os hooks 2x).
    def call(request)
      @hooks.around(:prompt, request) { |req| build_package(req) }
    end

    private

    def build_package(request)
      selected = select_providers(request.profile)
      fragments = estimate_tokens(produce(selected, request))
      cap = request.profile.limits[:context_budget] || 8_000
      fragments, evicted = apply_budget(fragments, cap)
      unless evicted.empty?
        emit_warning("ContextBuilder",
                     "orçamento: #{evicted.size} fragmento(s) evictado(s) de #{evicted.uniq}",
                     request)
      end
      assemble(fragments, cap, evicted)
    end

    # Passo 1: seleção — enabled_for? E allowlist do perfil.
    def select_providers(profile)
      @providers.select do |p|
        p.enabled_for?(profile) && allowlisted?(p, profile.context_providers)
      end
    end

    # Allowlist única: nil -> todos; [] -> nenhum; [names] -> subconjunto.
    def allowlisted?(provider, allow)
      return true if allow.nil?
      return false if allow.empty?

      Array(allow).map(&:to_s).include?(provider.id.to_s)
    end

    # Passo 2: produção em fan-out com BARRIER e timeout por provider
    # (with_timeout — nunca Timeout.timeout). Cada provider é um fiber FILHO
    # do fiber corrente: cancelar a task cancela a produção em voo.
    def produce(selected, request)
      timeout = request.profile.limits[:provider_timeout] || 5
      tasks = selected.map do |provider|
        child = Async::Task.current.async { |t| t.with_timeout(timeout) { provider.call(request) } }
        [provider, child]
      end

      fragments = []
      tasks.each do |provider, child|
        fragments.concat(Array(child.wait))
      rescue StandardError => e # Async::TimeoutError é StandardError; Async::Stop NÃO (propaga)
        handle_provider_failure(provider, e, request)
      end
      fragments
    end

    # required falha -> ContextError
    # (aborta o turno, quem mapeia é o Executor); opcional falha -> warning +
    # degradação graciosa (fragmentos omitidos, turno segue).
    def handle_provider_failure(provider, error, request)
      if provider.required?
        raise ContextError.new("provider obrigatório '#{provider.id}' falhou: #{error.message}",
                               provider: provider.id)
      end

      emit_warning(provider.id, error.message, request)
    end

    # Passo 3: estimativa de tokens só quando o provider não informou.
    def estimate_tokens(fragments)
      fragments.map { |f| f.tokens ? f : f.with(tokens: @estimator.estimate(estimable_text(f.content))) }
    end

    # Fragmentos de history carregam um Hash {role:, content:} como conteúdo;
    # estimar em cima do Hash contaria o texto do `#to_s` (":role=>", aspas,
    # símbolos), inflando cada mensagem e enviesando a evicção. Conta os valores,
    # não a representação Ruby.
    def estimable_text(content)
      case content
      when String then content
      when Hash then content.values.map(&:to_s).join(" ")
      else content.to_s
      end
    end

    # Passos 4-5: orçamento GLOBAL. Corta não-pinned do menor priority p/ o
    # maior; empate -> menor índice de produção primeiro (corte estável: entre
    # histories, a mais antiga cai primeiro). pinned é incortável; se só
    # pinned já excede -> ContextError (não truncar identidade).
    def apply_budget(fragments, cap)
      used = fragments.sum(&:tokens)
      return [fragments, []] if used <= cap

      indexed = fragments.each_with_index.to_a
      cuttable = indexed.reject { |f, _i| f.pinned }.sort_by { |f, i| [f.priority, i] }
      evicted_idx = []
      evicted_sources = []
      cuttable.each do |fragment, index|
        break if used <= cap

        used -= fragment.tokens
        evicted_sources << fragment.source
        evicted_idx << index
      end

      if used > cap
        raise ContextError.new(
          "orçamento insolúvel: fragmentos pinned (#{used} tokens) excedem o cap (#{cap})",
          provider: "ContextBuilder"
        )
      end

      survivors = fragments.each_index.reject { |i| evicted_idx.include?(i) }.map { |i| fragments[i] }
      [survivors, evicted_sources]
    end

    # Passo 6: montagem em ordem canônica DETERMINÍSTICA.
    def assemble(fragments, cap, evicted)
      system_frags = fragments.select { |f| f.placement == :system }
                              .sort_by.with_index { |f, i| [-f.priority, f.source.to_s, i] }
      history_frags = fragments.select { |f| f.placement == :history } # ordem de produção (cronológica)
      tool_frags = fragments.select { |f| f.placement == :tool_context }

      system = system_frags.map(&:content).join("\n\n")
      history = history_frags.map(&:content)
      tool_context = tool_frags.empty? ? nil : tool_frags.map(&:content).join("\n\n")

      canonical = system_frags + history_frags + tool_frags
      ContextPackage.new(
        system: system, history: history, tool_context: tool_context,
        fragments: canonical, budget: { cap: cap, used: canonical.sum(&:tokens), evicted: evicted }
      )
    end

    # :provider_warning. O Builder não conhece task_id/seq (correlação é do
    # Executor) — emite com o que tem; Event#to_h faz meta.compact.
    def emit_warning(provider_id, message, request)
      @event_stream.emit(Harness::Event.new(
                           type: :provider_warning,
                           data: { provider: provider_id, message: message },
                           meta: { session_id: request.session&.id, at: Time.now.utc.iso8601 }
                         ))
    end
  end
end
