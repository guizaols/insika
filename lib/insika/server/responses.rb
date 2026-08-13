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

        out = { agent: agent.strip, user: user, message: message }
        (origin = Insika::MessageOrigin.parse!(body[:origin])) && (out[:origin] = origin)
        # WS8: the optional customer_key — per-customer memory scope + purge handle
        (customer = Insika::Coercion.presence(body[:customer])) && (out[:customer] = customer)
        # WS9: the multimodal OPENAI shape — `input` as an array of content parts
        # ({type: text/image/audio}) is preserved additively alongside the
        # joined text; a string input stays byte-identical to before. The
        # CONTRACT is enforced here (422) — the engine stays lenient.
        raw = body[:input]
        if raw.is_a?(Array)
          unless Insika::Media.well_formed?(raw)
            raise Insika::ValidationError,
                  "malformed content part — each part must be {type: text|image|audio} with text/url"
          end

          normalized = Insika::Media.parts(raw).map do |p|
            { "type" => p.type, "text" => p.text, "url" => p.url }.compact
          end
          out[:parts] = normalized unless normalized.empty?
        end
        # The turn needs SOMETHING to be about — text, or media the engine will
        # turn into text (a voice note) or show the model (a photo). Checked
        # after the parts are known, because the anchor use case (a WhatsApp
        # voice note, no caption) carries no text at all and joining only the
        # text parts made it a 422 at the door.
        if message.strip.empty? && Array(out[:parts]).none? { |p| p["type"] != "text" }
          raise Insika::ValidationError, "input empty"
        end
        # WS9: `source` marks pre-transcribed voice text; anything else is refused.
        unless body[:source].nil? || body[:source].to_s == "voice"
          raise Insika::ValidationError, 'source must be "voice"'
        end
        out[:source] = body[:source].to_s if Insika::Coercion.presence(body[:source])
        # WS9 (saída): the channel declares which generated media it can
        # RECEIVE ({ capabilities: ["image_output", "audio_output"] }). Additive
        # + additive sibling on the completed frame; the exact capabilities are
        # validated at the boundary (message_flow), not here.
        (channel = body[:channel]) && (out[:channel] = channel)
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
        when :ttft
          # the live TTFB signal (WS6, INSIKA_TURN_TIMING opt-in): the provider's
          # ms-to-first-token, emitted when the first content chunk arrives.
          # Namespaced insika.* — no OpenAI Responses counterpart; unknown types
          # are ignored, the safe failure.
          sse("insika.ttft", { type: "insika.ttft", ttft_ms: event.data[:ttft_ms].to_i })
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
        # WS5 stuck signal: an additive sibling the terminal frame carries when the
        # agent ended the turn declaring it cannot proceed. Consumers that only read
        # the OpenAI-shaped response.use it to run their escalation ("stuck" means
        # what they decide it means, never the engine's business).
        (outcome = event.data[:outcome]) && (response[:outcome] = outcome.to_s)
        # WS9 (saída): generated media parts (image/audio clips) ride the
        # completed frame additively next to the text — absent when none were
        # generated. The base64 bytes are the consumer's to render/upload.
        (parts = event.data[:output_parts]) && (response[:output_parts] = parts)
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
