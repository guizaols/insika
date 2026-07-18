# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Harness::Plugin::Loader do
  around do |example|
    Dir.mktmpdir { |d| @root = d; example.run }
  end

  # Real registries (task 20) + real hooks + collections + event spy.
  let(:tools) { Harness::ToolRegistry.new }
  let(:workflows) { Harness::WorkflowRegistry.new }
  let(:policies) { Harness::PolicyRegistry.new }
  let(:capabilities) { Harness::CapabilityRegistry.new }
  let(:hooks) { Harness::Hooks.new }
  let(:middleware) { [] }
  let(:context_providers) { [] }
  let(:event_stream) { SpyEventStream.new } # spec/support/fakes.rb

  def registries
    { tools: tools, workflows: workflows, policies: policies, capabilities: capabilities,
      hooks: hooks, middleware: middleware, context_providers: context_providers }
  end

  # Writes a plugin (manifest + Ruby PORO entry — no ruby_llm).
  def write_plugin(id, manifest_yaml, entry_ruby, manifest_name: "harness.plugin.yml")
    dir = File.join(@root, id)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, manifest_name), manifest_yaml)
    File.write(File.join(dir, "plugin.rb"), entry_ruby) if entry_ruby
    dir
  end

  def load(enabled:)
    described_class.new(roots: [@root], registries: registries,
                        enabled: enabled, event_stream: event_stream).load_all
  end

  # Nameable PORO plugin module (avoids constant collision between examples).
  def poro_entry(mod_name, body)
    <<~RUBY
      module #{mod_name}
        #{body}
      end
    RUBY
  end

  it "loads a new manifest and registers the tool with manifest metadata" do
    write_plugin("alpha", <<~YAML, poro_entry("AlphaPlugin", <<~BODY))
      id: alpha
      module: AlphaPlugin
      entry: plugin.rb
      contracts: { tools: [greet] }
      tool_metadata: { greet: { side_effect: true } }
    YAML
      def self.register(api) = api.register_tool("greet", Class.new)
    BODY

    result = load(enabled: %w[alpha])

    expect(tools.names).to eq(["greet"])
    entry = tools.entries.first
    expect(entry.plugin).to eq("alpha")
    expect(entry.metadata[:side_effect]).to be(true)
    expect(result[:plugins].map(&:id)).to eq(["alpha"])
  end

  it "accepts old plugin.yml with a deprecation warning" do
    write_plugin("beta", <<~YAML, poro_entry("BetaPlugin", "def self.register(api) = nil"), manifest_name: "plugin.yml")
      id: beta
      module: BetaPlugin
      entry: plugin.rb
      contracts: { tools: [] }
    YAML

    expect { load(enabled: %w[beta]) }.to output(/plugin.yml is deprecated/).to_stderr
  end

  it "harness.plugin.yml takes precedence over plugin.yml in the same dir (no warn)" do
    dir = File.join(@root, "gamma")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "harness.plugin.yml"), "id: gamma\ncontracts: { tools: [] }\n")
    File.write(File.join(dir, "plugin.yml"), "id: gamma_old\ncontracts: { tools: [] }\n")

    result = nil
    expect { result = load(enabled: %w[gamma gamma_old]) }.not_to output(/deprecado/).to_stderr
    expect(result[:plugins].map(&:id)).to eq(["gamma"])
  end

  it "registers a workflow declared in contracts.workflows" do
    write_plugin("wf", <<~YAML, poro_entry("WfPlugin", <<~BODY))
      id: wf
      module: WfPlugin
      entry: plugin.rb
      contracts: { workflows: [flow] }
    YAML
      def self.register(api) = api.register_workflow("flow", ->(i, **) { i })
    BODY

    load(enabled: %w[wf])
    expect(workflows.names).to eq(["flow"])
  end

  it "ignores a workflow outside contracts.workflows with a warn" do
    write_plugin("wf2", <<~YAML, poro_entry("Wf2Plugin", <<~BODY))
      id: wf2
      module: Wf2Plugin
      entry: plugin.rb
      contracts: { workflows: [declarado] }
    YAML
      def self.register(api) = api.register_workflow("naodeclarado", ->(i, **) { i })
    BODY

    expect { load(enabled: %w[wf2]) }.to output(/not declared in contracts.workflows/).to_stderr
    expect(workflows.names).to eq([])
  end

  it "middleware/hook/provider/policy without a contract: committed after load" do
    write_plugin("full", <<~YAML, poro_entry("FullPlugin", <<~BODY))
      id: full
      module: FullPlugin
      entry: plugin.rb
      contracts: { tools: [] }
    YAML
      MW = Object.new
      PROV = Object.new
      class Pol < Harness::Policy::Base
        def decide(_r) = nil
      end
      def self.register(api)
        api.register_middleware(MW)
        api.register_context_provider(PROV)
        api.register_hook(:tool, before: ->(x) { x })
        api.register_policy("pol", Pol)
      end
    BODY

    load(enabled: %w[full])

    expect(middleware).to eq([FullPlugin::MW])
    expect(context_providers).to eq([FullPlugin::PROV])
    expect(policies.names).to eq(["pol"])
    # hook committed: run_before(:tool) runs the callback
    expect(hooks.run_before(:tool, "x")).to eq("x")
  end

  it "valid config_schema: plugin loads and api.config is the frozen config" do
    write_plugin("cfg", <<~YAML, poro_entry("CfgPlugin", <<~BODY))
      id: cfg
      module: CfgPlugin
      entry: plugin.rb
      contracts: { tools: [] }
      config_schema:
        type: object
        additionalProperties: false
        properties: { timeout: { type: integer } }
      config: { timeout: 30 }
    YAML
      SEEN = []
      def self.register(api) = SEEN << api.config
    BODY

    load(enabled: %w[cfg])
    expect(CfgPlugin::SEEN.first).to eq({ "timeout" => 30 })
    expect(CfgPlugin::SEEN.first).to be_frozen
  end

  it "invalid config: plugin does NOT load, warn, boot continues (another plugin loads)" do
    write_plugin("bad", <<~YAML, poro_entry("BadPlugin", "def self.register(api) = raise('should not load')"))
      id: bad
      module: BadPlugin
      entry: plugin.rb
      contracts: { tools: [] }
      config_schema: { type: object, properties: { timeout: { type: integer } } }
      config: { timeout: trinta }
    YAML
    write_plugin("ok", <<~YAML, poro_entry("OkPlugin", "def self.register(api) = api.register_tool('t', Class.new)"))
      id: ok
      module: OkPlugin
      entry: plugin.rb
      contracts: { tools: [t] }
    YAML

    result = nil
    expect { result = load(enabled: %w[bad ok]) }.to output(/invalid config/).to_stderr
    expect(result[:plugins].map(&:id)).to eq(["ok"])
    expect(tools.names).to eq(["t"])
  end

  it "rollback: entry registers 1 tool then raises -> tool removed, plugin discarded, next one loads" do
    write_plugin("boom", <<~YAML, poro_entry("BoomPlugin", <<~BODY))
      id: boom
      module: BoomPlugin
      entry: plugin.rb
      contracts: { tools: [t1] }
      skills: [skills]
    YAML
      def self.register(api)
        api.register_tool("t1", Class.new)
        raise "failure in the middle of register"
      end
    BODY
    write_plugin("after", <<~YAML, poro_entry("AfterPlugin", "def self.register(api) = api.register_tool('t2', Class.new)"))
      id: after
      module: AfterPlugin
      entry: plugin.rb
      contracts: { tools: [t2] }
    YAML

    result = nil
    expect { result = load(enabled: %w[boom after]) }.to output(/failed to load/).to_stderr
    expect(tools.names).to eq(["t2"]) # t1 reverted
    expect(result[:plugins].map(&:id)).to eq(["after"])
    expect(result[:skill_dirs]).not_to include(a_string_including("boom"))
  end

  it "staging discarded: middleware is left out if register raises (L3 — no partial leftovers)" do
    write_plugin("partial", <<~YAML, poro_entry("PartialPlugin", <<~BODY))
      id: partial
      module: PartialPlugin
      entry: plugin.rb
      contracts: { tools: [] }
    YAML
      MW = Object.new
      def self.register(api)
        api.register_middleware(MW)
        api.register_hook(:tools, before: ->(x) { x }) # invalid pair (:tools) -> raises at stage
      end
    BODY

    result = nil
    expect { result = load(enabled: %w[partial]) }.to output(/failed to load/).to_stderr
    expect(middleware).to eq([]) # staged middleware was NOT committed
    expect(result[:plugins]).to eq([])
  end

  it "root precedence: same id in two roots, the first wins" do
    root_a = File.join(@root, "ra")
    root_b = File.join(@root, "rb")
    [root_a, root_b].each { |r| FileUtils.mkdir_p(File.join(r, "dup")) }
    File.write(File.join(root_a, "dup", "harness.plugin.yml"),
               "id: dup\nmodule: DupA\nentry: plugin.rb\ncontracts: { tools: [ta] }\n")
    File.write(File.join(root_a, "dup", "plugin.rb"), poro_entry("DupA", "def self.register(api) = api.register_tool('ta', Class.new)"))
    File.write(File.join(root_b, "dup", "harness.plugin.yml"),
               "id: dup\nmodule: DupB\nentry: plugin.rb\ncontracts: { tools: [tb] }\n")
    File.write(File.join(root_b, "dup", "plugin.rb"), poro_entry("DupB", "def self.register(api) = api.register_tool('tb', Class.new)"))

    loader = described_class.new(roots: [root_a, root_b], registries: registries,
                                 enabled: %w[dup], event_stream: event_stream)
    result = loader.load_all

    expect(result[:plugins].map(&:id)).to eq(["dup"])
    expect(tools.names).to eq(["ta"]) # root_a won
  end

  it "ignores a tool outside contracts.tools with a warn (Phase 0 rule)" do
    write_plugin("toolless", <<~YAML, poro_entry("ToollessPlugin", <<~BODY))
      id: toolless
      module: ToollessPlugin
      entry: plugin.rb
      contracts: { tools: [declarada] }
    YAML
      def self.register(api) = api.register_tool("naodeclarada", Class.new)
    BODY

    expect { load(enabled: %w[toolless]) }.to output(/not declared in contracts.tools/).to_stderr
    expect(tools.names).to eq([])
  end

  describe "contracts.capabilities (P2B task 4)" do
    it "declared in contracts but without register_capability: loads WITHOUT a reserved warn" do
      write_plugin("cap", <<~YAML, poro_entry("CapPlugin", "def self.register(api) = api.register_tool('t', Class.new)"))
        id: cap
        module: CapPlugin
        entry: plugin.rb
        contracts: { tools: [t], capabilities: [foo] }
      YAML

      result = nil
      expect { result = load(enabled: %w[cap]) }.not_to output(/reservado/).to_stderr
      expect(result[:plugins].map(&:id)).to eq(["cap"])
      expect(capabilities.capabilities).to eq([])
    end

    it "exposes capability_names in Discovered" do
      write_plugin("cap", "id: cap\ncontracts: { capabilities: [a, b] }\n", nil)
      result = load(enabled: %w[cap])
      expect(result[:plugins].first.capability_names).to eq(%w[a b])
    end

    it "register_capability with tool: registers a :tool Provider in the CapabilityRegistry" do
      write_plugin("cap", <<~YAML, poro_entry("CapToolPlugin", <<~BODY))
        id: cap
        module: CapToolPlugin
        entry: plugin.rb
        contracts: { tools: [browse_impl], capabilities: [browse] }
      YAML
        def self.register(api)
          api.register_tool("browse_impl", Class.new)
          api.register_capability(:browse, tool: "browse_impl", priority: 100)
        end
      BODY

      load(enabled: %w[cap])
      providers = capabilities.providers(:browse)
      expect(providers.size).to eq(1)
      expect(providers.first).to have_attributes(impl_name: "browse_impl", kind: :tool,
                                                 plugin: "cap", priority: 100)
    end

    it "register_capability with workflow: registers :workflow + warn 'without a consumer'" do
      write_plugin("cap", <<~YAML, poro_entry("CapWfPlugin", <<~BODY))
        id: cap
        module: CapWfPlugin
        entry: plugin.rb
        contracts: { workflows: [research_wf], capabilities: [research] }
      YAML
        def self.register(api)
          api.register_workflow("research_wf", -> {})
          api.register_capability(:research, workflow: "research_wf")
        end
      BODY

      expect { load(enabled: %w[cap]) }.to output(/without a consumer/).to_stderr
      expect(capabilities.providers(:research).first.kind).to eq(:workflow)
    end

    it "capability NOT declared in contracts: warn + nothing registered" do
      write_plugin("cap", <<~YAML, poro_entry("CapUndeclPlugin", <<~BODY))
        id: cap
        module: CapUndeclPlugin
        entry: plugin.rb
        contracts: { tools: [t], capabilities: [] }
      YAML
        def self.register(api)
          api.register_tool("t", Class.new)
          api.register_capability(:undeclared, tool: "t")
        end
      BODY

      expect { load(enabled: %w[cap]) }.to output(/not declared in contracts.capabilities/).to_stderr
      expect(capabilities.capabilities).to eq([])
    end

    it "tool: and workflow: together: warn + nothing registered" do
      write_plugin("cap", <<~YAML, poro_entry("CapBothPlugin", <<~BODY))
        id: cap
        module: CapBothPlugin
        entry: plugin.rb
        contracts: { capabilities: [x] }
      YAML
        def self.register(api) = api.register_capability(:x, tool: "t", workflow: "w")
      BODY

      expect { load(enabled: %w[cap]) }.to output(/only tool: OR workflow:/).to_stderr
      expect(capabilities.capabilities).to eq([])
    end

    it "without tool: or workflow: warn + nothing registered" do
      write_plugin("cap", <<~YAML, poro_entry("CapNeitherPlugin", <<~BODY))
        id: cap
        module: CapNeitherPlugin
        entry: plugin.rb
        contracts: { capabilities: [x] }
      YAML
        def self.register(api) = api.register_capability(:x)
      BODY

      expect { load(enabled: %w[cap]) }.to output(/informe tool: ou workflow:/).to_stderr
      expect(capabilities.capabilities).to eq([])
    end

    it "rollback: entry registers a capability and raises -> nothing residual in the CapabilityRegistry" do
      write_plugin("cap", <<~YAML, poro_entry("CapBoomPlugin", <<~BODY))
        id: cap
        module: CapBoomPlugin
        entry: plugin.rb
        contracts: { tools: [t], capabilities: [browse] }
      YAML
        def self.register(api)
          api.register_tool("t", Class.new)
          api.register_capability(:browse, tool: "t")
          raise "boom"
        end
      BODY

      expect { load(enabled: %w[cap]) }.to output(/boom/).to_stderr
      expect(tools.names).to eq([])
      expect(capabilities.capabilities).to eq([])
    end
  end

  it "gating by enabled: id outside enabled does not load" do
    write_plugin("off", "id: off\ncontracts: { tools: [] }\n", nil)
    expect(load(enabled: [])[:plugins]).to eq([])
  end

  it "load_all return brings skill_dirs, prompt_dirs and plugins" do
    write_plugin("dirs", <<~YAML, poro_entry("DirsPlugin", "def self.register(api) = nil"))
      id: dirs
      module: DirsPlugin
      entry: plugin.rb
      contracts: { tools: [] }
      skills: [skills]
      prompts: [prompts]
    YAML

    result = load(enabled: %w[dirs])
    expect(result[:skill_dirs]).to eq([File.join(@root, "dirs", "skills")])
    expect(result[:prompt_dirs]).to eq([File.join(@root, "dirs", "prompts")])
  end

  it "emits :plugin_loaded per loaded plugin" do
    write_plugin("ev", <<~YAML, poro_entry("EvPlugin", "def self.register(api) = api.register_tool('t', Class.new)"))
      id: ev
      module: EvPlugin
      entry: plugin.rb
      contracts: { tools: [t] }
    YAML

    load(enabled: %w[ev])
    ev = event_stream.events.find { |e| e.type == :plugin_loaded }
    expect(ev.data).to include(id: "ev", tools: ["t"])
  end

  describe "enablement by root class (task 22)" do
    # Helper: writes a plugin with a tool in an arbitrary root tree.
    def write_in(root, id, mod, tool)
      dir = File.join(root, id)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "harness.plugin.yml"),
                 "id: #{id}\nmodule: #{mod}\nentry: plugin.rb\ncontracts: { tools: [#{tool}] }\n")
      File.write(File.join(dir, "plugin.rb"),
                 poro_entry(mod, "def self.register(api) = api.register_tool('#{tool}', Class.new)"))
      dir
    end

    def loader(roots:, enabled: [], disabled: [], announced: [])
      described_class.new(roots: roots, registries: registries, enabled: enabled,
                          disabled: disabled, announced_roots: announced, event_stream: event_stream)
    end

    it "announced gem is default-enabled (id outside enabled:)" do
      gem_root = File.join(@root, "gem")
      write_in(gem_root, "g", "GmodA", "gt")
      result = loader(roots: [gem_root], announced: [gem_root]).load_all
      expect(result[:plugins].map(&:id)).to eq(["g"])
    end

    it "disabled: vetoes an announced gem" do
      gem_root = File.join(@root, "gem")
      write_in(gem_root, "g", "GmodB", "gt")
      result = loader(roots: [gem_root], announced: [gem_root], disabled: %w[g]).load_all
      expect(result[:plugins]).to eq([])
    end

    it "bundled/non-announced still requires enabled: (Phase 0 rule)" do
      b_root = File.join(@root, "bundled")
      write_in(b_root, "b", "BmodC", "bt")
      # without announce and without enabled -> not loaded
      expect(loader(roots: [b_root]).load_all[:plugins]).to eq([])
      # with enabled -> loaded
      expect(loader(roots: [b_root], enabled: %w[b]).load_all[:plugins].map(&:id)).to eq(["b"])
    end

    it "absolute veto: id in enabled: AND disabled: does not load" do
      b_root = File.join(@root, "bundled")
      write_in(b_root, "b", "BmodD", "bt")
      expect(loader(roots: [b_root], enabled: %w[b], disabled: %w[b]).load_all[:plugins]).to eq([])
    end

    it "workspace > gem: same id, the workspace root (first) wins" do
      ws = File.join(@root, "ws")
      gem_root = File.join(@root, "gm")
      write_in(ws, "dup", "WsMod", "wtool")
      write_in(gem_root, "dup", "GmMod", "gtool")
      # workspace first in the list; gem announced
      result = loader(roots: [ws, gem_root], enabled: %w[dup], announced: [gem_root]).load_all
      expect(result[:plugins].map(&:id)).to eq(["dup"])
      expect(tools.names).to eq(["wtool"]) # workspace version
    end

    it "gem > bundled: same id, the gem (earlier root in the list) wins" do
      gem_root = File.join(@root, "gm")
      bundled = File.join(@root, "bd")
      write_in(gem_root, "dup", "GmB", "gtool")
      write_in(bundled, "dup", "BdB", "btool")
      # gem first in the list + announced; bundled enabled via enabled:
      result = loader(roots: [gem_root, bundled], enabled: %w[dup], announced: [gem_root]).load_all
      expect(result[:plugins].map(&:id)).to eq(["dup"])
      expect(tools.names).to eq(["gtool"]) # gem version
    end

    it "announce order: same id in two gems, the first in the list wins" do
      g1 = File.join(@root, "g1")
      g2 = File.join(@root, "g2")
      write_in(g1, "dup", "G1mod", "t1")
      write_in(g2, "dup", "G2mod", "t2")
      result = loader(roots: [g1, g2], announced: [g1, g2]).load_all
      expect(result[:plugins].map(&:id)).to eq(["dup"])
      expect(tools.names).to eq(["t1"]) # g1 (announced first / earlier root)
    end

    it "non-existent announced root: load_all without error" do
      expect { loader(roots: [File.join(@root, "nao-existe")], announced: [File.join(@root, "nao-existe")]).load_all }
        .not_to raise_error
    end

    it "backcompat: without announced_roots:/disabled: behaves like task 21" do
      b_root = File.join(@root, "bundled")
      write_in(b_root, "b", "BmodE", "bt")
      result = described_class.new(roots: [b_root], registries: registries,
                                   enabled: %w[b], event_stream: event_stream).load_all
      expect(result[:plugins].map(&:id)).to eq(["b"])
    end
  end

  describe Harness::Plugin::Loader::ConfigSchema do
    it "type incorreto" do
      expect(described_class.validate({ "type" => "integer" }, "x")).not_to be_empty
    end

    it "required missing" do
      errs = described_class.validate({ "type" => "object", "required" => ["a"] }, {})
      expect(errs.first).to include("missing required key: a")
    end

    it "additionalProperties false" do
      errs = described_class.validate(
        { "type" => "object", "additionalProperties" => false, "properties" => { "a" => {} } },
        { "a" => 1, "b" => 2 }
      )
      expect(errs.first).to include("keys not allowed: b")
    end

    it "enum fora" do
      expect(described_class.validate({ "enum" => %w[x y] }, "z")).not_to be_empty
    end

    it "keyword unsupported -> invalid schema" do
      expect(described_class.validate({ "minimum" => 1 }, 5)).not_to be_empty
    end

    it "valid -> empty" do
      schema = { "type" => "object", "properties" => { "a" => { "type" => "integer" } }, "required" => ["a"] }
      expect(described_class.validate(schema, { "a" => 1 })).to eq([])
    end
  end
end
