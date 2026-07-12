# frozen_string_literal: true

module Harness
  # Instâncias MCP autoradas em runtime. Um
  # record por instância no ConfigStore (scope "mcp"), keyed pelo slug do nome
  # (`tavily`, `github`, ...). Guarda transport/command/url, o flag `enabled` e
  # um Hash de credenciais `env` (tokens/keys que a instância injeta no servidor).
  #
  # As credenciais (`env`) NUNCA saem daqui em plaintext pra UI: as leituras de
  # exibição (`get`/`all`) mascaram CADA valor com o sentinel `__OCULTO__`. Só
  # `get_raw`/`all_raw` (consumidos por um cliente MCP, nunca pela tela) devolvem
  # os valores reais. Na escrita, o sentinel de volta preserva o valor; string
  # nova substitui; "" limpa (ver Harness::SecretMasking, o mesmo padrão das
  # api_keys de LLM).
  #
  # Escopo atual: CRUD durável de config (a UI de instâncias). A execução
  # de um cliente MCP contra estas instâncias é trabalho de runtime posterior
  # — o store é a fonte editável desde já.
  class McpStore
    include Coercion

    SCOPE = "mcp"

    def initialize(config_store:)
      @cs = config_store
    end

    # -> Hash MASCARADO (env com sentinel) | nil.
    def get(name)
      mask(raw(name))
    end

    # -> Hash com env REAL | nil. Uso interno (cliente MCP), nunca a tela.
    def get_raw(name)
      raw(name)
    end

    # -> [String] slugs, ordem lexicográfica.
    def names = @cs.keys(SCOPE)

    # -> [Hash] todos MASCARADOS (pra UI).
    def all
      names.filter_map { |n| get(n) }
    end

    # -> [Hash] todos com env REAL (pra um cliente MCP). Nunca vai pra tela.
    def all_raw
      names.filter_map { |n| raw(n) }
    end

    # Upsert com reconciliação de segredo por chave de env. `attrs`
    # (string|symbol keys):
    #   name (obrigatório), transport, command, url, description,
    #   enabled (bool), env ({ "CHAVE" => valor|sentinel|"" })
    # -> Hash MASCARADO (record gravado).
    def upsert(attrs)
      h = symbolize(attrs)
      name = presence(h[:name])
      raise Harness::ValidationError, "name é obrigatório" if name.nil?

      existing = raw(name)
      record = {
        "name" => name,
        "transport" => presence(h[:transport]) || "stdio",
        "command" => presence(h[:command]),
        "url" => presence(h[:url]),
        "description" => presence(h[:description]),
        "enabled" => h.fetch(:enabled, true) ? true : false,
        "env" => reconcile_env(h[:env], existing && existing["env"])
      }
      @cs.put(SCOPE, name, record)
      mask(record)
    end

    # -> bool (existia?).
    def delete(name) = @cs.delete(SCOPE, name.to_s)

    private

    def raw(name) = @cs.get(SCOPE, name.to_s)

    # Cada valor de env vira sentinel (ou some se vazio) — nunca vaza plaintext.
    def mask(record)
      return nil if record.nil?

      env = (record["env"] || {}).each_with_object({}) do |(k, v), acc|
        acc[k] = SecretMasking.mask(v)
      end
      record.merge("env" => env)
    end

    # Reconcilia o env recebido do form contra o gravado, chave a chave: uma
    # chave que veio como sentinel preserva; string nova substitui; "" (ou some
    # da submissão) limpa. Chaves NOVAS entram; chaves antigas ausentes do form
    # são removidas (o form manda o conjunto completo das chaves).
    def reconcile_env(incoming, existing)
      inc = stringify_hash(incoming)
      old = existing || {}
      inc.each_with_object({}) do |(k, v), acc|
        value = SecretMasking.reconcile(v, old[k])
        acc[k] = value unless value.nil? || value.to_s.empty?
      end
    end

    def stringify_hash(obj)
      return {} unless obj.is_a?(Hash)

      obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end

    def symbolize(attrs)
      (attrs || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end
  end
end
