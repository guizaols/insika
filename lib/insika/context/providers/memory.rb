# frozen_string_literal: true

module Insika
  module Context
    module Providers
      # Read path for cross-session memory. Thin adapter over
      # the MemoryStore — same pattern as the Skill/ToolSearch provider: one
      # `:system` fragment with the tenant's facts + recent notes. Deterministic
      # (no embeddings/ranking).
      class Memory < ContextProvider
        def initialize(store:, notes_limit: 10)
          @store = store
          @notes_limit = notes_limit
        end

        # Per-agent opt-in. The Builder still applies the `context_providers`
        # allowlist on top (two gates, like the other providers).
        def enabled_for?(profile) = !!profile.memory

        # required? == false (default): a failure (store unavailable) becomes a
        # :provider_warning + graceful degradation — never aborts the turn.
        def call(request)
          tenant = memory_scope(request)
          facts = @store.facts(tenant: tenant)
          notes = @store.notes(tenant: tenant, limit: @notes_limit)
          return [] if facts.empty? && notes.empty?

          # priority MEMORY (75): between skills (80) and deferred tools (70) in
          # the sacrifice order. pinned false (cuttable under a tight budget).
          [ContextFragment.build(content: format_block(facts, notes),
                                 placement: :system, priority: Context::Priority::MEMORY, source: id)]
        end

        private

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
        def format_block(facts, notes)
          lines = facts.map { |f| %(  <fact key="#{f.key}">#{f.value}</fact>) }
          lines += notes.map { |n| "  <note>#{n.text}</note>" }
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
