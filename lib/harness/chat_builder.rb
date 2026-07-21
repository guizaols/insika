# frozen_string_literal: true

module Harness
  # Assembles the turn's chat (pipeline stages 5-7): instructions, eager/deferred
  # tool partition, system tools (tool_search/load_skill/remember),
  # history and callbacks. Extracted from the Executor so it can coordinate the
  # pipeline without also carrying the RubyLLM glue.
  #
  # The Executor creates the chat (stage 6, the RubyLLM boundary) and passes it
  # here to be configured; event numbering (monotonic seq per task) stays in the
  # Executor, injected as the `emit` callable.
  class ChatBuilder
    def initialize(tool_registry:, skill_catalog:, checkpoint_store:, event_stream:,
                   hooks:, tool_catalog: nil, memory_store: nil)
      @tool_registry = tool_registry
      @skill_catalog = skill_catalog
      @checkpoint_store = checkpoint_store
      @event_stream = event_stream
      @hooks = hooks
      @tool_catalog = tool_catalog
      @memory_store = memory_store
    end

    # Configures an already-created chat with the context (stage 2) and the
    # Resolution (stage 3), seeds the history and wires the callbacks. `emit` is
    # the Executor's emitter (seq+task correlation), called as emit.call(type,
    # data). The system tools (Tools::ToolSearch/LoadSkill/Remember) were already
    # lazy-loaded by Executor#create_chat before reaching here.
    def assemble(chat, state, emit:)
      configure_chat(chat, state)
      seed_history(chat, Array(state.context.history))
      wire_callbacks(chat, state, emit)
      chat
    end

    # Assembles the chat with the context (stage 2) and the Resolution's tools (stage 3).
    def configure_chat(chat, state)
      system = state.context.system.to_s
      chat.with_instructions(system) unless system.empty?

      tools = Array(state.allowed_tools).dup

      # Tool Search: the partition only runs with @tool_catalog present (parity
      # when nil — the `&&` short-circuits before reading `.name`).
      # `deferred_allowed` = allowed_tools ∩ tools_deferred. The <available_tools>
      # catalog comes from Context::Providers::ToolSearch (stage 2); here we only
      # decide chat.tools.
      deferred_allowed = if @tool_catalog
                           Array(state.profile.tools_deferred).map(&:to_s) &
                             tools.map { |t| t.name.to_s }
                         else
                           []
                         end

      unless deferred_allowed.empty?
        tools.reject! { |t| deferred_allowed.include?(t.name.to_s) }
        # a system tool (outside the allowlist), like load_skill — never enveloped.
        tools << Tools::ToolSearch.new(@tool_catalog, deferred_allowed, chat,
                                       tool_registry: @tool_registry,
                                       checkpoint_store: @checkpoint_store,
                                       event_stream: @event_stream, state: state)
      end

      # load_skill is a system default (outside the allowlist), otherwise
      # progressive disclosure breaks. allowed_skills comes from the Resolution
      # (policy).
      skill_names = Array(state.allowed_skills).map { |s| s.respond_to?(:name) ? s.name : s.to_s }
      tools << Tools::LoadSkill.new(@skill_catalog, skill_names) unless skill_names.empty?

      # remember is the memory-write system tool — wired only with
      # @memory_store present AND profile.memory (a double gate). Never enveloped.
      if @memory_store && state.profile.memory
        tools << Tools::Remember.new(@memory_store, state.tenant,
                                     event_stream: @event_stream, state: state)
      end

      chat.with_tools(*tools) unless tools.empty?

      chat
    end

    # History comes from the context/checkpoint. The {role:, content:} shape
    # tolerates string keys (JSON from the stores). `flatten(1)` dissolves the
    # Session provider's "eviction units" (an assistant+tool_results cycle grouped
    # as one Array, §11 R1) back into a flat message stream.
    #
    # tool_calls / tool_call_id are rehydrated ONLY when present, so a message
    # without them keeps the 2-arg shape the specs' FakeChat expects (no unknown
    # keyword). This is what lets the model SEE the tools it already called.
    def seed_history(chat, messages)
      Array(messages).flatten(1).each do |m|
        attrs = { role: (m[:role] || m["role"]).to_sym, content: m[:content] || m["content"] }
        tool_calls = m[:tool_calls] || m["tool_calls"]
        tool_call_id = m[:tool_call_id] || m["tool_call_id"]
        attrs[:tool_calls] = rehydrate_tool_calls(tool_calls) if tool_calls && !Array(tool_calls).empty?
        attrs[:tool_call_id] = tool_call_id if tool_call_id
        chat.add_message(**attrs)
      end
    end

    # [{id,name,arguments}] (string|symbol keys) -> {id => RubyLLM::ToolCall}, the
    # shape RubyLLM seeds an assistant message with. Called only when the gem is
    # already loaded (create_chat required it before assemble).
    def rehydrate_tool_calls(list)
      Array(list).each_with_object({}) do |tc, acc|
        id = (tc[:id] || tc["id"]).to_s
        acc[id] = RubyLLM::ToolCall.new(
          id: id, name: (tc[:name] || tc["name"]).to_s,
          arguments: tc[:arguments] || tc["arguments"] || {}
        )
      end
    end

    # RubyLLM's additive callbacks become events. load_skill becomes
    # :skill_activated. Adds the max_tool_calls counter: the loop is RubyLLM's;
    # here we only count and abort.
    def wire_callbacks(chat, state, emit)
      tool_calls = 0
      max_tool_calls = state.profile.limits[:max_tool_calls] || 50
      last_tool_name = nil

      chat.before_tool_call do |tool_call|
        # call<->decorator correlation (side-effects/skip) — 1st line.
        state.current_tool_call = tool_call
        # max_tool_calls guard-rail: stays inline (not as a registered hook)
        # because Hooks is shared across turns and has no unregister.
        tool_calls += 1
        if tool_calls > max_tool_calls
          raise Harness::TimeoutError.new("tool call limit exceeded (#{max_tool_calls})",
                                          stage: :tool_limit)
        end

        # :tool pair: RubyLLM's callbacks are additive — the altered subject
        # feeds later hooks and the events, but does not rewrite the call the
        # model executes. A hook exception here aborts the turn.
        tool_call = @hooks.run_before(:tool, tool_call)

        last_tool_name = tool_call.name.to_s
        if last_tool_name == "load_skill"
          args = tool_call.arguments || {}
          emit.call(:skill_activated, { name: args["name"] || args[:name] })
        else
          emit.call(:tool_call, { name: tool_call.name, arguments: tool_call.arguments })
        end
      end

      chat.after_tool_result do |result|
        result = @hooks.run_after(:tool, result)
        emit.call(:tool_result, { name: last_tool_name, result: result.to_s })
      end
    end
  end
end
