# frozen_string_literal: true

require_relative "errors"

module Harness
  module Server
    module A2A
      # JSON-RPC 2.0 envelope. PURE — receives the already
      # deserialized Hash (raw JSON parsing belongs to Server::App). NEVER raises.
      module Protocol
        VERSION = "2.0"

        # -> [:ok, { id:, method:, params: }] | [:error, { id:, code:, message: }]
        def self.parse(body)
          return err(nil, Errors::INVALID_REQUEST, "request must be a JSON-RPC object") unless body.is_a?(Hash)

          id = body["id"] # missing -> nil (we always respond; no notifications in this slice)
          return err(id, Errors::INVALID_REQUEST, "jsonrpc must be '2.0'") unless body["jsonrpc"] == VERSION

          method = body["method"]
          return err(id, Errors::INVALID_REQUEST, "method missing") unless method.is_a?(String) && !method.empty?

          [:ok, { id: id, method: method, params: body["params"] || {} }]
        end

        # { jsonrpc:, id:, result: }
        def self.result(id, result)
          { jsonrpc: VERSION, id: id, result: result }
        end

        # { jsonrpc:, id:, error: { code:, message:, data? } }
        def self.error(id, code, message, data: nil)
          err = { code: code, message: message }
          err[:data] = data unless data.nil?
          { jsonrpc: VERSION, id: id, error: err }
        end

        def self.err(id, code, message)
          [:error, { id: id, code: code, message: message }]
        end
        private_class_method :err
      end
    end
  end
end
