# frozen_string_literal: true

module Insika
  module Context
    module Providers
      # Read path for cross-session memory. Thin adapter over
      # the MemoryStore — same pattern as the Skill/ToolSearch provider: one
      # `:system` fragment with the tenant's facts + recent notes.
      class Memory < ContextProvider
        def initialize(store:, notes_limit: 10, llm: nil)
          @store = store
          @notes_limit = notes_limit
          @reranker = Reranker.new(llm: llm) if llm
        end

        # Per-agent opt-in. The Builder still applies the `context_providers`
        # allowlist on top (two gates, like the other providers).
        def enabled_for?(profile) = !!profile.memory

        # required? == false (default): a failure (store unavailable) becomes a
        # :provider_warning + graceful degradation — never aborts the turn.
        def call(request)
          tenant = memory_scope(request)
          facts = @store.facts(tenant: tenant)
          config = request.profile.memory_retrieval
          limit = config ? [@notes_limit, config.dig("rerank", "candidate_limit")].max : @notes_limit
          notes = @store.notes(tenant: tenant, limit: limit)
          return [] if facts.empty? && notes.empty?

          legacy_notes = notes.first(@notes_limit)
          if config && @reranker && !request.message.to_s.strip.empty?
            selected = select_memory(request, facts, notes.first(config.dig("rerank", "candidate_limit")), config)
            facts, notes = selected || [facts, legacy_notes]
          else
            notes = legacy_notes
          end

          # priority MEMORY (75): between skills (80) and deferred tools (70) in
          # the sacrifice order. pinned false (cuttable under a tight budget).
          [ContextFragment.build(content: format_block(facts, notes, Insika::Fence.enabled?(request.profile)),
                                 placement: :system, priority: Context::Priority::MEMORY, source: id)]
        end

        private

        def select_memory(request, facts, notes, config)
          query = request.message.to_s
          terms = query.downcase.scan(/[[:alnum:]]+/).uniq
          candidates = facts.map do |fact|
            { kind: :fact, record: fact, id: "fact:#{fact.key}",
              text: "#{fact.key} #{fact.value}", at: fact.updated_at.to_s }
          end + notes.map do |note|
            { kind: :note, record: note, id: "note:#{note.id}",
              text: note.text.to_s, at: note.created_at.to_s }
          end
          candidates.sort_by! do |item|
            words = item[:text].downcase.scan(/[[:alnum:]]+/).uniq
            [-terms.count { |term| words.include?(term) }, -Time.iso8601(item[:at]).to_f, item[:id]]
          rescue ArgumentError
            [-terms.count { |term| words.include?(term) }, 0, item[:id]]
          end
          candidates = candidates.first(config.dig("rerank", "candidate_limit"))
          rerank = config.fetch("rerank")
          timeout = [rerank.fetch("timeout_seconds"),
                     (request.profile.limits[:provider_timeout] || 5) * 0.9].min
          documents = candidates.map { |item| item[:text] }
          indexes = @reranker.select(query: query, documents: documents,
                                     config: rerank.merge("timeout_seconds" => timeout),
                                     top_k: config.fetch("top_k"), emit: request.diagnostics,
                                     source: "Memory", budget: request.profile.limits[:context_budget] || 8_000)
          return nil unless indexes

          selected = indexes.map { |index| candidates[index] }
          [selected.filter_map { |item| item[:record] if item[:kind] == :fact },
           selected.filter_map { |item| item[:record] if item[:kind] == :note }]
        end

        # Engine memory scope (WS8): the request's CUSTOMER-scoped cell
        # ("[tenant:]customer" — engine-owner memory is per customer, never per
        # tenant) wins; otherwise an EXPLICIT tenant from the Command (the
        # multi-merchant override); otherwise the SESSION (=chat), MARKED like
        # the write path ("chat:<session id>" —  : a session cell is
        # never a bare cell, so the drill cannot read a conversation as a
        # customer). No session (one-shot) and no tenant -> nil (MemoryStore
        # applies _default). Symmetric to the write path (`state.tenant` in the
        # Executor).
        def memory_scope(request)
          scoped = request.respond_to?(:memory_scope) ? request.memory_scope : nil
          return scoped if scoped

          explicit = request.respond_to?(:tenant) ? request.tenant : nil
          return explicit if explicit

          session = request.respond_to?(:session) ? request.session : nil
          session && session.id ? "#{Insika::MemoryStore::SESSION_TAG}:#{session.id}" : nil
        end

        # Passive <memory> (no instruction — the HOW of writing lives in the `remember` tool).
        # Fenced: keys, values and notes are sanitized before they enter the block
        # — they are model- or customer-authored, and a value carrying `</fact>` or
        # a forged turn marker would otherwise reach the model as-is.
        def format_block(facts, notes, fenced)
          clean = fenced ? ->(s) { Insika::Fence.sanitize_text(s) } : ->(s) { s }
          lines = facts.map { |f| %(  <fact key="#{clean.call(f.key)}">#{clean.call(f.value)}</fact>) }
          lines += notes.map { |n| "  <note>#{clean.call(n.text)}</note>" }
          <<~BLOCK.strip
            <memory>
            #{lines.join("\n")}
            </memory>
          BLOCK
        end
      end
    end
  end
end
