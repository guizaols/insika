# frozen_string_literal: true

module Insika
  module Evals
    # A SIMULATED CUSTOMER — the data that turns a scripted case into a
    # generated conversation (RFC-0014 PR2). Pure data: goal, style, the opening
    # message, the ONLY facts the persona may assert, and a hard turn cap. The
    # persona is played by a model (the cheap utility_model) with this as its whole
    # instruction; the anti-invention rule below is the soul of the feature — a
    # simulator that invents an order number produces a conversation the agent
    # could never have had, and a case that tests nothing.
    Persona = Struct.new(:goal, :style, :opens_with, :knows, :max_turns, keyword_init: true) do
      def to_h
        { "goal" => goal, "style" => style, "opens_with" => opens_with,
          "knows" => knows, "max_turns" => max_turns }.compact
      end

      # The persona as a whole instruction. The `knows` facts are the ONLY
      # assertions the persona may make; anything else is answered with
      # ignorance — "não sei", "não tenho isso aqui" — exactly like a real
      # customer who does not have the fact. `transcript` is the conversation
      # so far, in order, as [{ role: "user"|"assistant", text: }].
      def prompt(transcript)
        facts = knows.map { |k, v| "- #{k}: #{v}" }.join("\n")
        <<~PROMPT
          You are simulating a customer in a chat with a store's virtual assistant.
          Stay in character. You are not helping the assistant; you are the person
          it serves.

          GOAL: #{goal}
          STYLE: #{style || "short, natural messages; answers what is asked"}

          FACTS YOU KNOW — the ONLY facts you may assert:
          #{facts}

          RULES:
          1. You may ONLY assert the facts above. Asked about anything else, you do
             not know it — answer with ignorance, like a real customer without that
             fact (you have no order number, no name, no date, no price beyond the
             facts above). Never invent an order number, a name, a date, a price or
             any other detail that is not in FACTS YOU KNOW.
          2. Reply with ONLY the customer's next message.
          3. When your goal has been met, end the message with the marker
             <<goal_met>>. When you give up (the assistant cannot get you there),
             end the message with the marker <<gave_up>>. Otherwise end with no
             marker.

          CONVERSATION SO FAR:
          #{transcript.map { |m| "#{m[:role]}: #{m[:text]}" }.join("\n")}

          Your next message:
        PROMPT
      end
    end

    # Loads + validates a persona mapping (the `persona:` key of a golden, or the
    # `--persona` file of the simulate CLI). Fails LOUD on a malformed persona —
    # a silently relaxed max_turns or a missing knows would produce a simulation
    # that tests nothing.
    module PersonaLoader
      class InvalidPersona < StandardError; end

      module_function

      def build(raw, source: "(inline)")
        raise InvalidPersona, "#{source}: persona must be a mapping" unless raw.is_a?(Hash)

        goal = presence(raw["goal"])
        raise InvalidPersona, "#{source}: persona needs a non-empty 'goal'" if goal.nil?

        knows = raw["knows"]
        unless knows.is_a?(Hash) && !knows.empty?
          raise InvalidPersona, "#{source}: persona needs a non-empty 'knows' mapping (the only facts it may assert)"
        end

        opens = presence(raw["opens_with"])
        raise InvalidPersona, "#{source}: persona needs a non-empty 'opens_with'" if opens.nil?

        max = raw["max_turns"]
        unless max.is_a?(Integer) && max.positive?
          raise InvalidPersona, "#{source}: persona needs 'max_turns' as a positive integer"
        end

        Persona.new(
          goal: goal, style: presence(raw["style"]),
          opens_with: opens,
          knows: knows.transform_keys(&:to_s).transform_values(&:to_s),
          max_turns: max
        )
      end

      def presence(v)
        s = v.to_s.strip
        s.empty? ? nil : s
      end
    end
  end
end