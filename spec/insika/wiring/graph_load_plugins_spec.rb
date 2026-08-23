# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# The boot step behind every root's `load_plugins`: discovers plugins from the
# three kinds of root (workspace env / announced gem / bundled), registers into
# an already-built graph and folds skill/prompt dirs into the catalogs at the
# LOWEST precedence. The Loader's own mechanics live in plugin/loader_spec.rb —
# this covers the wiring: env switches, root precedence, catalog fold.
RSpec.describe "Insika::Wiring::Graph.load_plugins" do
  around do |example|
    Dir.mktmpdir { |d| @tmp = d; example.run }
  ensure
    Insika::Plugin.reset_announced!
  end

  let(:graph_class) do
    Struct.new(
      :code_tool_registry, :workflow_registry, :policy_registry, :capability_registry,
      :channel_registry, :hooks, :middleware, :context_providers,
      :skill_catalog, :prompt_catalog, :event_stream, keyword_init: true
    )
  end

  let(:workspace_skills) { File.join(@tmp, "workspace-skills") }
  let(:graph) do
    graph_class.new(
      code_tool_registry: Insika::ToolRegistry.new,
      workflow_registry: Insika::WorkflowRegistry.new,
      policy_registry: Insika::PolicyRegistry.new,
      capability_registry: Insika::CapabilityRegistry.new,
      channel_registry: Insika::ChannelRegistry.new,
      hooks: Insika::Hooks.new,
      middleware: Insika::MiddlewareStack.new([]),
      context_providers: [],
      skill_catalog: Insika::SkillCatalog.new([workspace_skills]),
      prompt_catalog: Insika::PromptCatalog.new([]),
      event_stream: SpyEventStream.new
    )
  end

  def write_skill(root, name, description)
    dir = File.join(root, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"),
               "---\nname: #{name}\ndescription: #{description}\n---\nbody of #{name}\n")
  end

  def write_plugin(root_dir, id, mod_name, contracts: "{ tools: [] }", body: "def self.register(api) = nil", skills: nil)
    dir = File.join(root_dir, id)
    FileUtils.mkdir_p(dir)
    manifest = +"id: #{id}\nmodule: #{mod_name}\nentry: plugin.rb\ncontracts: #{contracts}\n"
    manifest << "skills: [skills]\n" if skills
    File.write(File.join(dir, "insika.plugin.yml"), manifest)
    File.write(File.join(dir, "plugin.rb"), "module #{mod_name}\n#{body}\nend\n")
    Array(skills).each { |(name, desc)| write_skill(File.join(dir, "skills"), name, desc) }
    dir
  end

  def load_plugins(env)
    Insika::Wiring::Graph.load_plugins(graph, env: env)
  end

  it "loads an INSIKA_PLUGIN_DIR plugin enabled via INSIKA_PLUGINS into every graph seam" do
    workspace = File.join(@tmp, "plugins")
    write_plugin(workspace, "acme", "WiringAcmePlugin",
                 contracts: "{ tools: [acme_ping] }",
                 body: <<~RUBY,
                   class Mw
                     def call(state, &nxt) = nxt.call(state << :acme)
                   end
                   def self.register(api)
                     api.register_tool("acme_ping", Class.new)
                     api.register_middleware(Mw.new)
                     api.register_context_provider(:acme_provider)
                   end
                 RUBY
                 skills: [%w[acme-howto from-plugin]])

    result = load_plugins("INSIKA_PLUGIN_DIR" => workspace, "INSIKA_PLUGINS" => "acme")

    expect(result[:plugins].map(&:id)).to eq(["acme"])
    expect(graph.code_tool_registry.names).to include("acme_ping")
    expect(graph.middleware.call([]) { |s| s }).to eq([:acme]) # the appended link runs
    expect(graph.context_providers).to include(:acme_provider)
    expect(graph.skill_catalog.find("acme-howto")&.description).to eq("from-plugin")
  end

  it "plugin skills join at the LOWEST precedence: the workspace root's skill wins" do
    write_skill(workspace_skills, "greeting", "from-workspace")
    workspace = File.join(@tmp, "plugins")
    write_plugin(workspace, "greeter", "WiringGreeterPlugin",
                 skills: [%w[greeting from-plugin], %w[farewell plugin-only]])

    load_plugins("INSIKA_PLUGIN_DIR" => workspace, "INSIKA_PLUGINS" => "greeter")

    expect(graph.skill_catalog.find("greeting").description).to eq("from-workspace")
    expect(graph.skill_catalog.find("farewell").description).to eq("plugin-only")
  end

  it "a bundled-root plugin does not load without INSIKA_PLUGINS naming it" do
    bundled = File.join(@tmp, "bundled")
    write_plugin(bundled, "dormant", "WiringDormantPlugin")

    result = Insika::Wiring::Graph.load_plugins(graph, env: {}, bundled_root: bundled)

    expect(result[:plugins]).to be_empty
  end

  it "an announced gem root is default-enabled, and INSIKA_PLUGINS_DISABLED vetoes it" do
    gem_root = File.join(@tmp, "gem")
    write_plugin(gem_root, "shipped", "WiringShippedPlugin")
    Insika::Plugin.announce(gem_root)

    expect(load_plugins({})[:plugins].map(&:id)).to eq(["shipped"])
    expect(load_plugins("INSIKA_PLUGINS_DISABLED" => " shipped ")[:plugins]).to be_empty
  end
end
