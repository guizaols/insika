# frozen_string_literal: true

module Insika
  module DSL
    # Adapts a DSL `workflow "name" do |input, ctx| … end` block to the engine's
    # canonical workflow callable, `#call(input, context:, tools:)`.
    #
    # The engine contract is unchanged — this only decides what the AUTHOR holds.
    # A workflow's job is orchestrating agent turns, so the second argument is a
    # small context whose main verb is `ask`; the raw `context`/`tools` the
    # Executor passes stay reachable for the rare workflow that wants them.
    class WorkflowAdapter
      def initialize(block:, runtime:)
        @block = block
        @runtime = runtime
      end

      def call(input, context:, tools:)
        ctx = Context.new(runtime: @runtime, context: context, tools: tools)
        @block.arity == 1 ? @block.call(input) : @block.call(input, ctx)
      end

      # What a workflow block receives. Deliberately tiny: the value of a workflow
      # is deterministic Ruby AROUND model calls, not a framework.
      class Context
        # `context` is the turn's ContextPackage; `tools` are the resolved,
        # enveloped tool instances (already filtered by the agent's policy).
        attr_reader :context, :tools

        def initialize(runtime:, context:, tools:)
          @runtime = runtime
          @context = context
          @tools = tools
        end

        # One turn against one agent of the system → its text.
        #
        # Stateless by design (no session): a workflow step is a unit of work, not
        # a conversation, and threading a session here would also drag in the
        # serving teardown path. Each step is its own Task, so every step of a
        # workflow is separately visible in the Studio and the trace.
        def ask(agent, message, timeout: nil)
          @runtime.chat(message.to_s, agent: agent.to_s, timeout: timeout)
        end

        # Runs blocks CONCURRENTLY on the turn's reactor and returns their values
        # IN ORDER — the fan-out/fan-in step. Thin pass-through to the engine's
        # own helper so a workflow does not hand-roll Async.
        #
        #   sec, perf = ctx.gather(-> { ctx.ask("security", code) },
        #                          -> { ctx.ask("performance", code) })
        def gather(*blocks, max: 8)
          require_relative "../tools/concurrency"
          Insika::Tools::Concurrency.gather(*blocks, max: max)
        end
      end
    end
  end
end
