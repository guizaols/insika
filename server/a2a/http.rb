# frozen_string_literal: true

require "json"

module Harness
  module Server
    module A2A
      # Adapter HTTP de produção (P3B, D2/L6): implementa o duck-type
      # `post_json(url, body) -> Hash` sobre async-http (roda no reactor do turno).
      # BOUNDARY — o require da lib fica aqui, nunca em lib/harness.rb/wiring-load.
      # O Client (a lógica) é testado com fake; este adapter, com teste leve.
      class Http
        HEADERS = [["content-type", "application/json"], ["accept", "application/json"]].freeze

        def initialize(internet: nil)
          @internet = internet # lazy: Async::HTTP::Internet.new
        end

        # POST JSON -> Hash (JSON-RPC parseado, chaves string).
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
