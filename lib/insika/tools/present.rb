# frozen_string_literal: true

require "ruby_llm"

module Insika
  module Tools
    # PRESENTATION tool: the model says WHICH products to show, the engine decides
    # WHAT is shown. Built by the overlay registry from a ToolDefinition that
    # declares `presentation` (one class, N instances — like DataDefinedTool).
    #
    # Cards used to be a side effect of evidence: every attachment a search tool
    # returned rode the channel delivery, all of them, and the model had no way to
    # say "these three, not the ten I searched". The deployments compensated with
    # inline markers in the text, parsed by regex on their side — where most of
    # the hallucinated ids came from. Here text never carries product data: the
    # model picks ids, and the engine
    #   1. keeps only ids the session's evidence ledger has seen (provenance),
    #   2. joins each to the card the evidence tool already hoarded this turn,
    #   3. caps at the declared `max`,
    #   4. records the selection on the turn (the delivery sends THAT),
    #   5. emits `:ui` on the stream (the edge publishes it as `insika.ui`),
    #   6. tells the model what was shown and what was dropped, and why.
    # No HTTP, no model call, deterministic. `execute` never raises.
    class Present < RubyLLM::Tool
      # The one sentence for the model when NOTHING could be shown. Engine-generic:
      # the pack tunes vocabulary through the tool's `description`.
      NOTHING_SHOWN = "no card could be shown; name the products in text or search again"

      def initialize(definition:, event_stream: nil)
        @definition = definition
        @event_stream = event_stream
        @state = nil
        super()
      end

      # Deposited by ToolAssembly before the envelope wraps the instance — the
      # ledger and the hoarded cards live on the turn, never on the registry.
      def turn_state=(state)
        @state = state
      end

      def name = @definition.name
      def description = @definition.description
      def parameters_schema = @definition.parameters

      def execute(**kwargs)
        spec = @definition.presentation
        ids = Array(kwargs[spec[:ids].to_sym]).map(&:to_s).reject(&:empty?).uniq
        title = Coercion.presence(kwargs[:title])

        shown, dropped = select(ids, spec[:max])
        record(spec[:component], title, shown)
        emit(spec[:component], title, shown, dropped)

        out = { "shown" => shown.map { |c| c["id"] }, "dropped" => dropped }
        out["instruction"] = NOTHING_SHOWN if shown.empty?
        out
      rescue StandardError => e
        { error: "presentation failed: #{e.message}" }
      end

      private

      # -> [shown cards, dropped [{id, reason}]]. Order preserved. Reasons:
      #   unknown — the ledger never saw the id (the model made it up, or the
      #             customer typed it); no ledger on the state reads as unknown too —
      #             a check that cannot verify does not pass.
      #   no_card — the id is known but no evidence tool returned a card for it
      #             this session (a text-only search result, or a seed of ids alone).
      #   max     — beyond the declared cap.
      # Cards come from this turn first, then from the ledger (the last few
      # searches of the session) — "show me the second one" a turn later works.
      def select(ids, max)
        ledger = @state.respond_to?(:evidence_ledger) ? @state.evidence_ledger : nil
        known = Array(ledger&.ids)
        turn_cards = @state.respond_to?(:evidence_attachments) ? Array(@state.evidence_attachments) : []
        session_cards = ledger.respond_to?(:cards) ? Array(ledger.cards) : []
        by_id = (turn_cards + session_cards).each_with_object({}) { |c, h| h[c["id"]] ||= c if c["id"] }

        shown = []
        dropped = []
        ids.each do |id|
          if !known.include?(id) then dropped << { "id" => id, "reason" => "unknown" }
          elsif (card = by_id[id]).nil? then dropped << { "id" => id, "reason" => "no_card" }
          elsif shown.size >= max then dropped << { "id" => id, "reason" => "max" }
          else shown << card
          end
        end
        [shown, dropped]
      end

      def record(component, title, shown)
        return unless @state.respond_to?(:presentations)

        @state.presentations ||= []
        @state.presentations << { "component" => component, "title" => title,
                                  "items" => shown.map { |c| c.slice("id", "type", "url", "caption") } }
      end

      def emit(component, title, shown, dropped)
        return unless @event_stream

        task = @state.respond_to?(:task) ? @state.task : nil
        meta = task ? { task_id: task.id, session_id: task.session_id } : {}
        @event_stream.emit(Insika::Event.new(
                             type: :ui,
                             data: { component: component, title: title,
                                     items: shown.map { |c| c.slice("id", "type", "url", "caption") },
                                     count: shown.size, dropped: dropped },
                             meta: meta
                           ))
      end
    end
  end
end
