# frozen_string_literal: true

require "spec_helper"

# Capability assembly sub-step in the Executor (P2B task 5). Tests the private
# assembly methods (pure — no ruby_llm) + the ToolEnvelope consulting
# impl_name. Full-pipeline integration is covered by the E2E smoke test (task 12).
RSpec.describe "Insika::Executor — capability assembly (P2B)" do
  # Instantiable "raw" tool with a stable name. Registered by BLOCK
  # (`register(name) { fake_tool(name) }`), as the smoke convention.
  def fake_tool(impl_name)
    Class.new do
      define_method(:name) { impl_name }
      def execute(**) = "ok"
    end.new
  end

  let(:event_stream) { Class.new { def emit(_e) = nil }.new }
  let(:tool_registry) { Insika::ToolRegistry.new }
  let(:capability_registry) { Insika::CapabilityRegistry.new }
  let(:inert) { Object.new }

  def build_executor(cap_registry: capability_registry)
    Insika::Executor.new(
      context_builder: inert, policy_engine: inert, middleware: inert,
      hooks: Insika::Hooks.new, tool_registry: tool_registry, skill_catalog: inert,
      profiles: {}, session_store: inert, task_store: inert, checkpoint_store: inert,
      event_stream: event_stream, capability_registry: cap_registry
    )
  end

  def profile(capabilities: nil, tools_deny: [])
    Insika::AgentProfile.build(id: "a", model: "m", capabilities: capabilities, tools_deny: tools_deny)
  end

  StateStub = Struct.new(:capability_names)

  describe "#resolve_capabilities" do
    it "without capability_registry -> {} (Phase 1 parity)" do
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

    it "impl resolved but not registered in tool_registry -> CapabilityError" do
      capability_registry.register(:browse, impl_name: "ghost", kind: :tool)
      exec = build_executor
      expect do
        exec.send(:resolve_capabilities, profile(capabilities: [:browse]), nil)
      end.to raise_error(Insika::CapabilityError, /not registered/)
    end

    it "provider kind :workflow is ignored (exposure deferred, L5)" do
      allow($stderr).to receive(:write) # silences the registration warn
      capability_registry.register(:research, impl_name: "research_wf", kind: :workflow)
      exec = build_executor
      expect(exec.send(:resolve_capabilities, profile(capabilities: [:research]), nil)).to eq({})
    end

    it "propagates CapabilityUnavailable when tools_deny exhausts candidates" do
      tool_registry.register("only") { fake_tool("only") }
      capability_registry.register(:browse, impl_name: "only", kind: :tool)
      exec = build_executor
      expect do
        exec.send(:resolve_capabilities, profile(capabilities: [:browse], tools_deny: ["only"]), nil)
      end.to raise_error(Insika::CapabilityUnavailable)
    end
  end

  describe "#assemble_tool_instances" do
    before do
      tool_registry.register("chromium_browse") { fake_tool("chromium_browse") }
      tool_registry.register("plain") { fake_tool("plain") }
    end

    it "without capability_names -> only instantiates the direct ones (parity)" do
      exec = build_executor
      state = StateStub.new({})
      tools = exec.send(:assemble_tool_instances, tool_registry.entries, state)
      expect(tools.map(&:name)).to contain_exactly("chromium_browse", "plain")
    end

    it "combines direct tools + capability (ResolvedTool with a stable name)" do
      exec = build_executor
      state = StateStub.new({ "chromium_browse" => "browse" })
      # direct allowed = only "plain" (the Policy did not pass the capability)
      plain_entry = tool_registry.entries.find { |e| e.name == "plain" }
      tools = exec.send(:assemble_tool_instances, [plain_entry], state)
      names = tools.map(&:name)
      expect(names).to contain_exactly("plain", "browse") # "browse" = stable alias
      resolved = tools.find { |t| t.name == "browse" }
      expect(resolved).to be_a(Insika::Capability::ResolvedTool)
      expect(resolved.impl_name).to eq("chromium_browse")
    end

    it "dedup: an impl also allowed directly does NOT appear under both names" do
      exec = build_executor
      state = StateStub.new({ "chromium_browse" => "browse" })
      # direct allowed includes the SAME impl as the capability
      tools = exec.send(:assemble_tool_instances, tool_registry.entries, state)
      names = tools.map(&:name)
      expect(names).to contain_exactly("plain", "browse") # raw chromium_browse is gone
      expect(names).not_to include("chromium_browse")
    end
  end

  describe "ToolEnvelope consults impl_name for ResolvedTool" do
    it "side_effect? uses impl_name (not the capability alias)" do
      impl = Class.new { def name = "chromium_browse" }.new
      resolved = Insika::Capability::ResolvedTool.new(impl, capability_name: "browse",
                                                             impl_name: "chromium_browse")
      tool_registry.register("chromium_browse", impl.class, side_effect: true)
      state = Struct.new(:current_tool_call).new(nil)
      envelope = Insika::ToolEnvelope.new(resolved, state: state, checkpoint_store: inert,
                                                     tool_registry: tool_registry, timeout: 1)
      # side_effect? should consult "chromium_browse" (registered), not "browse".
      expect(envelope.send(:side_effect?)).to be(true)
      expect(envelope.send(:real_name)).to eq("chromium_browse")
    end
  end
end
