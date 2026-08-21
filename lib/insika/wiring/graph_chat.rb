# frozen_string_literal: true

module Insika
  module Wiring
    # A synchronous, in-process "chat" seam over an assembled `Graph::Result`:
    # dispatch a Command, drain the event stream to its terminal event, hand
    # back the outcome. Extracted from `DSL::Runtime#chat`/`#run_workflow`
    # (C3.1) so a graph built OUTSIDE the DSL — `config/deployment.rb`, the
    # actual production/round1 composition root `config.ru` boots — can hand a
    # `#chat`-capable object to anything that needs one (today:
    # `run_persona_eval`'s `Evals::GraphTransport` seam), without a second copy
    # of this dispatch+drain plumbing. `DSL::Runtime` now delegates here too —
    # one implementation, exercised by both roots.
    class GraphChat
      TERMINAL = %i[task_completed task_failed task_cancelled].freeze

      def initialize(graph:)
        @graph = graph
      end

      # One turn, in-process -> the assistant's text. `agent:` is REQUIRED —
      # this seam has no notion of "the default agent" (that is a DSL::Runtime
      # concept, filled in by its own caller before delegating here). Raises
      # Insika::Error on a failed/cancelled turn, or the command's own
      # rejection (unknown agent, bad schema) verbatim.
      def chat(message, agent:, session_id: nil, timeout: nil)
        command = Insika::Command.build(
          :send_message, { agent: agent.to_s, message: message, session_id: session_id },
          transport: :cli
        )
        run_command(command, session_id: session_id, timeout: timeout)[:text]
      end

      # Dispatch + drain, generic over any Command — the seam a workflow run
      # also needs (a :trigger_workflow Command carries :output, not :text).
      # Subscribes BEFORE dispatching (the fiber may emit eagerly) and binds to
      # the dispatched task. A synchronous handler error (unknown agent/
      # workflow, bad input against the schema) propagates untouched — the
      # caller sees the real ValidationError/NotFoundError, not a turn failure.
      def run_command(command, session_id:, timeout:)
        require "async"
        outcome = {}
        rejected = nil
        Async do |task|
          serving = !session_id.nil?
          @graph.executor.supervised = true if serving
          ensure_session(session_id) if session_id
          sub = @graph.event_stream.subscribe
          res = begin
            @graph.bus.dispatch(command)
          rescue StandardError => e
            # CAPTURED, not re-raised inside the reactor: letting it escape the
            # Async block logs "Task may have ended with unhandled exception" —
            # alarming noise for a DOCUMENTED rejection (a schema violation, an
            # unknown agent). Re-raised verbatim below, outside the reactor.
            sub.close
            rejected = e
            next
          end
          sub.bind(task_id: res[:task_id])
          drain(sub, outcome, task, timeout)
          teardown_serving if serving
        end.wait
        raise rejected if rejected
        raise Insika::Error, "turn #{outcome[:error]}" if outcome[:error]

        outcome
      end

      private

      # Reads the stream until this turn reaches a terminal event, then stops.
      # A workflow run also carries its typed OUTPUT, which is not the turn text.
      def drain(sub, outcome, task, timeout)
        reader = task.async do
          sub.each do |ev|
            case ev.type
            when :task_completed      then outcome[:text] = ev.data[:content].to_s
            when :workflow_completed  then outcome[:output] = ev.data[:output]
            when :task_failed         then outcome[:error] = "failed: #{ev.data[:message] || ev.data[:error]}"
            when :task_cancelled      then outcome[:error] = "cancelled"
            end
            sub.close if TERMINAL.include?(ev.type)
          end
        end
        timeout ? task.with_timeout(timeout) { reader.wait } : reader.wait
      rescue Async::TimeoutError
        outcome[:error] = "timed out after #{timeout}s"
        sub.close
      end

      def ensure_session(session_id)
        @graph.session_store.find(session_id) || @graph.session_store.create(id: session_id, vars: {})
      end

      def teardown_serving
        @graph.executor.stop_session_actors
        @graph.executor.instance_variable_get(:@supervisor)&.stop
      end
    end
  end
end
