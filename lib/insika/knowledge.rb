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

    # The layer-2 confidence formula: more independent sightings, more
    # confidence, never certainty. `confidence_for(1)` is the first-sighting
    # value PR 1 hardcoded (0.6) — spelled out here as the formula's own
    # degenerate case, not a separate constant to keep in sync.
    CONFIDENCE_BASE = 0.5
    CONFIDENCE_STEP = 0.1
    CONFIDENCE_CAP = 0.95
    def confidence_for(distinct_sources) = [CONFIDENCE_CAP, CONFIDENCE_BASE + (CONFIDENCE_STEP * distinct_sources)].min

    # A contradiction is never silently resolved into a confidence climb —
    # it is a flat drop, regardless of how confirmed the concept was before.
    CONTRADICTION_CONFIDENCE = 0.4
    CONTRADICTION_HEADING = "## Contradiction"

    # The ONE entry point every write path uses (the Executor's terminal
    # hook, the backfill CLI, and a Studio-authored concept). Decides
    # new/same/related/contradicting when `concept:<name>` already exists,
    # and stamps the result — the model never gets to (RFC's "provenance
    # only as ids" rule). The ONE place a concept's body is redacted (every
    # write goes through this, so a caller cannot forget).
    #
    # store:        KnowledgeStore.
    # concept:      {"name","description","type","body"} — the extractor's
    #               candidate; body not yet redacted.
    # consolidator: Consolidator | nil. nil = the conservative default: a
    #               differing body is always `:contradicting` (never
    #               silently overwritten) rather than spending a model call
    #               to guess.
    # -> { verdict: :new | :same | :related | :contradicting, name:, type: }
    def write_concept(store:, agent_id:, concept:, session_id:, tenant: nil, consolidator: nil)
      name = concept["name"].to_s
      redacted_body, = Insika::Safety::Detectors.redact(concept["body"].to_s)
      current = store.get(agent_id, name, tenant: tenant)

      if current.nil?
        store.write(agent_id, name, first_sighting(concept, redacted_body, session_id), tenant: tenant)
        return { verdict: :new, name: name, type: concept["type"].to_s }
      end

      existing = Concept.parse(current)
      if same_claim?(existing[:body], redacted_body)
        store.write(agent_id, name, bump(existing, session_id), tenant: tenant)
        return { verdict: :same, name: existing[:name], type: existing[:type] }
      end

      resolution = consolidator && consolidator.resolve(existing_body: existing[:body], new_body: redacted_body)
      if resolution && resolution[:verdict] == :related
        store.write(agent_id, name, merge(existing, resolution[:merged_body], session_id), tenant: tenant)
        { verdict: :related, name: existing[:name], type: existing[:type] }
      else
        store.write(agent_id, name, contradict(existing, redacted_body, session_id), tenant: tenant)
        { verdict: :contradicting, name: existing[:name], type: existing[:type] }
      end
    end

    def first_sighting(concept, redacted_body, session_id)
      now = Time.now.utc.iso8601
      Concept.render(
        name: concept["name"], description: concept["description"], type: concept["type"], body: redacted_body,
        provenance: "observed", confidence: confidence_for(1), sources: [session_id.to_s], occurrences: 1,
        created_at: now, updated_at: now
      )
    end

    # Same claim, reworded or reconfirmed: the body stays (no operator edit
    # is silently discarded by a repeat sighting), only the evidence grows.
    def bump(existing, session_id)
      sources = (existing[:sources] + [session_id.to_s]).uniq
      Concept.render(
        name: existing[:name], description: existing[:description], type: existing[:type], body: existing[:body],
        provenance: "observed", confidence: confidence_for(sources.size), sources: sources,
        occurrences: existing[:occurrences] + 1, created_at: existing[:created_at], updated_at: Time.now.utc.iso8601
      )
    end

    # Related claim: the consolidator's merged text replaces the body — the
    # only branch where a second model call decided the wording.
    def merge(existing, merged_body, session_id)
      sources = (existing[:sources] + [session_id.to_s]).uniq
      Concept.render(
        name: existing[:name], description: existing[:description], type: existing[:type], body: merged_body,
        provenance: "observed", confidence: confidence_for(sources.size), sources: sources,
        occurrences: existing[:occurrences] + 1, created_at: existing[:created_at], updated_at: Time.now.utc.iso8601
      )
    end

    # Contradicting claim: never overwritten. The new claim joins the body
    # under a heading a human resolves in the Studio; occurrences do NOT
    # bump (a conflict is not a confirmation), but the sighting still joins
    # `sources` for the audit trail.
    def contradict(existing, new_body, session_id)
      sources = (existing[:sources] + [session_id.to_s]).uniq
      body = "#{existing[:body]}\n\n#{CONTRADICTION_HEADING}\n\n#{new_body}"
      Concept.render(
        name: existing[:name], description: existing[:description], type: existing[:type], body: body,
        provenance: "observed", confidence: CONTRADICTION_CONFIDENCE, sources: sources,
        occurrences: existing[:occurrences], created_at: existing[:created_at], updated_at: Time.now.utc.iso8601
      )
    end

    # Normalized equality (strip/downcase/collapse whitespace) — cheap and
    # deterministic, no model call spent confirming a reworded repeat.
    def same_claim?(a, b) = normalize_claim(a) == normalize_claim(b)
    def normalize_claim(text) = text.to_s.strip.downcase.gsub(/\s+/, " ")

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

    # The "second LLM call" §3.5 describes — spent ONLY when a concept name
    # already exists AND the new sighting's body differs from the stored one
    # (the cheap same-claim check in `Knowledge.write_concept` already
    # handled the identical-reworded case without a call). ONE call decides
    # AND merges together: `Workflow::Schema` cannot express "merged_body
    # required only if verdict==related", so the schema only requires
    # `verdict` and a Ruby check afterward treats a missing/oversized
    # `merged_body` on a "related" answer as unusable.
    #
    # `resolve` never raises: any parse/schema failure — or simply not being
    # configured — resolves to `{verdict: :contradicting}`, the safe default
    # when the engine cannot tell. A guess that risks merging two genuinely
    # different claims into one confident-sounding lie is the worse failure
    # mode; a conflict a human has to look at is not.
    class Consolidator
      class Unusable < Insika::ValidationError; end

      DEFAULT_PROMPT = <<~PROMPT.freeze
        You are comparing two claims about the SAME concept in a store's
        knowledge base — an existing one already on record, and a new one
        just observed in a conversation.

        Answer with a single JSON object and NOTHING else. No prose, no fences.

        - If the two claims are COMPATIBLE — they can be combined into one
          coherent statement without losing or inventing anything either one
          said — answer {"verdict": "related", "merged_body": "<the merged
          claim, in your own words, max 2000 chars>"}.
        - If they state genuinely DIFFERENT things and merging would hide a
          real change or disagreement, answer {"verdict": "contradicting"}.

        When unsure, prefer "contradicting" — a human resolves it; a wrong
        merge would state something nobody actually confirmed.
      PROMPT

      VERDICT_SCHEMA = Insika::Workflow::Schema.coerce({
        "type" => "object",
        "properties" => {
          "verdict" => { "type" => "string" },
          "merged_body" => { "type" => "string" }
        },
        "required" => ["verdict"]
      })

      MAX_MERGED_BODY = 2000

      attr_reader :model

      def initialize(ask:, model: "utility_model")
        @ask = ask
        @model = model.to_s
      end

      # -> { verdict: :related, merged_body: String } | { verdict: :contradicting }
      def resolve(existing_body:, new_body:)
        answer = @ask.call(prompt_for(existing_body, new_body))
        parsed = parse(text_of(answer))
        raise Unusable, "not a JSON object" unless VERDICT_SCHEMA.call(parsed).success?

        classify(parsed)
      rescue Unusable
        { verdict: :contradicting }
      end

      private

      def classify(parsed)
        return { verdict: :contradicting } unless parsed["verdict"].to_s == "related"

        merged = parsed["merged_body"].to_s
        return { verdict: :contradicting } if merged.strip.empty? || merged.length > MAX_MERGED_BODY

        { verdict: :related, merged_body: merged }
      end

      def text_of(answer) = (answer.respond_to?(:content) ? answer.content : answer).to_s

      def parse(raw)
        body = raw.strip.gsub(/\A```(?:json)?\s*|\s*```\z/, "")
        parsed = JSON.parse(body)
        raise Unusable, "the consolidator's answer is not an object" unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        raise Unusable, "the consolidator's answer is not valid JSON"
      end

      def prompt_for(existing_body, new_body)
        <<~PROMPT
          #{DEFAULT_PROMPT}

          ## Existing claim

          #{existing_body}

          ## New claim

          #{new_body}
        PROMPT
      end
    end

    # Resolves WHICH model consolidates — the same slot the extractor uses
    # (a deployment names one `knowledge.model`, not two). Reuses
    # `ExtractorFactory`'s ref-parsing and lazy ruby_llm ask builder rather
    # than duplicating them (both live in this same module).
    module ConsolidatorFactory
      module_function

      # config: the agent's `knowledge` hash. -> Consolidator | nil
      def build(config, utility_model: nil, ask_factory: nil, llm: nil)
        ref = Coercion.presence(config && config["model"]) || Coercion.presence(utility_model)
        return nil if ref.nil?

        provider, model = ExtractorFactory.split_ref(ref)
        factory = ask_factory || ->(m, p) { ExtractorFactory.ruby_llm_ask(m, p, llm: llm) }
        Consolidator.new(ask: factory.call(model, provider), model: ref)
      end
    end
  end
end
