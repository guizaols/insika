# frozen_string_literal: true

require "json"

module Insika
  # the one place distillation asks a model for anything.
  #
  # The engine's generic prompt (what a durable customer fact is, the shape of
  # the answer, and the "never invent, never guess a scope" rules). A pack
  # `distill.prompt` REPLACES this wholesale (the forge's half) — the engine
  # never writes store vocabulary.
  module Distill
    DEFAULT_PROMPT = <<~PROMPT.freeze
      You are distilling durable facts about ONE customer from a finished
      conversation, for a shop assistant's memory. A fact is something that
      stays true across conversations: a size, a preference, a situation, an
      address. It is NOT the conversation itself, not a summary, and not a
      question.

      Answer with a single JSON array and NOTHING else. No prose, no fences.

      Rules:
      - Each element is an object with "name" (the fact's key, short, lowercase,
        underscore-separated), "value" (the fact's content, plain text), an
        optional "confidence" (a number between 0 and 1) and an optional "turns"
        (the message indexes in the transcript that support the fact).
      - Never invent: only facts the conversation actually supports.
      - Never guess a scope: you are not told any customer id or tenant — do not
        include one, the engine stamps it.
      - Fewer, better facts beat filling a quota.
    PROMPT

    # The SAFE-subset JSON Schema (object/array/string/number/integer + required
    # + items — workflow.rb:77's subset). The validator is permissive on unknown
    # keys, so the Distiller itself rejects a proposal carrying any key OUTSIDE
    # this set (D1 — a model-authored `scope` is a cross-tenant escape) and
    # counts the drop.
    PROPOSAL_SCHEMA = Insika::Workflow::Schema.coerce({
      "type" => "array",
      "items" => {
        "type" => "object",
        "properties" => {
          "name" => { "type" => "string" },
          "value" => { "type" => "string" },
          "confidence" => { "type" => "number" },
          "turns" => { "type" => "array", "items" => { "type" => "integer" } }
        },
        "required" => ["name", "value"]
      }
    })

    # The per-PROPOSAL half (an item of PROPOSAL_SCHEMA) — the Distiller
    # validates each element against THIS, not the whole-answer schema.
    ITEM_SCHEMA = Insika::Workflow::Schema.coerce(PROPOSAL_SCHEMA.json_schema["items"])

    # The model's answer, filtered into data the command then dedups and a human
    # then gates. Pure over an injected `ask` — the Refinement::Proposer shape:
    # unit-testable without a provider, and the real ask is a lambda built by
    # DistillerFactory (ruby_llm required lazily, load_guard stays green).
    class Distiller
      # A model that answers with prose instead of JSON produces NOTHING,
      # loudly — empty output must not read as "the traffic is clean".
      class Unusable < Insika::ValidationError; end

      MAX_NAME_LENGTH = 120
      MAX_VALUE_LENGTH = 500
      MAX_TURNS = 20
      ALLOWED_KEYS = %w[name value confidence turns].freeze
      # The E4 audit counters: schema (shape/type/confidence range), unknown_key
      # (a model-authored key — the D1 escape), oversized (length caps),
      # bad_turns (evidence indexes), duplicate (exact repeats), capped (a
      # survivor over max_proposals).
      DROP_KEYS = %w[schema unknown_key oversized bad_turns duplicate capped].freeze

      # ask:   ->(prompt) { "<raw model text>" } | something answering #content
      #        (+ #input_tokens/#output_tokens/#cached_tokens for cost).
      # model: the ref recorded in the events ("utility_model" default).
      attr_reader :model

      def initialize(ask:, model: "utility_model")
        @ask = ask
        @model = model.to_s
      end

      # -> { proposals: [{ "name", "value", "confidence"?, "turns"? }],
      #      dropped: { "schema" => N, "unknown_key" => N, "oversized" => N,
      #                 "bad_turns" => N, "duplicate" => N },
      #      cost: { "spent" => N, "cached" => N } | nil }
      # prompt: the pack prompt or DEFAULT_PROMPT (the caller resolved it).
      # message_count: the session transcript size — turns are validated
      #   against it (an index >= message_count drops the proposal).
      # max_proposals: cap on surviving proposals (the model may return more).
      # Drops are counted, never fixed up.
      def distill(prompt:, message_count:, max_proposals: 10)
        answer = @ask.call(prompt)
        raw = parse(text_of(answer))
        proposals = []
        dropped = DROP_KEYS.to_h { |k| [k, 0] }
        seen = {}
        raw.each do |item|
          verdict, reason = classify(item, message_count)
          case verdict
          when :keep
            tuple = [item["name"].to_s, item["value"].to_s]
            if seen[tuple]
              dropped["duplicate"] += 1
            elsif proposals.size >= max_proposals
              dropped["capped"] += 1
            else
              seen[tuple] = true
              proposals << normalize(item)
            end
          when :drop
            dropped[reason] += 1
          end
        end
        { proposals: proposals, dropped: dropped, cost: cost_of(answer) }
      end

      private

      def text_of(answer) = (answer.respond_to?(:content) ? answer.content : answer).to_s

      # nil when the provider said nothing — never 0 (the Proposer's
      # discipline). The cached prefix is INCLUDED in the spent total.
      def cost_of(answer)
        return nil unless answer.respond_to?(:input_tokens) && answer.respond_to?(:output_tokens)

        input = answer.input_tokens.to_i
        output = answer.output_tokens.to_i
        cached = answer.respond_to?(:cached_tokens) ? answer.cached_tokens.to_i : 0
        spent = input + output + cached
        spent.positive? ? { "spent" => spent, "cached" => cached } : nil
      end

      # Fences are stripped, the payload parsed STRICTLY: a model that
      # improvises a schema fails here instead of producing half a proposal.
      def parse(raw)
        body = raw.strip.gsub(/\A```(?:json)?\s*|\s*```\z/, "")
        parsed = JSON.parse(body)
        raise Unusable, "the distiller's answer is not an array" unless parsed.is_a?(Array)

        parsed
      rescue JSON::ParserError => e
        raise Unusable, "the distiller's answer is not valid JSON: #{e.message}"
      end

      # -> [:keep, nil] | [:drop, drop_key]. The order is the safety order:
      # unknown keys first (D1 — a model-authored scope is a cross-tenant
      # escape), then the turns bounds, then the schema, then the length and
      # confidence bounds. Turns are checked before the schema so a
      # non-integer / out-of-bounds index counts as bad_turns, never as a
      # generic schema miss.
      def classify(item, message_count)
        # a non-Hash element is a shape violation, never an "unknown key"
        return [:drop, "schema"] unless item.is_a?(Hash)
        return [:drop, "unknown_key"] unless (item.keys.map(&:to_s) - ALLOWED_KEYS).empty?

        turns = item["turns"]
        if turns
          return [:drop, "bad_turns"] if !turns.is_a?(Array) || turns.size > MAX_TURNS
          return [:drop, "bad_turns"] if turns.any? { |t| !t.is_a?(Integer) || t.negative? || t >= message_count }
        end

        unless ITEM_SCHEMA.call(item).success?
          return [:drop, "schema"]
        end

        name = item["name"].to_s
        value = item["value"].to_s
        return [:drop, "oversized"] if name.length > MAX_NAME_LENGTH || value.length > MAX_VALUE_LENGTH

        confidence = item["confidence"]
        if !confidence.nil? && (!confidence.is_a?(Numeric) || confidence.negative? || confidence > 1)
          return [:drop, "schema"]
        end

        [:keep, nil]
      end

      # The SAFE subset only — anything the model smuggled in extra keys
      # already dropped with the proposal.
      def normalize(item)
        item.slice("name", "value", "confidence", "turns")
      end
    end

    # Resolves WHICH model distills, and builds the ask. Profile -> platform
    # utility_model -> nil (D4 — nil means "feature inert", never a guess).
    # `ask_factory`/`llm` injectable (specs).
    module DistillerFactory
      module_function

      # config: the agent's `distill` hash. -> Distiller | nil
      def build(config, utility_model: nil, ask_factory: nil, llm: nil)
        ref = Coercion.presence(config && config["model"]) || Coercion.presence(utility_model)
        return nil if ref.nil?

        provider, model = split_ref(ref)
        factory = ask_factory || ->(m, p) { ruby_llm_ask(m, p, llm: llm) }
        Distiller.new(ask: factory.call(model, provider), model: ref)
      end

      # "provider/model" -> [provider, model]; "model" -> [nil, model] — the
      # ProposerFactory reading, one syntax for "which model" across features.
      def split_ref(ref)
        prov, name = ref.to_s.split("/", 2)
        name ? [prov, name] : [nil, prov]
      end

      # Temperature 0: a rejected fact must be re-proposable deterministically.
      # `ruby_llm` is required lazily so nothing loads a provider gem until a
      # distiller is actually configured (load_guard stays green).
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
