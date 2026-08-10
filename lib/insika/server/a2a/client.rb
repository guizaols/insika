# frozen_string_literal: true

require_relative "message"

module Insika
  module Server
    module A2A
      # JSON-RPC response envelope carrying `error` (the remote refused/failed).
      class RemoteError < StandardError
        attr_reader :code

        def initialize(code, message)
          @code = code
          super(message)
        end
      end

      # Outbound A2A client: calls a remote A2A agent. PURE — the
      # `http` (post_json(url, body) -> Hash) is injected; the smoke test uses loopback.
      class Client
        TERMINAL = %w[completed failed canceled rejected input-required].freeze
        POLL_DELAY = 0.02

        def initialize(http:, poll_max: 30, sleeper: nil)
          @http = http
          @poll_max = poll_max
          @sleeper = sleeper || ->(seconds) { Async::Task.current&.sleep(seconds) }
          @id_seq = 0
        end

        # -> remote A2A Task (Hash) | raise RemoteError.
        def send_message(url, text, context_id: nil)
          message = { "role" => "user", "parts" => [{ "kind" => "text", "text" => text.to_s }] }
          message["contextId"] = context_id if context_id
          parse_envelope(@http.post_json(url, request("message/send", { "message" => message })))
        end

        # -> remote A2A Task (Hash) | raise RemoteError.
        def get_task(url, task_id)
          parse_envelope(@http.post_json(url, request("tasks/get", { "id" => task_id })))
        end

        # High level: send + poll until terminal. ALWAYS does ≥1 get_task — the
        # inbound message/send projects the Task WITHOUT `status.message` (the content
        # only comes from tasks/get). -> { text:, state:, id: } | { error:, state:, id: }.
        # NEVER raises (wraps RemoteError).
        def call(url, text, context_id: nil)
          sent = send_message(url, text, context_id: context_id)
          id = remote_id(sent)
          task = get_task(url, id)
          attempts = 0
          until TERMINAL.include?(remote_state(task)) || attempts >= @poll_max
            @sleeper.call(POLL_DELAY)
            attempts += 1
            task = get_task(url, id)
          end
          project(task, id)
        rescue RemoteError => e
          { error: e.message, state: "failed", id: nil }
        end

        private

        def request(method, params)
          @id_seq += 1
          { "jsonrpc" => "2.0", "id" => @id_seq, "method" => method, "params" => params }
        end

        def parse_envelope(response)
          raise RemoteError.new(nil, "invalid A2A response") unless response.is_a?(Hash)
          return response["result"] if response.key?("result")

          err = response["error"]
          raise RemoteError.new(err && err["code"], (err && err["message"]).to_s) if err

          raise RemoteError.new(nil, "A2A response has neither result nor error")
        end

        def remote_state(task) = task.is_a?(Hash) ? task.dig("status", "state").to_s : ""
        def remote_text(task)  = Message.text_from(task.is_a?(Hash) ? task.dig("status", "message") : nil)
        def remote_id(task)    = task.is_a?(Hash) ? task["id"] : nil

        # completed/input-required -> text; failed/canceled/rejected -> error
        # (text if present, else the state itself — avoids the "".truthy footgun);
        # exhausted poll (non-terminal) -> error.
        def project(task, id)
          state = remote_state(task)
          text = remote_text(task)
          case state
          when "completed", "input-required"
            { text: text, state: state, id: id }
          when "failed", "canceled", "rejected"
            { error: text.empty? ? state : text, state: state, id: id }
          else
            { error: "remote task did not complete (state: #{state})", state: state, id: id }
          end
        end
      end
    end
  end
end
