# frozen_string_literal: true

require "spec_helper"

# Sub-passo de capability assembly no Executor (P2B task 5). Testa os métodos
# privados de montagem (puros — sem ruby_llm) + o ToolEnvelope consultando
# impl_name. A integração full-pipeline é coberta pelo smoke E2E (task 12).
RSpec.describe "Harness::Executor — capability assembly (P2B)" do
  # Tool "crua" instanciável com name estável. Registrada por BLOCO
  # (`register(name) { fake_tool(name) }`), como a convenção do smoke.
  def fake_tool(impl_name)
    Class.new do
      define_method(:name) { impl_name }
      def execute(**) = "ok"
    end.new
  end

  let(:event_stream) { Class.new { def emit(_e) = nil }.new }
  let(:tool_registry) { Harness::ToolRegistry.new }
  let(:capability_registry) { Harness::CapabilityRegistry.new }
  let(:inert) { Object.new }

  def build_executor(cap_registry: capability_registry)
    Harness::Executor.new(
      context_builder: inert, policy_engine: inert, middleware: inert,
      hooks: Harness::Hooks.new, tool_registry: tool_registry, skill_catalog: inert,
      profiles: {}, session_store: inert, task_store: inert, checkpoint_store: inert,
      event_stream: event_stream, capability_registry: cap_registry
    )
  end

  def profile(capabilities: nil, tools_deny: [])
    Harness::AgentProfile.build(id: "a", model: "m", capabilities: capabilities, tools_deny: tools_deny)
  end

  StateStub = Struct.new(:capability_names)

  describe "#resolve_capabilities" do
    it "sem capability_registry -> {} (paridade Fase 1)" do
      exec = build_executor(cap_registry: nil)
      expect(exec.send(:resolve_capabilities, profile(capabilities: [:browse]), nil)).to eq({})
    end

    it "profile.capabilities nil -> {}" do
      exec = build_executor
      expect(exec.send(:resolve_capabilities, profile(capabilities: nil), nil)).to eq({})
    end

    it "resolve -> { impl_name => capability_name }" do
      tool_registry.register("chromium_browse") { fake_tool("chromium_browse") }
      capability_registry.register(:browse, impl_name: "chromium_browse", kind: :tool, priority: 100)
      exec = build_executor
      result = exec.send(:resolve_capabilities, profile(capabilities: [:browse]), nil)
      expect(result).to eq({ "chromium_browse" => "browse" })
    end

    it "impl resolvido mas não registrado em tool_registry -> CapabilityError" do
      capability_registry.register(:browse, impl_name: "ghost", kind: :tool)
      exec = build_executor
      expect do
        exec.send(:resolve_capabilities, profile(capabilities: [:browse]), nil)
      end.to raise_error(Harness::CapabilityError, /não registrado/)
    end

    it "provider kind :workflow é ignorado (exposição adiada, L5)" do
      allow($stderr).to receive(:write) # silencia o warn de registro
      capability_registry.register(:research, impl_name: "research_wf", kind: :workflow)
      exec = build_executor
      expect(exec.send(:resolve_capabilities, profile(capabilities: [:research]), nil)).to eq({})
    end

    it "propaga CapabilityUnavailable quando tools_deny esgota candidatos" do
      tool_registry.register("only") { fake_tool("only") }
      capability_registry.register(:browse, impl_name: "only", kind: :tool)
      exec = build_executor
      expect do
        exec.send(:resolve_capabilities, profile(capabilities: [:browse], tools_deny: ["only"]), nil)
      end.to raise_error(Harness::CapabilityUnavailable)
    end
  end

  describe "#assemble_tool_instances" do
    before do
      tool_registry.register("chromium_browse") { fake_tool("chromium_browse") }
      tool_registry.register("plain") { fake_tool("plain") }
    end

    it "sem capability_names -> só instancia as diretas (paridade)" do
      exec = build_executor
      state = StateStub.new({})
      tools = exec.send(:assemble_tool_instances, tool_registry.entries, state)
      expect(tools.map(&:name)).to contain_exactly("chromium_browse", "plain")
    end

    it "junta tools diretas + capability (ResolvedTool com nome estável)" do
      exec = build_executor
      state = StateStub.new({ "chromium_browse" => "browse" })
      # allowed direto = só "plain" (a Policy não passou a capability)
      plain_entry = tool_registry.entries.find { |e| e.name == "plain" }
      tools = exec.send(:assemble_tool_instances, [plain_entry], state)
      names = tools.map(&:name)
      expect(names).to contain_exactly("plain", "browse") # "browse" = apelido estável
      resolved = tools.find { |t| t.name == "browse" }
      expect(resolved).to be_a(Harness::Capability::ResolvedTool)
      expect(resolved.impl_name).to eq("chromium_browse")
    end

    it "dedup: impl também permitido direto NÃO aparece com os dois nomes" do
      exec = build_executor
      state = StateStub.new({ "chromium_browse" => "browse" })
      # allowed direto inclui o MESMO impl da capability
      tools = exec.send(:assemble_tool_instances, tool_registry.entries, state)
      names = tools.map(&:name)
      expect(names).to contain_exactly("plain", "browse") # chromium_browse cru sumiu
      expect(names).not_to include("chromium_browse")
    end
  end

  describe "ToolEnvelope consulta impl_name para ResolvedTool" do
    it "side_effect? usa impl_name (não o apelido da capability)" do
      impl = Class.new { def name = "chromium_browse" }.new
      resolved = Harness::Capability::ResolvedTool.new(impl, capability_name: "browse",
                                                             impl_name: "chromium_browse")
      tool_registry.register("chromium_browse", impl.class, side_effect: true)
      state = Struct.new(:current_tool_call).new(nil)
      envelope = Harness::ToolEnvelope.new(resolved, state: state, checkpoint_store: inert,
                                                     tool_registry: tool_registry, timeout: 1)
      # side_effect? deve consultar "chromium_browse" (registrado), não "browse".
      expect(envelope.send(:side_effect?)).to be(true)
      expect(envelope.send(:real_name)).to eq("chromium_browse")
    end
  end
end
