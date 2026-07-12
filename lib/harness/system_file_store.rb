# frozen_string_literal: true

require "time"

module Harness
  # Arquivos de sistema GLOBAIS. São prompts/regras
  # que valem para TODOS os agentes do deploy — a "casa" acima da identidade
  # individual de cada BIA. Diferente do AgentFileStore (por agente), aqui não há
  # tenant: um record por arquivo no ConfigStore (scope "system_files").
  #
  # O Context::Providers::Prompt lê estes arquivos e os injeta ANTES da
  # identidade por-agente, para todo turno. Sem arquivos de sistema (store
  # vazio), o prompt é byte-a-byte o de antes (paridade preservada) — a injeção
  # global só existe quando o operador autora algo aqui.
  #
  # Record por arquivo:
  #   { "content" => str, "updated_at" => iso8601,
  #     "history" => [ { "content" => str, "at" => iso8601 }, ... ] }
  #
  # Escrita versiona (mesmo contrato do AgentFileStore): o conteúdo anterior
  # entra em `history` (mais recente primeiro), com teto HISTORY_MAX; restauração
  # é uma nova escrita (histórico linear, sem "voltar no tempo" destrutivo).
  class SystemFileStore
    SCOPE = "system_files"
    HISTORY_MAX = 20

    def initialize(config_store:)
      @cs = config_store
    end

    # -> String | nil (conteúdo atual).
    def read(filename)
      entry(filename.to_s)&.fetch("content", nil)
    end

    # -> [String] nomes dos arquivos, ordem lexicográfica.
    def list
      @cs.keys(SCOPE).sort
    end

    # Grava (upsert). create_only: recusa sobrescrever. Versiona o anterior em
    # history. -> Hash (a entry gravada).
    def write(filename, content, create_only: false)
      name = filename.to_s
      raise Harness::ValidationError, "file é obrigatório" if name.empty?

      current = entry(name)
      if create_only && current
        raise Harness::ValidationError, "arquivo de sistema '#{name}' já existe"
      end

      built = build_entry(content.to_s, current)
      @cs.put(SCOPE, name, built)
      built
    end

    # -> bool (existia?).
    def delete(filename)
      @cs.delete(SCOPE, filename.to_s)
    end

    # -> [ { "content" =>, "at" => } ] versões antigas, mais recente primeiro.
    def versions(filename)
      entry(filename.to_s)&.fetch("history", []) || []
    end

    # Restaura a versão `index` de history como o conteúdo atual (nova escrita).
    # -> Hash (entry) | levanta se index inválido / arquivo inexistente.
    def restore(filename, index)
      name = filename.to_s
      current = entry(name)
      raise Harness::NotFoundError, "arquivo de sistema '#{name}' não encontrado" unless current

      hist = current.fetch("history", [])
      i = Integer(index)
      raise Harness::ValidationError, "versão #{index} inexistente" if i.negative? || i >= hist.length

      write(name, hist[i]["content"])
    end

    private

    def entry(name)
      @cs.get(SCOPE, name)
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
