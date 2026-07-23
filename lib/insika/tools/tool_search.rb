# frozen_string_literal: true

require "ruby_llm"

module Insika
  module Tools
    # Level 2 of TOOLS progressive disclosure (analog of LoadSkill):
    # searches the deferred catalog and PROMOTES the relevant ones into the live chat via
    # chat.with_tools (verified to propagate on the next round of the same `ask`
    # in ruby_llm 1.16). `require "ruby_llm"` stays in THIS file (it inherits from
    # RubyLLM::Tool) — it does not enter lib/harness.rb; the Executor loads it lazily in
    # configure_chat (like LoadSkill).
    class ToolSearch < RubyLLM::Tool
      description "Searches and enables additional tools by describing the need"
      param :query, desc: "What you need to do (e.g.: 'send email', 'generate invoice')"

      # RubyLLM::Tool#name derives from self.class.name — for a nested class
      # (Insika::Tools::ToolSearch) it produces "harness--tools--tool_search", not
      # "tool_search". Explicit override: the name the model calls must match
      # the catalog/docs/tests.
      def name = "tool_search"

      def initialize(catalog, deferred_allowed, chat, tool_registry:, event_stream:,
                     checkpoint_store:, state:)
        @catalog = catalog
        @deferred_allowed = Array(deferred_allowed).map(&:to_s)
        @chat = chat
        @tool_registry = tool_registry
        @event_stream = event_stream
        @checkpoint_store = checkpoint_store
        @state = state
        @promoted = [] # names already promoted IN THIS chat — idempotency
        super()
      end

      def execute(query:)
        matches = @catalog.search(query, within: @deferred_allowed)
        emit_tool_search(query, matches.map(&:name))
        if matches.empty?
          return { matched: [], message: "no tool found for '#{query}'" }
        end

        new_matches = matches.reject { |m| @promoted.include?(m.name) }
        promote(new_matches) unless new_matches.empty?

        { matched: matches.map { |m| describe(m) } }
      end

      private

      # Instantiates (via tool_registry), wraps in the SAME ToolEnvelope as the eager
      # ones (profile timeout + state's skip_side_effects) and promotes via
      # chat.with_tools. A NotFoundError (misaligned catalog) drops only
      # that match — the search does not break.
      def promote(entries)
        timeout = @state.profile.limits[:tool_timeout] || 60
        wrapped = entries.filter_map do |entry|
          tool = @tool_registry.resolve(entry.name)
          @promoted << entry.name
          ToolEnvelope.new(tool, state: @state, checkpoint_store: @checkpoint_store,
                                 tool_registry: @tool_registry, timeout: timeout,
                                 skip_side_effects: Array(@state.skip_side_effects))
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
        {
          name: entry.name,
          description: entry.description,
          parameters: tool.parameters.transform_values do |p|
            { type: p.type, description: p.description, required: p.required }
          end
        }
      rescue Insika::NotFoundError
        { name: entry.name, description: entry.description, parameters: {} }
      end
    end
  end
end
