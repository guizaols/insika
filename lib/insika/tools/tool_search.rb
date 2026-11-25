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

      def initialize(catalog, deferred_allowed, chat, tool_registry:, event_stream:,
                     checkpoint_store:, state:, trace_recorder: nil)
        @catalog = catalog
        @deferred_allowed = Array(deferred_allowed).map(&:to_s)
        @chat = chat
        @tool_registry = tool_registry
        @event_stream = event_stream
        @checkpoint_store = checkpoint_store
        @state = state
        @trace_recorder = trace_recorder
        @promoted = [] # names already promoted IN THIS chat — idempotency
        super()
      end

      def execute(query:)
        matches = @catalog.search(query, within: @deferred_allowed, limit: search_limit)
        emit_tool_search(query, matches.map(&:name))
        if matches.empty?
          return { matched: [], message: "no tool found for '#{query}'" }
        end

        new_matches = matches.reject { |m| @promoted.include?(m.name) }
        promote(new_matches) unless new_matches.empty?

        { matched: matches.map { |m| describe(m) } }
      end

      private

      # Each match is wired with its full schema and listed in the result, so the cap is
      # what keeps one search from filling the window. Below 1 means no cap.
      def search_limit
        limit = @state.profile.limits[:tool_search_limit] || AgentProfile::DEFAULT_LIMITS[:tool_search_limit]
        limit.to_i.positive? ? limit.to_i : nil
      end

      # Instantiates (via tool_registry), wraps in the SAME ToolEnvelope as the eager
      # ones (profile timeout + state's skip_side_effects) and promotes via
      # chat.with_tools. A NotFoundError (misaligned catalog) drops only
      # that match — the search does not break.
      def promote(entries)
        timeout = @state.profile.limits[:tool_timeout] || 60
        wrapped = entries.filter_map do |entry|
          tool = @tool_registry.resolve(entry.name)
          ToolAssembly.inject_turn_context(tool, @state) # {{ctx.*}} headers, like eager tools
          @promoted << entry.name
          ToolEnvelope.new(tool, state: @state, checkpoint_store: @checkpoint_store,
                                 tool_registry: @tool_registry, timeout: timeout,
                                 skip_side_effects: Array(@state.skip_side_effects),
                                 event_stream: @event_stream, trace_recorder: @trace_recorder)
        rescue Insika::NotFoundError
          nil
        end
        @chat.with_tools(*wrapped) unless wrapped.empty?
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
