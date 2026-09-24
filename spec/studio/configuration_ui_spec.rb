# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require_relative "../../lib/insika/studio/app"

RSpec.describe "Studio configuration editing" do
  let(:profile) { Insika::AgentProfile.build(id: "assistant", model: "example", memory: true, limits: { queue_mode: "collect", debounce_ms: 250 }) }
  let(:config_store) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }
  let(:mcp_store) { Insika::McpStore.new(config_store: config_store) }
  let(:tool_store) { Insika::ToolStore.new(config_store: config_store) }
  let(:profiles) do
    Insika::StoredProfileSource.new(config_store: config_store).tap do |source|
      source.put(profile)
      source.put(Insika::AgentProfile.build(id: "other", memory: true))
    end
  end
  let(:bus) do
    Insika::CommandBus.new.tap do |bus|
      bus.register(:update_agent, Insika::Commands::UpdateAgent.new(
        profile_source: profiles, event_stream: Insika::EventStream.new
      ))
    end
  end
  let(:app) do
    Class.new(Studio::App).tap do |app|
      app.configure(
        command_bus: bus,
        profile_source: profiles,
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
    expect(form).to include('<legend>Model</legend>', '<legend>Response generation')
    expect(form).to match(/<details class="newfile">\s*<summary>Messages received while busy<\/summary>.*?name="queue_mode".*?value="collect" selected.*?name="debounce_ms" value="250".*?<\/details>/m)
    expect(form).to include('name="model_policy_allow"', 'name="guardrail_input"', 'name="metadata"')
  end

  def save_retrieval(params)
    csrf = request("/agents/assistant?tab=config&cfg=retrieval").body[/name="_csrf" value="([^"]+)"/, 1]
    request("/agents/assistant/config", method: :post,
      params: { "cfg" => "retrieval", "memory" => "1", "_csrf" => csrf }.merge(params))
  end

  def rerank_fields(source, **overrides)
    { "#{source}_rerank_enabled" => "1", "#{source}_top_k" => "3",
      "#{source}_rerank_provider" => "cohere", "#{source}_rerank_model" => "rerank-v3.5",
      "#{source}_rerank_candidate_limit" => "20", "#{source}_rerank_timeout_seconds" => "1.5"
    }.merge(overrides.transform_keys { |key| "#{source}_#{key}" })
  end

  it "shows memory and knowledge controls with reranking off by default" do
    body = request("/agents/assistant?tab=config&cfg=retrieval").body
    expect(body).to include('data-config-group="retrieval">', 'name="cfg" value="retrieval"')
    expect(body).to match(/name="memory" value="1" checked/)
    %w[memory_rerank_enabled knowledge_rerank_enabled knowledge_extract knowledge_retrieve].each do |name|
      expect(body).to match(/name="#{name}" value="1">/)
    end
  end

  it "persists separate rerank settings, extraction and retrieval for only the selected agent" do
    response = save_retrieval(rerank_fields("memory").merge(
      rerank_fields("knowledge", top_k: "4", rerank_candidate_limit: "30"),
      "knowledge_extract" => "1", "knowledge_retrieve" => "1",
      "knowledge_types" => "fact, policy", "knowledge_model" => "deepseek-v4-flash",
      "knowledge_prompt" => "Keep durable policies <only>"
    ))
    expect(response.headers["location"]).to include("cfg=retrieval")
    saved = profiles.fetch("assistant")
    expect(saved.memory).to be(true)
    expect(saved.memory_retrieval).to eq("top_k" => 3, "rerank" => {
      "provider" => "cohere", "model" => "rerank-v3.5", "candidate_limit" => 20, "timeout_seconds" => 1.5
    })
    expect(saved.knowledge).to include("extract" => true, "retrieve" => true, "top_k" => 4,
      "types" => %w[fact policy], "model" => "deepseek-v4-flash", "prompt" => "Keep durable policies <only>")
    expect(saved.knowledge.dig("rerank", "candidate_limit")).to eq(30)
    body = request("/agents/assistant?tab=config&cfg=retrieval").body
    expect(body).to include('name="memory_top_k" value="3"', 'name="knowledge_top_k" value="4"')
    expect(body).to include('name="knowledge_rerank_candidate_limit" value="30"', 'Keep durable policies &lt;only&gt;')
    expect(body).to match(/name="memory_rerank_enabled" value="1" checked/)
    expect(profiles.fetch("other").memory_retrieval).to be_nil
    expect(profiles.fetch("other").knowledge).to be_nil
  end

  it "disables reranking without disabling memory or knowledge and preserves unexposed pack keys" do
    ranking = { "provider" => "cohere", "model" => "rerank-v3.5", "candidate_limit" => 20, "timeout_seconds" => 2 }
    profiles.put(Insika::AgentProfile.build(id: "assistant", memory: true,
      memory_retrieval: { top_k: 5, rerank: ranking },
      knowledge: { extract: true, retrieve: true, rerank: ranking, index: "scan" }))
    save_retrieval("knowledge_extract" => "1", "knowledge_retrieve" => "1", "knowledge_top_k" => "7",
      "memory_rerank_model" => "stale value", "memory_rerank_timeout_seconds" => "bad")
    saved = profiles.fetch("assistant")
    expect(saved.memory).to be(true)
    expect(saved.memory_retrieval).to be_nil
    expect(saved.knowledge).to eq("extract" => true, "retrieve" => true, "top_k" => 7, "index" => "scan")
  end

  it "lets knowledge extraction and retrieval run independently of memory" do
    save_retrieval("memory" => "0", "knowledge_extract" => "1")
    saved = profiles.fetch("assistant")
    expect(saved.memory).to be(false)
    expect(saved.knowledge).to include("extract" => true, "retrieve" => false)
    save_retrieval("knowledge_retrieve" => "1")
    expect(profiles.fetch("assistant").knowledge).to include("extract" => false, "retrieve" => true)
  end

  it "rejects invalid retrieval settings without persisting any part of the form" do
    [rerank_fields("memory", rerank_candidate_limit: "two"),
     rerank_fields("memory", rerank_candidate_limit: "2"),
     rerank_fields("memory", rerank_timeout_seconds: "NaN"),
     rerank_fields("memory", rerank_model: ""),
     rerank_fields("knowledge", rerank_model: "command-r-plus"),
     { "knowledge_top_k" => "0" }].each do |fields|
      before = profiles.fetch("assistant").to_h
      response = save_retrieval(fields.merge("model" => "must-not-save"))
      expect(response.status).to eq(302)
      expect(profiles.fetch("assistant").to_h).to eq(before)
      expect(request("/agents/assistant?tab=config&cfg=retrieval").body).not_to include("Configuration saved.")
    end
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
