# frozen_string_literal: true

require "ruby_llm"
require "json"
require "erb"

module Insika
  module Tools
    # DATA-DEFINED tool: one class, N instances parameterized by a
    # ToolDefinition (the same pattern as A2ARemote). It makes an HTTP call described
    # in config — no Ruby code per tool. Since it inherits RubyLLM::Tool (pulls in the gem),
    # it is NOT required in lib/harness.rb; the overlay loads it lazily at registration
    # (Step B). Phase 5, Step A.
    #
    # Contract preserved by duck-typing: it overrides name/description/parameters/
    # execute; RubyLLM's params_schema derives from #parameters automatically.
    # execute NEVER raises — an error (missing param, blocked egress, HTTP, parse)
    # becomes `{ error: }` to the model, like the other tools.
    class DataDefinedTool < RubyLLM::Tool
      def initialize(definition:, http:, egress: Insika::EgressGuard, egress_options: {},
                     event_stream: nil, turn_context: {})
        @definition = definition
        @http = http
        @egress = egress
        @egress_options = egress_options
        @event_stream = event_stream
        @turn_context = symbolize_ctx(turn_context)
        super()
      end

      # Turn context (Phase 6/D2/G3): the registry tool does NOT receive TurnState,
      # so the Executor DEPOSITS the turn ids here, per-turn
      # (chat/agent/tenant/store). They resolve {{ctx.*}} — SEPARATE from the model's
      # {{param}} — to emit X-Chat-Id/X-Store-Id/X-Agent-Id. They come from the TURN, never from
      # the model (R2). Reader for testing; the writer is the Executor's injection point.
      attr_reader :turn_context

      def turn_context=(ctx)
        @turn_context = symbolize_ctx(ctx)
      end

      # name/description/parameters per INSTANCE (otherwise the model would see the name
      # derived from the class for every data-tool).
      def name = @definition.name
      def description = @definition.description

      # FULL (nested) JSON Schema straight into RubyLLM's params_schema — it is what
      # the providers serialize (OpenAI/Anthropic/Gemini/Bedrock prefer
      # params_schema; parameters is just a fallback). Provider-agnostic (Phase 7/F6) and
      # the only form that expresses nesting (object/array/enum). Phase 7, Step A.
      def params_schema = @definition.parameters

      # FLAT top-level view for discovery (tool_search calls #parameters on the resolved
      # tool). The real nested schema goes through #params_schema above.
      def parameters
        @parameters ||= @definition.top_level_params.each_with_object({}) do |p, acc|
          sym = p[:name].to_sym
          acc[sym] = RubyLLM::Parameter.new(sym, type: p[:type], desc: p[:description], required: p[:required])
        end
      end

      def execute(**kwargs)
        missing = @definition.required_params.reject { |n| present?(kwargs[n.to_sym]) }
        return { error: "missing required parameter(s): #{missing.join(', ')}" } unless missing.empty?

        req = build_request(kwargs)
        reason = @egress.violation(req[:url], **@egress_options)
        return { error: "destination blocked: #{reason}" } if reason

        result = @http.request(**req)
        emit(result[:status])
        extract(result)
      rescue StandardError => e
        { error: "HTTP call failed: #{e.message}" }
      end

      private

      # Interpolates the definition's templates with the model's args, escaping by
      # context: url/query -> percent-encode; header -> strips CR/LF (anti-injection);
      # body -> JSON escaping.
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
        template.to_s.gsub(Insika::ToolDefinition::PLACEHOLDER_RE) do
          encode(resolve(Regexp.last_match(1), kwargs), mode)
        end
      end

      # ctx.* -> TURN context (deposited by the Executor); the rest -> MODEL args
      # (kwargs). The split is the D2/R2 trust boundary: the model does
      # not choose which chat/store the tool accesses.
      def resolve(name, kwargs)
        prefix = Insika::ToolDefinition::CTX_PREFIX
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
          return { error: "response is not JSON" }
        end
        dig_path(parsed, @definition.response[:path])
      end

      def dig_path(obj, path)
        path.split(".").reduce(obj) do |cur, seg|
          return { error: "path '#{path}' not found in the response" } unless cur.is_a?(Hash) && cur.key?(seg)

          cur[seg]
        end
      end

      def http_ok?(result) = result[:status] < 400

      def http_error(result)
        { error: "HTTP #{result[:status]}: #{result[:body].to_s[0, 200]}" }
      end

      def present?(v) = Insika::Coercion.present?(v)

      # No task correlation (registry tool does not receive TurnState) -> meta {}.
      # Emits only name + status: NEVER body/headers (0 secret leakage, R2).
      def emit(status)
        @event_stream&.emit(Insika::Event.new(
                              type: :data_tool_call, data: { tool: @definition.name, status: status }, meta: {}
                            ))
      end
    end
  end
end
