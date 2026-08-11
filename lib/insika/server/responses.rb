# frozen_string_literal: true

require "json"

module Insika
  module Server
    # OpenAI Responses edge adapter (`/v1/responses`) — the contract that
    # OpenClaw gateway consumers already speak.
    #
    # PURE module (no state, no framework): (a) translates the OpenAI
    # Responses request → `:send_message` payload; (b) maps each turn Event →
    # OpenAI Responses SSE frame (or nil for events with no counterpart). Follows the
    # constitutional rule: no business logic, no store access here.
    #
    # Request: { model: "openclaw:<agent>", user: "<chat.id>", stream: true,
    #            input: "<string with already-composed blocks>" } + header
    # X-Openclaw-Agent (agent fallback). The `input` enters VERBATIM as the
    # turn's message — the blocks (<memoria>/<dados_conhecidos>/directives) already come
    # composed by the consumer (the engine does not interpret them).
    module Responses
      module_function

      # -> { agent:, user:, message:, origin? } | raise ValidationError.
      #
      # `origin` is the consumer declaring WHO wrote the input it is sending. It
      # matters here more than anywhere: this adapter's `input` is a STRING the
      # consumer already composed out of context blocks plus the customer's text
      # (`<memoria> …`, `<store_cep_required> …`), so a transcript reader cannot
      # tell the two apart — the first refinement run over real traffic reported 219
      # "the customer repeated themselves" that were the engine reading its own
      # fragment back. A consumer that sends `origin: "engine"` on a composed turn
      # gets that filtered structurally instead of by a regex on the leading tag.
      # Omitted = a customer typed it, which is what every turn meant before.
      def parse_request(body, req)
        agent = body[:model].to_s.sub(/\Aopenclaw:/, "")
        agent = req.get_header("HTTP_X_OPENCLAW_AGENT").to_s if agent.empty?
        raise Insika::ValidationError, "model/agent missing" if agent.strip.empty?

        user = body[:user].to_s
        raise Insika::ValidationError, "user missing" if user.strip.empty?

        message = extract_input(body[:input])
        raise Insika::ValidationError, "input empty" if message.strip.empty?

        out = { agent: agent.strip, user: user, message: message }
        (origin = Insika::MessageOrigin.parse!(body[:origin])) && (out[:origin] = origin)
        out
      end

      # V1: `input` is a STRING (the dispatcher composes the blocks + user text). Tolerates
      # an array of parts (OpenAI multimodal shape) by joining the texts.
      def extract_input(input)
        case input
        when String then input
        when Array
          input.flat_map { |part| part.is_a?(Hash) ? (part[:text] || part["text"]) : part }
               .compact.join("\n")
        else input.to_s
        end
      end

      # Turn Event -> OpenAI Responses SSE frame | nil (event with no
      # counterpart: :task_started, :tool_result, :skill_activated, ...).
      # Terminal events emit the final frame + `[DONE]` (close the stream).
      def frame_for(event)
        case event.type
        when :content
          sse("response.output_text.delta",
              { type: "response.output_text.delta", delta: event.data[:delta].to_s })
        when :tool_call
          sse("response.output_item.added",
              { type: "response.output_item.added",
                item: { type: "function_call", name: event.data[:name].to_s } })
        when :task_completed
          completed(event) + done
        when :task_failed
          failed(event.data[:message] || "task failed") + done
        when :task_cancelled
          failed("task cancelled") + done
        when :error
          failed(event.data[:message] || "error") + done
        when :thinking
          # The provider's reasoning. Internal unless the AGENT opted in
          # (`edge_stream thinking: true`), which tags the event. Even then it does
          # NOT become answer text: it gets the Responses reasoning frame, so a
          # consumer that only accumulates `output_text` deltas — a dispatcher
          # that turns them into one WhatsApp message — is unaffected,
          # and one that renders reasoning has something to render.
          if public_delta(event)
            sse("response.reasoning_summary_text.delta",
                { type: "response.reasoning_summary_text.delta", delta: event.data[:delta].to_s })
          end
        when :intermediate
          # The model's own prose that did not turn out to be the answer — the
          # narration of a message that also called a tool, or the reasoning-in-content
          # a model emits when it has no tool to call. A real store's prompt sent 132
          # deltas of an English monologue this way before TurnOutput held them back.
          #
          # NAMESPACED on purpose when published. There is no `response.*` event for
          # "text the assistant said that is not the answer": in the real protocol that
          # text IS `output_text.delta`, told apart only by an output-item index this
          # adapter does not carry. So a `response.*` type here would be a lie a strict
          # client would believe. `insika.*` is obviously ours and unknown types are
          # ignored — which is the safe failure.
          if public_delta(event)
            sse("insika.intermediate.delta",
                { type: "insika.intermediate.delta", delta: event.data[:delta].to_s })
          end
        when :guardrail_blocked, :guardrail_flagged
          # audit events with no OpenAI Responses counterpart. On a BLOCK
          # the safe reply still reaches the consumer through the normal :content
          # deltas + :task_completed path (the turn completes gracefully), so there
          # is nothing extra to translate here — the events live in /v1/events + the
          # Studio + the trace. Explicit (not a fall-through) to keep the closed
          # catalog honest.
          nil
        end
      end

      # Did the AGENT opt this channel in? The Executor tags the event (`edge_stream`)
      # because this mapper is pure and static — no agent, no stores, no state. An
      # untagged event is internal, which is the default and the safe reading — and
      # "not published" must be nil, like every other unmapped event in the catalog.
      def public_delta(event) = event.data[:public] == true

      def completed(event)
        response = {}
        if (usage = event.data[:usage])
          # `model` travels alongside usage in the event; in the OpenAI shape it is a sibling of
          # usage (pure tokens in usage).
          model = usage[:model] || usage["model"]
          response[:usage] = usage.reject { |k, _| k.to_s == "model" }
          response[:model] = model if model
        end
        # Opt-in per-turn latency breakdown (INSIKA_TURN_TIMING). Absent
        # by default — a non-standard sibling used only for TTFB diagnostics.
        (timing = event.data[:timing]) && (response[:timing] = timing)
        sse("response.completed", { type: "response.completed", response: response })
      end

      def failed(message)
        sse("response.failed",
            { type: "response.failed", response: { error: { message: message.to_s } } })
      end

      # event: + data: (the dispatcher reads both: `event:` and `type` in the JSON).
      def sse(event_name, data)
        "event: #{event_name}\ndata: #{JSON.generate(data)}\n\n"
      end

      def done = "data: [DONE]\n\n"
    end
  end
end
