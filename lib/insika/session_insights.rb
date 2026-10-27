# frozen_string_literal: true

require "time"

module Insika
  # READ-ONLY ANSWERS ABOUT REAL CONVERSATIONS — what an operator asks before trusting
  # an agent: how much traffic each agent really had, what a session said, and which
  # guardrail flags fired and why. Served over MCP (Server::Mcp) so an analysis is a
  # tool call instead of an ssh session and hand-written SQL.
  #
  # "Real" is decided here, once:
  # · a session WITH TURNS has at least one task. An imported transcript has messages
  #   but no task — it never ran through the engine, so it says nothing about it;
  # · simulator/eval sessions (SessionStore.synthetic?) are left out unless asked for.
  #
  # ponytail: every call reads all session stats and all tasks (one bulk read each).
  # Fine for thousands of sessions on one SQLite file; add per-agent indexes when a
  # call gets slow.
  class SessionInsights
    SNIPPET = 400

    def initialize(session_store:, task_store:)
      @sessions = session_store
      @tasks = task_store
    end

    # -> [Hash] one row per agent: sessions, sessions_with_turns, turns by status,
    # flagged sessions, first/last turn. `since`: ISO-8601, counts turns created after.
    def agent_summary(since: nil, include_synthetic: false)
      turns = turns_by_session(since)
      stats(include_synthetic).group_by { |s| s.vars["agent"].to_s }.map do |agent, rows|
        mine = rows.flat_map { |s| turns.fetch(s.id, []) }
        times = mine.map(&:created_at).compact.sort
        { "agent" => agent.empty? ? nil : agent,
          "sessions" => rows.size,
          "sessions_with_turns" => rows.count { |s| turns.key?(s.id) },
          "turns" => mine.size,
          "turns_by_status" => mine.map { |t| t.status.to_s }.tally,
          "flagged_sessions" => rows.count { |s| s.flagged.positive? },
          "first_turn" => times.first, "last_turn" => times.last }
      end.sort_by { |row| -row["turns"] }
    end

    # -> [Hash] newest first. `with_turns`: true (default) = only sessions the engine
    # ran; false = only the ones it never ran (imported); nil = both. `since` limits
    # which turns count, so with `with_turns: true` it means "had a turn since".
    def list_sessions(agent: nil, since: nil, with_turns: true, flagged: false,
                      include_synthetic: false, limit: 50)
      turns = turns_by_session(since)
      rows = stats(include_synthetic).select do |s|
        (agent.nil? || s.vars["agent"] == agent) &&
          (with_turns.nil? || turns.key?(s.id) == with_turns) &&
          (!flagged || s.flagged.positive? || s.reported.positive?)
      end
      rows.sort_by { |s| s.updated_at.to_s }.reverse.first(limit).map do |s|
        { "session_id" => s.id, "agent" => s.vars["agent"], "customer" => s.vars["customer"],
          "customer_name" => s.vars["customer_name"], "updated_at" => s.updated_at,
          "messages" => s.message_count, "turns" => turns.fetch(s.id, []).size,
          "last_role" => s.last_role, "flagged" => s.flagged, "reported" => s.reported }
      end
    end

    # -> Hash | nil: the transcript, each message with role, origin and its flags.
    def transcript(session_id, max_chars: 4000)
      session = @sessions.find(session_id) or return nil

      { "session_id" => session.id, "vars" => session.vars,
        "created_at" => session.created_at, "updated_at" => session.updated_at,
        "turns" => turns_by_session(nil).fetch(session.id, []).size,
        "messages" => Array(session.messages).each_with_index.map do |m, i|
          { "index" => i, "role" => m["role"], "origin" => m["origin"],
            "content" => text_of(m)[0, max_chars], "guardrail_flags" => m["guardrail_flags"] }.compact
        end }
    end

    # -> [Hash] one row per guardrail flag: where it fired, what it said, the message
    # it judged and the reply that came next — enough to tell a true positive from a
    # false one without opening the session. Resolved flags only when asked.
    def list_flags(agent: nil, category: nil, include_resolved: false, include_synthetic: false, limit: 100)
      ids = stats(include_synthetic).select do |s|
        (agent.nil? || s.vars["agent"] == agent) &&
          (include_resolved || s.flagged.positive? || s.reported.positive?)
      end.map(&:id)

      ids.flat_map { |id| flags_of(@sessions.find(id), category, include_resolved) }
         .sort_by { |row| row["updated_at"].to_s }.reverse.first(limit)
    end

    private

    def stats(include_synthetic)
      all = @sessions.all_stats
      include_synthetic ? all : all.reject { |s| SessionStore.synthetic?(s.id) }
    end

    def turns_by_session(since)
      tasks = @tasks.all.select(&:session_id)
      tasks = tasks.select { |t| t.created_at.to_s >= since } if since
      tasks.group_by(&:session_id)
    end

    def flags_of(session, category, include_resolved)
      return [] if session.nil?

      messages = Array(session.messages)
      messages.each_with_index.flat_map do |m, i|
        Array(m["guardrail_flags"]).filter_map do |f|
          next unless include_resolved || SessionStore.open_flag?(f)
          next if category && f["category"].to_s != category

          { "session_id" => session.id, "agent" => session.vars["agent"], "updated_at" => session.updated_at,
            "message_index" => i, "role" => m["role"], "category" => f["category"], "source" => f["source"],
            "action" => f["action"], "detail" => f["detail"], "review" => f["review"],
            "message" => text_of(m)[0, SNIPPET], "reply" => text_of(messages[i + 1])[0, SNIPPET] }.compact
        end
      end
    end

    # A message's text: a plain string, or the text parts of a multi-part content.
    def text_of(message)
      return "" unless message.is_a?(Hash)

      content = message["content"]
      return content.to_s unless content.is_a?(Array)

      content.filter_map { |part| part.is_a?(Hash) ? part["text"] : part.to_s }.join("\n")
    end
  end
end
