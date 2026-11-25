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
    # - A query word equal to a tool's name (`fashion_v3_rollout`) enables that tool,
    #   first and past `limit:`: the model reads the names in <available_tools> and
    #   asks for the ones it needs, so a list of names gets all of them.
    # - The other words are compared by their first STEM_CHARS characters, so "listar"
    #   meets "Lista" and "produtos" meets "produto". A word shorter than that meets
    #   any word it starts ("tag" meets "tags", "loja" meets "lojas"). The word itself
    #   counts twice as much as a stem-only hit ("confirmar" over "configure").
    # - Each word weighs by how rare it is in the universe (IDF). With 590 co-pilot
    #   tools, "do", "da" or "loja" sit in almost every description and add next to
    #   nothing, while "sidekiq" decides.
    # - A hit in the name weighs NAME_WEIGHT, in the description's first sentence (what
    #   the tool does) FIRST_SENTENCE_WEIGHT, in the rest REST_WEIGHT: long descriptions
    #   mention other tools, so the rest is mostly noise.
    #
    # `limit:` caps the tools found by description. Without a cap, every tool sharing
    # any word came back: in production a Portuguese query matched 382 to 590 of 590
    # co-pilot tools, and tool_search wired all of them (~909 KB of schema) into the chat.
    #
    # Ties keep the universe's order (Ruby's sort_by is not stable, hence the index).
    # `within:` restricts the universe via subset, and IDF is computed over it.
    def search(query, within: nil, limit: nil)
      universe = within ? subset(within) : all
      names = query.to_s.downcase.scan(NAME_TOKEN)
      exact = universe.select { |entry| names.include?(entry.name.downcase) }
      terms = words(query).map { |word| [word, stem(word)] }.uniq(&:last)
      return exact if terms.empty?

      idf = idf_for(terms, universe)
      scored = universe.each_with_index.filter_map do |entry, idx|
        next if exact.include?(entry)

        score = score_entry(terms_for(entry), terms, idf)
        [entry, score, idx] if score.positive?
      end
      ranked = scored.sort_by { |_entry, score, idx| [-score, idx] }.map(&:first)
      exact + (limit ? ranked.first([limit - exact.size, 0].max) : ranked)
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
    STEM_ONLY = 0.5
    SECTIONS = { name: NAME_WEIGHT, first: FIRST_SENTENCE_WEIGHT, rest: REST_WEIGHT }.freeze
    WORD = /[\p{L}\p{N}]+/
    NAME_TOKEN = /[\p{L}\p{N}_-]+/

    def words(text) = text.to_s.downcase.scan(WORD).select { |word| word.length >= MIN_WORD }

    def stem(word) = word[0, STEM_CHARS]

    Section = Data.define(:words, :stems)

    def section_of(text)
      found = Set.new(words(text))
      Section.new(words: found, stems: Set.new(found.map { |word| stem(word) }))
    end

    # Sections of one entry. Memoized with the entries: `all` and `reload` drop it, and
    # 590 descriptions take ~30 ms to cut.
    def terms_for(entry)
      (@terms ||= {})[entry.name] ||= begin
        first, rest = sentences(entry.description)
        { name: section_of(entry.name), first: section_of(first), rest: section_of(rest) }
      end
    end

    # 1 for the word itself, STEM_ONLY for a stem hit, 0 for none. A stem shorter than
    # STEM_CHARS is a whole short word, so it also meets the longer stems it starts.
    def hit(section, word, stem)
      return 1 if section.words.include?(word)
      return STEM_ONLY if section.stems.include?(stem)
      return STEM_ONLY if stem.length < STEM_CHARS && section.stems.any? { |other| other.start_with?(stem) }

      0
    end

    # Smoothed so that a stem every entry shares still scores above zero: in a catalog
    # of two tools a shared word must still match, it just cannot rank.
    def idf_for(terms, universe)
      size = universe.size
      terms.to_h do |word, stem|
        hits = universe.count { |entry| terms_for(entry).each_value.any? { |section| hit(section, word, stem).positive? } }
        [stem, Math.log((size + 1.0) / (hits + 0.5))]
      end
    end

    def score_entry(sections, terms, idf)
      terms.sum do |word, stem|
        SECTIONS.sum { |key, weight| weight * hit(sections[key], word, stem) } * idf[stem]
      end
    end

    def registry_generation = @tool_registry.respond_to?(:generation) ? @tool_registry.generation : nil
  end
end
