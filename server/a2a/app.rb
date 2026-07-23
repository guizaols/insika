# frozen_string_literal: true

require "time"
require_relative "protocol"
require_relative "errors"
require_relative "message"
require_relative "task_projection"
require_relative "agent_card"

module Insika
  module Server
    module A2A
      # A2A edge handler: injected sub-app mounted by Server::App. A2A is
      # TRANSPORT — translates JSON-RPC↔Command on the SAME bus, projects
      # Task→A2A, and NEVER leaks an exception (always an error object).
      class App
        def initialize(command_bus:, task_store:, session_store:, profiles:, skill_catalog:, config:)
          @command_bus = command_bus
          @task_store = task_store
          @session_store = session_store
          @profiles = Insika::ProfileSource.coerce(profiles)
          @skill_catalog = skill_catalog
          @config = config # { a2a_agent:, base_url: }
        end

        # POST /a2a — `body` is already the deserialized Hash. -> JSON-RPC envelope.
        def rpc(body)
          kind, parsed = Protocol.parse(body)
          return Protocol.error(parsed[:id], parsed[:code], parsed[:message]) if kind == :error

          dispatch_method(parsed[:id], parsed[:method], parsed[:params])
        rescue StandardError => e # safety net: parse ok but something slipped through
          code, message = Errors.from_exception(e)
          Protocol.error(nil, code, message)
        end

        # GET /.well-known/agent-card.json
        def agent_card
          agent = @profiles[@config[:a2a_agent]]
          skills = @skill_catalog.effective(agent.skills)
          AgentCard.build(agent: agent, base_url: @config[:base_url], skills: skills)
        end

        private

        def dispatch_method(id, method, params)
          case method
          when "message/send" then message_send(id, params)
          when "tasks/get"    then tasks_get(id, params)
          when "tasks/cancel" then tasks_cancel(id, params)
          else Protocol.error(id, Errors::METHOD_NOT_FOUND, "method '#{method}' not supported")
          end
        rescue StandardError => e # map core error -> A2A code
          code, message = Errors.from_exception(e)
          Protocol.error(id, code, message)
        end

        # message/send returns the Task; missing contextId -> creates a session (the
        # server assigns the contextId; ensures a transcript for tasks/get).
        def message_send(id, params)
          message = params["message"] || {}
          session_id = message["contextId"] || params["contextId"]
          session_id ||= @command_bus.dispatch(build(:create_session, {})).id
          text = Message.text_from(message)
          result = @command_bus.dispatch(build(:send_message,
                                               agent: @config[:a2a_agent], message: text, session_id: session_id))
          task = @task_store.find(result[:task_id])
          Protocol.result(id, TaskProjection.call(task, at: now))
        end

        def tasks_get(id, params)
          task = @task_store.find(params["id"])
          return Protocol.error(id, Errors::TASK_NOT_FOUND, "task not found: #{params['id']}") if task.nil?

          Protocol.result(id, TaskProjection.call(task, at: now,
                                                        content: terminal_content(task),
                                                        error: terminal_error(task)))
        end

        def tasks_cancel(id, params)
          task_id = params["id"]
          return Protocol.error(id, Errors::TASK_NOT_FOUND, "task not found: #{task_id}") if @task_store.find(task_id).nil?

          @command_bus.dispatch(build(:cancel_task, task_id: task_id))
          Protocol.result(id, TaskProjection.call(@task_store.find(task_id), at: now))
        end

        # Final content = last `assistant` message in the session transcript.
        def terminal_content(task)
          return nil unless task.session_id

          session = @session_store.find(task.session_id)
          return nil unless session

          msg = session.messages.reverse.find { |m| (m["role"] || m[:role]).to_s == "assistant" }
          msg && (msg["content"] || msg[:content])
        end

        # Error message from the last :failed Execution.
        def terminal_error(task)
          exec = task.executions.last
          return nil unless exec && exec.outcome.to_s == "failed"

          exec.error && (exec.error["message"] || exec.error[:message])
        end

        def build(type, payload) = Insika::Command.build(type, payload, transport: :a2a)
        def now = Time.now.utc.iso8601
      end
    end
  end
end
