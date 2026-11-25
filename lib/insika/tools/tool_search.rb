# frozen_string_literal: true

require "ruby_llm"

module Insika
  module Tools
    # Level 2 of TOOLS progressive disclosure (analog of LoadSkill):
    # searches the deferred catalog and PROMOTES the relevant ones into the live chat via
    # chat.with_tools (propagates on the next round of the same `ask`).
    # `require "ruby_llm"` stays in THIS file (it inherits from
    # RubyLLM::Tool) — it does not enter lib/insika.rb; the Executor loads it lazily in
    # configure_chat (like LoadSkill).
    class ToolSearch < RubyLLM::Tool
      description "Enables tools listed in <available_tools> by their exact names, or finds the closest few by need"
      parameter :query, description: "Tool names from <available_tools>, several at once (e.g.: 'send_email create_invoice'), " \
                                      "or a short description of the need"

      # RubyLLM::Tool#name derives from self.class.name — for a nested class
      # (Insika::Tools::ToolSearch) it produces "insika--tools--tool_search", not
      # "tool_search". Explicit override: the name the model calls must match
      # the catalog/docs/tests.
      def name = "tool_search"

      # Tools wired per call when the agent sets no limits[:tool_search_limit]. Kept
      # here, not in AgentProfile::DEFAULT_LIMITS, so saved agents do not store it.
      DEFAULT_LIMIT = 8
      # Tools one turn may enable by description, as a multiple of the limit. Exact
      # names stay open (capped per call): vague repeats are what refilled the window.
      # Per turn: ChatBuilder builds a new ToolSearch each turn, so the count restarts.
      RANKED_BUDGET_FACTOR = 3

      def initialize(catalog, deferred_allowed, chat, tool_registry:, event_stream:,
                     checkpoint_store:, state:, trace_recorder: nil, enabled: [])
        @catalog = catalog
        @deferred_allowed = Array(deferred_allowed).map(&:to_s)
        @chat = chat
        @tool_registry = tool_registry
        @event_stream = event_stream
        @checkpoint_store = checkpoint_store
        @state = state
        @trace_recorder = trace_recorder
        # names already promoted IN THIS chat — idempotency. `enabled:` seeds the ones a
        # resumed turn brings back from the approval pause, so a search skips them too.
        @promoted = Array(enabled).map(&:to_s)
        @ranked_count = 0 # tools this turn enabled by description, against the budget
        super()
      end

      # Tools already enabled in this chat leave the ranking (named in
      # `already_enabled`, without their schema again), so a similar search brings the
      # next ones instead of the same top. What the caps cut is said in `message`.
      def execute(query:)
        limit = search_limit
        cap = ranked_left(limit)
        found = @catalog.find(query, within: @deferred_allowed, listed: @state.profile.tools_deferred,
                                     limit: limit, known: @promoted, ranked_cap: cap)
        matches = found.entries
        emit_tool_search(query, matches.map(&:name))
        notes = cut_notes(found, limit, budget_cut: cap && cap < limit - found.named)
        if matches.empty? && found.known.empty?
          # Matches cut by the caps, or a denied name, are not "nothing found".
          lead = found.more.zero? && found.unavailable.empty? ? ["no tool found for '#{query}'."] : []
          return { matched: [], message: (lead + notes).join(" ") }
        end

        # Only tools actually wired count against the budget (promote drops a misaligned one).
        wired = promote(matches.reject { |m| @promoted.include?(m.name) })
        @ranked_count += (matches.drop(found.named).map(&:name) & wired).size

        result = { matched: matches.map { |m| describe(m) } }
        result[:already_enabled] = found.known unless found.known.empty?
        result[:message] = notes.join(" ") unless notes.empty?
        result
      end

      private

      # Each match is wired with its full schema and listed in the result, so the cap is
      # what keeps one search from filling the window. Below 1 means no cap.
      # A value that is not a number ("", "abc") falls back to the default instead of
      # turning into 0, which would lift the cap silently.
      def search_limit
        limit = Integer(@state.profile.limits[:tool_search_limit].to_s, 10, exception: false) || DEFAULT_LIMIT
        limit.positive? ? limit : nil
      end

      def ranked_left(limit) = limit && [(limit * RANKED_BUDGET_FACTOR) - @ranked_count, 0].max

      # `budget_cut`: the per-turn budget, not the per-call limit, is what cut the matches.
      def cut_notes(found, limit, budget_cut:)
        notes = []
        unless found.unavailable.empty?
          notes << "Not available to this agent: #{found.unavailable.join(", ")}. Do not use another tool in its place."
        end
        if budget_cut && found.more.positive?
          notes << "#{found.more} more tools match, but this turn has used its searches by description: " \
                   "ask for tools by exact name."
        elsif found.more.positive?
          notes << "#{found.more} more tools match past the limit of #{limit}: ask for them by exact name, " \
                   "or describe the need more precisely."
        end
        unless found.left_out.empty?
          notes << "Not enabled, over the cap of names per call: #{found.left_out.join(", ")}. " \
                   "Ask for them in another call."
        end
        notes
      end

      # Instantiates (via tool_registry), wraps in the SAME ToolEnvelope as the eager
      # ones (profile timeout + state's skip_side_effects) and promotes via
      # chat.with_tools. A NotFoundError (misaligned catalog) drops only
      # that match — the search does not break.
      # Returns the names it wired.
      def promote(entries)
        return [] if entries.empty?

        timeout = @state.profile.limits[:tool_timeout] || 60
        names = []
        wrapped = entries.filter_map do |entry|
          tool = @tool_registry.resolve(entry.name)
          ToolAssembly.inject_turn_context(tool, @state) # {{ctx.*}} headers, like eager tools
          @promoted << entry.name
          names << entry.name
          ToolEnvelope.new(tool, state: @state, checkpoint_store: @checkpoint_store,
                                 tool_registry: @tool_registry, timeout: timeout,
                                 skip_side_effects: Array(@state.skip_side_effects),
                                 event_stream: @event_stream, trace_recorder: @trace_recorder)
        rescue Insika::NotFoundError
          nil
        end
        @chat.with_tools(*wrapped) unless wrapped.empty?
        names
      end

      # Mirrors :skill_activated, but emitted by the tool itself (it has event_stream/
      # state in the constructor). Without a monotonic `seq` (private to the Executor) — a
      # documented gap, not a blocker.
      def emit_tool_search(query, matched_names)
        @event_stream.emit(Insika::Event.new(
                             type: :tool_search,
                             data: { query: query, matched: matched_names },
                             meta: { task_id: @state.task.id, session_id: @state.task.session_id }
                           ))
      end

      def describe(entry)
        tool = @tool_registry.resolve(entry.name)
        schema = Coercion.deep_stringify(tool.parameters_schema || {})
        {
          name: entry.name,
          description: entry.description,
          parameters: schema.fetch("properties", {}).to_h do |name, property|
            [name.to_sym, { type: property["type"], description: property["description"],
                            required: Array(schema["required"]).include?(name) }]
          end
        }
      rescue Insika::NotFoundError
        { name: entry.name, description: entry.description, parameters: {} }
      end
    end
  end
end
