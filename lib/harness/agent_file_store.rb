# frozen_string_literal: true

require "time"

module Harness
  # Workspace por agente (Fase 4 — Studio, Etapa C / D3 revisado). Guarda o
  # CONTEÚDO dos arquivos de prompt de cada agente (IDENTITY.md/SOUL.md/TOOLS.md
  # e afins) no Store durável — não em disco. É o que faz "cada um cria sua BIA
  # com identidade própria": o Prompt provider lê daqui, por agente, em vez dos
  # `files:` fixos do wiring (que agora são só o default do deployment).
  #
  # Um record por agente no ConfigStore (scope "agent_files"):
  #   { "files" => { "<nome>" => { "content" => str,
  #                                "updated_at" => iso8601,
  #                                "history" => [ { "content" => str, "at" => iso8601 }, ... ] } } }
  #
  # Escrita versiona: o conteúdo anterior entra em `history` (mais recente
  # primeiro), com teto HISTORY_MAX — restauração vira uma nova escrita
  # (preserva o histórico linear, sem "voltar no tempo" destrutivo).
  class AgentFileStore
    SCOPE = "agent_files"
    HISTORY_MAX = 20

    def initialize(config_store:)
      @cs = config_store
    end

    # -> String | nil (conteúdo atual; nil = arquivo/agente inexistente).
    def read(agent_id, filename)
      entry(agent_id, filename.to_s)&.fetch("content", nil)
    end

    # -> [String] nomes dos arquivos do agente, ordem lexicográfica.
    def list(agent_id)
      files(agent_id).keys.sort
    end

    # Grava (upsert). create_only: recusa sobrescrever. Versiona o conteúdo
    # anterior em history. -> Hash (a entry gravada).
    def write(agent_id, filename, content, create_only: false)
      name = filename.to_s
      record = @cs.get(SCOPE, agent_id.to_s) || { "files" => {} }
      record["files"] ||= {}
      current = record["files"][name]
      if create_only && current
        raise Harness::ValidationError, "arquivo '#{name}' já existe para o agente '#{agent_id}'"
      end

      record["files"][name] = build_entry(content.to_s, current)
      @cs.put(SCOPE, agent_id.to_s, record)
      record["files"][name]
    end

    # -> bool (existia?). Remove o arquivo; se o agente ficar sem arquivos,
    # mantém o record vazio (barato; o delete de agente cuida da limpeza).
    def delete(agent_id, filename)
      name = filename.to_s
      record = @cs.get(SCOPE, agent_id.to_s)
      return false unless record && record.dig("files", name)

      record["files"].delete(name)
      @cs.put(SCOPE, agent_id.to_s, record)
      true
    end

    # -> [ { "content" =>, "at" => } ] versões antigas, mais recente primeiro.
    def versions(agent_id, filename)
      entry(agent_id, filename.to_s)&.fetch("history", []) || []
    end

    # Restaura a versão `index` de history como o conteúdo atual (nova escrita:
    # o atual vai para o topo do history). -> Hash (entry) | levanta se index
    # inválido / arquivo inexistente.
    def restore(agent_id, filename, index)
      name = filename.to_s
      hist = versions(agent_id, name)
      i = Integer(index)
      unless entry(agent_id, name)
        raise Harness::NotFoundError, "arquivo '#{name}' não encontrado para o agente '#{agent_id}'"
      end
      raise Harness::ValidationError, "versão #{index} inexistente" if i.negative? || i >= hist.length

      write(agent_id, name, hist[i]["content"])
    end

    private

    def files(agent_id)
      (@cs.get(SCOPE, agent_id.to_s) || {})["files"] || {}
    end

    def entry(agent_id, filename)
      files(agent_id)[filename]
    end

    def build_entry(content, current)
      history = current ? current.fetch("history", []) : []
      if current
        history = [{ "content" => current["content"], "at" => current["updated_at"] }] + history
        history = history.first(HISTORY_MAX)
      end
      { "content" => content, "updated_at" => Time.now.utc.iso8601, "history" => history }
    end
  end
end
