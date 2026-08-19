# frozen_string_literal: true

require "time"

module Insika
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
                   hooks:, tool_catalog: nil, memory_store: nil, subagent_runner: nil,
                   tool_trace_store: nil, media_runner: nil, session_store: nil,
                   contact_store: nil, followup_store: nil)
      @tool_registry = tool_registry
      @skill_catalog = skill_catalog
      @checkpoint_store = checkpoint_store
      @event_stream = event_stream
      @hooks = hooks
      @tool_catalog = tool_catalog
      @memory_store = memory_store
      # only to trace load_skill, which is not enveloped — nil = no trace (parity).
      @tool_trace_store = tool_trace_store
      # the object exposing #run_subagent (the Executor). nil = the
      # spawn_subagent system tool is never wired (parity for a builder used
      # without delegation, e.g. some unit stubs).
      @subagent_runner = subagent_runner
      # the Executor as the generate_image/tts runner (seams + usage
      # accounting). nil = the media tools are never wired (parity for stubs).
      @media_runner = media_runner
      # update_briefing / set_next_step are the briefing-write system
      # tools — wired only with @session_store present AND profile.briefing_fields
      # non-empty (double gate, like remember). nil = never wired (parity for a
      # builder used without session persistence, e.g. some unit stubs).
      @session_store = session_store
      # the schedule/cancel_followup system tools — wired only
      # with BOTH stores present AND a parsed follow-up policy on the profile
      # (double gate, like remember). nil = never wired (parity).
      @contact_store = contact_store
      @followup_store = followup_store
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
      apply_instructions(chat, system, state) unless system.empty?

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
      # (policy), minus the EAGER ones: their bodies are already in the prompt, so a
      # call could only pay for a duplicate. Nothing lazy left -> the tool is not
      # wired at all. Keeping it for the discretionary skills is deliberate: that
      # call is the only record of which skill the model actually reached for.
      skill_names = lazy_skill_names(state)
      unless skill_names.empty?
        tools << Tools::LoadSkill.new(@skill_catalog, skill_names,
                                      trace_recorder: @tool_trace_store, state: state,
                                      agent: state.profile.id)
      end

      # remember is the memory-write system tool — wired only with
      # @memory_store present AND profile.memory (a double gate). Never enveloped.
      if @memory_store && state.profile.memory
        tools << Tools::Remember.new(@memory_store, state.tenant,
                                     event_stream: @event_stream, state: state)
      end

      # update_briefing / set_next_step are the briefing-write system tools
      #  — wired only with @session_store present AND
      # profile.briefing_fields non-empty (double gate, like remember). Never
      # enveloped: deterministic in-process writes.
      fields = if state.profile.respond_to?(:briefing_fields)
                 Array(state.profile.briefing_fields).map(&:to_s)
               else
                 []
               end
      if @session_store && !fields.empty?
        tools << Tools::UpdateBriefing.new(session_store: @session_store, fields: fields,
                                           event_stream: @event_stream, state: state)
        tools << Tools::UpdateBriefing::SetNextStep.new(session_store: @session_store,
                                                        event_stream: @event_stream, state: state)
      end

      # signal_stuck is the "I cannot proceed" system tool (WS5) — wired only
      # when the agent opted in (`profile.stuck_signal`), never enveloped. It is a
      # deterministic signal; the consumer decides what "stuck" means. Defensive
      # read: a minimal profile double without the reader means off (nil = parity).
      if state.profile.respond_to?(:stuck_signal) && state.profile.stuck_signal
        tools << Tools::StuckSignal.new(state: state)
      end

      # schedule/cancel_followup are the follow-up system tools  —
      # wired only with BOTH stores present AND a parsed follow-up policy on
      # the profile (double gate, like remember). Never enveloped: the store
      # writes are deterministic. The tools stay OUT of the allowlist — they
      # are data-driven per agent, not admittable (prompts/memory/stuck_signal
      # are the precedent).
      if @contact_store && @followup_store && followup_policy(state)
        tools << Tools::ScheduleFollowup.new(contact_store: @contact_store,
                                             followup_store: @followup_store,
                                             state: state,
                                             event_stream: @event_stream)
        tools << Tools::CancelFollowup.new(followup_store: @followup_store,
                                           state: state,
                                           event_stream: @event_stream)
      end

      # generate_image / tts are the generated-media system tools (WS9, saída)
      # — wired only when BOTH gates pass, never enveloped: the AGENT opted in
      # (`profile.outputs` — the per-kind generator config) AND the CHANNEL
      # declared it can receive the media (state.channel_capabilities, from the
      # request's `channel.capabilities`). The "abstraction admits only what
      # leaks" rule, C4: a channel that never declared image_output cannot get
      # a generated image; a profile without `outputs` never generates. The
      # runner is the Executor (seams + usage accounting); nil = no media
      # output at all (parity for a stub builder).
      output_media_tools(state).each { |tool| tools << tool } if @media_runner

      # spawn_subagent is the delegation system tool — wired only with a
      # runner present AND profile.subagents non-empty (a double gate, like
      # remember). Never enveloped: in the synchronous mode the child lives in the
      # parent's envelope. The runtime gate on WHICH agent is spawnable is the
      # parent's subagents allowlist, enforced in Executor#run_subagent.
      if @subagent_runner && !Array(state.profile.subagents).empty?
        tools << Tools::Subagent.new(runner: @subagent_runner, state: state)
        # and its parallel sibling: fan-out N children at once.
        tools << Tools::Subagents.new(runner: @subagent_runner, state: state)
      end

      unless tools.empty?
        # the ONLY place the gem is told to run tool calls in parallel.
        # `:fibers` is not a preference but the only admissible mode — `:threads`
        # breaks ToolEnvelope's `Async::Task.current.with_timeout`, the SQLite
        # store's fiber semaphore, and the turn's own durability (mailbox,
        # approvals, cancellation are all expressed in fiber terms). The number
        # the operator configured is OUR cap (ToolAssembly#install_tool_gate);
        # the gem has none.
        if tool_concurrency_for(state)
          chat.with_tools(*tools, concurrency: :fibers)
        else
          chat.with_tools(*tools)
        end
      end

      chat
    end

    # The skills the model still has to ask for: the Resolution's set minus the eager
    # ones. Intersected by NAME against the catalog's own verdict (SkillCatalog#eager_for)
    # so the tool and the level-1 list can never disagree about who is eager. A catalog
    # without the reader (a unit stub) falls back to the whole set — parity.
    def lazy_skill_names(state)
      names = Array(state.allowed_skills).map { |s| s.respond_to?(:name) ? s.name : s.to_s }
      return names unless @skill_catalog.respond_to?(:eager_for)

      eager = @skill_catalog.eager_for(state.profile).map(&:name)
      names - eager
    end

    # the follow-up tools' gate — a PARSED policy on the profile.
    # A malformed declaration reads as "no policy" (the firer blocks it, the
    # doctor reports it; the tools are simply not offered).
    def followup_policy(state)
      followup = state.profile.respond_to?(:followup) ? state.profile.followup : nil
      followup && Insika::FollowupPolicy.parse(followup)
    end

    # WS9 (saída): the media-output tools this turn may carry, per the double
    # gate (profile outputs ∩ channel capabilities). [] = none. Defensive reads
    # throughout — a minimal profile/state stub is "off", which is the safe
    # parity reading.
    def output_media_tools(state)
      outputs = state.profile.respond_to?(:outputs) ? state.profile.outputs : nil
      return [] unless outputs.is_a?(Hash)
      return [] unless state.respond_to?(:channel_capabilities)

      caps = Array(state.channel_capabilities).map(&:to_s)
      image_cfg = outputs["image"]
      tts_cfg = outputs["tts"]
      [
        (Tools::GenerateImage.new(runner: @media_runner, config: image_cfg, state: state) if image_cfg.is_a?(Hash) && caps.include?("image_output")),
        (Tools::Tts.new(runner: @media_runner, config: tts_cfg, state: state) if tts_cfg.is_a?(Hash) && caps.include?("audio_output"))
      ].compact
    end

    # The turn's effective tool concurrency (nil = serial), plus the ONE thing the
    # gate owes the operator: when the profile asked for parallel tool calls and
    # this turn silently cannot have them (an approval-required tool would
    # deadlock two fibers on the single per-task mailbox), say so once. Otherwise
    # the speedup just vanishes with no reason given. The rule itself lives in
    # TurnState; a state predating those readers (a unit stub) means off.
    def tool_concurrency_for(state)
      return nil unless state.respond_to?(:tool_concurrency)

      effective = state.tool_concurrency
      return effective if effective

      requested = state.requested_tool_concurrency
      warn_tool_concurrency_gated(state, requested) if requested
      nil
    end

    def warn_tool_concurrency_gated(state, requested)
      gated = Array(state.requires_approval)
      @event_stream.emit(Insika::Event.new(
                           type: :provider_warning,
                           data: { provider: "tool_concurrency",
                                   message: "parallel tool calls (#{requested}) disabled for this turn: " \
                                            "#{gated.size} tool(s) require approval (#{gated.join(', ')})" },
                           meta: { task_id: state.task&.id, at: Time.now.utc.iso8601 }
                         ))
    end

    # R3: opt-in Anthropic prompt caching. When the agent enables
    # prompt_caching AND the resolved provider is Anthropic, wrap the system in
    # the provider's native Content helper with cache: true — ONE breakpoint at
    # the END of the system block. By Anthropic's prefix order
    # (tools -> system -> messages), a breakpoint on the last system block caches
    # tools + system together and is immune to history eviction (messages come
    # after it). RubyLLM::Content::Raw is Anthropic-specific: build_system_content
    # emits its blocks verbatim, so the cache_control rides along.
    #
    # Any other case (caching off, or a non-Anthropic provider) uses the plain
    # string — OpenAI caches its prefix on its own; the Raw shape would confuse
    # non-Anthropic providers. The gem only supports MANUAL caching, and only for
    # Anthropic.
    #
    # PRE-AUDIT (why this is opt-in): the system must be BYTE-STABLE between turns
    # for a read hit. A context provider that injects volatile content into
    # :system (timestamps, per-turn data) makes every turn a paid cache WRITE
    # with no hit — worse than off. Enable only for stable-system agents.
    def apply_instructions(chat, system, state)
      if state.profile.prompt_caching && anthropic_provider?(chat)
        chat.with_instructions(RubyLLM::Providers::Anthropic::Content.new(system, cache: true))
      else
        chat.with_instructions(system)
      end
    end

    # The RESOLVED provider (chat.model.provider is the slug string, e.g.
    # "anthropic"), authoritative even when the agent left provider nil and
    # RubyLLM inferred it from the model id. Any surface without a model (fakes,
    # a provider that raises) -> false: caching silently stays off.
    def anthropic_provider?(chat)
      chat.respond_to?(:model) && chat.model && chat.model.provider.to_s == "anthropic"
    rescue StandardError
      false
    end

    # History comes from the context/checkpoint. The {role:, content:} shape
    # tolerates string keys (JSON from the stores). `flatten(1)` dissolves the
    # Session provider's "eviction units" (an assistant+tool_results cycle grouped
    # as one Array, R1) back into a flat message stream.
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
      # Per-TURN counter: safe as a closure local even under concurrent tool calls
      # (MRI fibers do not preempt between the read and the write). The per-CALL
      # correlation is NOT — it lives in fiber storage behind TurnState, because
      # each call gets its own fiber once tool concurrency is on.
      tool_calls = 0
      max_tool_calls = state.profile.limits[:max_tool_calls] || 50

      # the loop detector. Needs #after_message + #add_message for the
      # batch-boundary intervention; a chat without them (smoke shim, minimal
      # double) stays bounded by max_tool_calls alone — never half-wired.
      detector = if %i[after_message add_message].all? { |m| chat.respond_to?(m) }
                   repeat = state.profile.limits[:max_tool_repeat] || Insika::AgentProfile::DEFAULT_LIMITS[:max_tool_repeat]
                   Insika::LoopDetector.new(chat: chat, limit: repeat, emit: emit) if repeat >= 2
                 end

      chat.before_tool_call do |tool_call|
        # call<->decorator correlation (side-effects/skip) — 1st line.
        state.current_tool_call = tool_call
        # max_tool_calls guard-rail: stays inline (not as a registered hook)
        # because Hooks is shared across turns and has no unregister.
        tool_calls += 1
        if tool_calls > max_tool_calls
          raise Insika::TimeoutError.new("tool call limit exceeded (#{max_tool_calls})",
                                           stage: :tool_limit)
        end

        # AFTER the count, BEFORE the call runs — a post-warning
        # repeat raises here, so the stubborn loop pays for no extra call.
        detector&.tool_call(tool_call.name, tool_call.arguments)

        # :tool pair: RubyLLM's callbacks are additive — the altered subject
        # feeds later hooks and the events, but does not rewrite the call the
        # model executes. A hook exception here aborts the turn.
        tool_call = @hooks.run_before(:tool, tool_call)

        # The name of the (possibly hook-altered) subject, for the :tool_result
        # label. Also fiber-scoped: as a closure local it belonged to the TURN, so
        # under concurrency `after_tool_result` labelled every result with whichever
        # call started last.
        state.current_tool_name = tool_call.name.to_s
        if state.current_tool_name == "load_skill"
          args = tool_call.arguments || {}
          emit.call(:skill_activated, { name: args["name"] || args[:name] })
        else
          emit.call(:tool_call, { name: tool_call.name, arguments: tool_call.arguments })
        end
      end

      chat.after_tool_result do |result|
        # the RAW result — the only place a Tool::Halt (halt_when) is
        # still recognizable, and a halted batch must receive no intervention.
        detector&.tool_result(result)
        result = @hooks.run_after(:tool, result)
        emit.call(:tool_result, { name: state.current_tool_name, result: result.to_s })
      end

      # the intervention appends at the batch boundary (the Nth tool
      # result closing) — never between two tool results of one batch.
      chat.after_message { |message| detector.message_ended(message) } if detector
    end
  end
end
