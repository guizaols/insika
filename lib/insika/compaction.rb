# frozen_string_literal: true

module Insika
  # In-session compaction: when a session's UNCOMPACTED transcript
  # grows past `compact_after` messages, everything but the last `keep_last`
  # is summarized by a cheap model into one fragment; the tail stays verbatim.
  # This module is the pure half — boundary math, the prompt, and the
  # Summarizer over an injected ask (the Distiller shape: unit-testable
  # without a provider). The trigger lives in the Executor (post-turn, off
  # the critical path); the persistence in SessionStore#set_compaction; the
  # read path in Context::Providers::Session.
  module Compaction
    DEFAULT_KEEP_LAST = 20
    DEFAULT_COMPACT_AFTER = 40
    # A summary that outgrows this is truncated — the compaction must never
    # grow the context it exists to shrink.
    MAX_SUMMARY_CHARS = 6_000
    # Per-message cap in the transcript slice sent to the summarizer (a
    # `role: tool` body can be 4 000 chars in the store); the head of a long
    # result carries the identity of what happened, which is what a summary needs.
    MESSAGE_CHAR_CAP = 1_000

    # The engine's generic prompt. A platform `compaction.prompt` REPLACES it
    # wholesale (the distill convention) — the engine never writes store
    # vocabulary. The preserve-list is the P28 contract: facts (CEP, order
    # numbers), commitments, the MISSING list, decisions.
    DEFAULT_PROMPT = <<~PROMPT.freeze
      You are compacting the OLD part of an ongoing customer conversation into
      one summary that the assistant will read INSTEAD of those messages. The
      recent messages stay verbatim; your summary is the only surviving trace
      of the old ones — anything you drop is gone for good.

      Preserve, verbatim where short:
      - every fact the customer stated (sizes, budget, address, postal code/CEP,
        order numbers, product choices, dates, quantities);
      - every commitment the assistant made (promises, prices quoted, delivery
        windows, agreed next steps);
      - what was asked and is still unanswered (the missing information);
      - decisions already made, so nothing gets re-asked or re-litigated.

      Do not invent, do not editorialize, do not add advice. Answer with the
      summary text only — plain text, compact, in the conversation's own language.
    PROMPT

    # The compaction plan: summarize messages[from...upto] (from = the previous
    # boundary), keep messages[upto..] verbatim. count = upto - from.
    Plan = Data.define(:from, :upto, :count)

    module_function

    # Decides whether (and what) to compact. -> Plan | nil.
    #   messages: the session transcript (append-only, RFC-0016).
    #   state:    the persisted "compaction" hash ({"upto"=>, ...}) | nil.
    #   config:   the Settings "compaction" hash (keep_last/compact_after).
    # `compact_after` is clamped to at least `keep_last` so the plan always
    # moves the boundary forward. The boundary retreats over `role: "tool"`
    # messages so an eviction unit (assistant-with-tool_calls + its results)
    # is never split — the whole cycle stays verbatim instead.
    def plan(messages:, state:, config:)
      msgs = Array(messages)
      keep_last = positive(config && config["keep_last"], DEFAULT_KEEP_LAST)
      compact_after = positive(config && config["compact_after"], DEFAULT_COMPACT_AFTER)
      compact_after = keep_last if compact_after < keep_last
      from = state ? state["upto"].to_i : 0
      return nil unless msgs.size - from > compact_after

      upto = msgs.size - keep_last
      upto -= 1 while upto > from && role_of(msgs[upto]) == "tool"
      return nil unless upto > from

      Plan.new(from: from, upto: upto, count: upto - from)
    end

    # The full prompt for one compaction run: the base rules, the PREVIOUS
    # summary (so a fact from turn 3 survives every re-compaction — each
    # summary folds the last one in) and only the NEW slice. The slice is
    # sent UNREDACTED on purpose: it replaces transcript the main model
    # already reads raw, inside the same trust boundary, and redaction would
    # delete exactly the facts (CEP, order id) the summary must preserve.
    def prompt(messages:, plan:, previous: nil, base: nil)
      rules = Coercion.presence(base.to_s) || DEFAULT_PROMPT
      parts = [rules.rstrip]
      if Coercion.presence(previous.to_s)
        parts << "## The summary so far (fold it into the new one — its facts must survive)\n\n#{previous}"
      end
      parts << "## The messages to compact\n\n#{transcript(messages, plan)}"
      parts.join("\n\n")
    end

    # "[i] role: content" over the plan's slice, one line per message; a
    # tool-calling assistant message with no text renders the tool names.
    def transcript(messages, plan)
      Array(messages)[plan.from...plan.upto].to_a.each_with_index.map do |msg, offset|
        "[#{plan.from + offset}] #{role_of(msg)}: #{text_of(msg)}"
      end.join("\n")
    end

    def role_of(msg) = (msg["role"] || msg[:role]).to_s

    def text_of(msg)
      content = (msg["content"] || msg[:content]).to_s.strip.gsub(/\s+/, " ")
      if content.empty?
        calls = msg["tool_calls"] || msg[:tool_calls]
        names = Array(calls).filter_map { |c| c.is_a?(Hash) ? (c["name"] || c[:name] || c.dig("function", "name")) : nil }
        content = names.empty? ? "(empty)" : "(tool calls: #{names.join(', ')})"
      end
      content[0, MESSAGE_CHAR_CAP]
    end

    def positive(value, default)
      n = value.to_i
      n.positive? ? n : default
    end

    # The one place compaction asks a model for anything. Pure over an
    # injected `ask` (the Distiller shape); the real ask is a lambda built by
    # SummarizerFactory (ruby_llm required lazily, load_guard stays green).
    class Summarizer
      # A blank answer must not overwrite the boundary — empty output is a
      # loud failure, never "the old turns said nothing".
      class Unusable < Insika::ValidationError; end

      # ask:   ->(prompt) { "<raw model text>" } | something answering #content
      #        (+ #input_tokens/#output_tokens/#cached_tokens for cost).
      # model: the ref recorded on the event ("utility_model" default).
      attr_reader :model

      def initialize(ask:, model: "utility_model")
        @ask = ask
        @model = model.to_s
      end

      # -> { summary: String, cost: { "spent" => N, "cached" => N } | nil }
      # Raises Unusable on a blank answer; truncates past MAX_SUMMARY_CHARS.
      def summarize(prompt:)
        answer = @ask.call(prompt)
        text = Coercion.utf8(text_of(answer)).strip
        raise Unusable, "the summarizer answered with nothing" if text.empty?

        { summary: text[0, MAX_SUMMARY_CHARS], cost: cost_of(answer) }
      end

      private

      def text_of(answer) = (answer.respond_to?(:content) ? answer.content : answer).to_s

      # nil when the provider said nothing — never 0 (the Distiller's
      # discipline). The cached prefix is INCLUDED in the spent total.
      def cost_of(answer)
        return nil unless answer.respond_to?(:input_tokens) && answer.respond_to?(:output_tokens)

        input = answer.input_tokens.to_i
        output = answer.output_tokens.to_i
        cached = answer.respond_to?(:cached_tokens) ? answer.cached_tokens.to_i : 0
        { "spent" => input + output, "cached" => cached }
      end
    end

    # Resolves WHICH model summarizes and builds the ask. compaction.model ->
    # platform utility_model -> nil (nil means "feature inert", never a guess —
    # the DistillerFactory ladder). NOT the fallbacks chain: that one answers
    # "which model serves the customer turn". `ask_factory`/`llm` injectable (specs).
    module SummarizerFactory
      module_function

      # config: the Settings "compaction" hash. -> Summarizer | nil
      def build(config, utility_model: nil, ask_factory: nil, llm: nil)
        ref = Coercion.presence(config && config["model"]) || Coercion.presence(utility_model)
        return nil if ref.nil?

        provider, model = split_ref(ref)
        factory = ask_factory || ->(m, p) { ruby_llm_ask(m, p, llm: llm) }
        Summarizer.new(ask: factory.call(model, provider), model: ref)
      end

      # "provider/model" -> [provider, model]; "model" -> [nil, model] — one
      # syntax for "which model" across features (DistillerFactory's reading).
      def split_ref(ref)
        prov, name = ref.to_s.split("/", 2)
        name ? [prov, name] : [nil, prov]
      end

      # Temperature 0: the same slice must compact to the same boundary
      # deterministically. `ruby_llm` is required lazily so nothing loads a
      # provider gem until compaction is actually configured (load_guard stays green).
      def ruby_llm_ask(model, provider, llm: nil)
        require "ruby_llm"
        llm ||= RubyLLM
        lambda do |prompt|
          llm.chat(model: model, provider: provider, assume_model_exists: true)
             .with_temperature(0).ask(prompt)
        end
      end
    end
  end
end
