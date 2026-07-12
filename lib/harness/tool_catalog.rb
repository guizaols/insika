# frozen_string_literal: true

module Harness
  # Visão "nível 1" (progressive disclosure, RFC-0005 §5) das tools: só
  # name+description, o análogo do SkillCatalog para tools (P2B-02 L3). NÃO lê
  # disco (as tools já estão no ToolRegistry, registradas no boot) e NÃO herda de
  # RubyLLM::Tool — duck typing sobre `.description` (puro, testável sem a gem).
  #
  # A `description` canônica não vive no Entry (Registry::Entry não tem esse
  # campo): vem da INSTÂNCIA da tool (`factory.call.description`) — o mesmo
  # `factory.call` que o Executor já paga em instantiate_tools (estágio 3).
  class ToolCatalog
    Entry = Data.define(:name, :description)

    def initialize(tool_registry:)
      @tool_registry = tool_registry
      @entries = build_entries # cache eager — mesma disciplina do SkillCatalog
    end

    def all
      @entries
    end

    # Recorte deferred permitido (tipicamente allowed_tools ∩ tools_deferred).
    # Nomes fora do catálogo são silenciosamente ignorados (falha segura: menos
    # exposição, nunca mais).
    def subset(names)
      wanted = Array(names).map(&:to_s)
      all.select { |e| wanted.include?(e.name) }
    end

    # Matcher PURO (P2B-02 L5): case-insensitive, substring/keyword, SEM
    # embeddings. name pesa 2, description pesa 1; desempate por índice original
    # (sort_by do Ruby não é estável). `within:` restringe o universo via subset.
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

    # Nível 1 injetado no prompt — mirror do SkillCatalog#format_for_prompt,
    # trocando a tag e a instrução final (load_skill -> tool_search).
    def format_for_prompt(entries = all)
      return "" if entries.empty?

      lines = entries.map { |e| %(  <tool name="#{e.name}">#{e.description}</tool>) }.join("\n")

      <<~PROMPT.strip
        <available_tools>
        #{lines}
        </available_tools>

        Antes de usar uma tool acima, chame `tool_search` com o que você precisa
        fazer para habilitá-la nesta conversa.
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
