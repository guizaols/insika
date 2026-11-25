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

    def all = snapshot.entries

    # Reloads the index (after authoring a data-tool in the overlay). Mirrors
    # SkillCatalog#reload — level-1/tool_search starts seeing the new tool without a
    # restart. An in-flight turn has already captured `all`.
    def reload
      @snapshot = build_snapshot
      @generation = registry_generation
      self
    end

    # Allowed deferred slice (typically allowed_tools ∩ tools_deferred).
    # Names outside the catalog are silently ignored (safe failure: less
    # exposure, never more).
    def subset(names) = select_names(all, names)

    # PURE matcher for `tool_search`: no embeddings, no per-language word list.
    #
    # - A query word equal to a tool's name (`fashion_v3_rollout`) enables that tool,
    #   first and past `limit:` (up to NAME_CAP_FACTOR times it): the model reads the
    #   names in <available_tools> and asks for the ones it needs, so a list of names
    #   gets all of them. A matched name is not read as description words too, so
    #   "send_email" alone does not bring every tool that says "send" or "email".
    # - The other words lose a final "s" and are compared by their first STEM_CHARS
    #   characters, so "listar" meets "Lista", "produtos" meets "produto" and "tags"
    #   meets "tag". A query word already shorter than that meets any word it starts
    #   ("tag" meets "tagged"); one the "s" cut shortened does not ("mais" does not
    #   meet "mail"). The word itself counts twice as much as a stem-only hit
    #   ("confirmar" over "configure"); query words that share a stem count once,
    #   by the best of them, whatever their order. Names are also split at camelCase
    #   (`getOrderStatus` meets "order").
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
    def search(query, within: nil, limit: nil) = find(query, within: within, limit: limit).entries

    # What #search returns, plus what the caller has to tell the model:
    # - entries: tools to enable, the exact names first;
    # - known: matches among `known:` (already enabled), never in entries nor counted
    #   against the limit, so asking again brings the next ones instead of the same top;
    # - left_out: exact names past the name cap, to ask for in another call;
    # - more: how many description matches the limit cut.
    Found = Data.define(:entries, :known, :left_out, :more)

    def find(query, within: nil, limit: nil, known: [])
      current = snapshot # one index for the whole search, even if `reload` runs meanwhile
      universe = within ? select_names(current.entries, within) : current.entries
      known = Array(known).map(&:to_s)
      tokens = query.to_s.scan(NAME_TOKEN)
      lowered = tokens.map(&:downcase)
      exact = universe.select { |entry| lowered.include?(entry.name.downcase) }
      repeated, fresh = exact.partition { |entry| known.include?(entry.name) }
      kept = limit ? fresh.first(limit * NAME_CAP_FACTOR) : fresh

      exact_names = exact.map { |entry| entry.name.downcase }
      terms = stem_groups(tokens.reject { |token| exact_names.include?(token.downcase) }.join(" "))
      found_known, ranked = rank(terms, universe, current.terms, skip: exact).partition { |entry| known.include?(entry.name) }
      room = limit ? [limit - kept.size, 0].max : ranked.size

      Found.new(entries: kept + ranked.first(room), known: (repeated + found_known).map(&:name),
                left_out: (fresh - kept).map(&:name), more: [ranked.size - room, 0].max)
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

    # The entries and their search index, built together so a search never reads one
    # registry generation's entries against another's words.
    Snapshot = Data.define(:entries, :terms)

    def snapshot
      gen = registry_generation
      @snapshot = nil if gen != @generation
      @generation = gen
      @snapshot ||= build_snapshot
    end

    def build_snapshot
      entries = @tool_registry.entries.map do |entry|
        Entry.new(name: entry.name, description: entry.factory.call.description.to_s, plugin: entry.plugin)
      end
      Snapshot.new(entries: entries, terms: entries.to_h { |entry| [entry.name, sections_of(entry)] })
    end

    # Every entry with a positive score, best first; `skip:` stays out.
    def rank(terms, universe, index, skip:)
      return [] if terms.empty?

      idf = idf_for(terms, universe, index)
      scored = universe.each_with_index.filter_map do |entry, idx|
        next if skip.include?(entry)

        score = score_entry(index.fetch(entry.name), terms, idf)
        [entry, score, idx] if score.positive?
      end
      scored.sort_by { |_entry, score, idx| [-score, idx] }.map(&:first)
    end

    def select_names(entries, names)
      wanted = Array(names).map(&:to_s)
      entries.select { |e| wanted.include?(e.name) }
    end

    # Search weights and word shape (see #search).
    STEM_CHARS = 5
    MIN_WORD = 2
    NAME_WEIGHT = 3
    FIRST_SENTENCE_WEIGHT = 2
    REST_WEIGHT = 0.5
    STEM_ONLY = 0.5
    PLURAL_MIN = 3
    # Exact names one call enables, as a multiple of the limit: a model pasting the
    # whole <available_tools> list would wire hundreds of schemas at once.
    NAME_CAP_FACTOR = 3
    SECTIONS = { name: NAME_WEIGHT, first: FIRST_SENTENCE_WEIGHT, rest: REST_WEIGHT }.freeze
    WORD = /[\p{L}\p{N}]+/
    NAME_TOKEN = /[\p{L}\p{N}_-]+/

    def words(text) = text.to_s.downcase.scan(WORD).select { |word| word.length >= MIN_WORD }

    # A final "s" goes first ("tags" -> "tag", "lojas" -> "loja"), only when a word of
    # at least three letters remains: "os" or "as" cut to one letter would meet everything.
    def stem(word)
      word = word.delete_suffix("s") if word.length > PLURAL_MIN && word.end_with?("s")
      word[0, STEM_CHARS]
    end

    # {stem => [query words with that stem]}: "listar lista" is one stem, scored by
    # its best word, so neither the order nor the repetition changes the score.
    def stem_groups(text) = words(text).uniq.group_by { |word| stem(word) }

    Section = Data.define(:words, :stems)

    def section_of(text)
      found = Set.new(words(text))
      Section.new(words: found, stems: Set.new(found.map { |word| stem(word) }))
    end

    # MCP tools are often camelCase: "getOrderStatus" -> "get Order Status",
    # "HTTPServer" -> "HTTP Server".
    def split_camel(name) = name.gsub(/([\p{Ll}\p{N}])(\p{Lu})/, '\1 \2').gsub(/(\p{Lu})(\p{Lu}\p{Ll})/, '\1 \2')

    # Sections of one entry, cut once per snapshot: 590 descriptions take ~30 ms.
    def sections_of(entry)
      first, rest = sentences(entry.description)
      { name: section_of(split_camel(entry.name)), first: section_of(first), rest: section_of(rest) }
    end

    # 1 when the section has one of the query words itself, STEM_ONLY for a stem hit,
    # 0 for none. A query word shorter than STEM_CHARS is its own stem and also meets
    # the longer stems it starts; a stem the plural cut shortened ("mais" -> "mai") is
    # not a word the model typed, so it does not.
    def hit(section, stem, query_words)
      return 1 if query_words.any? { |word| section.words.include?(word) }
      return STEM_ONLY if section.stems.include?(stem)
      return STEM_ONLY if prefix?(stem, query_words) && section.stems.any? { |other| other.start_with?(stem) }

      0
    end

    def prefix?(stem, query_words) = stem.length < STEM_CHARS && query_words.include?(stem)

    # Smoothed so that a stem every entry shares still scores above zero: in a catalog
    # of two tools a shared word must still match, it just cannot rank.
    def idf_for(terms, universe, index)
      size = universe.size
      terms.to_h do |stem, query_words|
        hits = universe.count do |entry|
          index.fetch(entry.name).each_value.any? { |section| hit(section, stem, query_words).positive? }
        end
        [stem, Math.log((size + 1.0) / (hits + 0.5))]
      end
    end

    def score_entry(sections, terms, idf)
      terms.sum do |stem, query_words|
        SECTIONS.sum { |key, weight| weight * hit(sections[key], stem, query_words) } * idf[stem]
      end
    end

    def registry_generation = @tool_registry.respond_to?(:generation) ? @tool_registry.generation : nil
  end
end
