# frozen_string_literal: true

module AgentRuntime
  # Monta o system prompt no estilo OpenClaw: base + arquivos de identidade
  # (SOUL.md...) + a lista de skills de nível 1 (já filtrada pelo agente).
  class SystemPrompt
    def initialize(base: "", files: [])
      @base = base
      @files = Array(files)
    end

    def build(skills_block: "")
      parts = [@base]
      @files.each { |f| parts << File.read(f, encoding: "UTF-8") if File.exist?(f) }
      parts << skills_block
      parts.reject { |p| p.nil? || p.strip.empty? }.join("\n\n")
    end
  end
end
