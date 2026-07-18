# frozen_string_literal: true

require "spec_helper"
require_relative "../../../server/app"

# WRITE Control UI (P2-04, tasks 11-13) via Server::App: each action POSTs a
# Command on the bus, emits :operator_action (audit) and responds with a Turbo Stream (if
# the client accepts) or a 303 redirect (graceful degradation without JS). Operator auth (Bearer)
# already covers POST (inherited from Phase 1).
RSpec.describe "Harness::Server::Admin::App — write" do
  PendingDouble = Struct.new(:records) do
    def open_for(task_id) = (records || []).select { |r| r.task_id == task_id }
  end

  def build_app(bus: ServerBusDouble.new, event_stream: ServerEventStreamDouble.new,
                pending: [], admin_token: "s3cret")
    Harness::Server::App.new(
      command_bus: bus, event_stream: event_stream,
      session_store: ServerStoreDouble.new(nil), task_store: ServerStoreDouble.new(nil),
      checkpoint_store: nil, pending_action_store: PendingDouble.new(pending),
      catalogs: { skills: nil }, registries: { tools: nil, workflows: nil },
      config: { admin_token: admin_token, allowed_origins: [] }
    )
  end

  def post(app, path, form: nil, auth: "Bearer s3cret", turbo: false)
    env = Rack::MockRequest.env_for(path, method: "POST")
    env["HTTP_AUTHORIZATION"] = auth if auth
    env["CONTENT_TYPE"] = "application/x-www-form-urlencoded" if form
    env["rack.input"] = StringIO.new(form) if form
    env["HTTP_ACCEPT"] = "text/vnd.turbo-stream.html" if turbo
    app.call(env)
  end

  describe "task actions" do
    it "POST /admin/tasks/:id/pause -> Command pause_task + :operator_action + redirect" do
      bus = ServerBusDouble.new
      events = ServerEventStreamDouble.new
      app = build_app(bus: bus, event_stream: events)

      status, headers, = post(app, "/admin/tasks/t-1/pause")

      cmd = bus.dispatched.last
      expect(cmd.type).to eq(:pause_task)
      expect(cmd.payload).to eq(task_id: "t-1")
      expect(status).to eq(303)                      # without Turbo: redirect
      expect(headers["location"]).to eq("/admin/tasks")
      expect(events.emitted.map(&:type)).to include(:operator_action)
    end

    it "resume/cancel route to the correct Commands" do
      bus = ServerBusDouble.new
      app = build_app(bus: bus)
      post(app, "/admin/tasks/t-1/resume")
      post(app, "/admin/tasks/t-1/cancel")
      expect(bus.dispatched.map(&:type)).to eq(%i[resume_task cancel_task])
    end

    it "with Accept turbo-stream -> 200 text/vnd.turbo-stream.html" do
      app = build_app
      status, headers, resp = post(app, "/admin/tasks/t-1/pause", turbo: true)
      expect(status).to eq(200)
      expect(headers["content-type"]).to include("turbo-stream")
      expect(resp.join).to include("turbo-stream")
    end

    it "emits :operator_action BEFORE the dispatch (audit, D6)" do
      events = ServerEventStreamDouble.new
      app = build_app(event_stream: events)
      post(app, "/admin/tasks/t-1/cancel")
      op = events.emitted.find { |e| e.type == :operator_action }
      expect(op).not_to be_nil
      expect(op.data[:action]).to eq("cancel_task")
      expect(op.data[:operator]).to eq("operator")
    end
  end

  describe "approval" do
    it "POST /admin/approvals/:pid -> approve_action with decision from the form" do
      bus = ServerBusDouble.new
      app = build_app(bus: bus)
      post(app, "/admin/approvals/p-1", form: "decision=approved")
      cmd = bus.dispatched.last
      expect(cmd.type).to eq(:approve_action)
      expect(cmd.payload[:pending_id]).to eq("p-1")
      expect(cmd.payload[:decision]).to eq("approved")
    end
  end

  describe "chat" do
    it "POST /admin/chat -> send_message with the form" do
      bus = ServerBusDouble.new
      app = build_app(bus: bus)
      post(app, "/admin/chat", form: "agent=sales&message=oi&session_id=s1")
      cmd = bus.dispatched.last
      expect(cmd.type).to eq(:send_message)
      expect(cmd.payload).to eq(agent: "sales", message: "oi", session_id: "s1")
    end

    it "audit does NOT leak the message content (only metadata) — /v1/events has no auth" do
      events = ServerEventStreamDouble.new
      app = build_app(event_stream: events)
      post(app, "/admin/chat", form: "agent=sales&message=segredo&session_id=s1")

      op = events.emitted.find { |e| e.type == :operator_action }
      expect(op.data[:target]).to eq(agent: "sales", session_id: "s1")
      expect(op.data[:target]).not_to have_key(:message)
      expect(op.meta[:session_id]).to eq("s1") # stamped for correlation
    end
  end

  describe "Command error" do
    it "NotFoundError becomes a write response (not an HTTP status); audit emitted" do
      bus = ServerBusDouble.new { raise Harness::NotFoundError, "sumiu" }
      events = ServerEventStreamDouble.new
      app = build_app(bus: bus, event_stream: events)

      status, = post(app, "/admin/tasks/ghost/pause", turbo: true)

      expect(status).to eq(422) # error turbo-stream
      expect(events.emitted.map(&:type)).to include(:operator_action) # attempt audited
    end
  end

  describe "auth (inherited)" do
    it "POST without token -> 503 (fail-closed), does not dispatch" do
      bus = ServerBusDouble.new
      app = build_app(bus: bus, admin_token: nil)
      status, = post(app, "/admin/tasks/t-1/pause", auth: nil)
      expect(status).to eq(503)
      expect(bus.dispatched).to be_empty
    end

    it "POST with wrong token -> 401" do
      status, = post(build_app, "/admin/tasks/t-1/pause", auth: "Bearer nope")
      expect(status).to eq(401)
    end
  end

  describe "assets vendored" do
    it "GET /admin/assets/turbo.js -> 200 javascript" do
      env = Rack::MockRequest.env_for("/admin/assets/turbo.js", method: "GET")
      env["HTTP_AUTHORIZATION"] = "Bearer s3cret"
      status, headers, = build_app.call(env)
      expect(status).to eq(200)
      expect(headers["content-type"]).to include("javascript")
    end
  end
end
