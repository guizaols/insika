# frozen_string_literal: true

require "ruby_llm"
require "json"
require "erb"

module Insika
  module Tools
    # DATA-DEFINED tool: one class, N instances parameterized by a
    # ToolDefinition (the same pattern as A2ARemote). It makes an HTTP call described
    # in config — no Ruby code per tool. Since it inherits RubyLLM::Tool (pulls in the gem),
    # it is NOT required in lib/insika.rb; the overlay loads it lazily at registration
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

      # Turn context: the registry tool does NOT receive TurnState,
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

      # RFC-0029 D4: the tool's own evidence declaration (a Spec | nil). The
      # envelope's duck-typed resolution checks this FIRST — a data-tool declares
      # its evidence on its definition, never in the registry metadata.
      def evidence = @definition.evidence

      # FULL (nested) JSON Schema straight into RubyLLM's params_schema — it is what
      # the providers serialize (OpenAI/Anthropic/Gemini/Bedrock prefer
      # params_schema; parameters is just a fallback). Provider-agnostic and
      # the only form that expresses nesting (object/array/enum).,.
      def params_schema = @definition.parameters

      # FLAT top-level view for discovery (tool_search calls #parameters on the resolved
      # tool). The real nested schema goes through #params_schema above.
      def parameters
        @parameters ||= @definition.top_level_params.each_with_object({}) do |p, acc|
          sym = p[:name].to_sym
          acc[sym] = RubyLLM::Parameter.new(sym, type: p[:type], desc: p[:description], required: p[:required])
        end
      end

      # The args are checked against the tool's own JSON Schema BEFORE the request is
      # built: a call the schema does not allow becomes `{ error: }` the model can act
      # on, instead of a wrongly-shaped request that a backend answers 200 to.
      def execute(**kwargs)
        if (bad = Insika::SchemaGuard.violation(@definition.parameters, kwargs))
          return { error: bad }
        end

        req = build_request(kwargs)
        reason = @egress.violation(req[:url], **@egress_options)
        return { error: "destination blocked: #{reason}" } if reason

        result = @http.request(**req)
        emit(result[:status])
        payload = extract(result)
        # The RESPONSE says the turn is over (`halt_when`): the backend already
        # answered the customer, so letting the model comment would deliver the
        # message twice. RubyLLM's Tool::Halt ends its loop right here — no second
        # provider call, and the decision is the engine's, not a request in a prompt.
        # Only on a 2xx: an error body that happens to carry the value is a failure,
        # and a failure must reach the model.
        if http_ok?(result) && @definition.halt?(result[:body])
          # `say` (optional) travels WITH the halt so the Executor can publish it when
          # the model wrote no lead-in. Wrapped only when there is one, so every tool
          # that declares no `say` keeps producing exactly the payload it always did.
          say = @definition.halt_say(result[:body])
          return RubyLLM::Tool::Halt.new(say ? Insika::ToolDefinition.wrap_halt(payload, say) : payload)
        end

        payload
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
      # (kwargs). The split is the/R2 trust boundary: the model does
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
        # RFC-0029 D3: the raw response body under an envelope-only key, so the
        # ToolEnvelope can parse items/attachments. A non-2xx is an ERROR like
        # any other extract — an error must reach the model verbatim.
        when "evidence_envelope"
          http_ok?(result) ? { "__insika_body" => result[:body].to_s } : http_error(result)
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

      # 2xx only. A 3xx is NOT success: the HttpClient does not follow redirects
      # (the EgressGuard cleared the authored URL, not the hop's destination), and
      # servers send a 3xx with an empty body — so treating it as ok handed the
      # model "" and it narrated a plausible outage. A moved API must read as an
      # error naming its new URL, which is a definition to fix.
      def http_ok?(result) = result[:status] >= 200 && result[:status] < 300

      # A non-2xx is an ERROR — the backend said so, and the model has to know the call
      # failed. But the body of a failure is often the backend TALKING: an envelope with
      # a status and an instruction ("chat not found — ask the person to start over").
      # Flattening it into a 200-char slice of a string threw that away exactly when the
      # model needed it most, so a JSON body rides along parsed, under its own key.
      # A non-JSON body (an HTML error page) stays truncated: it is noise, not a message.
      ERROR_BODY_MAX = 2_000

      def http_error(result)
        if (300..399).cover?(result[:status]) && result[:location]
          return { error: "HTTP #{result[:status]}: moved to #{result[:location]}" }
        end

        raw = result[:body].to_s
        parsed = parse_error_body(raw)
        return { error: "HTTP #{result[:status]}", body: parsed } if parsed

        { error: "HTTP #{result[:status]}: #{raw[0, 200]}" }
      end

      # -> parsed JSON body worth forwarding | nil (not JSON, or too big to be a message).
      def parse_error_body(raw)
        return nil if raw.empty? || raw.bytesize > ERROR_BODY_MAX

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) || parsed.is_a?(Array) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

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
