# frozen_string_literal: true

module Harness
  module Commands
    # Command de TURNO (D3): retoma uma task do último checkpoint. Crash-recovery
    # e resume manual usam ESTE mesmo caminho (o Recovery só descobre e despacha,
    # task 8). Reexecuta o turno checkpointado inteiro; tools não-idempotentes já
    # concluídas são puladas via side-effect registry (doc 02 L5, doc 03 §4.1).
    class ResumeTask
      def initialize(profiles:, task_store:, checkpoint_store:, executor:)
        @profiles = profiles
        @task_store = task_store
        @checkpoint_store = checkpoint_store
        @executor = executor
      end

      def call(command)
        task_id = (command.payload[:task_id] || command.payload["task_id"]).to_s
        raise Harness::ValidationError, "task_id é obrigatório" if task_id.empty?

        task = @task_store.find(task_id) ||
               (raise Harness::NotFoundError, "task '#{task_id}' não encontrada")

        # RESUME IN-PROCESS (P2 task 4): task :paused cujo fiber AINDA vive (blocked
        # em await) — NÃO re-despachar (spawn duplicaria o fiber). Só posta :resume;
        # o fiber transita paused->running e segue. (Um :waiting vivo é resolvido
        # pelo ApproveAction, não aqui — Etapa B.)
        if task.status == :paused && @executor.running?(task_id)
          @executor.resume_live(task_id)
          return { task_id: task_id }
        end

        # :queued (P2-03): turno que estava na fila do SessionActor e nunca
        # iniciou no crash (sem checkpoint) — recuperar = RODAR do zero, do
        # Command original. Perfil vem do agente do próprio Command.
        if task.status == :queued
          @executor.spawn_in_session(task, profile: profile_for(task), resume_from: nil)
          return { task_id: task_id }
        end

        # RE-DISPATCH (crash-resume): sem fiber vivo, reexecuta do checkpoint.
        # resume exige checkpoint (doc 03 §3); sem ele a task é irrecuperável (o
        # Recovery já a teria marcado :failed na varredura — doc 02 §4).
        checkpoint = @checkpoint_store.latest(task_id) ||
                     (raise Harness::ValidationError,
                            "task '#{task_id}' não tem checkpoint — irrecuperável")

        check_eligibility!(task)

        # perfil vem do checkpoint (agent_id): o agente pode ter saído da config
        # entre o crash e o boot -> falha alta e clara.
        profile = @profiles[checkpoint.agent_id] ||
                  (raise Harness::NotFoundError, "agente '#{checkpoint.agent_id}' não configurado")

        @executor.spawn_in_session(task, profile: profile, resume_from: checkpoint)
        { task_id: task_id }
      end

      private

      # Perfil para re-rodar uma task :queued: do agente no Command persistido
      # (não há checkpoint). NotFoundError se o agente saiu da config.
      def profile_for(task)
        payload = task.command["payload"] || task.command[:payload] || {}
        agent = (payload["agent"] || payload[:agent]).to_s
        @profiles[agent] || (raise Harness::NotFoundError, "agente '#{agent}' não configurado")
      end

      # Matriz de elegibilidade (doc 03 §3): paused/waiting sempre; running só
      # órfã (sem fiber vivo NESTE processo — D7, single-node); :queued é tratado
      # antes (re-run); terminais não são retomáveis.
      def check_eligibility!(task)
        case task.status
        when :paused, :waiting
          nil
        when :running
          raise Harness::ValidationError, "task '#{task.id}' em execução" if @executor.running?(task.id)
        else # terminais (:completed, :failed, :cancelled)
          raise Harness::ValidationError,
                "task '#{task.id}' com status '#{task.status}' não é retomável"
        end
      end
    end
  end
end
