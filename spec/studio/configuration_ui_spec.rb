# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require_relative "../../lib/insika/studio/app"

RSpec.describe "Studio configuration editing" do
  let(:profile) { Insika::AgentProfile.build(id: "assistant", model: "example", limits: { queue_mode: "collect", debounce_ms: 250 }) }
  let(:config_store) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }
  let(:mcp_store) { Insika::McpStore.new(config_store: config_store) }
  let(:tool_store) { Insika::ToolStore.new(config_store: config_store) }
  let(:app) do
    Class.new(Studio::App).tap do |app|
      app.configure(
        command_bus: double(registered?: false),
        profile_source: double(all: [profile], ids: [profile.id], fetch: profile),
        event_stream: nil, config: { admin_token: "secret" },
        mcp_store: mcp_store, tool_store: tool_store, session_secret: "x" * 64
      )
    end
  end

  def request(path, method: :get, params: {})
    response = Rack::MockRequest.new(app).public_send(method, path, "HTTP_COOKIE" => @cookie.to_s, params: params)
    @cookie = Array(response.headers["set-cookie"]).map { |value| value.split(";").first }.join("; ") if response.headers["set-cookie"]
    response
  end

  before do
    csrf = request("/login").body[/name="_csrf" value="([^"]+)"/, 1]
    request("/login", method: :post, params: { "token" => "secret", "_csrf" => csrf })
  end

  it "keeps advanced agent controls inside the guarded config form with their saved values" do
    response = request("/agents/assistant")
    expect(response.status).to eq(200)
    form = response.body[/<form id="config-form".*?<\/form>/m]
    expect(form).to include('data-controller="dirty-guard"', 'name="_csrf"', 'name="cfg" value="model"')
    expect(form).to include('<legend>Model &amp; memory</legend>', '<legend>Response generation')
    expect(form).to match(/<details class="newfile">\s*<summary>Messages received while busy<\/summary>.*?name="queue_mode".*?value="collect" selected.*?name="debounce_ms" value="250".*?<\/details>/m)
    expect(form).to include('name="model_policy_allow"', 'name="guardrail_input"', 'name="metadata"')
  end

  it "keeps request credentials visible when editing a configured HTTP tool" do
    tool_store.write({
      "name" => "lookup", "description" => "Find a record", "parameters" => [],
      "request" => { "method" => "GET", "url" => "https://example.com", "headers" => { "Authorization" => "private-token" } },
      "secret_headers" => ["Authorization"], "response" => { "extract" => "body_raw" }
    })
    response = request("/tools/def/lookup")
    expect(response.status).to eq(200)
    expect(response.body).to match(/<details class="newfile" open>\s*<summary>Query, headers &amp; request body<\/summary>.*?name="headers".*?name="secret_headers".*?<\/details>/m)
    expect(response.body).to include('name="parameters"', 'name="requires_evidence"', 'name="_csrf"')
    expect(response.body).not_to include("private-token")
  end

  it "escapes MCP connection metadata and clarifies that testing uses saved settings" do
    mcp_store.upsert(name: "search", transport: "http", url: "https://example.com/<script>alert(1)</script>", description: "<img src=x onerror=alert(1)>", enabled: true)
    response = request("/mcp")
    expect(response.status).to eq(200)
    expect(response.body).to include("&lt;script&gt;", "&lt;img", "Save changes before testing the connection.", 'data-controller="transport-fields dirty-guard"')
    expect(response.body).not_to include("<script>alert(1)</script>", "<img src=x onerror=alert(1)>")
    expect(response.body).to include('action="/studio/mcp/test"', 'name="name" value="search"')
  end

  it "saves per-model reasoning separately from platform model defaults" do
    response = request("/settings?s=models")
    expect(response.status).to eq(200)
    defaults = response.body[/<form id="set-models".*?<\/form>/m]
    reasoning = response.body[/<form id="set-model-params".*?<\/form>/m]
    expect(defaults).to include('action="/studio/settings/models"', 'name="default_model"', 'name="_csrf"')
    expect(defaults).not_to include('name="model_params"')
    expect(reasoning).to include('action="/studio/settings/model-params"', 'name="model_params"', 'name="_csrf"')
    expect(response.body).to include('form="set-models"', "Save model defaults", "Saved separately from platform model defaults.")
  end
end
