# frozen_string_literal: true

require "async"
require "time"

module Harness
  # Builder output, consumed by the Executor in stage 5.
  #   system:       String (final concatenation for with_instructions)
  #   history:      [{role:, content:}] (for seeding the chat)
  #   tool_context: String | nil
  #   fragments:    [ContextFragment] post-cut, in canonical order (audit)
  #   budget:       { cap:, used:, evicted: [source] }
  ContextPackage = Data.define(:system, :history, :tool_context, :fragments, :budget)

  # Stage 2 of the pipeline: the Runtime NEVER builds the prompt — it asks the
  # Builder for the package. Implements selection -> fan-out production ->
  # collection/estimation -> budgeting with eviction -> canonical assembly.
  class ContextBuilder
    def initialize(providers:, event_stream:, hooks: Hooks.new, estimator: TokenEstimator)
      @providers = providers
      @event_stream = event_stream
      @hooks = hooks # :prompt pair (task 16); empty Hooks = no-op
      @estimator = estimator
    end

    # The :prompt pair is wrapped HERE, not in the Executor: before_prompt
    # can rewrite the ContextRequest (providers run with the modified one);
    # after_prompt can rewrite the assembled ContextPackage. IMPORTANT: the
    # Executor calls only `builder.call(request)` — do NOT wrap it with
    # around(:prompt) again (double-wrapping would fire the hooks twice).
    def call(request)
      @hooks.around(:prompt, request) { |req| build_package(req) }
    end

    private

    def build_package(request)
      selected = select_providers(request.profile)
      fragments = estimate_tokens(produce(selected, request))
      cap = request.profile.limits[:context_budget] || 8_000
      fragments, evicted = apply_budget(fragments, cap)
      unless evicted.empty?
        emit_warning("ContextBuilder",
                     "budget: #{evicted.size} fragment(s) evicted from #{evicted.uniq}",
                     request)
      end
      assemble(fragments, cap, evicted)
    end

    # Step 1: selection — enabled_for? AND the profile allowlist.
    def select_providers(profile)
      @providers.select do |p|
        p.enabled_for?(profile) && Allowlist.allows?(profile.context_providers, p.id)
      end
    end

    # Step 2: fan-out production with a BARRIER and a per-provider timeout
    # (with_timeout — never Timeout.timeout). Each provider is a CHILD fiber
    # of the current fiber: cancelling the task cancels the in-flight production.
    def produce(selected, request)
      timeout = request.profile.limits[:provider_timeout] || 5
      tasks = selected.map do |provider|
        child = Async::Task.current.async { |t| t.with_timeout(timeout) { provider.call(request) } }
        [provider, child]
      end

      fragments = []
      tasks.each do |provider, child|
        fragments.concat(Array(child.wait))
      rescue StandardError => e # Async::TimeoutError is a StandardError; Async::Stop is NOT (propagates)
        handle_provider_failure(provider, e, request)
      end
      fragments
    end

    # A required provider failing -> ContextError
    # (aborts the turn, mapped by the Executor); an optional one failing ->
    # warning + graceful degradation (fragments omitted, turn proceeds).
    def handle_provider_failure(provider, error, request)
      if provider.required?
        raise ContextError.new("required provider '#{provider.id}' failed: #{error.message}",
                               provider: provider.id)
      end

      emit_warning(provider.id, error.message, request)
    end

    # Step 3: estimate tokens only when the provider did not report them.
    def estimate_tokens(fragments)
      fragments.map { |f| f.tokens ? f : f.with(tokens: @estimator.estimate(estimable_text(f.content))) }
    end

    # History fragments carry a Hash {role:, content:} as their content;
    # estimating over the Hash would count the `#to_s` text (":role=>", quotes,
    # symbols), inflating each message and biasing the eviction. Count the values,
    # not the Ruby representation.
    def estimable_text(content)
      case content
      when String then content
      when Hash then content.values.map(&:to_s).join(" ")
      else content.to_s
      end
    end

    # Steps 4-5: GLOBAL budget. Cuts non-pinned fragments from lowest priority to
    # highest; ties -> lowest production index first (stable cut: among
    # histories, the oldest drops first). pinned is uncuttable; if pinned alone
    # already exceeds -> ContextError (do not truncate identity).
    def apply_budget(fragments, cap)
      used = fragments.sum(&:tokens)
      return [fragments, []] if used <= cap

      indexed = fragments.each_with_index.to_a
      cuttable = indexed.reject { |f, _i| f.pinned }.sort_by { |f, i| [f.priority, i] }
      evicted_idx = []
      evicted_sources = []
      cuttable.each do |fragment, index|
        break if used <= cap

        used -= fragment.tokens
        evicted_sources << fragment.source
        evicted_idx << index
      end

      if used > cap
        raise ContextError.new(
          "orçamento insolúvel: fragmentos pinned (#{used} tokens) excedem o cap (#{cap})",
          provider: "ContextBuilder"
        )
      end

      survivors = fragments.each_index.reject { |i| evicted_idx.include?(i) }.map { |i| fragments[i] }
      [survivors, evicted_sources]
    end

    # Step 6: assembly in DETERMINISTIC canonical order.
    def assemble(fragments, cap, evicted)
      system_frags = fragments.select { |f| f.placement == :system }
                              .sort_by.with_index { |f, i| [-f.priority, f.source.to_s, i] }
      history_frags = fragments.select { |f| f.placement == :history } # production order (chronological)
      tool_frags = fragments.select { |f| f.placement == :tool_context }

      system = system_frags.map(&:content).join("\n\n")
      history = history_frags.map(&:content)
      tool_context = tool_frags.empty? ? nil : tool_frags.map(&:content).join("\n\n")

      canonical = system_frags + history_frags + tool_frags
      ContextPackage.new(
        system: system, history: history, tool_context: tool_context,
        fragments: canonical, budget: { cap: cap, used: canonical.sum(&:tokens), evicted: evicted }
      )
    end

    # :provider_warning. The Builder does not know task_id/seq (correlation is
    # the Executor's job) — emits with what it has; Event#to_h does meta.compact.
    def emit_warning(provider_id, message, request)
      @event_stream.emit(Harness::Event.new(
                           type: :provider_warning,
                           data: { provider: provider_id, message: message },
                           meta: { session_id: request.session&.id, at: Time.now.utc.iso8601 }
                         ))
    end
  end
end
