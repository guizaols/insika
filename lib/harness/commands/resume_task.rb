# frozen_string_literal: true

module Harness
  module Commands
    # Turn command: resumes a task from the latest checkpoint. Crash-recovery
    # and manual resume both use THIS same path (Recovery only discovers and dispatches).
    # Re-executes the entire checkpointed turn; non-idempotent tools that already
    # completed are skipped via the side-effect registry.
    class ResumeTask
      def initialize(profiles:, task_store:, checkpoint_store:, executor:)
        @profiles = ProfileSource.coerce(profiles)
        @task_store = task_store
        @checkpoint_store = checkpoint_store
        @executor = executor
      end

      def call(command)
        task_id = (command.payload[:task_id] || command.payload["task_id"]).to_s
        raise Harness::ValidationError, "task_id is required" if task_id.empty?

        task = @task_store.find(task_id) ||
               (raise Harness::NotFoundError, "task '#{task_id}' não encontrada")

        # IN-PROCESS RESUME: a :paused task whose fiber is STILL alive (blocked
        # on await) — do NOT re-dispatch (spawn would duplicate the fiber). Just post :resume;
        # the fiber transitions paused->running and continues. (A live :waiting is resolved
        # by ApproveAction, not here.)
        if task.status == :paused && @executor.running?(task_id)
          @executor.resume_live(task_id)
          return { task_id: task_id }
        end

        # :queued: a turn that was in the SessionActor queue and never
        # started at crash time (no checkpoint) — recovering = RUN from scratch, from the
        # original Command. Profile comes from the agent in the Command itself.
        if task.status == :queued
          @executor.spawn_in_session(task, profile: profile_for(task), resume_from: nil)
          return { task_id: task_id }
        end

        # RE-DISPATCH (crash-resume): no live fiber, re-executes from the checkpoint.
        # resume requires a checkpoint; without one the task is unrecoverable (Recovery
        # would already have marked it :failed during the sweep).
        checkpoint = @checkpoint_store.latest(task_id) ||
                     (raise Harness::ValidationError,
                            "task '#{task_id}' não tem checkpoint — irrecuperável")

        check_eligibility!(task)

        # profile comes from the checkpoint (agent_id): the agent may have been removed from
        # the config between the crash and boot -> fail loudly and clearly.
        profile = @profiles[checkpoint.agent_id] ||
                  (raise Harness::NotFoundError, "agent '#{checkpoint.agent_id}' not configured")

        @executor.spawn_in_session(task, profile: profile, resume_from: checkpoint)
        { task_id: task_id }
      end

      private

      # Profile for re-running a :queued task: from the agent in the persisted Command
      # (there is no checkpoint). NotFoundError if the agent left the config.
      def profile_for(task)
        payload = task.command["payload"] || task.command[:payload] || {}
        agent = (payload["agent"] || payload[:agent]).to_s
        @profiles[agent] || (raise Harness::NotFoundError, "agent '#{agent}' not configured")
      end

      # Eligibility matrix: paused/waiting always; running only when
      # orphaned (no live fiber IN THIS process — single-node); :queued is handled
      # earlier (re-run); terminal states are not resumable.
      def check_eligibility!(task)
        case task.status
        when :paused, :waiting
          nil
        when :running
          raise Harness::ValidationError, "task '#{task.id}' em execução" if @executor.running?(task.id)
        else # terminal states (:completed, :failed, :cancelled)
          raise Harness::ValidationError,
                "task '#{task.id}' with status '#{task.status}' is not resumable"
        end
      end
    end
  end
end
