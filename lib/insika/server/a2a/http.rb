# frozen_string_literal: true

require "json"

module Insika
  module Server
    module A2A
      # Production HTTP adapter: implements the duck-type
      # `post_json(url, body) -> Hash` over async-http (runs on the turn's reactor).
      # BOUNDARY — the lib require lives here, never in lib/insika.rb/wiring-load.
      # The Client (the logic) is tested with a fake; this adapter, with a light test.
      class Http
        HEADERS = [["content-type", "application/json"], ["accept", "application/json"]].freeze

        def initialize(internet: nil)
          @internet = internet # lazy: Async::HTTP::Internet.new
        end

        # POST JSON -> Hash (parsed JSON-RPC, string keys).
        def post_json(url, body)
          response = internet.post(url, HEADERS, JSON.generate(body))
          JSON.parse(response.read.to_s)
        end

        def close
          @internet&.close
        rescue StandardError
          nil # best-effort
        end

        private

        def internet
          @internet ||= begin
            require "async/http/internet"
            Async::HTTP::Internet.new
          end
        end
      end
    end
  end
end
