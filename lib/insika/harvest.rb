# frozen_string_literal: true

require "json"

module Insika
  # the one place harvest asks a model for anything.
  #
  # The engine's generic prompt (what a harvestable skill is, the answer
  # shape, the provenance + grounding rules — "only reference IDs you saw in
  # the evidence; never invent a product"). A pack `harvest.prompt` REPLACES
  # this wholesale (the forge's half).
  module Harvest
    DEFAULT_PROMPT = <<~PROMPT.freeze
      You are mining SKILLS from finished customer-service conversations of ONE
      store agent, for a playbook the agent loads on demand. A skill is a
      reusable procedure: WHEN to load it and the exact steps to follow. It is
      NOT a fact about one customer, and NOT a rewrite of the agent's
      instructions.

      Answer with a single JSON array and NOTHING else. No prose, no fences.

      Each element is an object with:
      - "name" — the skill's key, short (max 64 chars), lowercase,
        underscore-separated;
      - "description" — one line (max 300 chars): what the skill is for;
      - "body" — the SKILL.md body (max 6000 chars): the procedure itself;
      - "triggers" — optional, up to 10 short words or phrases that should
        surface this skill;
      - "rationale" — optional, one line: what problem the skill solves;
      - "evidence_turns" — optional, the message indexes in the conversations
        that support it.

      Rules:
      - Reference products by their ID only — an ID you saw in the evidence.
        Never invent a SKU or a product name; the engine rejects anything it
        cannot verify (grounding).
      - Never include a session id, a customer id or a tenant — the engine
        stamps the origin itself.
      - A skill every good agent already does is not a skill worth proposing.
      - Fewer, better skills beat filling a quota.
    PROMPT

    # The safe-subset JSON Schema (array of objects — Workflow::Schema's
    # subset, the house zero-dep validator). The miner rejects any key OUTSIDE
    # this set and counts the drop: a model-authored `origin`/`agent` would be
    # a provenance lie — the schema refuses it by not having the key, and the
    # engine stamps origin itself.
    SKILL_SCHEMA = Insika::Workflow::Schema.coerce({
      "type" => "array",
      "items" => {
        "type" => "object",
        "properties" => {
          "name" => { "type" => "string" },
          "description" => { "type" => "string" },
          "body" => { "type" => "string" },
          "triggers" => { "type" => "array", "items" => { "type" => "string" } },
          "rationale" => { "type" => "string" },
          "evidence_turns" => { "type" => "array", "items" => { "type" => "integer" } }
        },
        "required" => %w[name description body]
      }
    })

    # The per-SKILL half (an item of SKILL_SCHEMA) — validated per element.
    ITEM_SCHEMA = Insika::Workflow::Schema.coerce(SKILL_SCHEMA.json_schema["items"])

    # The model's raw skills, filtered into data the command then filters
    # (negative list, grounding, dedup — C6) and a human then gates.
    # Pure over an injected `ask` — the Refinement::Proposer shape.
    class Miner
      # A model that answers with prose instead of JSON produces NOTHING,
      # loudly — empty output must not read as "the traffic is clean".
      class Unusable < Insika::ValidationError; end

      MAX_NAME = 64
      MAX_DESCRIPTION = 300
      MAX_BODY = 6000
      MAX_TRIGGERS = 10
      MAX_TRIGGER = 80
      MAX_RATIONALE = 500
      MAX_EVIDENCE_TURNS = 20
      # The window cap the RUN applies (C6): a candidate whose origin sessions
      # are a lie of provenance must never be stamped from a window of 50.
      MAX_SESSIONS = 5

      ALLOWED_KEYS = %w[name description body triggers rationale evidence_turns].freeze
      DROP_KEYS = %w[schema unknown_key oversized bad_turns duplicate capped].freeze
      # The A/B audit counters: the distinct drops a run records and the
      # first-10 audit reads back.

      # ask:   ->(prompt) { "<raw model text>" } | something answering #content
      #        (+ #input_tokens/#output_tokens/#cached_tokens for cost).
      # model: the ref recorded as the candidate's `proposer` ("utility_model"
      #        default).
      attr_reader :model

      def initialize(ask:, model: "utility_model")
        @ask = ask
        @model = model.to_s
      end

      # -> { skills: [ raw candidate hashes ],
      #      dropped: { "schema" => N, "unknown_key" => N, "oversized" => N,
      #                 "bad_turns" => N, "duplicate" => N, "capped" => N },
      #      cost: { "spent" => N, "cached" => N } | nil }
      # prompt: the pack prompt or DEFAULT_PROMPT (the caller resolved it).
      # message_counts: the origin sessions' transcript sizes, in prompt order,
      #   so `evidence_turns` indexes are validated against the sessions they
      #   name (an index is valid if it fits at least one session).
      # max_proposals: cap on surviving raw skills. Drops counted, never fixed.
      def mine(prompt:, message_counts:, max_proposals: 10)
        answer = @ask.call(prompt)
        raw = parse(text_of(answer))
        skills = []
        dropped = DROP_KEYS.to_h { |k| [k, 0] }
        seen = {}
        raw.each do |item|
          verdict, reason = classify(item, message_counts)
          case verdict
          when :keep
            tuple = [item["name"].to_s, item["description"].to_s, item["body"].to_s]
            if seen[tuple]
              dropped["duplicate"] += 1
            elsif skills.size >= max_proposals
              dropped["capped"] += 1
            else
              seen[tuple] = true
              skills << normalize(item)
            end
          when :drop
            dropped[reason] += 1
          end
        end
        { skills: skills, dropped: dropped, cost: cost_of(answer) }
      end

      private

      def text_of(answer) = (answer.respond_to?(:content) ? answer.content : answer).to_s

      # nil when the provider said nothing — never 0 (the Proposer's
      # discipline). The cached prefix is INCLUDED in the spent total (E1: the
      # run's cost is the harvest's only side spend).
      def cost_of(answer)
        return nil unless answer.respond_to?(:input_tokens) && answer.respond_to?(:output_tokens)

        input = answer.input_tokens.to_i
        output = answer.output_tokens.to_i
        cached = answer.respond_to?(:cached_tokens) ? answer.cached_tokens.to_i : 0
        spent = input + output + cached
        spent.positive? ? { "spent" => spent, "cached" => cached } : nil
      end

      # Fences stripped, parsed STRICTLY (the Proposer's discipline): a model
      # that improvises a schema fails here instead of producing half a skill.
      def parse(raw)
        body = raw.strip.gsub(/\A```(?:json)?\s*|\s*```\z/, "")
        parsed = JSON.parse(body)
        raise Unusable, "the miner's answer is not an array" unless parsed.is_a?(Array)

        parsed
      rescue JSON::ParserError => e
        raise Unusable, "the miner's answer is not valid JSON: #{e.message}"
      end

      # -> [:keep, nil] | [:drop, drop_key]. The safety order: unknown keys
      # first (a model-authored `origin` is a provenance lie), then the
      # evidence bounds, then the schema, then the length caps.
      def classify(item, message_counts)
        return [:drop, "schema"] unless item.is_a?(Hash)
        return [:drop, "unknown_key"] unless (item.keys.map(&:to_s) - ALLOWED_KEYS).empty?

        turns = item["evidence_turns"]
        if turns
          return [:drop, "bad_turns"] if !turns.is_a?(Array) || turns.size > MAX_EVIDENCE_TURNS
          span = Array(message_counts).map(&:to_i).max.to_i
          return [:drop, "bad_turns"] if turns.any? { |t| !t.is_a?(Integer) || t.negative? || (span.positive? && t >= span) }
        end

        unless ITEM_SCHEMA.call(item).success?
          return [:drop, "schema"]
        end

        return [:drop, "oversized"] if oversized?(item)

        [:keep, nil]
      end

      def oversized?(item)
        item["name"].to_s.length > MAX_NAME ||
          item["description"].to_s.length > MAX_DESCRIPTION ||
          item["body"].to_s.length > MAX_BODY ||
          item["rationale"].to_s.length > MAX_RATIONALE ||
          Array(item["triggers"]).size > MAX_TRIGGERS ||
          Array(item["triggers"]).any? { |t| t.to_s.length > MAX_TRIGGER }
      end

      # The SAFE subset only — anything the model smuggled in has already
      # dropped the skill.
      def normalize(item)
        item.slice(*ALLOWED_KEYS)
      end
    end

    # Resolves WHICH model mines, and builds the ask. Profile -> platform
    # utility_model -> nil (D12 — nil means "feature inert", never a guess).
    # `ask_factory`/`llm` injectable (specs).
    module MinerFactory
      module_function

      # config: the agent's `harvest` hash. -> Miner | nil
      def build(config, utility_model: nil, ask_factory: nil, llm: nil)
        ref = Coercion.presence(config && config.dig("miner", "model")) || Coercion.presence(utility_model)
        return nil if ref.nil?

        provider, model = split_ref(ref)
        factory = ask_factory || ->(m, p) { ruby_llm_ask(m, p, llm: llm) }
        Miner.new(ask: factory.call(model, provider), model: ref)
      end

      # "provider/model" -> [provider, model]; "model" -> [nil, model] — the
      # ProposerFactory reading, one syntax for "which model" across features.
      def split_ref(ref)
        prov, name = ref.to_s.split("/", 2)
        name ? [prov, name] : [nil, prov]
      end

      # Temperature 0: a rejected skill must be re-proposable deterministically.
      # `ruby_llm` is required lazily so nothing loads a provider gem until a
      # miner is actually configured (load_guard stays green).
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