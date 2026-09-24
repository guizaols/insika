# frozen_string_literal: true

module Insika
  module Context
    # Optional second pass over already scoped retrieval candidates.
    class Reranker
      MAX_INPUT_TOKENS = 4_000

      def initialize(llm:)
        @llm = llm
      end

      # Returns indexes into documents, or nil so the caller keeps lexical order.
      def select(query:, documents:, config:, top_k:, emit: nil, source: "Knowledge", budget: MAX_INPUT_TOKENS)
        return nil if documents.empty?

        # The same estimator used by the context budget bounds the provider input.
        tokens = [budget.to_i, MAX_INPUT_TOKENS].min
        query_tokens = [tokens / 4, 1_000].min
        per_document = [(tokens - query_tokens) / documents.length, 400].min
        return nil if per_document < 1

        bounded = documents.map { |text| trim(text, per_document) }
        bounded_query = trim(query, query_tokens)
        llm = operation_context(emit, config)
        result = Async::Task.current.with_timeout(config.fetch("timeout_seconds")) do
          llm.rerank(bounded_query, bounded, provider: config.fetch("provider"),
                     model: config.fetch("model"), top_n: top_k)
        end
        indexes = result.results.map(&:index)
        unless indexes.any? && indexes.length <= top_k &&
               indexes.all? { |index| index.is_a?(Integer) && index >= 0 && index < documents.length } &&
               indexes.uniq.length == indexes.length
          safe_emit(emit, :provider_warning, { provider: source, message: "invalid rerank indexes" })
          return nil
        end
        safe_emit(emit, :retrieval_reranked,
                  { provider: source, candidate_count: documents.length, selected_count: indexes.length })
        indexes
      rescue StandardError => error
        # Provider messages may quote the query or a document. Only the class is safe.
        safe_emit(emit, :provider_warning, { provider: source, message: "rerank failed: #{error.class.name}" })
        nil
      end

      private

      def trim(value, limit)
        text = value.to_s[0, limit * 4]
        text = text[0...-1] while TokenEstimator.estimate(text) > limit
        text
      end

      def safe_emit(emit, type, data)
        emit&.call(type, data)
      rescue StandardError
        nil
      end

      def operation_context(emit, config)
        source = @llm.respond_to?(:call) ? @llm.call : @llm
        return source unless emit && source.respond_to?(:config)

        require "ruby_llm"
        require_relative "../telemetry/ruby_llm_instrumenter"
        copy = source.config.dup
        copy.instrumenter = Insika::Telemetry::RubyLLMInstrumenter.new(
          delegate: copy.instrumenter, operation: "rerank", model: config.fetch("model"),
          emit: ->(type, data) { safe_emit(emit, type, data) }
        )
        RubyLLM::Context.new(copy)
      end
    end
  end
end
