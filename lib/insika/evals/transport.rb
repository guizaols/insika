# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "assertions"

module Insika
  module Evals
    # How the runner turns a (agent, conversation, message) into a TurnResult. The
    # runner depends only on this seam, so it's unit-testable with a fake — the real
    # HttpTransport is exercised against a running insika.
    #
    # One turn's outcome: the TurnResult the engine asserts on + perf timing (ttfb/
    # total in ms) so `--mode perf` reports real latency over the real corpus (#6b).
    #
    # `usage` is the turn's token counts as the deployment reported them
    # (`response.completed`), or nil when the provider sent none. It is carried, never
    # asserted on: the consumer is RFC-0013's refinement budget, which has to bound the
    # cost of a gate replay and cannot invent the number. nil is preserved as nil
    # rather than zeroed — "the provider did not say" and "it cost nothing" are
    # different facts, and a budget that confuses them stops being a budget.
    TurnOutcome = Struct.new(:result, :ttfb, :total, :usage, keyword_init: true)

    # Pure reduction of the /v1/responses SSE stream. Kept separate from the HTTP so
    # it's testable offline with canned frames (server/responses.rb is the producer).
    module Sse
      module_function

      # Raw SSE text -> [parsed JSON payload]. Skips `event:` lines, blanks, [DONE].
      def payloads(text)
        text.to_s.split("\n\n").flat_map do |frame|
          frame.each_line.filter_map do |line|
            next unless line.start_with?("data:")

            p = line.sub(/^data:\s*/, "").strip
            next if p.empty? || p == "[DONE]"

            begin
              JSON.parse(p)
            rescue JSON::ParserError
              nil
            end
          end
        end
      end

      # [payload] -> { output_text:, tool_calls:, usage:, error: }. Maps the Responses
      # frames (see server/responses.rb#frame_for): text deltas accumulate; each
      # function_call item contributes a tool NAME (this stream carries no per-tool
      # status — that lives in the ToolTraceStore, an in-process enrichment); a
      # `response.failed` sets the turn error.
      def reduce(payloads)
        text = +""
        tools = []
        usage = nil
        error = nil
        payloads.each do |o|
          case o["type"]
          when "response.output_text.delta"
            text << o["delta"].to_s
          when "response.output_item.added"
            item = o["item"] || {}
            tools << { "name" => item["name"].to_s, "status" => nil } if item["type"] == "function_call"
          when "response.completed"
            usage = o.dig("response", "usage")
          when "response.failed"
            error = o.dig("response", "error", "message") || "response.failed"
          end
        end
        { output_text: text, tool_calls: tools, usage: usage, error: error }
      end
    end

    # What the deployment HAS, per agent (RFC-0014 §3.2), read over the same gated
    # `/v1` the replay uses. The eval stays a client: it asks the engine instead of
    # keeping its own idea of which tools exist.
    #
    # `#for(id)` -> { "tools" => [names] | nil, "capabilities" => [names] } | nil.
    # nil means UNRESOLVED — the agent is not there, the route is not wired, the
    # deployment is unreachable — and the Runner treats that as "run the case
    # anyway". Silence must not shrink a suite. Answers are memoized: a corpus has
    # many cases per agent and this is the same answer every time.
    class HttpCapabilities
      def initialize(base_url:, token:, timeout: 10)
        @base = base_url
        @token = token
        @timeout = timeout
        @cache = {}
      end

      def for(agent_id)
        @cache.fetch(agent_id) { @cache[agent_id] = fetch(agent_id) }
      end

      private

      def fetch(agent_id)
        uri = URI.join("#{@base}/", "v1/agents/#{URI.encode_www_form_component(agent_id)}")
        req = Net::HTTP::Get.new(uri)
        req["Authorization"] = "Bearer #{@token}"

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.read_timeout = @timeout
        http.open_timeout = @timeout
        res = http.start { http.request(req) }
        return nil unless res.code.to_i == 200

        body = JSON.parse(res.body)
        { "tools" => body["tools"], "capabilities" => Array(body["capabilities"]) }
      rescue StandardError, JSON::ParserError
        nil
      end
    end

    # Drives real turns over POST /v1/responses — the SAME surface as
    # scripts/loadtest.rb, so `--mode perf` is apples-to-apples with the loadtest and
    # closes the real-traffic gap (#6b). A conversation is keyed by `user` (the
    # adapter continues an existing chat on the same id), so multi-turn goldens replay
    # in order under one `conv` id.
    class HttpTransport
      def initialize(base_url:, token:, timeout: 120)
        @base = base_url
        @token = token
        @timeout = timeout
      end

      def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def turn(agent:, conv:, message:)
        uri = URI.join("#{@base}/", "v1/responses")
        req = Net::HTTP::Post.new(uri)
        req["Authorization"] = "Bearer #{@token}"
        req["Content-Type"] = "application/json"
        req["Accept"] = "text/event-stream"
        req.body = JSON.generate(model: "openclaw:#{agent}", user: conv, stream: true, input: message)

        t0 = mono
        ttfb = nil
        buffer = +""
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.read_timeout = @timeout
        http.open_timeout = 10

        status = nil
        http.start do
          http.request(req) do |res|
            status = res.code.to_i
            return failure("HTTP #{status}", t0) unless status.between?(200, 299)

            res.read_body do |chunk|
              ttfb ||= (mono - t0) * 1000.0
              buffer << chunk
            end
          end
        end

        reduced = Sse.reduce(Sse.payloads(buffer))
        TurnOutcome.new(
          result: TurnResult.new(output_text: reduced[:output_text],
                                 tool_calls: reduced[:tool_calls], error: reduced[:error]),
          ttfb: ttfb, total: (mono - t0) * 1000.0, usage: reduced[:usage]
        )
      rescue StandardError => e
        failure(e.class.to_s, t0)
      end

      private

      def failure(msg, t0)
        TurnOutcome.new(result: TurnResult.new(output_text: "", tool_calls: [], error: msg),
                        ttfb: nil, total: (mono - t0) * 1000.0)
      end
    end
  end
end
