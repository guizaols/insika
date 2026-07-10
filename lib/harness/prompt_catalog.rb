# frozen_string_literal: true

require "yaml"

module Harness
  # Catalog de prompts (RFC-0001 princípio 6, doc 06 §2): conteúdo NÃO-executável
  # (é Catalog, não Registry). Espelha o SkillCatalog: cada prompt é um diretório
  # com um PROMPT.md (frontmatter YAML name/description + corpo markdown).
  # Fonte do provider Prompt quando o perfil usa prompt_refs (doc 04 §2).
  class PromptCatalog
    Prompt = Data.define(:name, :description, :path, :body)

    # roots ordenados por PRECEDÊNCIA (maior primeiro) — mesmo nome em mais de
    # um root: o primeiro vence (idêntico ao SkillCatalog).
    def initialize(roots)
      @roots = Array(roots)
      @prompts = load_all
    end

    def all = @prompts.values

    # -> Prompt | nil (o provider Prompt converte nil em ContextError; não é
    # papel do catálogo levantar).
    def find(name) = @prompts[name.to_s]

    private

    def load_all
      found = {}
      @roots.each do |root|
        Dir.glob(File.join(root, "**", "PROMPT.md")).sort.each do |file|
          prompt = parse(file)
          next unless prompt

          found[prompt.name] ||= prompt # precedência: primeiro root vence
        end
      end
      found
    end

    def parse(file)
      raw = File.read(file, encoding: "UTF-8")
      match = raw.match(/\A---\s*\n(.*?)\n---\s*\n(.*)\z/m)
      return nil unless match

      meta = YAML.safe_load(match[1]) || {}
      name = meta["name"]
      return nil unless name

      Prompt.new(name: name.to_s, description: meta["description"].to_s,
                 path: file, body: match[2].strip)
    end
  end
end
