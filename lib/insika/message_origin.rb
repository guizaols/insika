# frozen_string_literal: true

module Insika
  # WHO PRODUCED A TRANSCRIPT MESSAGE — the field a `role` cannot carry.
  #
  # `role` says where a message sits in the conversation, not who wrote it, and the
  # two come apart constantly:
  #
  # · The engine delivers an async subagent's result to the parent as a NEW turn
  # a `user` message the engine wrote.
  # · A guardrail short-circuits with a safe reply — an `assistant` message produced
  #   with zero LLM calls.
  # · A consumer composes context blocks into the input it sends (`<memoria> …`,
  #   `<store_cep_required> …`) — a `user` message the customer never typed.
  # · In an imported transcript, a human operator types after a handoff — an
  #   `assistant` message no model produced.
  #
  # Reading a transcript without that distinction is not a rounding error. The first
  # refinement run over real traffic reported `repetition ×219` on one agent: every
  # one of them the engine reading its own injected fragment back and calling it a
  # customer repeating themselves (PR #133). That was filtered by a REGEX on the
  # leading tag, labelled in the code as a heuristic standing in for this field.
  #
  # ABSENT is the common case and stays valid forever: a message with no origin is
  # read as the natural producer for its role (`user` → the customer, `assistant` →
  # the agent). Nothing in the existing corpus, the stores or the pilot's database
  # has to be migrated, and a reader that ignores the field is exactly as correct as
  # it was before.
  module MessageOrigin
    KEY = "origin"

    CUSTOMER = "customer" # a person on the user side (the default for `user`)
    AGENT    = "agent"    # the model (the default for `assistant`)
    ENGINE   = "engine"   # Insika itself, or the consumer composing on its behalf
    OPERATOR = "operator" # a HUMAN on the assistant side (a handoff; set by importers)
    # RFC-0033: the FollowupEngine's synthetic turn — the engine's own kick,
    # never the customer. RESERVED: a consumer cannot declare it (the
    # SendMessage edge refuses the spelling — only the engine creates those
    # turns, D5).
    SCHEDULED = "scheduled"

    ALL = [CUSTOMER, AGENT, ENGINE, OPERATOR, SCHEDULED].freeze

    module_function

    # A declared origin, or nil. Anything outside the closed set is REFUSED rather
    # than stored: an unknown value would silently read as "absent" downstream, and
    # a typo'd marker is worse than none — it looks like the filtering is on.
    def parse!(value)
      return nil if Coercion.blank?(value)

      name = value.to_s.strip.downcase
      return name if ALL.include?(name)

      raise Insika::ValidationError,
            "unknown message origin: #{value.inspect} (expected #{ALL.join(', ')})"
    end

    # Did a PERSON on the user side write this? Absent origin = yes, because that is
    # what a `user` message meant before this field existed.
    def customer?(message)
      message["role"].to_s == "user" && [nil, CUSTOMER].include?(origin_of(message))
    end

    # Did the MODEL write this? Absent origin = yes, same reasoning.
    def agent?(message)
      message["role"].to_s == "assistant" && [nil, AGENT].include?(origin_of(message))
    end

    def origin_of(message)
      v = message[KEY] || message[KEY.to_sym]
      Coercion.presence(v)&.downcase
    end

    # Stamps a message hash, leaving it untouched when there is nothing to declare —
    # so the common turn keeps producing exactly the two-key shape it always did.
    def stamp(message, origin)
      origin.nil? ? message : message.merge(KEY => origin)
    end
  end
end
