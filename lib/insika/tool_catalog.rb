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
    Entry = Data.define(:name, :description)

    def initialize(tool_registry:)
      @tool_registry = tool_registry
    end

    def all
      @entries ||= build_entries
    end

    # Reloads the index (after authoring a data-tool in the overlay). Mirrors
    # SkillCatalog#reload — level-1/tool_search starts seeing the new tool without a
    # restart. An in-flight turn has already captured `all`.
    def reload
      @entries = build_entries
      self
    end

    # Allowed deferred slice (typically allowed_tools ∩ tools_deferred).
    # Names outside the catalog are silently ignored (safe failure: less
    # exposure, never more).
    def subset(names)
      wanted = Array(names).map(&:to_s)
      all.select { |e| wanted.include?(e.name) }
    end

    # PURE matcher: case-insensitive, substring/keyword, NO
    # embeddings. name weighs 2, description weighs 1; ties broken by original index
    # (Ruby's sort_by is not stable). `within:` restricts the universe via subset.
    def search(query, within: nil)
      terms = query.to_s.downcase.split(/\s+/).reject(&:empty?)
      return [] if terms.empty?

      universe = within ? subset(within) : all
      scored = universe.each_with_index.filter_map do |entry, idx|
        score = score_entry(entry, terms)
        [entry, score, idx] if score.positive?
      end
      scored.sort_by { |_entry, score, idx| [-score, idx] }.map(&:first)
    end

    # Level 1 injected into the prompt — mirror of SkillCatalog#format_for_prompt,
    # swapping the tag and the final instruction (load_skill -> tool_search).
    def format_for_prompt(entries = all)
      return "" if entries.empty?

      lines = entries.map { |e| %(  <tool name="#{e.name}">#{e.description}</tool>) }.join("\n")

      <<~PROMPT.strip
        <available_tools>
        #{lines}
        </available_tools>

        Before using a tool above, call `tool_search` with what you need
        to do to enable it in this conversation.
      PROMPT
    end

    private

    def build_entries
      @tool_registry.entries.map do |entry|
        Entry.new(name: entry.name, description: entry.factory.call.description.to_s)
      end
    end

    def score_entry(entry, terms)
      name = entry.name.downcase
      desc = entry.description.downcase
      terms.sum { |term| (name.include?(term) ? 2 : 0) + (desc.include?(term) ? 1 : 0) }
    end
  end
end
