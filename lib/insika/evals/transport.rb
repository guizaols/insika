# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "open3"
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
    # asserted on: the consumer is's refinement budget, which has to bound the
    # cost of a gate replay and cannot invent the number. nil is preserved as nil
    # rather than zeroed — "the provider did not say" and "it cost nothing" are
    # different facts, and a budget that confuses them stops being a budget.
    TurnOutcome = Struct.new(:result, :ttfb, :total, :usage, keyword_init: true)

    # The deployment answered the seed with a refusal (403: `evals.seeding` is off
    # there). Its own class so the Runner can SKIP the case with the reason — a
    # different fact from a seed that failed (409, 5xx, network), which fails it.
    class SeedRefused < Insika::Error; end

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
      # function_call `added` item opens a tool call (name + arguments); its `done`
      # item closes it with how the call ended (status ok/error/blocked + the gate
      # that held it). An older deployment sends `added` only, and the entries keep
      # `status: nil` — the shape widened, nothing moved. A `response.failed` sets
      # the turn error.
      def reduce(payloads)
        text = +""
        tools = []
        by_id = {}
        ui = []
        usage = nil
        error = nil
        payloads.each do |o|
          case o["type"]
          when "response.output_text.delta"
            text << o["delta"].to_s
          when "insika.ui"
            # A presentation tool's selection — the component and how many cards it
            # showed. The `ui_components`/`no_ui` graders read this.
            ui << { "component" => o["component"].to_s, "count" => o["count"].to_i }
          when "response.output_item.added"
            item = o["item"] || {}
            next unless item["type"] == "function_call"

            entry = { "name" => item["name"].to_s, "status" => nil }
            (args = arguments_of(item["arguments"])) && (entry["arguments"] = args)
            tools << entry
            (id = item["call_id"]) && (by_id[id] = entry)
          when "response.output_item.done"
            item = o["item"] || {}
            next unless item["type"] == "function_call"

            # Paired by call_id. An older engine's frames carry none: then the FIRST
            # still-open call of that name (a batch runs concurrently and its `done`
            # frames arrive in completion order). No `added` at all = a system tool
            # the engine reports the end of but never announced (load_skill): not a
            # tool call here, exactly as it is not one in the in-process transport.
            entry = by_id[item["call_id"]] || tools.find { |t| t["name"] == item["name"].to_s && t["status"].nil? }
            next unless entry

            entry["status"] = item["status"].to_s
            entry["gate"] = item["gate"].to_s if item["gate"]
          when "response.completed"
            usage = o.dig("response", "usage")
          when "response.failed"
            error = o.dig("response", "error", "message") || "response.failed"
          end
        end
        { output_text: text, tool_calls: tools, ui: ui, usage: usage, error: error }
      end

      # The item's `arguments` is a JSON string on the wire (the OpenAI shape); the
      # graders want the Hash. Anything unparseable stays the raw string — the call
      # happened, and a report should still show what it saw. nil when absent.
      def arguments_of(raw)
        return nil if raw.nil?
        return raw unless raw.is_a?(String)

        JSON.parse(raw)
      rescue JSON::ParserError
        raw
      end
    end

    # What the deployment HAS, per agent, read over the same gated
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
        { "tools" => body["tools"], "capabilities" => Array(body["capabilities"]),
          "side_effect_tools" => body["side_effect_tools"] }
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
        req.body = JSON.generate(model: "insika:#{agent}", user: conv, stream: true, input: message)

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
          result: TurnResult.new(output_text: reduced[:output_text], tool_calls: reduced[:tool_calls],
                                 ui: reduced[:ui], error: reduced[:error]),
          ttfb: ttfb, total: (mono - t0) * 1000.0, usage: reduced[:usage]
        )
      rescue StandardError => e
        failure(e.class.to_s, t0)
      end

      # Loads a case's `state:` into the conversation BEFORE its first turn —
      # `POST /v1/conversations/:conv/seed`, the same Bearer as the turn, so the
      # seeded session is the one the turn continues. The body is the state mapping
      # (+ `customer` when the turns will carry one). A 403 is the deployment
      # refusing to seed (`evals.seeding` off) -> SeedRefused, which the Runner
      # turns into a skip; anything else that is not 2xx is an error that fails the
      # case — a seed that did not land must never let the case run empty and pass.
      def seed(conv, state, customer: nil)
        uri = URI.join("#{@base}/", "v1/conversations/#{URI.encode_www_form_component(conv)}/seed")
        req = Net::HTTP::Post.new(uri)
        req["Authorization"] = "Bearer #{@token}"
        req["Content-Type"] = "application/json"
        body = Insika::Coercion.deep_stringify(state)
        body["customer"] = customer if customer
        req.body = JSON.generate(body)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.read_timeout = @timeout
        http.open_timeout = 10
        res = http.start { http.request(req) }
        code = res.code.to_i
        return true if code.between?(200, 299)

        message = begin
          JSON.parse(res.body.to_s).dig("error", "message")
        rescue JSON::ParserError
          nil
        end
        raise SeedRefused, "HTTP 403#{" #{message}" if message}" if code == 403

        raise Insika::Error, "HTTP #{code}#{" #{message}" if message}"
      rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout => e
        raise Insika::Error, e.class.to_s
      end

      private

      def failure(msg, t0)
        TurnOutcome.new(result: TurnResult.new(output_text: "", tool_calls: [], error: msg),
                        ttfb: nil, total: (mono - t0) * 1000.0)
      end
    end

    # A transport over the deployment's OWN graph, in-process — no HTTP. This is
    # how a simulated conversation (or a replay) exercises the local agent the
    # way a customer would reach it, tools and guardrails included, without a
    # server in between. `runtime` is anything answering the DSL Runtime contract
    # (#chat(message, session_id:, agent:) -> text, raising on failure) — the DSL
    # Definition/System runtime, or a test double.
    #
    # Tool activity is captured from the graph's event stream (the `:tool_call`
    # events the ChatBuilder emits), so an in-process transcript records the same
    # tool names an HTTP replay would — the Simulator's transcript is not blind to
    # what the local agent called. `event_stream` is optional; when omitted it is
    # read off the runtime's graph when one is reachable.
    class GraphTransport
      def initialize(runtime:, event_stream: nil)
        @runtime = runtime
        @event_stream = event_stream ||
                      (runtime.graph.event_stream if runtime.respond_to?(:graph) && runtime.graph)
      end

      def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def turn(agent:, conv:, message:)
        t0 = mono
        sub = @event_stream&.subscribe(types: %i[tool_call ui])
        begin
          text = @runtime.chat(message, session_id: conv, agent: agent)
          tools, ui = drain(sub)
          TurnOutcome.new(
            result: TurnResult.new(output_text: text.to_s, tool_calls: tools, ui: ui, error: nil),
            ttfb: nil, total: (mono - t0) * 1000.0, usage: nil
          )
        rescue Insika::Error => e
          tools, ui = drain(sub)
          TurnOutcome.new(
            result: TurnResult.new(output_text: "", tool_calls: tools, ui: ui, error: e.message),
            ttfb: nil, total: (mono - t0) * 1000.0, usage: nil
          )
        ensure
          sub&.close
        end
      end

      # In-process seeding: the SAME `seed_session` command the HTTP route dispatches,
      # on the graph's own bus — no route, no gate (there is no tenant token to
      # protect here; whoever holds the graph already holds everything). A runtime
      # that exposes no graph cannot seed, and says so as an error the Runner fails
      # the case with.
      def seed(conv, state, customer: nil)
        bus = @runtime.graph.bus if @runtime.respond_to?(:graph) && @runtime.graph
        raise Insika::Error, "transport cannot seed state: the runtime exposes no graph" if bus.nil?

        payload = { id: conv, state: state }
        payload[:customer] = customer if customer
        bus.dispatch(Insika::Command.build(:seed_session, payload, transport: :internal))
      end

      private

      # The same shapes an HTTP replay produces: tools as [{ "name" =>, "status" => nil }]
      # (the stream carries no per-tool status — that lives in the trace store), ui as
      # [{ "component" =>, "count" => }]. -> [tools, ui]
      def drain(sub)
        return [[], []] if sub.nil?

        events = sub.drain_nonblocking
        tools = events.select { |ev| ev.type == :tool_call }
                      .map { |ev| { "name" => ev.data[:name].to_s, "status" => nil } }
        ui = events.select { |ev| ev.type == :ui }
                   .map { |ev| { "component" => ev.data[:component].to_s, "count" => ev.data[:count].to_i } }
        [tools, ui]
      end
    end

    # Drives a turn through an EXTERNAL agent runtime — a rival harness in a
    # container — so the same corpus can be replayed against something that is not
    # Insika and the answers land in the same TurnResult the graders already read.
    #
    # The protocol is one JSON object each way, per turn:
    #
    #   in  (stdin):  {"agent": "...", "conv": "...", "message": "..."}
    #   out (stdout): {"output_text": "...", "tool_calls": [...], "error": null,
    #                  "usage": {...}}
    #
    # `command` is an argv array, never a shell string: the message is customer text
    # and must not be able to reach a shell. The adapter that speaks this protocol
    # lives with the harness under test, not here — every rival has its own idea of
    # what a turn is, and that translation is exactly what a bench entry costs.
    #
    # A harness whose adapter cannot report which tools were called says so ONCE, at
    # construction (`reports_tool_calls: false`), and the Runner skips its tool-shaped
    # graders with the reason. Otherwise a missing `tool_calls` is read as "this turn
    # called nothing", which is a claim, not an absence.
    #
    # Timeout kills the child process; a container it started keeps running, which is
    # the compose file's business (`--rm` and a per-run project name) rather than
    # something to reimplement here.
    class DriverTransport
      def initialize(command:, timeout: 300, reports_tool_calls: true, env: {})
        raise ArgumentError, "command must be an argv array" unless command.is_a?(Array) && !command.empty?

        @command = command.map(&:to_s)
        @timeout = timeout
        @reports_tool_calls = reports_tool_calls
        @env = env.transform_keys(&:to_s).transform_values(&:to_s)
      end

      def reports_tool_calls? = @reports_tool_calls

      def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def turn(agent:, conv:, message:)
        t0 = mono
        out, err, status = run_driver(JSON.generate(agent: agent, conv: conv, message: message))
        return failure(err, t0) if status.nil? || !status.success?

        answer = last_json_object(out)
        return failure("driver wrote no JSON object#{" (stderr: #{tail(err)})" if err}", t0) if answer.nil?

        TurnOutcome.new(
          result: TurnResult.new(output_text: answer["output_text"].to_s,
                                 tool_calls: normalize_tool_calls(answer["tool_calls"]),
                                 ui: [], error: presence(answer["error"])),
          ttfb: nil, total: (mono - t0) * 1000.0, usage: answer["usage"]
        )
      rescue StandardError => e
        failure("#{e.class}: #{e.message}", t0)
      end

      private

      # -> [stdout, stderr-or-reason, status]. status nil = it never finished.
      def run_driver(input)
        Open3.popen3(@env, *@command) do |stdin, stdout, stderr, wait_thr|
          stdin.write(input)
          stdin.close
          out = +""
          err = +""
          readers = [Thread.new { out << stdout.read }, Thread.new { err << stderr.read }]

          if wait_thr.join(@timeout).nil?
            kill(wait_thr.pid)
            readers.each(&:kill)
            return [out, "driver timed out after #{@timeout}s", nil]
          end

          readers.each(&:join)
          status = wait_thr.value
          [out, status.success? ? err : "exit #{status.exitstatus}#{" — #{tail(err)}" if presence(err)}", status]
        end
      end

      def kill(pid)
        Process.kill("KILL", pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      # The driver's answer is the LAST JSON object it printed: an adapter that logs
      # to stdout is the normal case, and refusing to read past its chatter would
      # turn every such harness into an entry-gate failure it does not deserve.
      def last_json_object(out)
        out.to_s.each_line.reverse_each do |line|
          parsed = begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          return parsed if parsed.is_a?(Hash)
        end
        nil
      end

      # Adapters report tool calls in whichever shape their harness has: a bare name,
      # or an object. Both become the shape the graders read.
      def normalize_tool_calls(raw)
        Array(raw).filter_map do |call|
          case call
          when String then { "name" => call, "status" => nil }
          when Hash
            name = (call["name"] || call[:name]).to_s
            next if name.empty?

            entry = { "name" => name, "status" => presence(call["status"]) }
            (args = call["arguments"]) && (entry["arguments"] = args)
            (gate = presence(call["gate"])) && (entry["gate"] = gate)
            entry
          end
        end
      end

      def presence(value)
        s = value.to_s.strip
        s.empty? ? nil : s
      end

      def tail(text) = text.to_s.strip.lines.last(3).join.strip

      def failure(msg, t0)
        TurnOutcome.new(result: TurnResult.new(output_text: "", tool_calls: [], ui: [], error: msg.to_s),
                        ttfb: nil, total: (mono - t0) * 1000.0, usage: nil)
      end
    end

    # WHAT THE STORE HOLDS, for the `store_state:` graders. The bench dumps the
    # store to one JSON file ({ collection => [rows] }) after the turn and points
    # the runner at it; the file is re-read on every call, so the same reader serves
    # a whole run as the dump is rewritten between tasks.
    #
    # Deliberately a file and not an MCP client: the harnesses under test reach the
    # store over MCP and nothing else, but the GRADER is not a harness — reading the
    # dumped truth is stricter than asking the same surface the agent could have
    # confused, and it costs no per-store tool mapping.
    class JsonStoreReader
      def initialize(path)
        @path = path
      end

      def read(collection)
        snapshot = JSON.parse(File.read(@path))
        raise Insika::Error, "#{@path}: expected a mapping of collection -> rows" unless snapshot.is_a?(Hash)

        Array(snapshot[collection.to_s])
      rescue Errno::ENOENT
        raise Insika::Error, "#{@path}: no store snapshot on disk"
      rescue JSON::ParserError => e
        raise Insika::Error, "#{@path}: #{e.message}"
      end
    end

    # The store, asked for its own state by running a command — `docker compose exec
    # store dump-state`, or whatever a given store answers with. Preferred over the
    # file reader for a benched harness: the dump then happens AFTER the turn, outside
    # the window the runner is timing, so the store's own latency never lands in the
    # harness's column.
    #
    # The dump is read ONCE per case and cached, because a case asks for several
    # collections and dumping twice would report two different stores. `forget` is how
    # the Runner opens a new case; a reader nobody resets would grade every case
    # against the first one.
    class CommandStoreReader
      def initialize(command:, timeout: 60)
        raise ArgumentError, "command must be an argv array" unless command.is_a?(Array) && !command.empty?

        @command = command.map(&:to_s)
        @timeout = timeout
        @snapshot = nil
      end

      def forget = @snapshot = nil

      def read(collection)
        @snapshot ||= dump
        Array(@snapshot[collection.to_s])
      end

      private

      def dump
        out, err, status = Open3.capture3(*@command)
        raise Insika::Error, "store dump exited #{status.exitstatus}: #{err.to_s.strip.lines.last}" unless status.success?

        parsed = JSON.parse(out)
        raise Insika::Error, "store dump is not a mapping of collection -> rows" unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError => e
        raise Insika::Error, "store dump is not JSON: #{e.message}"
      rescue SystemCallError => e
        raise Insika::Error, "store dump could not run: #{e.message}"
      end
    end

    # Thin A2A transport: drives a REMOTE A2A agent (an agent that only speaks
    # A2A) through the same `turn` seam the Simulator uses. The outbound A2A
    # client already does the send+poll; this is the wrapper that makes it a
    # Transport. `client` answers `#call(url, text, context_id:)` -> {text:} or
    # {error:} — the `Server::A2A::Client` shape.
    class A2ATransport
      def initialize(client:, url:)
        @client = client
        @url = url
      end

      def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def turn(agent:, conv:, message:)
        t0 = mono
        result = @client.call(@url, message.to_s, context_id: conv)
        if result[:error]
          TurnOutcome.new(
            result: TurnResult.new(output_text: "", tool_calls: [], error: result[:error].to_s),
            ttfb: nil, total: (mono - t0) * 1000.0, usage: nil
          )
        else
          TurnOutcome.new(
            result: TurnResult.new(output_text: result[:text].to_s, tool_calls: [], error: nil),
            ttfb: nil, total: (mono - t0) * 1000.0, usage: nil
          )
        end
      end
    end
  end
end
