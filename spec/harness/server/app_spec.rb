# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../../server/app"

# Contrato de rotas do doc 07 §2-§6 com Rack::MockRequest + bus/stores DUPLOS
# (doc 07 §7, duplos em spec/support/server_doubles.rb). Nenhum componente real
# do Executor/RubyLLM é tocado.
RSpec.describe Harness::Server::App do
  def event(type, data = {}, task_id: "t-1")
    Harness::Event.new(type: type, data: data, meta: { task_id: task_id })
  end

  def build_app(bus: ServerBusDouble.new, event_stream: ServerEventStreamDouble.new,
                session_store: ServerStoreDouble.new(nil), task_store: ServerStoreDouble.new(nil),
                config: {})
    described_class.new(
      command_bus: bus, event_stream: event_stream,
      session_store: session_store, task_store: task_store,
      catalogs: {}, registries: {},
      config: { sync_timeout: 0.05 }.merge(config)
    )
  end

  def call(app, method, path, body: nil)
    opts = { method: method }
    opts[:input] = body if body
    app.call(Rack::MockRequest.env_for(path, opts))
  end

  def json_body(resp) = JSON.parse(resp.join)

  describe "POST /v1/commands/:type (genérica)" do
    it "traduz body em Command(type, payload, transport: :http)" do
      bus = ServerBusDouble.new { |_c| { task_id: "t-9" } }
      app = build_app(bus: bus)

      call(app, "POST", "/v1/commands/cancel_task", body: '{"task_id":"t-9"}')

      cmd = bus.dispatched.last
      expect(cmd.type).to eq(:cancel_task)
      expect(cmd.payload).to eq(task_id: "t-9")
      expect(cmd.meta[:transport]).to eq(:http)
    end

    it "resultado de controle (Data) -> 200 com to_h" do
      session = Harness::SessionStore::Session.new(
        id: "s-1", messages: [], vars: {}, memory_refs: [],
        created_at: "t", updated_at: "t"
      )
      app = build_app(bus: ServerBusDouble.new { session })

      status, _h, resp = call(app, "POST", "/v1/commands/create_session", body: "{}")

      expect(status).to eq(200)
      expect(json_body(resp)).to include("id" => "s-1")
    end

    it "resultado de turno ({task_id:}) -> 202" do
      app = build_app(bus: ServerBusDouble.new { { task_id: "t-1" } })

      status, _h, resp = call(app, "POST", "/v1/commands/send_message", body: "{}")

      expect(status).to eq(202)
      expect(json_body(resp)).to eq("task_id" => "t-1")
    end

    it "body vazio vira payload {}" do
      bus = ServerBusDouble.new { { task_id: "t" } }
      app = build_app(bus: bus)

      call(app, "POST", "/v1/commands/send_message")

      expect(bus.dispatched.last.payload).to eq({})
    end
  end

  describe "POST /v1/sessions (açúcar)" do
    it "despacha :create_session e responde 201 {session}" do
      session = Harness::SessionStore::Session.new(
        id: "s-1", messages: [], vars: { "a" => 1 }, memory_refs: [],
        created_at: "t", updated_at: "t"
      )
      bus = ServerBusDouble.new { session }
      app = build_app(bus: bus)

      status, _h, resp = call(app, "POST", "/v1/sessions", body: '{"vars":{"a":1}}')

      expect(bus.dispatched.last.type).to eq(:create_session)
      expect(bus.dispatched.last.payload).to eq(vars: { a: 1 })
      expect(status).to eq(201)
      expect(json_body(resp)["session"]).to include("id" => "s-1")
    end
  end

  describe "POST /v1/messages (açúcar)" do
    it "despacha :send_message com o payload traduzido (stream=false)" do
      bus = ServerBusDouble.new { { task_id: "t-1" } }
      stream = ServerEventStreamDouble.new([event(:done, { content: "" })])
      app = build_app(bus: bus, event_stream: stream)

      call(app, "POST", "/v1/messages?stream=false",
           body: '{"agent":"sales","message":"oi"}')

      cmd = bus.dispatched.last
      expect(cmd.type).to eq(:send_message)
      expect(cmd.payload).to eq(agent: "sales", message: "oi")
    end
  end

  describe "leituras (nunca são Command — D3)" do
    it "GET /v1/sessions/:id chama o store e NÃO despacha" do
      session = Harness::SessionStore::Session.new(
        id: "s-1", messages: [], vars: {}, memory_refs: [],
        created_at: "t", updated_at: "t"
      )
      bus = ServerBusDouble.new
      app = build_app(bus: bus, session_store: ServerStoreDouble.new(session))

      status, _h, resp = call(app, "GET", "/v1/sessions/s-1")

      expect(status).to eq(200)
      expect(json_body(resp)["session"]).to include("id" => "s-1")
      expect(bus.dispatched).to be_empty
    end

    it "GET /v1/tasks/:id chama o store e NÃO despacha" do
      task = Harness::TaskStore::Task.new(
        id: "t-1", status: :completed, command: {}, session_id: nil,
        executions: [], mailbox_state: {}, claimed_by: nil, claim_expires_at: nil,
        created_at: "t", updated_at: "t"
      )
      bus = ServerBusDouble.new
      app = build_app(bus: bus, task_store: ServerStoreDouble.new(task))

      status, _h, resp = call(app, "GET", "/v1/tasks/t-1")

      expect(status).to eq(200)
      expect(json_body(resp)["task"]).to include("id" => "t-1", "status" => "completed")
      expect(bus.dispatched).to be_empty
    end

    it "GET /v1/tasks/:id serializa executions como objetos JSON legíveis" do
      execution = Harness::TaskStore::Execution.new(
        attempt: 1, started_at: "a", finished_at: "b", outcome: "failed",
        error: { "class" => "Harness::ProviderError", "message" => "x" }
      )
      task = Harness::TaskStore::Task.new(
        id: "t-1", status: :failed, command: {}, session_id: nil,
        executions: [execution], mailbox_state: {}, claimed_by: nil,
        claim_expires_at: nil, created_at: "t", updated_at: "t"
      )
      app = build_app(task_store: ServerStoreDouble.new(task))

      _status, _h, resp = call(app, "GET", "/v1/tasks/t-1")

      exec = json_body(resp)["task"]["executions"].first
      expect(exec).to be_a(Hash) # não uma string opaca "#<data ...>"
      expect(exec["outcome"]).to eq("failed")
      expect(exec["error"]).to eq("class" => "Harness::ProviderError", "message" => "x")
    end

    it "leitura de sessão inexistente -> 404 com corpo de erro padrão" do
      app = build_app(session_store: ServerStoreDouble.new(nil))

      status, _h, resp = call(app, "GET", "/v1/sessions/nope")

      expect(status).to eq(404)
      expect(json_body(resp)["error"]["class"]).to eq("Harness::NotFoundError")
    end
  end

  describe "mapeamento erro->status" do
    it "JSON malformado -> 400, zero dispatch" do
      bus = ServerBusDouble.new
      app = build_app(bus: bus)

      status, _h, resp = call(app, "POST", "/v1/commands/x", body: "{oops")

      expect(status).to eq(400)
      expect(json_body(resp)["error"]["class"]).to eq("JSON::ParserError")
      expect(bus.dispatched).to be_empty
    end

    it "ValidationError -> 422" do
      app = build_app(bus: ServerBusDouble.new { raise Harness::ValidationError, "ruim" })

      status, _h, resp = call(app, "POST", "/v1/commands/x", body: "{}")

      expect(status).to eq(422)
      expect(json_body(resp)["error"]).to eq(
        "class" => "Harness::ValidationError", "message" => "ruim"
      )
    end

    it "NotFoundError -> 404" do
      app = build_app(bus: ServerBusDouble.new { raise Harness::NotFoundError, "sumiu" })

      status, = call(app, "POST", "/v1/commands/x", body: "{}")

      expect(status).to eq(404)
    end

    it "StandardError genérico -> 500" do
      app = build_app(bus: ServerBusDouble.new { raise "boom" })

      status, = call(app, "POST", "/v1/commands/x", body: "{}")

      expect(status).to eq(500)
    end

    it "timeout do dispatch síncrono -> 504" do
      bus = ServerBusDouble.new { Async::Task.current.sleep(0.3) }
      app = build_app(bus: bus)

      status = nil
      Sync { status, = call(app, "POST", "/v1/commands/x", body: "{}") }

      expect(status).to eq(504)
    end

    it "nenhum caminho do App produz status 403" do
      source = File.read(File.expand_path("../../../server/app.rb", __dir__))
      expect(source).not_to match(/\b403\b/)
    end
  end

  describe "stream=false agrega no terminal" do
    it "acumula deltas de :content e responde no :done" do
      events = [event(:content, { delta: "a" }), event(:content, { delta: "b" }),
                event(:done, { content: "ab" })]
      app = build_app(bus: ServerBusDouble.new { { task_id: "t-1" } },
                      event_stream: ServerEventStreamDouble.new(events))

      status, _h, resp = call(app, "POST", "/v1/messages?stream=false", body: "{}")

      body = json_body(resp)
      expect(status).to eq(200)
      expect(body["content"]).to eq("ab")
      expect(body["task_id"]).to eq("t-1")
      expect(body["events"].size).to eq(3)
    end

    it "responde com error: no :task_failed" do
      events = [event(:task_failed, { error: "Harness::ProviderError", message: "x" })]
      app = build_app(bus: ServerBusDouble.new { { task_id: "t-1" } },
                      event_stream: ServerEventStreamDouble.new(events))

      status, _h, resp = call(app, "POST", "/v1/messages?stream=false", body: "{}")

      body = json_body(resp)
      expect(status).to eq(200)
      expect(body["error"]).to eq("class" => "Harness::ProviderError", "message" => "x")
    end

    it "reporta :task_cancelled como error (nunca sucesso)" do
      events = [event(:content, { delta: "parcial" }), event(:task_cancelled, { task_id: "t-1" })]
      app = build_app(bus: ServerBusDouble.new { { task_id: "t-1" } },
                      event_stream: ServerEventStreamDouble.new(events))

      _status, _h, resp = call(app, "POST", "/v1/messages?stream=false", body: "{}")

      body = json_body(resp)
      expect(body).not_to have_key("content")
      expect(body["error"]["class"]).to eq("Harness::CancelledError")
    end

    it "reporta :error de overflow como error (não 200 de sucesso truncado)" do
      events = [event(:content, { delta: "a" }), event(:error, { message: "subscription overflow" })]
      app = build_app(bus: ServerBusDouble.new { { task_id: "t-1" } },
                      event_stream: ServerEventStreamDouble.new(events))

      _status, _h, resp = call(app, "POST", "/v1/messages?stream=false", body: "{}")

      body = json_body(resp)
      expect(body).not_to have_key("content")
      expect(body["error"]["message"]).to eq("subscription overflow")
    end
  end

  describe "SSE (stream=true default)" do
    it "responde 200 com headers SSE e corpo SSEBody" do
      app = build_app(bus: ServerBusDouble.new { { task_id: "t-1" } })

      status, headers, body = call(app, "POST", "/v1/messages", body: "{}")

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/event-stream")
      expect(headers["cache-control"]).to eq("no-cache")
      expect(headers["connection"]).to eq("keep-alive")
      expect(body).to be_a(Harness::Server::SSEBody)
    end

    it "GET /v1/events assina com os filtros da query e NÃO despacha" do
      bus = ServerBusDouble.new
      stream = ServerEventStreamDouble.new
      app = build_app(bus: bus, event_stream: stream)

      status, _h, body = call(app, "GET", "/v1/events?task_id=t-1&session_id=s-2")

      expect(status).to eq(200)
      expect(body).to be_a(Harness::Server::SSEBody)
      expect(stream.subscribes.last).to eq(task_id: "t-1", session_id: "s-2")
      expect(bus.dispatched).to be_empty
    end
  end

  describe "rota desconhecida" do
    it "GET /nada -> 404 not found (text/plain)" do
      status, headers, resp = call(build_app, "GET", "/nada")

      expect(status).to eq(404)
      expect(headers["content-type"]).to eq("text/plain")
      expect(resp.join).to eq("not found")
    end

    it "/admin* -> 404 até a task 25" do
      status, = call(build_app, "GET", "/admin")
      expect(status).to eq(404)
    end

    it "método errado numa rota conhecida -> 404" do
      status, = call(build_app, "PUT", "/v1/commands/x")
      expect(status).to eq(404)
    end
  end
end
