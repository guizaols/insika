# frozen_string_literal: true

module Insika
  # WS4: intent routing as DATA. When `AgentProfile#routes` is present, the
  # turn's message is classified into one of the configured routes with a cheap
  # model BEFORE the agent chat is assembled. This class owns the PURE parts —
  # normalizing the route config, generating the classifier prompt from the
  # route descriptions, and parsing the model's answer back into a route — so
  # they are testable without a provider. The ask itself and its usage are the
  # Executor's (a pre-stage call counted in the turn's usage and trace).
  #
  # Config shape (string keys at the persistence boundary — the pack and the
  # Studio store it like any other free-form hash):
  #
  #   { "shopping" => "the customer wants to browse products",
  #     "order"    => { "description" => "asks about an existing order",
  #                     "delegate" => "order-agent" },     # hand the turn to that agent
  #     "human"    => { "description" => "the customer is frustrated or asks for a person",
  #                     "stuck" => true, "message" => "..." }, # end the turn :stuck (WS5)
  #     "default"  => "shopping",                            # deterministic fallback
  #     "model"    => "deepseek-v4-flash" }                  # the CHEAP classifier
  #
  # `default`/`model`/`provider` are reserved top-level keys; everything else is
  # a route name (single token). A route value is a description String or a Hash
  # with `description` + optional `delegate` (an existing agent the turn is
  # handed to) / `stuck` (the turn ends with the WS5 stuck outcome) / `message`
  # (the consumer-facing lead-in for a stuck route).
  class Routing
    RESERVED = %w[model provider default].freeze
    # A name the classifier can actually answer with: one lowercase token.
    NAME = /\A[a-z0-9][a-z0-9_-]*\z/
    # The turn's usage fields the classifier call can contribute.
    TOKEN_FIELDS = %i[input_tokens output_tokens cached_tokens cache_creation_tokens total_tokens].freeze

    Entry = Data.define(:name, :description, :delegate, :stuck, :message)

    class << self
      # -> { entries: [Entry], default: String, model: String, provider: String }
      # | nil (routes absent/empty = routing off). Raises ValidationError on a
      # route name the classifier could never answer with (spaces/symbols) or on
      # a config with zero routes — a routing config that silently routes nothing
      # is a config error, not a quiet off.
      def normalize(routes)
        return nil unless routes.is_a?(Hash) && !routes.empty?

        bad = routes.keys.map(&:to_s).reject { |k| RESERVED.include?(k) || k.match?(NAME) }
        unless bad.empty?
          raise Insika::ValidationError,
                "route names may not contain spaces or symbols: #{bad.join(', ')}"
        end

        entries = routes.each_with_object([]) do |(name, value), acc|
          next if RESERVED.include?(name.to_s)

          cfg = value.is_a?(Hash) ? stringify(value) : { "description" => value.to_s }
          acc << Entry.new(name: name.to_s, description: cfg["description"].to_s,
                           delegate: cfg["delegate"].to_s, stuck: cfg["stuck"] == true,
                           message: cfg["message"].to_s)
        end
        raise Insika::ValidationError, "routes must define at least one route" if entries.empty?

        default = routes["default"].to_s
        default = entries.first.name if default.empty?
        unless entries.any? { |e| e.name == default }
          raise Insika::ValidationError,
                "default route '#{default}' is not a configured route"
        end
        { entries: entries, default: default,
          model: routes["model"].to_s, provider: routes["provider"].to_s }
      end

      # The classifier's instructions, auto-generated from the route descriptions
      # (config-over-code: no per-route prompt file).
      def classifier_prompt(meta)
        lines = meta[:entries].map do |e|
          "-#{e.name}: #{e.description.empty? ? e.name : e.description}"
        end
        <<~PROMPT
          Classify the customer's message into exactly one of these intents.
          Reply with ONLY the intent name — nothing else.

          #{lines.join("\n")}
        PROMPT
      end

      # -> Symbol: the route the model named; the DEFAULT when it named nothing
      # usable (prose, punctuation, an unknown name, empty). Deterministic by
      # construction — a chatty or confused classifier can never invent a route.
      def parse(text, meta)
        token = text.to_s.strip.split(/\s+/).first.to_s.downcase
                    .delete_suffix(".").delete_suffix(",")
        names = meta[:entries].map(&:name)
        (names.include?(token) ? token : meta[:default]).to_sym
      end
    end

    def self.stringify(hash)
      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end
  end
end
