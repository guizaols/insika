# frozen_string_literal: true

require "json"

module Harness
  # Trace de TOOL-CALLS por sessão, para debug no Studio (FOLLOWUP §3.1). Um
  # record por sessão no backend cru (scope "tool_traces") — dado de RUNTIME, ao
  # lado de sessions/tasks, NÃO config (por isso `store:` cru, como o SessionStore,
  # e não o ConfigStore). Uma LISTA capada de entradas; o ToolEnvelope grava uma
  # por call (nome + args do modelo + resultado + status + ms). Responde
  # `/studio/sessions/:id`.
  #
  # SEGURANÇA mora AQUI (o store é dono): a tela é de operador, mas args/resposta
  # podem trazer PII/credencial. Toda escrita passa por mask (valores de chaves
  # sensíveis viram sentinel) + clip (trunca campos grandes). O evento efêmero
  # `data_tool_call` (nome+status, 0 vazamento) continua para os cards ao vivo;
  # ISTO é o registro durável, mais rico, atrás do login do Studio.
  class ToolTraceStore
    SCOPE = "tool_traces"
    MAX_PER_SESSION = 200                # cauda por sessão (evita crescer sem fim)
    MAX_FIELD_CHARS = 2_000              # teto por campo args/result
    SECRET_KEY_RE = /token|secret|authorization|password|passwd|api[-_]?key|bearer|cookie/i

    def initialize(store:)
      @store = store
    end

    # Grava uma entrada (sanitizada) na sessão. session_id ausente -> no-op. O
    # ToolEnvelope já protege, mas aqui também: trace NUNCA quebra o turno.
    def record(session_id:, entry:)
      sid = session_id.to_s
      return if sid.empty?

      list = (@store.get(SCOPE, sid) || []) + [sanitize(entry)]
      @store.set(SCOPE, sid, list.last(MAX_PER_SESSION))
    rescue StandardError
      nil
    end

    # -> [Hash] entradas da sessão em ordem cronológica. [] se nenhuma.
    def for_session(session_id) = @store.get(SCOPE, session_id.to_s) || []

    # Descarta o trace de uma sessão (limpeza). -> bool (existia?).
    def clear(session_id) = @store.delete(SCOPE, session_id.to_s)

    private

    def sanitize(entry)
      e = stringify_keys(entry)
      {
        "turn" => e["turn"], "tool" => e["tool"].to_s, "call_id" => e["call_id"].to_s,
        "ok" => ok?(e["result"]),
        "args" => clip(mask(e["args"])), "result" => clip(mask(e["result"])),
        "ms" => e["ms"], "at" => e["at"].to_s
      }
    end

    # Erro convencional das tools = Hash com chave "error"/:error (o resto é ok).
    def ok?(result)
      !(result.is_a?(Hash) && (result.key?("error") || result.key?(:error)))
    end

    # Mascara valores de chaves sensíveis (recursivo); demais passam intactos.
    def mask(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), acc|
          acc[k.to_s] = SECRET_KEY_RE.match?(k.to_s) ? SecretMasking::SENTINEL : mask(v)
        end
      when Array then obj.map { |v| mask(v) }
      else obj
      end
    end

    # -> String legível e capada (JSON quando estruturado). Trunca por CARACTERE
    # (não byte — evita cortar UTF-8 no meio).
    def clip(obj)
      s = obj.is_a?(String) ? obj : safe_json(obj)
      s.length > MAX_FIELD_CHARS ? "#{s[0, MAX_FIELD_CHARS]}…(truncado)" : s
    end

    def safe_json(obj)
      JSON.generate(obj)
    rescue StandardError
      obj.inspect
    end

    def stringify_keys(hash)
      (hash || {}).each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end
  end
end
