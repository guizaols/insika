# frozen_string_literal: true

require "time"

module Harness
  # Skills compartilhadas AUTORADAS (Fase 4 — Studio, Etapa C / D3 revisado).
  # Guarda o SKILL.md completo (frontmatter + corpo) no Store durável. O
  # SkillCatalog sobrepõe estas skills sobre as de disco (seed), com o Store
  # vencendo — então editar/criar skill no Studio vale sem restart (via reload).
  #
  # Um record por skill no ConfigStore (scope "skills"):
  #   { "content" => "<SKILL.md inteiro>",
  #     "updated_at" => iso8601,
  #     "history" => [ { "content" =>, "at" => }, ... ] }
  #
  # A chave é o nome canônico da skill (o mesmo do frontmatter). Versiona igual
  # ao AgentFileStore.
  class SkillStore
    SCOPE = "skills"
    HISTORY_MAX = 20

    def initialize(config_store:)
      @cs = config_store
    end

    # -> String | nil (SKILL.md completo).
    def get(name)
      record(name)&.fetch("content", nil)
    end

    # -> [String] nomes, ordem lexicográfica.
    def names = @cs.keys(SCOPE)

    # -> { name => content } de todas as skills autoradas.
    def all
      @cs.keys(SCOPE).each_with_object({}) { |n, acc| acc[n] = get(n) }
    end

    # Grava (upsert). create_only recusa sobrescrever. -> Hash (record gravado).
    def write(name, content, create_only: false)
      key = name.to_s
      current = @cs.get(SCOPE, key)
      raise Harness::ValidationError, "skill '#{key}' já existe" if create_only && current

      rec = build_record(content.to_s, current)
      @cs.put(SCOPE, key, rec)
      rec
    end

    # -> bool (existia?).
    def delete(name) = @cs.delete(SCOPE, name.to_s)

    # -> [ { "content" =>, "at" => } ] mais recente primeiro.
    def versions(name) = record(name)&.fetch("history", []) || []

    # Restaura versão `index` como conteúdo atual (nova escrita). -> Hash.
    def restore(name, index)
      hist = versions(name)
      i = Integer(index)
      raise Harness::NotFoundError, "skill '#{name}' não encontrada" unless record(name)
      raise Harness::ValidationError, "versão #{index} inexistente" if i.negative? || i >= hist.length

      write(name, hist[i]["content"])
    end

    private

    def record(name) = @cs.get(SCOPE, name.to_s)

    def build_record(content, current)
      history = current ? current.fetch("history", []) : []
      if current
        history = [{ "content" => current["content"], "at" => current["updated_at"] }] + history
        history = history.first(HISTORY_MAX)
      end
      { "content" => content, "updated_at" => Time.now.utc.iso8601, "history" => history }
    end
  end
end
