# frozen_string_literal: true

module Insika
  # "Level 1" (progressive disclosure) view of the tools: just
  # name+description, the analog of SkillCatalog for tools. It does NOT read
  # disk (the tools are already in the ToolRegistry, registered at boot) and does NOT
  # inherit from RubyLLM::Tool — duck typing over `.description` (pure, testable without
  # the gem).
  #
  # The canonical `description` does not live in the Entry (Registry::Entry has no such
  # field): it comes from the tool INSTANCE (`factory.call.description`). That is why the
  # catalog is LAZY: it only instantiates the tools on the first query (`all`), not at
  # boot. A deployment without `tools_deferred` never touches the catalog and pays for
  # no instantiation at all; a broken factory surfaces on first use (where the
  # Executor would also catch it at stage 3), not at construction.
  class ToolCatalog
    Entry = Data.define(:name, :description, :plugin) do
      def initialize(name:, description:, plugin: nil)
        super
      end
    end

    def initialize(tool_registry:)
      @tool_registry = tool_registry
    end

    def all
      gen = registry_generation
      @entries = @terms = nil if gen != @generation
      @generation = gen
      @entries ||= build_entries
    end

    # Reloads the index (after authoring a data-tool in the overlay). Mirrors
    # SkillCatalog#reload — level-1/tool_search starts seeing the new tool without a
    # restart. An in-flight turn has already captured `all`.
    def reload
      @terms = nil
      @entries = build_entries
      @generation = registry_generation
      self
    end

    # Allowed deferred slice (typically allowed_tools ∩ tools_deferred).
    # Names outside the catalog are silently ignored (safe failure: less
    # exposure, never more).
    def subset(names)
      wanted = Array(names).map(&:to_s)
      all.select { |e| wanted.include?(e.name) }
    end

    # PURE matcher for `tool_search`: no embeddings, no per-language word list.
    #
    # - The query is cut into words, and each word is compared by its first
    #   STEM_CHARS characters, so "listar" meets "Lista" and "produtos" meets "produto".
    # - Each word weighs by how rare it is in the universe (IDF). With 590 co-pilot
    #   tools, "do", "da" or "loja" sit in almost every description and add next to
    #   nothing, while "sidekiq" decides.
    # - A hit in the name weighs NAME_WEIGHT, in the description's first sentence (what
    #   the tool does) FIRST_SENTENCE_WEIGHT, in the rest REST_WEIGHT: long descriptions
    #   mention other tools, so the rest is mostly noise.
    # - A query word equal to a tool's name (`fashion_v3_rollout`) puts that tool first.
    #   The model reads the names in <available_tools> and can ask for them directly.
    #
    # `limit:` caps the result. Without a cap, every tool sharing any word came back: in
    # production a Portuguese query matched 382 to 590 of 590 co-pilot tools, and
    # tool_search wired all of them (~909 KB of schema) into the chat.
    #
    # Ties keep the universe's order (Ruby's sort_by is not stable, hence the index).
    # `within:` restricts the universe via subset, and IDF is computed over it.
    def search(query, within: nil, limit: nil)
      stems = words(query).map { |word| stem(word) }.uniq
      return [] if stems.empty?

      names = query.to_s.downcase.scan(NAME_TOKEN)
      universe = within ? subset(within) : all
      idf = idf_for(stems, universe)
      scored = universe.each_with_index.filter_map do |entry, idx|
        score = score_entry(terms_for(entry), stems, idf)
        score += EXACT_NAME if names.include?(entry.name.downcase)
        [entry, score, idx] if score.positive?
      end
      ranked = scored.sort_by { |_entry, score, idx| [-score, idx] }.map(&:first)
      limit ? ranked.first(limit) : ranked
    end

    # Level 1 injected into the prompt — mirror of SkillCatalog#format_for_prompt,
    # swapping the tag and the final instruction (load_skill -> tool_search).
    def format_for_prompt(entries = all)
      return "" if entries.empty?

      lines = entries.map { |e| %(  <tool name="#{e.name}">#{summary(e.description)}</tool>) }.join("\n")

      <<~PROMPT.strip
        <available_tools>
        #{lines}
        </available_tools>

        Before using a tool above, call `tool_search` with its exact name
        (several names in one query are fine) to enable it in this conversation.
        A description of the need also works, but only the closest few come back.
      PROMPT
    end

    private

    # The catalog only has to make the model search; the full description comes with
    # the tool once tool_search wires it. First sentence, capped: 592 full co-pilot
    # descriptions were ~64k tokens, over the agent's whole context budget.
    SUMMARY_MAX = 120

    def summary(description)
      first = sentences(description).first.to_s
      first.length > SUMMARY_MAX ? "#{first[0, SUMMARY_MAX - 1]}…" : first
    end

    # [first sentence, the rest]
    def sentences(description) = description.to_s.strip.split(/(?<=[.!?])\s/, 2)

    def build_entries
      @tool_registry.entries.map do |entry|
        Entry.new(name: entry.name, description: entry.factory.call.description.to_s, plugin: entry.plugin)
      end
    end

    # Search weights and word shape (see #search).
    STEM_CHARS = 5
    MIN_WORD = 2
    NAME_WEIGHT = 3
    FIRST_SENTENCE_WEIGHT = 2
    REST_WEIGHT = 0.5
    EXACT_NAME = 1_000
    WORD = /[\p{L}\p{N}]+/
    NAME_TOKEN = /[\p{L}\p{N}_-]+/

    def words(text) = text.to_s.downcase.scan(WORD).select { |word| word.length >= MIN_WORD }

    def stem(word) = word[0, STEM_CHARS]

    def stems_of(text) = Set.new(words(text).map { |word| stem(word) })

    # Stems of one entry, by where they appear. Memoized with the entries: `all` and
    # `reload` drop it, and 590 descriptions take ~30 ms to cut.
    def terms_for(entry)
      (@terms ||= {})[entry.name] ||= begin
        first, rest = sentences(entry.description)
        { name: stems_of(entry.name), first: stems_of(first), rest: stems_of(rest) }
      end
    end

    # Smoothed so that a stem every entry shares still scores above zero: in a catalog
    # of two tools a shared word must still match, it just cannot rank.
    def idf_for(stems, universe)
      size = universe.size
      stems.to_h do |stem|
        hits = universe.count { |entry| terms_for(entry).each_value.any? { |set| set.include?(stem) } }
        [stem, Math.log((size + 1.0) / (hits + 0.5))]
      end
    end

    def score_entry(terms, stems, idf)
      stems.sum do |stem|
        weight = (terms[:name].include?(stem) ? NAME_WEIGHT : 0) +
                 (terms[:first].include?(stem) ? FIRST_SENTENCE_WEIGHT : 0) +
                 (terms[:rest].include?(stem) ? REST_WEIGHT : 0)
        weight * idf[stem]
      end
    end

    def registry_generation = @tool_registry.respond_to?(:generation) ? @tool_registry.generation : nil
  end
end
