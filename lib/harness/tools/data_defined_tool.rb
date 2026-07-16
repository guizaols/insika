# frozen_string_literal: true

require "ruby_llm"
require "json"
require "erb"

module Harness
  module Tools
    # Tool POR DADOS: uma classe, N instâncias parametrizadas por uma
    # ToolDefinition (o mesmo padrão do A2ARemote). Faz uma chamada HTTP descrita
    # em config — sem código Ruby por tool. Como herda RubyLLM::Tool (puxa a gem),
    # NÃO é requerida em lib/harness.rb; o overlay a carrega lazy no registro
    # (Etapa B). Fase 5, Etapa A.
    #
    # Contrato preservado por duck-typing: sobrescreve name/description/parameters/
    # execute; params_schema do RubyLLM deriva de #parameters automaticamente.
    # execute NUNCA levanta — erro (param faltando, egress bloqueado, HTTP, parse)
    # vira `{ error: }` ao modelo, como as demais tools.
    class DataDefinedTool < RubyLLM::Tool
      def initialize(definition:, http:, egress: Harness::EgressGuard, egress_options: {},
                     event_stream: nil, turn_context: {})
        @definition = definition
        @http = http
        @egress = egress
        @egress_options = egress_options
        @event_stream = event_stream
        @turn_context = symbolize_ctx(turn_context)
        super()
      end

      # Contexto de turno (Fase 6/D2/G3): a tool de registry NÃO recebe TurnState,
      # então o Executor DEPOSITA aqui, por-turno, os ids do turno
      # (chat/agent/tenant/store). Resolvem {{ctx.*}} — SEPARADO dos {{param}} do
      # modelo — p/ emitir X-Chat-Id/X-Store-Id/X-Agent-Id. Vêm do TURNO, nunca do
      # modelo (R2). Reader p/ teste; writer é o ponto de injeção do Executor.
      attr_reader :turn_context

      def turn_context=(ctx)
        @turn_context = symbolize_ctx(ctx)
      end

      # name/description/parameters por INSTÂNCIA (senão o modelo veria o nome
      # derivado da classe p/ todas as data-tools).
      def name = @definition.name
      def description = @definition.description

      # JSON Schema COMPLETO (aninhado) direto no params_schema do RubyLLM — é o que
      # os providers serializam (OpenAI/Anthropic/Gemini/Bedrock preferem
      # params_schema; parameters é só fallback). Provider-agnóstico (Fase 7/F6) e
      # a única forma que expressa aninhamento (object/array/enum). Fase 7, Etapa A.
      def params_schema = @definition.parameters

      # Visão PLANA de topo p/ discovery (tool_search chama #parameters no tool
      # resolvido). O schema aninhado real vai pelo #params_schema acima.
      def parameters
        @parameters ||= @definition.top_level_params.each_with_object({}) do |p, acc|
          sym = p[:name].to_sym
          acc[sym] = RubyLLM::Parameter.new(sym, type: p[:type], desc: p[:description], required: p[:required])
        end
      end

      def execute(**kwargs)
        missing = @definition.required_params.reject { |n| present?(kwargs[n.to_sym]) }
        return { error: "parâmetro(s) obrigatório(s) ausente(s): #{missing.join(', ')}" } unless missing.empty?

        req = build_request(kwargs)
        reason = @egress.violation(req[:url], **@egress_options)
        return { error: "destino bloqueado: #{reason}" } if reason

        result = @http.request(**req)
        emit(result[:status])
        extract(result)
      rescue StandardError => e
        { error: "falha na chamada HTTP: #{e.message}" }
      end

      private

      # Interpola os templates da definição com os args do modelo, com escaping por
      # contexto: url/query -> percent-encode; header -> tira CR/LF (anti-injeção);
      # body -> escaping JSON.
      def build_request(kwargs)
        r = @definition.request
        url = interpolate(r[:url], kwargs, :url)
        url = append_query(url, r[:query], kwargs)
        headers = r[:headers].transform_values { |v| interpolate(v, kwargs, :header) }
        body = r[:body] && interpolate(r[:body], kwargs, :body)
        { method: r[:method], url: url, headers: headers, body: body, timeout: @definition.timeout }
      end

      def append_query(url, query, kwargs)
        return url if query.nil? || query.empty?

        pairs = query.map { |k, v| "#{ERB::Util.url_encode(k)}=#{interpolate(v, kwargs, :query)}" }
        url + (url.include?("?") ? "&" : "?") + pairs.join("&")
      end

      def interpolate(template, kwargs, mode)
        template.to_s.gsub(Harness::ToolDefinition::PLACEHOLDER_RE) do
          encode(resolve(Regexp.last_match(1), kwargs), mode)
        end
      end

      # ctx.* -> contexto do TURNO (depositado pelo Executor); demais -> args do
      # MODELO (kwargs). A separação é a fronteira de confiança de D2/R2: o modelo
      # não escolhe qual chat/loja a tool acessa.
      def resolve(name, kwargs)
        prefix = Harness::ToolDefinition::CTX_PREFIX
        if name.start_with?(prefix)
          @turn_context[name.delete_prefix(prefix).to_sym]
        else
          kwargs[name.to_sym]
        end
      end

      def symbolize_ctx(ctx)
        (ctx || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end

      def encode(value, mode)
        case mode
        when :url, :query then ERB::Util.url_encode(value.to_s)
        when :header then value.to_s.gsub(/[\r\n]/, "")
        when :body then value.is_a?(String) ? value.to_json[1..-2] : value.to_json
        end
      end

      def extract(result)
        case @definition.response[:extract]
        when "status" then { status: result[:status] }
        when "body_raw" then http_ok?(result) ? result[:body] : http_error(result)
        when "json_path" then extract_json(result)
        end
      end

      def extract_json(result)
        return http_error(result) unless http_ok?(result)

        parsed = begin
          JSON.parse(result[:body])
        rescue JSON::ParserError
          return { error: "resposta não é JSON" }
        end
        dig_path(parsed, @definition.response[:path])
      end

      def dig_path(obj, path)
        path.split(".").reduce(obj) do |cur, seg|
          return { error: "caminho '#{path}' não encontrado na resposta" } unless cur.is_a?(Hash) && cur.key?(seg)

          cur[seg]
        end
      end

      def http_ok?(result) = result[:status] < 400

      def http_error(result)
        { error: "HTTP #{result[:status]}: #{result[:body].to_s[0, 200]}" }
      end

      def present?(v) = !(v.nil? || v.to_s.empty?)

      # Sem correlação de task (tool de registry não recebe TurnState) -> meta {}.
      # Emite só nome + status: NUNCA corpo/headers (0 vazamento de segredo, R2).
      def emit(status)
        @event_stream&.emit(Harness::Event.new(
                              type: :data_tool_call, data: { tool: @definition.name, status: status }, meta: {}
                            ))
      end
    end
  end
end
