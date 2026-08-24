# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # The recovery path (extraction is best-effort — a crash between a turn's
    # terminal and the write loses that turn's concepts, not the conversation
    # nor a previously learned one). Replays one agent's stored sessions
    # through the SAME `Knowledge::Extractor` the per-turn hook uses.
    #
    # Synchronous — the CLI's own path (`insika knowledge:backfill`), same
    # "no app boot" discipline as RunHarvest/RunDistillation: no task, no
    # turn, nothing written but the concepts themselves.
    class BackfillKnowledge
      DEFAULT_MIN_MESSAGES = 2

      def initialize(profiles:, knowledge_store:, session_store:, task_store:,
                     settings_store: nil, event_stream:, extractor_factory: nil, consolidator_factory: nil)
        @profiles = ProfileSource.coerce(profiles)
        @knowledge_store = knowledge_store
        @session_store = session_store
        @task_store = task_store
        @settings_store = settings_store
        @extractor_factory = extractor_factory ||
                             ->(config) { Knowledge::ExtractorFactory.build(config, utility_model: utility_model) }
        @consolidator_factory = consolidator_factory ||
                                ->(config) { Knowledge::ConsolidatorFactory.build(config, utility_model: utility_model) }
        @event_stream = event_stream
      end

      # payload: { agent:, since?: ISO8601 }
      # -> { backfilled: true, sessions: N, concepts: N, conflicts: N, dropped: {...} }
      #  | { backfilled: false, skipped: "disabled|no_model|no_sessions" }
      def call(command)
        p = AgentPayload.symbolize(command.payload)
        agent = AgentPayload.presence(p[:agent])
        raise Insika::ValidationError, "agent is required" if agent.nil?

        profile = @profiles[agent] || (raise Insika::NotFoundError, "agent '#{agent}' not configured")
        config = Coercion.deep_stringify(profile.knowledge)
        return skip("disabled") if config.nil? || !Coercion.truthy?(config["extract"])

        extractor = @extractor_factory.call(config)
        return skip("no_model") if extractor.nil?

        # Same resolved model as the extractor. nil (unresolvable) is still
        # meaningful: Knowledge.write_concept's conservative default.
        consolidator = @consolidator_factory.call(config)

        sessions = resolve_sessions(agent, p)
        return skip("no_sessions") if sessions.empty?

        concepts = 0
        conflicts = 0
        dropped = Hash.new(0)
        sessions.each do |s|
          result = extractor.extract(prompt: build_prompt(config, s[:messages]))
          result[:concepts].each do |c|
            case write_concept(profile, s[:id], c, consolidator)[:verdict]
            when :new, :related then concepts += 1
            when :contradicting then conflicts += 1
            end
          end
          result[:dropped].each { |k, v| dropped[k] += v }
        end

        emit(:knowledge_backfilled, agent: agent, sessions: sessions.size, concepts: concepts,
                                    conflicts: conflicts, dropped: dropped.to_h)
        { backfilled: true, sessions: sessions.size, concepts: concepts, conflicts: conflicts, dropped: dropped.to_h }
      end

      private

      def skip(reason) = { backfilled: false, skipped: reason }

      # Every task of the agent, distinct session ids, newest first — the
      # same reading `RunHarvest#window_session_ids` uses, without the
      # last-N cap (a backfill is meant to be exhaustive over `--since`).
      def resolve_sessions(agent, p)
        since = AgentPayload.presence(p[:since])
        tasks = @task_store.each_id.filter_map { |id| @task_store.find(id) }
                           .select { |t| task_agent(t) == agent }
                           .sort_by { |t| [t.created_at.to_s, t.id] }.reverse
        tasks = tasks.select { |t| t.created_at.to_s >= since.to_s } if since

        seen = {}
        tasks.filter_map do |t|
          sid = Coercion.presence(t.session_id)
          next if sid.nil? || seen[sid]

          seen[sid] = true
          session = @session_store.find(sid)
          next unless session && session.messages.size >= DEFAULT_MIN_MESSAGES

          { id: sid.to_s, messages: session.messages }
        end
      end

      def task_agent(task)
        task.command.is_a?(Hash) ? task.command.dig("payload", "agent").to_s : ""
      end

      def build_prompt(config, messages)
        base = Coercion.presence(config["prompt"]) || Knowledge::DEFAULT_PROMPT
        <<~PROMPT
          #{base.rstrip}

          ## The conversation

          #{render_transcript(messages)}
        PROMPT
      end

      def render_transcript(messages)
        redacted, = Insika::Safety::Detectors.redact(
          messages.each_with_index.map { |m, i| "[#{i}] #{m['role']}: #{m['content']}" }.join("\n")
        )
        redacted
      end

      def write_concept(profile, session_id, concept, consolidator)
        outcome = Knowledge.write_concept(store: @knowledge_store, agent_id: profile.id, concept: concept,
                                          session_id: session_id, consolidator: consolidator)
        case outcome[:verdict]
        when :new, :related
          emit(:knowledge_learned, name: outcome[:name], type: outcome[:type], agent: profile.id)
        when :contradicting
          emit(:knowledge_conflict, name: outcome[:name], agent: profile.id)
        end
        outcome
      end

      def utility_model
        return nil unless @settings_store

        @settings_store.get["utility_model"]
      end

      def emit(type, **data)
        @event_stream.emit(Insika::Event.new(type: type, data: data, meta: { at: Time.now.utc.iso8601 }))
      end
    end
  end
end
