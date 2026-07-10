# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Harness::Plugin::Loader do
  around do |example|
    Dir.mktmpdir { |d| @root = d; example.run }
  end

  # Registries reais (task 20) + hooks real + coleções + spy de eventos.
  let(:tools) { Harness::ToolRegistry.new }
  let(:workflows) { Harness::WorkflowRegistry.new }
  let(:policies) { Harness::PolicyRegistry.new }
  let(:hooks) { Harness::Hooks.new }
  let(:middleware) { [] }
  let(:context_providers) { [] }
  let(:event_stream) { SpyEventStream.new } # spec/support/fakes.rb

  def registries
    { tools: tools, workflows: workflows, policies: policies,
      hooks: hooks, middleware: middleware, context_providers: context_providers }
  end

  # Escreve um plugin (manifesto + entry Ruby PORO — sem ruby_llm).
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

  # Módulo de plugin PORO nomeável (evita colisão de constante entre exemplos).
  def poro_entry(mod_name, body)
    <<~RUBY
      module #{mod_name}
        #{body}
      end
    RUBY
  end

  it "carrega manifesto novo e registra a tool com metadata do manifesto" do
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

  it "aceita plugin.yml antigo com warn de deprecação" do
    write_plugin("beta", <<~YAML, poro_entry("BetaPlugin", "def self.register(api) = nil"), manifest_name: "plugin.yml")
      id: beta
      module: BetaPlugin
      entry: plugin.rb
      contracts: { tools: [] }
    YAML

    expect { load(enabled: %w[beta]) }.to output(/plugin.yml está deprecado/).to_stderr
  end

  it "harness.plugin.yml precede plugin.yml no mesmo dir (sem warn)" do
    dir = File.join(@root, "gamma")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "harness.plugin.yml"), "id: gamma\ncontracts: { tools: [] }\n")
    File.write(File.join(dir, "plugin.yml"), "id: gamma_old\ncontracts: { tools: [] }\n")

    result = nil
    expect { result = load(enabled: %w[gamma gamma_old]) }.not_to output(/deprecado/).to_stderr
    expect(result[:plugins].map(&:id)).to eq(["gamma"])
  end

  it "registra workflow declarado em contracts.workflows" do
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

  it "ignora workflow fora de contracts.workflows com warn" do
    write_plugin("wf2", <<~YAML, poro_entry("Wf2Plugin", <<~BODY))
      id: wf2
      module: Wf2Plugin
      entry: plugin.rb
      contracts: { workflows: [declarado] }
    YAML
      def self.register(api) = api.register_workflow("naodeclarado", ->(i, **) { i })
    BODY

    expect { load(enabled: %w[wf2]) }.to output(/não declarado em contracts.workflows/).to_stderr
    expect(workflows.names).to eq([])
  end

  it "middleware/hook/provider/policy sem contrato: efetivados após load" do
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
    # hook efetivado: run_before(:tool) roda o callback
    expect(hooks.run_before(:tool, "x")).to eq("x")
  end

  it "config_schema válido: plugin carrega e api.config é a config congelada" do
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

  it "config inválida: plugin NÃO carrega, warn, boot segue (outro plugin carrega)" do
    write_plugin("bad", <<~YAML, poro_entry("BadPlugin", "def self.register(api) = raise('não deveria carregar')"))
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
    expect { result = load(enabled: %w[bad ok]) }.to output(/config inválida/).to_stderr
    expect(result[:plugins].map(&:id)).to eq(["ok"])
    expect(tools.names).to eq(["t"])
  end

  it "rollback: entry registra 1 tool e depois levanta -> tool removida, plugin descartado, próximo carrega" do
    write_plugin("boom", <<~YAML, poro_entry("BoomPlugin", <<~BODY))
      id: boom
      module: BoomPlugin
      entry: plugin.rb
      contracts: { tools: [t1] }
      skills: [skills]
    YAML
      def self.register(api)
        api.register_tool("t1", Class.new)
        raise "falha no meio do register"
      end
    BODY
    write_plugin("after", <<~YAML, poro_entry("AfterPlugin", "def self.register(api) = api.register_tool('t2', Class.new)"))
      id: after
      module: AfterPlugin
      entry: plugin.rb
      contracts: { tools: [t2] }
    YAML

    result = nil
    expect { result = load(enabled: %w[boom after]) }.to output(/falha ao carregar/).to_stderr
    expect(tools.names).to eq(["t2"]) # t1 revertida
    expect(result[:plugins].map(&:id)).to eq(["after"])
    expect(result[:skill_dirs]).not_to include(a_string_including("boom"))
  end

  it "staging descartado: middleware fica de fora se o register levanta (L3 — nada parcial sobra)" do
    write_plugin("partial", <<~YAML, poro_entry("PartialPlugin", <<~BODY))
      id: partial
      module: PartialPlugin
      entry: plugin.rb
      contracts: { tools: [] }
    YAML
      MW = Object.new
      def self.register(api)
        api.register_middleware(MW)
        api.register_hook(:tools, before: ->(x) { x }) # par inválido (:tools) -> levanta no stage
      end
    BODY

    result = nil
    expect { result = load(enabled: %w[partial]) }.to output(/falha ao carregar/).to_stderr
    expect(middleware).to eq([]) # middleware staged NÃO foi efetivado
    expect(result[:plugins]).to eq([])
  end

  it "precedência de roots: mesmo id em dois roots, o primeiro vence" do
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
    expect(tools.names).to eq(["ta"]) # root_a venceu
  end

  it "ignora tool fora de contracts.tools com warn (regra Fase 0)" do
    write_plugin("toolless", <<~YAML, poro_entry("ToollessPlugin", <<~BODY))
      id: toolless
      module: ToollessPlugin
      entry: plugin.rb
      contracts: { tools: [declarada] }
    YAML
      def self.register(api) = api.register_tool("naodeclarada", Class.new)
    BODY

    expect { load(enabled: %w[toolless]) }.to output(/não declarada em contracts.tools/).to_stderr
    expect(tools.names).to eq([])
  end

  it "contracts.capabilities: warn reservado + plugin carrega normalmente" do
    write_plugin("cap", <<~YAML, poro_entry("CapPlugin", "def self.register(api) = api.register_tool('t', Class.new)"))
      id: cap
      module: CapPlugin
      entry: plugin.rb
      contracts: { tools: [t], capabilities: [foo] }
    YAML

    result = nil
    expect { result = load(enabled: %w[cap]) }.to output(/capabilities é reservado/).to_stderr
    expect(result[:plugins].map(&:id)).to eq(["cap"])
  end

  it "gating por enabled: id fora de enabled não carrega" do
    write_plugin("off", "id: off\ncontracts: { tools: [] }\n", nil)
    expect(load(enabled: [])[:plugins]).to eq([])
  end

  it "retorno de load_all traz skill_dirs, prompt_dirs e plugins" do
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

  it "emite :plugin_loaded por plugin carregado" do
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

  describe Harness::Plugin::Loader::ConfigSchema do
    it "type incorreto" do
      expect(described_class.validate({ "type" => "integer" }, "x")).not_to be_empty
    end

    it "required ausente" do
      errs = described_class.validate({ "type" => "object", "required" => ["a"] }, {})
      expect(errs.first).to include("obrigatória ausente: a")
    end

    it "additionalProperties false" do
      errs = described_class.validate(
        { "type" => "object", "additionalProperties" => false, "properties" => { "a" => {} } },
        { "a" => 1, "b" => 2 }
      )
      expect(errs.first).to include("não permitidas: b")
    end

    it "enum fora" do
      expect(described_class.validate({ "enum" => %w[x y] }, "z")).not_to be_empty
    end

    it "keyword não suportada -> schema inválido" do
      expect(described_class.validate({ "minimum" => 1 }, 5)).not_to be_empty
    end

    it "válido -> vazio" do
      schema = { "type" => "object", "properties" => { "a" => { "type" => "integer" } }, "required" => ["a"] }
      expect(described_class.validate(schema, { "a" => 1 })).to eq([])
    end
  end
end
