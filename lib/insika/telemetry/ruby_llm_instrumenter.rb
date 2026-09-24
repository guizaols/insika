# frozen_string_literal: true

require "securerandom"

module Insika
  module Telemetry
    # One instance belongs to one chat context, never to a graph or current fiber.
    class RubyLLMInstrumenter
      def initialize(emit:, delegate: nil, operation: nil, model: nil)
        @emit, @delegate, @operation, @model = emit, delegate, operation, model
      end

      def instrument(name, payload = {}, &block)
        return chat(payload, &block) if name == "chat.ruby_llm" && block
        return request(payload, &block) if name == "request.ruby_llm" && block

        result = delegate(name, payload, &block)
        record(:llm_usage, payload) if name == "usage.ruby_llm"
        result
      end

      private

      def chat(payload, &block)
        previous_model, previous_request = @model, @request_id
        @model, @request_id = scalar(payload[:model]), nil
        delegate("chat.ruby_llm", payload, &block)
      ensure
        @model, @request_id = previous_model, previous_request
      end

      def request(payload, &block)
        @request_id = SecureRandom.uuid
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        error = nil
        begin
          delegate("request.ruby_llm", payload, &block)
        rescue Exception => error # Preserve cancellation and the original model exception too.
          raise
        ensure
          record(:llm_request, payload, error: error,
            duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
        end
      end

      # Host notifications still wrap the operation. A broken subscriber must not
      # retry the model, replace its result, or swallow/replace its exception.
      def delegate(name, payload, &block)
        return block&.call(payload) unless @delegate.respond_to?(:instrument)

        called = false
        result = error = nil
        operation = proc do |*args|
          called = true
          begin
            result = block.call(*args)
          rescue Exception => caught
            error = caught
            raise
          end
        end
        begin
          block ? @delegate.instrument(name, payload, &operation) : @delegate.instrument(name, payload)
        rescue StandardError
          # Telemetry is best effort; the operation's outcome is authoritative.
        end
        raise error if error
        return unless block

        called ? result : block.call(payload)
      end

      def record(type, payload, error: nil, duration_ms: nil)
        data = {
          "operation" => scalar(payload[:operation] || @operation),
          "provider" => scalar(payload[:provider]),
          "model" => scalar(payload[:model] || @model),
          "status" => type == :llm_request ? (error ? "failed" : "succeeded") : scalar(payload[:status]),
          "request_id" => @request_id
        }
        if type == :llm_request
          data["duration_ms"] = duration_ms
          data["exception_class"] = error.class.name if error
        else
          %i[input output cache_read cache_write thinking].each do |field|
            value = payload[:tokens]&.public_send(field)
            data["#{field}_tokens"] = value.is_a?(Numeric) ? value : nil
          end
          value = payload[:cost]&.total
          data["cost"] = value.is_a?(Numeric) ? value : nil
        end
        @emit.call(type, data)
      rescue StandardError
        nil
      end

      def scalar(value)
        value.to_s if value.is_a?(String) || value.is_a?(Symbol)
      end
    end
  end
end
