# frozen_string_literal: true

require "json"
require "time"

module Insika
  # the one place knowledge extraction asks a model for anything, and the
  # concept format itself (markdown + YAML frontmatter, the same shape a
  # SKILL.md uses).
  #
  # The engine's generic prompt (what a concept worth keeping is, the answer
  # shape, the "never invent, never state as policy" rules). A pack
  # `knowledge.prompt` REPLACES this wholesale (the forge's half), like
  # `distill.prompt` / `harvest.prompt`.
  module Knowledge
    DEFAULT_TYPES = %w[fact entity procedure policy objection].freeze

    DEFAULT_PROMPT = <<~PROMPT.freeze
      You are extracting durable KNOWLEDGE from one finished conversation, for
      a store agent's shared memory. A concept is something worth remembering
      across DIFFERENT conversations: a policy, a recurring question, an
      objection customers raise, a fact about how the business operates. It
      is NOT a fact about one customer (that belongs to per-customer memory)
      and NOT a summary of this conversation.

      Answer with a single JSON array and NOTHING else. No prose, no fences.

      Each element is an object with:
      - "name" — a short, lowercase, hyphen-separated slug (max 80 chars);
      - "description" — one line (max 300 chars): what the concept says;
      - "type" — one of: fact, entity, procedure, policy, objection;
      - "body" — the concept's content (max 2000 chars): the durable claim,
        in your own words, plus `[[other-concept-name]]` links to any related
        concept you are also proposing in this same answer.

      Rules:
      - Never invent: only concepts the conversation actually supports.
      - Never state something the agent merely PROMISED as if it were
        official policy — describe it as what was said, not as a guarantee.
      - Never include a customer id, a session id or anything that identifies
        one person — the engine stamps provenance itself.
      - A concept every good agent already assumes is not worth proposing.
      - Fewer, better concepts beat filling a quota.
    PROMPT

    # The safe-subset JSON Schema (Workflow::Schema, the house zero-dep
    # validator). Anything outside this set — a model-authored `provenance`,
    # `confidence`, `sources`, `occurrences` — is a provenance lie: the schema
    # refuses it by not having the key, and the extractor drops+counts it
    # rather than trusting the model's self-assessment (RFC's "provenance
    # only as ids" rule, enforced here, not just documented).
    CONCEPT_SCHEMA = Insika::Workflow::Schema.coerce({
      "type" => "array",
      "items" => {
        "type" => "object",
        "properties" => {
          "name" => { "type" => "string" },
          "description" => { "type" => "string" },
          "type" => { "type" => "string" },
          "body" => { "type" => "string" }
        },
        "required" => %w[name description type body]
      }
    })

    ITEM_SCHEMA = Insika::Workflow::Schema.coerce(CONCEPT_SCHEMA.json_schema["items"])

    module_function

    # Stamps a model-proposed concept (a Hash with "name"/"description"/
    # "type"/"body") with the fields the model never supplies — provenance,
    # confidence, sources, occurrences, timestamps — and renders it as the
    # complete concept markdown, ready for `KnowledgeStore#write`. The ONE
    # place a concept's body is redacted (RFC's PII rule: every write goes
    # through this, so a caller cannot forget).
    #
    # Layer 1 only: every write is treated as a first sighting — one source,
    # the layer-2 confidence formula (`min(0.95, 0.5 + 0.1 x distinct_sources)`)
    # evaluated at distinct_sources = 1. Consolidating repeat sightings
    # (merged sources/occurrences, a real confidence climb) is layer 2 — not
    # this method's job.
    def stamp_and_render(concept, session_id:)
      body, = Insika::Safety::Detectors.redact(concept["body"].to_s)
      now = Time.now.utc.iso8601
      Concept.render(
        name: concept["name"], description: concept["description"], type: concept["type"], body: body,
        provenance: "observed", confidence: 0.6, sources: [session_id.to_s], occurrences: 1,
        created_at: now, updated_at: now
      )
    end

    # The concept format: markdown with a YAML frontmatter block, parsed and
    # rendered with the SAME split `SkillCatalog#parse_content` uses, so the
    # Studio's existing markdown editor already curates it.
    module Concept
      module_function

      NAME_RE = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

      # -> { name:, description:, type:, body:, provenance:, confidence:,
      #      sources:, occurrences:, created_at:, updated_at: } | nil
      def parse(raw)
        match = raw.to_s.match(/\A---\s*\n(.*?)\n---\s*\n(.*)\z/m)
        return nil unless match

        meta = Insika::Frontmatter.parse(match[1])
        name = Coercion.presence(meta["name"])
        return nil unless name

        {
          name: name.to_s, description: meta["description"].to_s, type: meta["type"].to_s,
          provenance: meta["provenance"].to_s, confidence: meta["confidence"].to_f,
          sources: Array(meta["sources"]).map(&:to_s), occurrences: meta["occurrences"].to_i,
          created_at: meta["created_at"].to_s, updated_at: meta["updated_at"].to_s,
          body: match[2].strip
        }
      end

      # Renders the complete concept markdown. Every field but `body` is
      # engine-stamped (never the model's own words) — see `Extractor`.
      def render(name:, description:, type:, body:, provenance:, confidence:, sources:, occurrences:,
                 created_at:, updated_at:)
        frontmatter = {
          "name" => name, "description" => description, "type" => type,
          "provenance" => provenance, "confidence" => confidence.round(2),
          "sources" => Array(sources), "occurrences" => occurrences,
          "created_at" => created_at, "updated_at" => updated_at
        }
        yaml = frontmatter.map { |k, v| "#{k}: #{v.to_json}" }.join("\n")
        "---\n#{yaml}\n---\n\n#{body}\n"
      end
    end

    # The model's raw concepts, filtered into data the caller stamps with
    # provenance and persists. Pure over an injected `ask` — the
    # Distiller/Miner shape: unit-testable without a provider.
    class Extractor
      # A model that answers with prose instead of JSON produces NOTHING,
      # loudly — empty output must not read as "the turn taught nothing".
      class Unusable < Insika::ValidationError; end

      MAX_NAME = 80
      MAX_DESCRIPTION = 300
      MAX_BODY = 2000
      ALLOWED_KEYS = %w[name description type body].freeze
      # The audit counters: schema (shape/type miss), unknown_key (a
      # model-authored provenance/confidence/sources — the escape this
      # extractor exists to block), bad_type (outside the configured
      # allowlist), oversized (length caps), duplicate (exact repeats within
      # the batch), capped (a survivor over max_concepts).
      DROP_KEYS = %w[schema unknown_key bad_type oversized duplicate capped].freeze

      attr_reader :model, :types

      # ask:   ->(prompt) { "<raw model text>" } | something answering #content
      #        (+ #input_tokens/#output_tokens/#cached_tokens for cost).
      # model: the ref recorded on the concept's provenance ("utility_model"
      #        default).
      # types: the allowed concept types (the profile's `knowledge.types`,
      #        default DEFAULT_TYPES) — a type outside this set is dropped,
      #        never silently reclassified.
      def initialize(ask:, model: "utility_model", types: DEFAULT_TYPES)
        @ask = ask
        @model = model.to_s
        @types = Array(types).map(&:to_s)
      end

      # -> { concepts: [{ "name", "description", "type", "body" }],
      #      dropped: { "schema" => N, "unknown_key" => N, "bad_type" => N,
      #                 "oversized" => N, "duplicate" => N, "capped" => N },
      #      cost: { "spent" => N, "cached" => N } | nil }
      def extract(prompt:, max_concepts: 10)
        answer = @ask.call(prompt)
        raw = parse(text_of(answer))
        concepts = []
        dropped = DROP_KEYS.to_h { |k| [k, 0] }
        seen = {}
        raw.each do |item|
          verdict, reason = classify(item)
          case verdict
          when :keep
            tuple = [item["name"].to_s, item["body"].to_s]
            if seen[tuple]
              dropped["duplicate"] += 1
            elsif concepts.size >= max_concepts
              dropped["capped"] += 1
            else
              seen[tuple] = true
              concepts << normalize(item)
            end
          when :drop
            dropped[reason] += 1
          end
        end
        { concepts: concepts, dropped: dropped, cost: cost_of(answer) }
      end

      private

      def text_of(answer) = (answer.respond_to?(:content) ? answer.content : answer).to_s

      def cost_of(answer)
        return nil unless answer.respond_to?(:input_tokens) && answer.respond_to?(:output_tokens)

        input = answer.input_tokens.to_i
        output = answer.output_tokens.to_i
        cached = answer.respond_to?(:cached_tokens) ? answer.cached_tokens.to_i : 0
        spent = input + output + cached
        spent.positive? ? { "spent" => spent, "cached" => cached } : nil
      end

      # Fences stripped, parsed STRICTLY: a model that improvises a schema
      # fails here instead of producing half a concept, never persisted
      # half-parsed.
      def parse(raw)
        body = raw.strip.gsub(/\A```(?:json)?\s*|\s*```\z/, "")
        parsed = JSON.parse(body)
        raise Unusable, "the extractor's answer is not an array" unless parsed.is_a?(Array)

        parsed
      rescue JSON::ParserError => e
        raise Unusable, "the extractor's answer is not valid JSON: #{e.message}"
      end

      # -> [:keep, nil] | [:drop, drop_key]. Unknown keys first (a
      # model-authored provenance/confidence/sources is the escape this
      # extractor exists to block), then the schema, then the type allowlist,
      # then the length caps.
      def classify(item)
        return [:drop, "schema"] unless item.is_a?(Hash)
        return [:drop, "unknown_key"] unless (item.keys.map(&:to_s) - ALLOWED_KEYS).empty?
        return [:drop, "schema"] unless ITEM_SCHEMA.call(item).success?
        return [:drop, "bad_type"] unless @types.include?(item["type"].to_s)

        name = item["name"].to_s
        return [:drop, "schema"] unless Concept::NAME_RE.match?(name)
        return [:drop, "oversized"] if oversized?(item)

        [:keep, nil]
      end

      def oversized?(item)
        item["name"].to_s.length > MAX_NAME ||
          item["description"].to_s.length > MAX_DESCRIPTION ||
          item["body"].to_s.length > MAX_BODY
      end

      # The SAFE subset only — anything the model smuggled in has already
      # dropped the concept.
      def normalize(item) = item.slice(*ALLOWED_KEYS)
    end

    # Resolves WHICH model extracts, and builds the ask. Profile -> platform
    # utility_model -> nil (nil means "feature inert", never a guess).
    # `ask_factory`/`llm` injectable (specs).
    module ExtractorFactory
      module_function

      # config: the agent's `knowledge` hash. -> Extractor | nil
      def build(config, utility_model: nil, ask_factory: nil, llm: nil)
        ref = Coercion.presence(config && config["model"]) || Coercion.presence(utility_model)
        return nil if ref.nil?

        provider, model = split_ref(ref)
        types = Array(config && config["types"]).map(&:to_s)
        types = DEFAULT_TYPES if types.empty?
        factory = ask_factory || ->(m, p) { ruby_llm_ask(m, p, llm: llm) }
        Extractor.new(ask: factory.call(model, provider), model: ref, types: types)
      end

      # "provider/model" -> [provider, model]; "model" -> [nil, model].
      def split_ref(ref)
        prov, name = ref.to_s.split("/", 2)
        name ? [prov, name] : [nil, prov]
      end

      # Temperature 0: extraction should be deterministic for the same turn.
      # `ruby_llm` required lazily so nothing loads a provider gem until an
      # extractor is actually configured (load_guard stays green).
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
