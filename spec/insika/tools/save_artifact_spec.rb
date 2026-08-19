# frozen_string_literal: true

require "spec_helper"
require "insika/tools/save_artifact" # the Executor loads it lazily; explicit in the test

# the `save_artifact` tool: the agent hands in title + content and
# gets the URL back. A REGISTRY tool (allowlisted per agent — the allowlist IS
# the switch); the tenant/agent/task bindings come from the deposited turn
# context, never from the model's arguments.
RSpec.describe Insika::Tools::SaveArtifact do
  let(:backend) { Insika::Stores::Memory.new }
  let(:artifact_store) { Insika::ArtifactStore.new(store: backend) }
  let(:stream) { SpyEventStream.new }
  let(:now) { Time.iso8601("2026-08-19T12:00:00Z") }

  def tool(store: artifact_store, base_url: "https://insika.example", signing_key: nil,
           signing_ttl: nil, event_stream: stream, max_bytes: nil)
    described_class.new(artifact_store: store, base_url: base_url,
                        signing_key: signing_key, signing_ttl: signing_ttl,
                        event_stream: event_stream, max_bytes: max_bytes)
  end

  def bound(t, tenant: "acme", agent: "reporter", task_id: "t-1")
    t.turn_context = { command_tenant: tenant, agent_id: agent, task_id: task_id }
    t
  end

  it "saves the artifact under the TURN's bindings and returns the URL" do
    t = bound(tool, tenant: "acme", agent: "reporter", task_id: "t-1")
    result = t.execute(title: "Daily report", content: "<h1>Report</h1>", mime: "text/html")

    expect(result[:id]).not_to be_nil
    expect(result[:url]).to eq("https://insika.example/studio/artifacts/#{result[:id]}/content")
    record = artifact_store.find(result[:id])
    expect(record.tenant).to eq("acme")
    expect(record.agent).to eq("reporter")
    expect(record.task_id).to eq("t-1")
    expect(record.title).to eq("Daily report")
    expect(record.mime).to eq("text/html")
  end

  it "single-tenant (no declared tenant) binds the 'platform' cell — the agent's tenant, not the chat's" do
    t = bound(tool, tenant: nil, agent: "reporter", task_id: nil)
    result = t.execute(title: "Report", content: "x")
    expect(artifact_store.find(result[:id]).tenant).to eq("platform")
  end

  it "with the signing key + ttl, the result ALSO carries a signed_url" do
    t = bound(tool(signing_key: "k3y" * 8, signing_ttl: 3600))
    result = t.execute(title: "Daily report", content: "<h1>Report</h1>")
    expect(result[:signed_url]).to match(%r{\Ahttps://insika\.example/studio/artifacts/s/#{result[:id]}\?exp=[^&]+&sig=[0-9a-f]{64}\z})
    expect(result[:url]).to eq("https://insika.example/studio/artifacts/#{result[:id]}/content")
  end

  it "without the signing key, no signed_url key at all (no signed surface)" do
    result = bound(tool).execute(title: "Daily report", content: "<h1>Report</h1>")
    expect(result).not_to have_key(:signed_url)
  end

  it "without a base URL, the url is the relative path" do
    result = bound(tool(base_url: nil)).execute(title: "Daily report", content: "x")
    expect(result[:url]).to eq("/studio/artifacts/#{result[:id]}/content")
  end

  it "mime defaults to text/html" do
    result = bound(tool).execute(title: "Daily report", content: "x")
    expect(artifact_store.find(result[:id]).mime).to eq("text/html")
  end

  it "a store refusal becomes { error: } the model can act on (never a raise)" do
    result = bound(tool).execute(title: "", content: "x")
    expect(result[:error]).to match(/title/)
    expect(bound(tool).execute(title: "x", content: "y", mime: "application/pdf")[:error]).to match(/mime/)
  end

  it "respects the deployment's max_bytes (INSIKA_ARTIFACT_MAX_BYTES), not only the store default" do
    t = bound(tool(max_bytes: 10))
    expect(t.execute(title: "Report", content: "x" * 11)[:error]).to match(/content/)
    expect(t.execute(title: "Report", content: "x" * 10)[:id]).not_to be_nil
  end

  it "emits :artifact_saved with ids + title, NEVER the content" do
    bound(tool).execute(title: "Daily report", content: "<h1>top-secret</h1>")
    ev = stream.events.find { |e| e.type == :artifact_saved }
    expect(ev.data[:id]).not_to be_nil
    expect(ev.data[:title]).to eq("Daily report")
    expect(ev.data.to_s).not_to include("top-secret")
  end

  describe "the allowlist is the switch (registry + policy)" do
    let(:registry) { Insika::ToolRegistry.new }

    def decide_for(profile, candidates)
      request = Insika::Policy::PolicyRequest.new(
        profile: profile, command: nil, context: nil,
        candidate_tools: candidates, candidate_skills: []
      )
      Insika::Policy::Builtin::ToolAllowlist.new.decide(request)
    end

    it "save_artifact is registered OPTIONAL, so an agent without it in tools_allow is denied" do
      registry.register("save_artifact", optional: true) { Object.new }
      entry = registry.entries.find { |e| e.name == "save_artifact" }
      expect(entry.metadata[:optional]).to be(true)

      profile = Insika::AgentProfile.build(id: "reporter", model: "m", tools_allow: %w[menu])
      decision = decide_for(profile, [entry])
      expect(decision.deny_tools).to include("save_artifact")
    end

    it "an agent WITH save_artifact in tools_allow may call it — and only then" do
      registry.register("save_artifact", optional: true) { Object.new }
      entry = registry.entries.find { |e| e.name == "save_artifact" }

      profile = Insika::AgentProfile.build(id: "reporter", model: "m", tools_allow: %w[save_artifact])
      decision = decide_for(profile, [entry])
      expect(decision.deny_tools).not_to include("save_artifact")
      expect(decision.allow_tools).to include("save_artifact")
    end
  end
end