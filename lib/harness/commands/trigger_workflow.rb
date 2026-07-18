# frozen_string_literal: true

module Harness
  module Commands
    # Turn command: fires a workflow. Reuses the canonical
    # pipeline — only stage 6 varies (Executor). Validates everything
    # synchronously and responds `{task_id:}` immediately. The workflow allowlist is NOT
    # checked here: it is stage-3 enforcement via WorkflowAllowlist
    # -> PolicyDenied -> task :failed.
    class TriggerWorkflow
      ALLOWED_KEYS = %i[workflow agent input session_id].freeze

      def initialize(profiles:, session_store:, task_store:, executor:, workflow_registry:)
        @profiles = ProfileSource.coerce(profiles)
        @session_store = session_store
        @task_store = task_store
        @executor = executor
        @workflow_registry = workflow_registry
      end

      def call(command)
        p = normalize(command.payload)
        reject_unknown_keys!(command.payload) # strict validation

        workflow = p[:workflow].to_s
        raise Harness::ValidationError, "workflow is required" if workflow.empty?

        agent = p[:agent].to_s
        raise Harness::ValidationError, "agent is required" if agent.empty?

        profile = @profiles[agent] ||
                  (raise Harness::NotFoundError, "agent '#{agent}' not configured")

        input = p[:input] || {}
        raise Harness::ValidationError, "input must be a Hash" unless input.is_a?(Hash)

        if p[:session_id]
          @session_store.find(p[:session_id]) ||
            (raise Harness::NotFoundError, "session '#{p[:session_id]}' not found")
        end

        # existence is validatable without executing — names, NEVER resolve (don't instantiate
        # outside the fiber).
        unless @workflow_registry.names.include?(workflow)
          raise Harness::NotFoundError, "workflow '#{workflow}' not registered"
        end

        task = @task_store.create(command: command.to_h, session_id: p[:session_id])
        @executor.spawn_in_session(task, profile: profile)
        { task_id: task.id }
      end

      private

      def normalize(payload)
        {
          workflow: payload[:workflow] || payload["workflow"],
          agent: payload[:agent] || payload["agent"],
          input: payload[:input] || payload["input"],
          session_id: payload[:session_id] || payload["session_id"]
        }
      end

      def reject_unknown_keys!(payload)
        extra = payload.keys.map(&:to_sym) - ALLOWED_KEYS
        raise Harness::ValidationError, "unknown keys in payload: #{extra.join(', ')}" unless extra.empty?
      end
    end
  end
end
