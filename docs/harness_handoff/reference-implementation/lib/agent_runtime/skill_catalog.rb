# frozen_string_literal: true

require "yaml"

module AgentRuntime
  # Convenção OpenClaw / AgentSkills: cada skill é um diretório com um
  # SKILL.md (YAML frontmatter + corpo markdown). Progressive disclosure:
  # nível 1 = name+description no system prompt; nível 2 = corpo carregado
  # sob demanda pela tool load_skill.
  class SkillCatalog
    Skill = Data.define(:name, :description, :path, :body)

    # roots ordenados por PRECEDÊNCIA (maior primeiro): workspace, managed,
    # bundled. Mesmo nome em mais de um root: o primeiro vence.
    def initialize(roots)
      @roots = Array(roots)
      @skills = load_all
    end

    def all
      @skills.values
    end

    def find(name)
      @skills[name.to_s]
    end

    # Allowlist por agente (semântica OpenClaw):
    #   nil -> todas | [] -> nenhuma | [names] -> subconjunto final
    def effective(skills_policy)
      return all if skills_policy.nil?
      return [] if skills_policy.empty?

      names = Array(skills_policy).map(&:to_s)
      all.select { |s| names.include?(s.name) }
    end

    # Nível 1: lista compacta injetada no system prompt. Só metadados.
    # Recebe o conjunto já filtrado pelo agente.
    def format_for_prompt(skills = all)
      return "" if skills.empty?

      entries = skills.map do |s|
        %(  <skill name="#{s.name}">#{s.description}</skill>)
      end.join("\n")

      <<~PROMPT.strip
        <available_skills>
        #{entries}
        </available_skills>

        Antes de agir numa tarefa que casa com uma skill acima, chame a tool
        `load_skill` com o nome dela para carregar as instruções completas.
      PROMPT
    end

    private

    def load_all
      found = {}
      @roots.each do |root|
        Dir.glob(File.join(root, "**", "SKILL.md")).sort.each do |file|
          skill = parse(file)
          next unless skill

          found[skill.name] ||= skill # precedência: primeiro root vence
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

      Skill.new(
        name: name.to_s,
        description: meta["description"].to_s,
        path: file,
        body: match[2].strip
      )
    end
  end
end
