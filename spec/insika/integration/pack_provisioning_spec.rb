# frozen_string_literal: true

require "spec_helper"

# (tasks 7-8) — end-to-end provisioning: the PackImporter emits the
# REAL authoring Commands over REAL stores. Proves that "provision 1 store"
# actually works (the payloads the importer builds are accepted by the Commands)
# and produces a USABLE agent: profile with correct allowlists, files in the
# AgentFileStore, skills in the catalog and data-tools in the registry.
RSpec.describe "Integration: pack provisioning" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }
  let(:agent_files) { Insika::AgentFileStore.new(config_store: config_store) }
  let(:skill_store) { Insika::SkillStore.new(config_store: config_store) }
  let(:skill_catalog) { Insika::SkillCatalog.new([], store: skill_store) }
  let(:tool_store) { Insika::ToolStore.new(config_store: config_store) }
  let(:registry) do
    Insika::OverlayToolRegistry.new(base: Insika::ToolRegistry.new, tool_store: tool_store,
                                     http: Object.new, event_stream: event_stream)
  end
  let(:tool_catalog) { Insika::ToolCatalog.new(tool_registry: registry) }
  let(:event_stream) { Class.new { def emit(_e) = nil }.new }

  let(:bus) do
    b = Insika::CommandBus.new
    b.register(:create_agent, Insika::Commands::CreateAgent.new(profile_source: profiles, event_stream: event_stream))
    b.register(:update_agent, Insika::Commands::UpdateAgent.new(profile_source: profiles, event_stream: event_stream))
    b.register(:delete_agent, Insika::Commands::DeleteAgent.new(profile_source: profiles, event_stream: event_stream))
    b.register(:write_agent_file, Insika::Commands::WriteAgentFile.new(profile_source: profiles, agent_file_store: agent_files, event_stream: event_stream))
    b.register(:write_skill, Insika::Commands::WriteSkill.new(skill_store: skill_store, skill_catalog: skill_catalog, event_stream: event_stream))
    b.register(:write_data_tool, Insika::Commands::WriteDataTool.new(tool_store: tool_store, registry: registry, tool_catalog: tool_catalog, event_stream: event_stream))
    b
  end

  let(:importer) { Insika::PackImporter.new(bus: bus, profiles: profiles) }

  let(:pack) do
    Insika::Pack.from_h(
      config: { id: "loja-7", model: "deepseek-chat", provider: "deepseek", metadata: { store_id: "7" } },
      files: { "IDENTITY.md" => "Sou a BIA da loja 7.", "SOUL.md" => "Tom caloroso." },
      skills: { "escalation" => "---\nname: escalation\ndescription: talk to a human\n---\nbody",
                "promo" => "---\nname: promo\ndescription: promotions\n---\nbody" },
      tools: [{ "name" => "add_to_cart", "description" => "adiciona ao carrinho",
                "request" => { "method" => "POST", "url" => "https://api.internal/agent_tools/cart",
                               "headers" => { "X-Chat-Id" => "{{ctx.chat_id}}", "X-Store-Id" => "{{ctx.store_id}}" } },
                "secret_headers" => ["Authorization"] }]
    )
  end

  it "creates a USABLE agent: profile + files + skills + data-tools" do
    result = importer.import(pack)
    expect(result).to include(agent_id: "loja-7", created: true)

    profile = profiles.fetch("loja-7")
    expect(profile.model).to eq("deepseek-chat")
    expect(profile.provider).to eq(:deepseek)          # symbol preserved on the round-trip
    expect(profile.store_id).to eq("7")                # metadata -> ctx.store_id
    expect(profile.prompt_files).to contain_exactly("IDENTITY.md", "SOUL.md")
    expect(profile.skills).to contain_exactly("escalation", "promo")
    expect(profile.tools_allow).to include("add_to_cart")

    # files written and readable (the Prompt provider reads from here)
    expect(agent_files.read("loja-7", "IDENTITY.md")).to eq("Sou a BIA da loja 7.")

    # skills are effective in the catalog (write_skill reloaded)
    expect(skill_catalog.find("escalation")).not_to be_nil
    expect(skill_catalog.find("promo").description).to eq("promotions")

    # data-tool in the registry (overlay reload) and resolvable
    expect(registry.names).to include("add_to_cart")
    expect(registry.resolve("add_to_cart").name).to eq("add_to_cart")
  end

  it "re-import is an idempotent upsert: update, without duplicating prompt_files" do
    importer.import(pack)
    result = importer.import(pack) # 2nd time: agent already exists

    expect(result[:created]).to be(false)
    profile = profiles.fetch("loja-7")
    expect(profile.prompt_files).to contain_exactly("IDENTITY.md", "SOUL.md") # no duplicate
  end

  it "re-provisioning with fewer files removes what left the pack (authoritative allowlist)" do
    importer.import(pack)
    slim = Insika::Pack.from_h(
      config: { id: "loja-7", model: "deepseek-chat" },
      files: { "IDENTITY.md" => "nova identidade" }, skills: {}, tools: []
    )
    importer.import(slim)

    profile = profiles.fetch("loja-7")
    expect(profile.prompt_files).to eq(["IDENTITY.md"]) # SOUL.md removed
    expect(agent_files.read("loja-7", "IDENTITY.md")).to eq("nova identidade") # content rewritten
  end

  it "delete removes the agent" do
    importer.import(pack)
    importer.delete("loja-7")
    expect(profiles.fetch("loja-7")).to be_nil
  end
end
