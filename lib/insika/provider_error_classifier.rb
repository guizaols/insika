# frozen_string_literal: true

module Insika
  # Classifies provider/transport failures by ACTION (B9). Four kinds —
  # the hermes/openclaw structural rule: NON-retryable checked first, so an
  # error we do not recognize defaults to :fatal (a retry would hammer a
  # poisoned credential; a fatal is retried only after the operator fixes the
  # cause):
  #
  #   :fatal              401/402/403/400 (auth, billing, permanent quota,
  #                       bad request, context too long) — retrying does not help.
  #   :retryable          5xx/529/socket/timeout — the same call may succeed
  #                       moments later.
  #   :rate_limited_short a 429 that says "back off briefly" (RPM-scale).
  #   :rate_limited_long  a 429 with a long retry-after — quota-scale.
  #
  # The classification is STRING-based (class names, no constant references):
  # the core loads without ruby_llm, and the smoke-shim's fake RubyLLM is a
  # drop-in. `retry_after` is read from the provider's own Retry-After header
  # when the error carries a response, else a per-kind default.
  class ProviderErrorClassifier
    Classification = Data.define(:kind, :retryable, :retry_after) do
      # the additive envelope fields — compacted so a retry_after-less fatal
      # never invents one.
      def to_h
        { kind: kind, retryable: retryable, retry_after: retry_after }.compact
      end
    end

    KINDS = %i[fatal retryable rate_limited_short rate_limited_long].freeze

    # Above this a 429 means quota, not RPM (this is what tells the two apart —
    # a short 429 wants a quick retry; a long one is a billing event).
    SHORT_RETRY_LIMIT = 60 # seconds

    DEFAULTS = {
      retryable: 5,
      rate_limited_short: 10,
      rate_limited_long: 300
    }.freeze

    # RubyLLM's taxonomy (error.rb), matched by class name so the core stays
    # ruby_llm-free at load time.
    FATAL_ERROR_NAMES = %w[
      RubyLLM::ContextLengthExceededError RubyLLM::BadRequestError
      RubyLLM::UnauthorizedError RubyLLM::PaymentRequiredError RubyLLM::ForbiddenError
    ].freeze
    RATE_LIMITED_ERROR_NAME = "RubyLLM::RateLimitError"
    RETRYABLE_ERROR_NAMES = %w[
      RubyLLM::ServerError RubyLLM::ServiceUnavailableError RubyLLM::OverloadedError
    ].freeze
    RUBY_LLM_ERROR_NAMES = (
      FATAL_ERROR_NAMES + [RATE_LIMITED_ERROR_NAME] +
      RETRYABLE_ERROR_NAMES + ["RubyLLM::Error"]
    ).freeze

    # Transport failures while talking to the provider: connection
    # refused/reset, DNS, TLS, timeouts (Faraday wraps its own names; the
    # stdlib ones surface from raw sockets).
    TRANSPORT_NAME_PATTERNS = [
      /\AFaraday::/,
      /\ASocketError\z/,
      /\AIOError\z/,
      /\AErrno::/,
      /\ANet::(Read|Open)Timeout\z/,
      /\ATimeout::Error\z/,
      /\AOpenSSL::SSL::SSLError\z/
    ].freeze

    class << self
      # -> Classification
      def classify(error)
        names = class_names(error)

        # Non-retryable first (the structural rule): a known fatal is NEVER
        # retried, and an unknown error defaults to fatal — never to retry.
        return fatal if (names & FATAL_ERROR_NAMES).any?

        return rate_limited(error) if names.include?(RATE_LIMITED_ERROR_NAME)

        return retryable if (names & RETRYABLE_ERROR_NAMES).any?
        return retryable if transport?(names)

        # A generic RubyLLM::Error (or a raw HTTP error) still carries the
        # status: 429 and 5xx are retryable regardless of the wrapping class.
        case http_status(error)
        when 429      then rate_limited(error)
        when 500..599 then retryable
        else fatal
        end
      end

      # True when the error came from the provider call itself (RubyLLM
      # family or transport) — the executor routes these to the :ruby_llm
      # stage with a wrapped classification instead of :unknown.
      def provider_error?(error)
        names = class_names(error)
        (names & RUBY_LLM_ERROR_NAMES).any? || transport?(names)
      end

      # The typed ProviderError the executor stores and emits.
      def wrap(error)
        c = classify(error)
        Insika::ProviderError.new(
          error.message || error.class.name,
          kind: c.kind, retryable: c.retryable, retry_after: c.retry_after
        )
      end

      private

      def fatal
        Classification.new(kind: :fatal, retryable: false, retry_after: nil)
      end

      def retryable
        Classification.new(kind: :retryable, retryable: true,
                           retry_after: DEFAULTS[:retryable])
      end

      def rate_limited(error)
        ra = retry_after_header(error)
        if ra && ra > SHORT_RETRY_LIMIT
          Classification.new(kind: :rate_limited_long, retryable: true, retry_after: ra)
        else
          Classification.new(kind: :rate_limited_short, retryable: true,
                             retry_after: ra || DEFAULTS[:rate_limited_short])
        end
      end

      def class_names(error)
        ([error.class.name] + Array(error.class.ancestors).map(&:name)).compact
      end

      def transport?(names)
        names.any? { |n| TRANSPORT_NAME_PATTERNS.any? { |p| p.match?(n) } }
      end

      # The provider's own Retry-After (seconds), when the error carries a
      # response. All access guarded — a bare double must not raise.
      def retry_after_header(error)
        headers = response_headers(error)
        value = headers && (headers["retry-after"] || headers["Retry-After"])
        value = value.to_s.strip
        value.match?(/\A\d+\z/) ? value.to_i : nil
      end

      def http_status(error)
        response = error.respond_to?(:response) ? error.response : nil
        status = response && response.respond_to?(:status) ? response.status : nil
        status&.to_i
      end

      def response_headers(error)
        response = error.respond_to?(:response) ? error.response : nil
        response && response.respond_to?(:headers) ? response.headers : nil
      end
    end
  end
end