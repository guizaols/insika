# frozen_string_literal: true

require "yaml"

module Harness
  # Catalog of prompts: NON-executable content
  # (it is a Catalog, not a Registry). Mirrors the SkillCatalog: each prompt is a directory
  # with a PROMPT.md (YAML frontmatter name/description + markdown body).
  # Source for the Prompt provider when the profile uses prompt_refs.
  class PromptCatalog
    Prompt = Data.define(:name, :description, :path, :body)

    # roots ordered by PRECEDENCE (highest first) — same name in more than
    # one root: the first wins (identical to SkillCatalog).
    def initialize(roots)
      @roots = Array(roots)
      @prompts = load_all
    end

    def all = @prompts.values

    # -> Prompt | nil (the Prompt provider converts nil into a ContextError; it is not
    # the catalog's job to raise).
    def find(name) = @prompts[name.to_s]

    # Rescan + atomic index swap: parity with the SkillCatalog
    # for reload without a restart when the on-disk seed changes.
    def reload
      @prompts = load_all
      self
    end

    private

    def load_all
      found = {}
      @roots.each do |root|
        Dir.glob(File.join(root, "**", "PROMPT.md")).sort.each do |file|
          prompt = parse(file)
          next unless prompt

          found[prompt.name] ||= prompt # precedence: first root wins
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
