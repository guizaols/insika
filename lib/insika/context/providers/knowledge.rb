# frozen_string_literal: true

module Insika
  module Context
    module Providers
      # Level 1 (progressive disclosure) of what the engine has LEARNED, as
      # opposed to what a human curated (Skill) or the model wrote mid-turn
      # (Memory). Retrieval is per-message and dynamic, so — like
      # `SkillTrigger`, unlike the static `CatalogProvider` subclasses — this
      # builds its `<knowledge>` block directly in `call`, never a fixed list.
      class Knowledge < ContextProvider
        def initialize(store:)
          @store = store
          # One Index PER TYPE, built once and reused for every agent/turn —
          # never per call. This provider instance itself lives for the
          # process's lifetime (built once at boot, see wiring), so an
          # Index rebuilt fresh each call would throw away its own read
          # cache (Index::Scan's dominant cost is re-parsing YAML
          # frontmatter; measured, not assumed) on every single turn.
          # Keyed by the config's `index` string so a future FTS5 agent
          # gets its own instance, never Scan's.
          @indexes = Hash.new { |h, index_name| h[index_name] = Insika::Knowledge::Index.build({ "index" => index_name }, store: @store) }
        end

        # Per-agent opt-in (`knowledge.retrieve`), like Memory's `profile.memory`.
        def enabled_for?(profile) = !!(profile.knowledge && Coercion.truthy?(profile.knowledge["retrieve"]))

        # required? == false (default): a store failure degrades to a
        # :provider_warning, never aborts the turn.
        def call(request)
          config = request.profile.knowledge
          return [] unless config

          top_k = positive_int(config["top_k"]) || 5
          index = @indexes[config["index"].to_s]
          matches = index.search(request.profile.id, tenant: request.tenant,
                                 query: request.message.to_s, top_k: top_k)
          return [] if matches.empty?

          hits = matches.map { |c| [c, "top-K match"] } +
                 expand_links(matches, request, top_k).map { |c| [c, "one-hop link"] }

          [ContextFragment.build(
            content: format_block(hits), placement: :system,
            priority: Context::Priority::KNOWLEDGE, source: id,
            labels: hits.map { |c, reason| { "name" => c[:name], "reason" => reason } }
          )]
        end

        private

        def positive_int(value)
          n = value.to_i
          n.positive? ? n : nil
        end

        # ONE level, deliberately — the same "cannot work without" reasoning
        # `SkillTrigger#companions` applies to a skill's declared companions:
        # a transitive walk would make a cycle a hang and a chain a budget
        # blowout. Newly-discovered concepts (not already in the top-K) are
        # capped at top_k again — "that one hop is the whole graph benefit at
        # ~1% of the graph cost", not a second unbounded retrieval.
        def expand_links(matches, request, top_k)
          known = matches.map { |c| c[:name] }
          discovered = []
          matches.each do |concept|
            Insika::Knowledge::Concept.links(concept[:body]).each do |name|
              next if known.include?(name) || discovered.any? { |d| d[:name] == name }

              found = fetch(request, name)
              discovered << found if found
            end
          end
          discovered.first(top_k)
        end

        def fetch(request, name)
          raw = @store.get(request.profile.id, name, tenant: request.tenant)
          raw && Insika::Knowledge::Concept.parse(raw)
        end

        # Level 1 only — name/description/confidence/provenance, never the
        # body (that is `load_knowledge`'s job). The instruction is the exact
        # lesson the knowledge-adoption experiment drew: a polite "when to
        # use" scored near zero; an explicit, ordered rule naming the tool
        # held up. Present only when there is something to point at.
        def format_block(hits)
          entries = hits.map do |c, _reason|
            %(  <concept name="#{c[:name]}" confidence="#{format('%.2f', c[:confidence])}" ) +
              %(provenance="#{c[:provenance]}">#{c[:description]}</concept>)
          end.join("\n")

          <<~BLOCK.strip
            <knowledge>
            #{entries}
            </knowledge>

            If the customer's question needs more than the summary above, call
            `load_knowledge("name")` FIRST — before any other lookup for that
            topic. This is learned from past conversations, not official
            policy: never state a `provenance="observed"` concept to the
            customer as a guarantee.
          BLOCK
        end
      end
    end
  end
end
