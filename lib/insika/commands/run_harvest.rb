# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # the ONLY path that writes candidates. Mines ONE window end
    # to end: resolve the sessions, read the transcripts + evidence, ask the
    # miner, schema-drop, apply the negative list and the grounding filter,
    # dedup against the ledger, write the run + candidates, stamp the markers.
    #
    # Synchronous (it runs on the engine's worker fiber, C12, or the CLI, C15)
    # — it creates no task and no turn. It writes NOTHING to sessions or
    # skills: D2's fork discipline is this command's contract — a customer
    # turn's prefix is untouched by construction, and the only harvest-side
    # spend is the run's cost (E1).
    #
    # Payload: { agent:, last_sessions?, since?, full?, session_ids?,
    #            max_proposals?, exclude_sessions? }
    class RunHarvest
      DEFAULT_LAST_SESSIONS = 200 # the EvidenceCollector's window default
      DEFAULT_MIN_MESSAGES = 3
      DEFAULT_MAX_PROPOSALS = 10
      DEFAULT_IDLE_HOURS = 24

      def initialize(profiles:, harvest_store:, session_store:, task_store:,
                     skill_store: nil, tool_trace_store: nil, settings_store: nil,
                     negative_list: nil, miner_factory: nil, event_stream:)
        @profiles = ProfileSource.coerce(profiles)
        @harvest_store = harvest_store
        @session_store = session_store
        @task_store = task_store
        @skill_store = skill_store
        @tool_trace_store = tool_trace_store
        @settings_store = settings_store
        @negative_list = negative_list
        @miner_factory = miner_factory ||
                         ->(config) { Harvest::MinerFactory.build(config, utility_model: utility_model) }
        @event_stream = event_stream
      end

      # -> { mined: true, run_id:, candidates: N,
      #      rejected: { "<rule-id>" => N, "ungrounded" => N, "dedup" => N,
      #                  "schema" => N, ... }, cost: {...} | nil }
      #  | { mined: false, skipped: "disabled|no_model|no_grounding_matcher" }
      def call(command)
        p = AgentPayload.symbolize(command.payload)
        agent = AgentPayload.presence(p[:agent])
        raise Insika::ValidationError, "agent is required" if agent.nil?

        profile = @profiles[agent] ||
                  (raise Insika::NotFoundError, "agent '#{agent}' not configured")
        config = Coercion.deep_stringify(profile.harvest)
        return skip("disabled") if config.nil? || !Coercion.truthy?(config["enabled"])

        # D4: the OPERATIVE negative list lives on the profile (hot-editable,
        # seeded by `insika harvest:negative import`); the injected list is
        # the deployment's fallback. The engine applies data, never authors it.
        @list = negative_list_for(config)

        # D3: product claims cannot be verified without a matcher, so NOTHING
        # mines — refused, not warned (D12's "by refusal, not by prompt").
        grounding = Grounding.parse(profile.grounding)
        return skip("no_grounding_matcher") if grounding.nil? || !grounding.matcher.sku?

        miner = @miner_factory.call(config)
        return skip("no_model") if miner.nil?

        run = @harvest_store.create_run(agent_id: agent, window: window_record(p),
                                        budget: budget_cap(config))
        sessions = resolve_sessions(agent, p, config)

        begin
          # No eligible sessions: a run that says "we looked and it was clean"
          # without paying a bill; markers untouched (re-scan, D10).
          if sessions.empty?
            @harvest_store.complete_run(run.id, candidates: 0)
            return { mined: true, run_id: run.id, candidates: 0,
                     rejected: empty_rejected, cost: nil }
          end

          prompt = build_prompt(config, sessions, agent)
          result = miner.mine(prompt: prompt,
                              message_counts: sessions.map { |s| s[:messages].size },
                              max_proposals: max_proposals(p, config))

          # The mining budget is a REAL cap (the review fix): a pass that
          # spent more than the pack declared is failed with the numbers and
          # proposes NOTHING — the docs' "the budget cap bounds it" is
          # enforced here, post-hoc for the one model call, pre-hoc for every
          # downstream write and gate.
          if budget_exceeded?(budget_cap(config), result[:cost])
            @harvest_store.fail_run(run.id, error: "mining budget exceeded: " \
                                                 "spent #{result[:cost]['spent']} > " \
                                                 "#{budget_cap(config)['tokens']}")
            emit(:harvest_mined, agent: agent, run_id: run.id, candidates: 0,
                                 rejected: empty_rejected, cost: result[:cost])
            return { mined: true, run_id: run.id, candidates: 0,
                     rejected: empty_rejected, cost: result[:cost] }
          end

          survivors, rejected = filter_skills(result[:skills], sessions, agent, grounding.matcher)

          survivors.each do |skill|
            @harvest_store.create_candidate(
              run_id: run.id, agent: agent, name: skill["name"],
              description: skill["description"], body: skill_md(skill),
              triggers: skill["triggers"] || [], rationale: skill["rationale"].to_s,
              origin: sessions.map { |s| s[:id] }, evidence_turns: skill["evidence_turns"] || [],
              proposer: miner.model
            )
          end

          final_rejected = merge_rejected(result[:dropped], rejected)
          @harvest_store.complete_run(run.id, candidates: survivors.size,
                                              cost: result[:cost],
                                              rejected: final_rejected)
          # Markers AFTER the pass completes (D10's crash-safe re-scan).
          sessions.each { |s| @harvest_store.mark_mined(s[:id], candidates: survivors.size) }

          emit(:harvest_mined, agent: agent, run_id: run.id, candidates: survivors.size,
                               rejected: final_rejected, cost: result[:cost])
          { mined: true, run_id: run.id, candidates: survivors.size,
            rejected: final_rejected, cost: result[:cost] }
        rescue StandardError => e
          # The run is failed; the markers are NOT written (re-scan, D10);
          # the exception propagates to the caller's fiber or the CLI.
          begin
            @harvest_store.fail_run(run.id, error: e.message)
          rescue StandardError
            nil
          end
          raise
        end
      end

      private

      def skip(reason)
        { mined: false, skipped: reason }
      end

      # The pack's harvest.miner.budget as { "tokens" => N } — nil when
      # absent/not positive (no cap, the refinement discipline).
      def budget_cap(config)
        raw = config && config.dig("miner", "budget")
        raw.is_a?(Hash) && raw["tokens"].to_i.positive? ? { "tokens" => raw["tokens"].to_i } : nil
      end

      def budget_exceeded?(cap, cost)
        cap && cost && cost["spent"].to_i > cap["tokens"].to_i
      end

      # The candidate's body is a full SKILL.md by construction: the model
      # writes the procedure, the engine wraps the frontmatter (name /
      # description / triggers — the miner's own fields), so a candidate is
      # servable the moment a human promotes it (WriteSkill validates the
      # frontmatter, and the gate's clone serves it the same way).
      def skill_md(skill)
        fm = { "name" => skill["name"], "description" => skill["description"] }
        fm["triggers"] = Array(skill["triggers"]).join(", ") if Array(skill["triggers"]).any?
        "---\n#{fm.map { |k, v| "#{k}: #{v}" }.join("\n")}\n---\n#{skill['body']}"
      end

      # The profile's own rules win over the injected seed (D4). A malformed
      # profile list parses to nil — the injected list stays the fallback,
      # never a silent empty.
      def negative_list_for(config)
        return @negative_list unless config && config["negative_list"]

        Harvest::NegativeList.parse(config["negative_list"]) || @negative_list
      end

      def empty_rejected = { "schema" => 0, "unknown_key" => 0, "oversized" => 0,
                             "bad_turns" => 0, "duplicate" => 0, "capped" => 0 }

      def window_record(p)
        return { "session_ids" => Array(p[:session_ids]).map(&:to_s) } if p[:session_ids]
        return { "since" => p[:since].to_s } if AgentPayload.presence(p[:since])
        return { "last_sessions" => Integer(p[:last_sessions]) } if p[:last_sessions]

        {}
      end

      # The EvidenceCollector window discipline, applied to session ids: the
      # agent's turns (by the task's command payload), distinct session ids,
      # newest first, capped at the "last N conversations". Marker suppression
      # unless `full` (a re-mine is explicit). A session's evidence ledger
      #  is the grounding filter's input.
      def resolve_sessions(agent, p, config)
        ids = window_session_ids(agent, p, config)
        ids = ids.reject { |sid| @harvest_store.mined?(sid) } unless EnvSchema.truthy?(p[:full])
        ids = ids.first(Harvest::Miner::MAX_SESSIONS)

        min_messages = (config["min_messages"] || DEFAULT_MIN_MESSAGES).to_i
        idle_hours = (config["idle_hours"] || DEFAULT_IDLE_HOURS).to_i
        ids.filter_map do |sid|
          session = @session_store.find(sid)
          next unless session

          messages = session.messages.to_a
          next if messages.size < min_messages # a 2-message session mines noise
          # D10: the per-agent maturity bound is re-checked here — the engine
          # scan's default is only the LOWER bound (a pack that wants 12 h is
          # never mined at 6, and a manual CLI run over fresh traffic mines
          # nothing).
          next unless idle?(session.updated_at, idle_hours)

          evidence = (session.evidence || {})["ids"] || []
          { id: sid.to_s, messages: messages, evidence: Array(evidence).map(&:to_s) }
        end
      end

      def window_session_ids(agent, p, config)
        explicit = Array(p[:session_ids]).map(&:to_s)
        return explicit unless explicit.empty?

        since = AgentPayload.presence(p[:since])
        tasks = @task_store.each_id
                           .filter_map { |id| @task_store.find(id) }
                           .select { |t| task_agent(t) == agent }
                           .sort_by { |t| [t.created_at.to_s, t.id] }.reverse

        tasks = tasks.select { |t| t.created_at.to_s >= since.to_s } if since

        distinct = []
        seen = {}
        tasks.each do |t|
          sid = presence(t.session_id)
          next if sid.nil? || seen[sid]

          seen[sid] = true
          distinct << sid
        end
        return distinct if since

        last = AgentPayload.presence(p[:last_sessions])
        count = last ? Integer(last) : config_window(config)
        distinct.first(count)
      end

      # The config's miner.window last_sessions, or the collector default.
      def config_window(config)
        configured = config.dig("miner", "window", "last_sessions")
        configured ? Integer(configured) : DEFAULT_LAST_SESSIONS
      end

      def task_agent(task)
        task.command.is_a?(Hash) ? task.command.dig("payload", "agent").to_s : ""
      end

      def idle?(updated_at, idle_hours)
        return false if Coercion.blank?(updated_at)

        Time.iso8601(updated_at.to_s) <= Time.now.utc - idle_hours * 3600
      rescue ArgumentError
        false
      end

      def presence(value)
        Insika::Coercion.presence(value)
      end

      def max_proposals(p, config)
        raw = p[:max_proposals] || config.dig("miner", "max_proposals")
        raw ? Integer(raw) : DEFAULT_MAX_PROPOSALS
      end

      # The prompt: the transcript slices (masked through the   output
      # filter — the   redaction rule), the evidence ids per
      # session, the agent's CURRENT skill names (the model should not
      # re-propose them), and the answer rules. The pack prompt replaces
      # DEFAULT_PROMPT whole (the forge's half).
      def build_prompt(config, sessions, agent)
        base = Coercion.presence(config["prompt"]) || Harvest::DEFAULT_PROMPT
        current_skills = current_skill_names(agent)
        blocks = sessions.map do |s|
          evidence = s[:evidence].join(", ")
          lines = ["## Session #{s[:id]} (#{s[:messages].size} messages; " \
                   "evidence ids: #{evidence.empty? ? '(none)' : evidence})"]
          lines << render_transcript(s[:messages])
          lines.join("\n")
        end
        <<~PROMPT
          #{base.rstrip}

          ## Conversations to mine

          #{blocks.join("\n")}

          ## Skills this agent already has (do not re-propose them)

          #{current_skills.empty? ? "(none)" : current_skills.join(", ")}
        PROMPT
      end

      def current_skill_names(agent)
        return [] unless @skill_store

        (@skill_store.names | @skill_store.names(agent: agent)).sort
      end

      def render_transcript(messages)
        redacted, = Insika::Safety::Detectors.redact(
          messages.each_with_index.map { |m, i| "[#{i}] #{m['role']}: #{m['content']}" }.join("\n")
        )
        redacted
      end

      # The safety order: negative list (D4) -> grounding (D3) -> dedup. A
      # drop is COUNTED and NEVER written. `rejected` keys: the matched RULE
      # ids for negative hits (each named — E2), "ungrounded"/"dedup" for the
      # other two filters.
      # -> [[raw skill], { key => count }]
      def filter_skills(skills, sessions, agent, matcher)
        rejected = Hash.new(0)
        survivors = skills.select do |skill|
          hits = negative_hits(skill)
          if hits.any?
            hits.each { |r| rejected[r.rule] += 1 }
            false
          elsif !grounded?(skill, sessions, matcher)
            rejected["ungrounded"] += 1
            false
          elsif deduped?(skill, agent)
            rejected["dedup"] += 1
            false
          else
            true
          end
        end
        [survivors, rejected.to_h]
      end

      # D4: every rejected-by-list candidate is logged with the matching rule
      # id. The BODY is part of the match (the review fix): it is exactly what
      # enters the model's context when the skill loads, so a banned phrase
      # hidden there is the Hermes failure the design cites — the same text
      # the grounding filter already reads (name+description+body). The name
      # uses the stricter substring reading, the prose the word-boundary one.
      def negative_hits(skill)
        return [] unless @list

        text = [skill["name"], skill["description"], skill["body"]].join(" ")
        hits = @list.matches_name(skill["name"].to_s)
        hits | @list.matches(text)
      end

      # D3: every reference must be in the union of the origin sessions'
      # persisted evidence ids. The empty-ledger conservative reading (the
      # enforcer's rule): a candidate whose origin sessions hold NO evidence
      # ids and that carries a reference is dropped too. A skill with no
      # references is not a grounding casualty. -> bool
      def grounded?(skill, sessions, matcher)
        text = [skill["name"], skill["description"], skill["body"]].join(" ")
        refs = matcher.references(text)
        return true if refs.empty?

        union = sessions.flat_map { |s| s[:evidence] }.uniq
        return false if union.empty?

        missing = refs.reject { |r| union.include?(r) }
        missing.empty?
      end

      # The dedup ledger: the same name already in the store's SkillStore
      # (shared or agent scope) or an open (agent, name) tuple.
      def deduped?(skill, agent)
        name = skill["name"].to_s
        store_has = @skill_store && (@skill_store.get(name) || @skill_store.get(name, agent: agent))
        store_has || @harvest_store.open_pending?(agent: agent, name: name)
      end

      # The miner's schema drops + the filters' — one record; the keys never
      # collide (the filters own rule ids and their own names).
      def merge_rejected(dropped, filters)
        dropped.merge(filters) { |_k, left, right| left + right }
      end

      def utility_model
        return nil unless @settings_store

        @settings_store.get["utility_model"]
      end

      def emit(type, **data)
        @event_stream.emit(Insika::Event.new(
                             type: type, data: data, meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end