# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require_relative "../../lib/insika/studio/app"

RSpec.describe "Studio operation screens" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:sessions) { Insika::SessionStore.new(store: backend) }
  let(:tasks) { Insika::TaskStore.new(store: backend) }
  let(:memory) { Insika::MemoryStore.new(store: backend) }
  let(:traces) { Insika::ToolTraceStore.new(store: backend) }
  let(:followups) { Insika::FollowupStore.new(store: backend) }
  let(:agent) { Insika::AgentProfile.build(id: "support", followup: { "policy" => {} }) }
  let(:app) do
    Class.new(Studio::App).tap do |app|
      app.configure(command_bus: double(registered?: true),
                    profile_source: double(all: [agent], ids: [agent.id], fetch: agent),
                    event_stream: nil, config: { admin_token: "secret" }, session_secret: "s" * 64,
                    session_store: sessions, task_store: tasks, memory_store: memory,
                    tool_trace_store: traces, followup_store: followups)
    end
  end

  def request(method, path, **options)
    response = Rack::MockRequest.new(app).request(method, path, **options.merge("HTTP_COOKIE" => @cookie.to_s))
    if (cookie = response.headers["set-cookie"])
      @cookie = Array(cookie).map { |value| value.split(";").first }.join("; ")
    end
    response
  end

  before do
    form = request("GET", "/login")
    csrf = form.body[/name="_csrf" value="([^"]+)"/, 1]
    request("POST", "/login", params: { token: "secret", _csrf: csrf })
  end

  it "keeps the selected session's continuation action and stream status inside the frame" do
    sessions.create(id: "chat-1", vars: { "agent" => "support", "customer" => "<b>Ada</b>" })
    traces.record(session_id: "chat-1", entry: { turn: 1, tool: "lookup", result: { error: "timeout" } })
    response = request("GET", "/sessions/chat-1", "HTTP_TURBO_FRAME" => "session-detail")
    expect(response.status).to eq(200)
    expect(response.body).to include('data-live-transcript-session-value="chat-1"',
                                     'data-live-transcript-target="status"', '&lt;b&gt;Ada&lt;/b&gt;')
    expect(response.body).to include('href="/studio/playground?session_id=chat-1" data-turbo-frame="_top"')
    expect(response.body).to match(/<summary>Tool calls.*?1 failed or blocked.*?<\/summary>/m)
    expect(response.body).not_to include('operation-head', '<b>Ada</b>')
  end

  it "shows execution errors before the collapsed command and model diagnostics" do
    tasks.create(id: "task-1", session_id: "chat-1", command: { type: "send_message" })
    tasks.begin_execution("task-1")
    tasks.transition("task-1", to: :running)
    tasks.transition("task-1", to: :failed, error: "<script>failed</script>")
    body = request("GET", "/tasks/task-1").body
    expect(body.index('&lt;script&gt;failed&lt;/script&gt;')).to be < body.index('<summary>Command</summary>')
    expect(body).to include('<details class="card operation-diagnostics">', '<summary>Model requests')
    expect(body).not_to include('<script>failed</script>')
  end

  it "reads escaped facts before editing and preserves the agent scope in the customer frame" do
    memory.put_fact(tenant: "support", customer: "ada", key: "preference", value: "<img src=x>")
    body = request("GET", "/customers/support:ada?agent=support", "HTTP_TURBO_FRAME" => "customer-detail").body
    expect(body.index('&lt;img src=x&gt;')).to be < body.index('Add or update a fact')
    expect(body).to include('for="customer-fact-key"', 'for="customer-fact-value"', 'for="customer-fact-expiry"')
    expect(body.scan('name="agent" value="support"').size).to eq(4)
    expect(body).to include('name="_csrf"', 'name="key" value="preference"')
    expect(body).not_to include('<img src=x>')
  end

  it "preserves the agent filter on session navigation and customer action redirects" do
    sessions.create(id: "chat-1", vars: { "agent" => "support" })
    sessions.create(id: "other-chat", vars: { "agent" => "another-agent" })
    body = request("GET", "/sessions/chat-1?agent=support").body
    expect(body).to include('href="/studio/sessions/chat-1?agent=support"')
    expect(body).not_to include('href="/studio/sessions/other-chat')
    memory.put_fact(tenant: "support", customer: "ada", key: "size", value: "M")
    body = request("GET", "/customers/support:ada?agent=support").body
    expect(body).to include('/export" data-turbo="false"', '/forget" data-turbo-frame="_top"')
    allow(app.insika[:command_bus]).to receive(:dispatch).and_return({ ok: true })
    csrf = body[/name="_csrf" value="([^"]+)"/, 1]
    params = { agent: "support", _csrf: csrf, key: "size", value: "L" }
    saved = request("POST", "/customers/support:ada/fact", params: params)
    expect(saved["location"]).to eq("/studio/customers/support:ada?agent=support")
    forgotten = request("POST", "/customers/support:ada/forget", params: params)
    expect(forgotten["location"]).to eq("/studio/customers?agent=support")
  end

  it "filters follow-ups without hiding the pending actions or their conversation link" do
    followups.create(id: "follow-1", tenant: "platform", agent: "support", customer: "ada",
                     session_id: "chat-1", at: Time.now.utc + 3600, reason: "<em>Check in</em>", arm: "schedule")
    body = request("GET", "/followups?agent=support").body
    expect(body).to include('aria-label="Filter follow-ups"', 'data-list-filter-target="item"', '&lt;em&gt;Check in&lt;/em&gt;')
    expect(body).to include('href="/studio/sessions/chat-1"', '/studio/followups/support/cancel', '/studio/followups/support/revoke')
    expect(body).to include('<summary>Follow-up policy</summary>', 'name="tenant" value="platform"')
    expect(body).not_to include('<em>Check in</em>')
  end
end
