# frozen_string_literal: true

module Insika
  module DSL
    # The result of `Insika.system { … }`: N agents sharing ONE runtime graph.
    #
    # It is the multi-agent counterpart of Definition, and deliberately the same
    # shape — `reply` for a turn, `serve` for the server, `to_packs` for the data.
    # Nothing here is a new engine path: every agent is still an ordinary Pack
    # imported by the standard PackImporter, so a system of three agents is
    # indistinguishable from three hand-written packs provisioned into the same
    # deployment.
    #
    # Why it exists: delegation (`subagents`), fan-out/fan-in and routing all
    # require the child agents to be resolvable in the SAME ProfileSource. A
    # Definition owns exactly one pack, so those patterns had no home in the DSL.
    class System
      attr_reader :definitions, :runtime_options

      def initialize(definitions:, runtime: {})
        @definitions = definitions.freeze
        # Agent-level runtime knobs merged in declaration order, then the
        # system-level ones on top (an explicit `provider`/`api_key` in the
        # system block is the shared default and wins the tie).
        @runtime_options = definitions.map(&:runtime_options)
                                      .reduce({}) { |acc, opts| acc.merge(opts) }
                                      .merge(runtime)
                                      .freeze
      end

      def ids = definitions.map(&:id)

      # The primary agent: the first declared. Only used where a single id is
      # structurally required (the default model seed, the banner) — never to
      # guess the target of a turn, which is always explicit.
      def id = definitions.first.id

      # The portable artifacts — one Pack per agent. Hand them to any
      # PackImporter and you get this same system.
      def to_packs = definitions.map(&:to_pack)
      def packs = to_packs

      # Runtime reads it for the provider/default-model seed.
      def pack = definitions.first.to_pack

      def find(agent_id)
        definitions.find { |d| d.id == agent_id.to_s } ||
          (raise Insika::NotFoundError, "agent '#{agent_id}' is not in this system (have: #{ids.join(', ')})")
      end

      # The AgentProfile the engine runs for one agent, read back from the store.
      def profile(agent_id) = runtime.profile(find(agent_id).id)

      # One turn against ONE agent of the system, in-process. The agent is always
      # explicit: with several agents in the graph, inferring the target would be
      # a guess, and a wrong guess is a silently wrong conversation.
      def reply(agent_id, message, session: nil, timeout: nil)
        runtime.chat(message, agent: find(agent_id).id, session_id: session, timeout: timeout)
      end
      alias_method :chat, :reply

      # Boot the control UI (/studio) + the drop-in API (/v1) with EVERY agent of
      # the system served — each agent's id is a `model` on /v1/responses.
      def serve(port: 9292, host: "localhost", token: nil, **opts)
        runtime.serve(port: port, host: host, token: token, **opts)
      end

      # The live runtime graph with every pack imported. Memoized.
      def runtime
        @runtime ||= begin
          require_relative "runtime"
          Runtime.new(self)
        end
      end
    end
  end
end
