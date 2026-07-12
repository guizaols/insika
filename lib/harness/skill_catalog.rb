# frozen_string_literal: true

require "yaml"

module Harness
  # Convenção OpenClaw / AgentSkills: cada skill é um diretório com um
  # SKILL.md (YAML frontmatter + corpo markdown). Progressive disclosure:
  # nível 1 = name+description no system prompt; nível 2 = corpo carregado
  # sob demanda pela tool load_skill.
  #
  # Migrado da Fase 0 (reference-implementation) sem mudança de lógica — só o
  # módulo AgentRuntime -> Harness (doc 00 §4). Consumido pelo Executor
  # (skill_catalog:) e pelo estágio 3 (effective/format_for_prompt).
  class SkillCatalog
    Skill = Data.define(:name, :description, :path, :body)

    # roots ordenados por PRECEDÊNCIA (maior primeiro): workspace, managed,
    # bundled. Mesmo nome em mais de um root: o primeiro vence.
    #
    # store (Etapa C, opcional): um SkillStore com as skills AUTORADAS no Studio.
    # Sobrepõem as de disco (seed) — Store vence, é a fonte da verdade (D3
    # revisado). Nil = comportamento Fase 0 (só disco), zero regressão.
    def initialize(roots, store: nil)
      @roots = Array(roots)
      @store = store
      @skills = load_all
    end

    def all
      @skills.values
    end

    def find(name)
      @skills[name.to_s]
    end

    # Recarrega do disco + Store e TROCA o índice atomicamente (Etapa C): uma
    # skill autorada/editada passa a valer sem restart. Um turno em andamento
    # capturou @skills no dispatch, então não vê a troca no meio (D3).
    def reload
      @skills = load_all
      self
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
          skill = parse_content(File.read(file, encoding: "UTF-8"), path: file)
          next unless skill

          found[skill.name] ||= skill # precedência: primeiro root vence
        end
      end
      overlay_store(found)
      found
    end

    # Skills do Store sobrepõem as de disco (autorado > seed). path sentinela
    # "store:<name>" — não é arquivo real (o load_skill usa `body`, não o path).
    def overlay_store(found)
      return unless @store

      @store.all.each do |name, content|
        skill = parse_content(content.to_s, path: "store:#{name}")
        found[skill.name] = skill if skill # Store vence
      end
    end

    def parse_content(raw, path:)
      match = raw.match(/\A---\s*\n(.*?)\n---\s*\n(.*)\z/m)
      return nil unless match

      meta = YAML.safe_load(match[1]) || {}
      name = meta["name"]
      return nil unless name

      Skill.new(
        name: name.to_s,
        description: meta["description"].to_s,
        path: path,
        body: match[2].strip
      )
    end
  end
end
