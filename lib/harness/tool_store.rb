# frozen_string_literal: true

require "time"

module Harness
  # Tools POR DADOS autoradas em runtime. Um record por tool no ConfigStore
  # (scope "tools"), keyed pelo nome. Guarda a ToolDefinition inteira, versiona
  # (igual SkillStore/AgentFileStore) e MASCARA os headers-credencial (igual
  # McpStore mascara o env): os headers cujo nome está em `secret_headers` nunca
  # saem em plaintext pra UI — viram o sentinel `__OCULTO__`. Só `get_raw`/
  # `all_raw` (consumidos pelo DataDefinedTool/overlay, nunca a tela) devolvem os
  # valores reais. Fase 5, Etapa A.
  #
  # Record no ConfigStore:
  #   { "definition" => { ...ToolDefinition#to_h... },
  #     "updated_at" => iso8601,
  #     "history"    => [ { "definition" =>, "at" => }, ... ] }
  class ToolStore
    SCOPE = "tools"
    HISTORY_MAX = 20

    def initialize(config_store:)
      @cs = config_store
    end

    # -> Hash da ToolDefinition MASCARADA (headers secretos c/ sentinel) | nil.
    def get(name)
      d = raw_definition(name)
      d && mask_definition(d)
    end

    # -> Hash da ToolDefinition com headers REAIS | nil. Uso interno (tool/overlay).
    def get_raw(name) = raw_definition(name)

    # -> [String] nomes, ordem lexicográfica.
    def names = @cs.keys(SCOPE)

    # -> [Hash] definições MASCARADAS (pra UI).
    def all
      names.filter_map { |n| get(n) }
    end

    # -> [Hash] definições com headers REAIS (pro overlay/registry). Nunca à tela.
    def all_raw
      names.filter_map { |n| raw_definition(n) }
    end

    # Grava (upsert). `attrs` é um Hash de ToolDefinition (a UI pode mandar headers
    # secretos como sentinel: preserva o gravado). create_only recusa sobrescrever.
    # Valida via ToolDefinition.from_h. -> Hash da definição MASCARADA.
    def write(attrs, create_only: false)
      definition = Harness::ToolDefinition.from_h(attrs)   # valida (levanta ValidationError)
      name = definition.name
      existing = @cs.get(SCOPE, name)
      raise Harness::ValidationError, "tool '#{name}' já existe" if create_only && existing

      final = definition.to_h
      final["request"]["headers"] = reconcile_secret_headers(
        final["request"]["headers"], definition.secret_headers,
        existing&.dig("definition", "request", "headers")
      )

      rec = build_record(final, existing)
      @cs.put(SCOPE, name, rec)
      mask_definition(final)
    end

    # -> bool (existia?).
    def delete(name) = @cs.delete(SCOPE, name.to_s)

    # -> [ { "definition" => MASCARADA, "at" => } ] mais recente primeiro.
    def versions(name)
      (record(name)&.fetch("history", []) || []).map do |h|
        { "definition" => mask_definition(h["definition"]), "at" => h["at"] }
      end
    end

    # Restaura a versão `index` como definição atual (nova escrita, versiona a atual).
    # -> Hash da definição MASCARADA.
    def restore(name, index)
      rec = record(name)
      raise Harness::NotFoundError, "tool '#{name}' não encontrada" unless rec

      hist = rec.fetch("history", [])
      i = Integer(index)
      raise Harness::ValidationError, "versão #{index} inexistente" if i.negative? || i >= hist.length

      # A versão histórica guarda headers REAIS -> reescreve direto (bypass do
      # masking de entrada; write só re-valida a estrutura).
      write(hist[i]["definition"])
    end

    private

    def record(name) = @cs.get(SCOPE, name.to_s)

    def raw_definition(name) = record(name)&.fetch("definition", nil)

    def build_record(definition, current)
      history = current ? current.fetch("history", []) : []
      if current
        history = [{ "definition" => current["definition"], "at" => current["updated_at"] }] + history
        history = history.first(HISTORY_MAX)
      end
      { "definition" => definition, "updated_at" => Time.now.utc.iso8601, "history" => history }
    end

    # Cada header em secret_headers vira sentinel; os demais passam intactos.
    def mask_definition(definition)
      secret = definition["secret_headers"] || []
      return definition if secret.empty?

      headers = (definition.dig("request", "headers") || {}).each_with_object({}) do |(k, v), acc|
        acc[k] = secret.include?(k) ? SecretMasking.mask(v) : v
      end
      definition.merge("request" => definition["request"].merge("headers" => headers))
    end

    # Reconcilia SÓ os headers secretos contra o gravado: sentinel preserva,
    # string nova substitui, "" limpa (remove a chave). Non-secret passam intactos.
    def reconcile_secret_headers(incoming, secret_names, existing)
      old = existing || {}
      secret_names.each_with_object(incoming.dup) do |hname, acc|
        next unless acc.key?(hname)

        value = SecretMasking.reconcile(acc[hname], old[hname])
        if value.nil? || value.to_s.empty?
          acc.delete(hname)
        else
          acc[hname] = value
        end
      end
    end
  end
end
