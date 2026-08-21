# frozen_string_literal: true

module Insika
  module DSL
    # The result of `Insika.agent("id") { … }`. Holds the generated Pack and knows
    # how to run it — but stays gem-free until you actually chat/serve/introspect:
    # the runtime (ruby_llm + the HTTP server) is required lazily inside Runtime.
    #
    # Every runtime path goes through the SAME config-over-code import: the pack is
    # imported (create_agent + write_agent_file/skill/data_tool) into a StoredProfileSource,
    # exactly like any other pack. That is what makes `#profile` identical to a
    # hand-written equivalent pack (the parity spec) — there is only one path.
    class Definition
      attr_reader :pack, :runtime_options, :mcp_instances

      def initialize(pack:, runtime: {}, mcp_instances: [])
        @pack = pack
        @runtime_options = runtime
        @mcp_instances = mcp_instances
      end

      def id = pack.config[:id].to_s

      # The generated portable artifact — hand it to any PackImporter and you get
      # this same agent. This is the DSL's real output.
      def to_pack = @pack

      # The AgentProfile the engine runs, read back from the store after import —
      # so it is byte-for-byte what a hand-written equivalent pack produces.
      def profile = runtime.profile

      # One turn, in-process, returns the assistant's text. `session:` threads
      # multi-turn memory (a session is created on first use); omit it for a
      # stateless one-shot. Raises on a failed/cancelled turn.
      def reply(message, session: nil, timeout: nil)
        runtime.chat(message, session_id: session, timeout: timeout)
      end
      alias_method :chat, :reply

      # Boot the control UI (/studio) + the drop-in API (/v1) — the "1 command"
      # of the quickstart. Blocks (runs the reactor) until interrupted.
      def serve(port: 9292, host: "localhost", token: nil, **opts)
        runtime.serve(port: port, host: host, token: token, **opts)
      end

      # The live runtime graph (Executor + bus + stores) with the pack imported.
      # Memoized: chat/serve/profile share one graph. Pulls in ruby_llm here.
      def runtime
        @runtime ||= begin
          require_relative "runtime"
          Runtime.new(self)
        end
      end
    end
  end
end
