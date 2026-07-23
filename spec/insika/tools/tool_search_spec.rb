# frozen_string_literal: true

require "spec_helper"
require "insika/tools/tool_search" # the Executor loads it lazily; explicit in the test

RSpec.describe Insika::Tools::ToolSearch do
  # A genuine deferred tool: name/description/parameters/execute (enough for the
  # catalog, the describe and the wrap in ToolEnvelope). Without inheriting RubyLLM::Tool.
  Param = Struct.new(:type, :description, :required)
  def deferred_tool(name, desc)
    Class.new do
      define_method(:name) { name }
      define_method(:description) { desc }
      def parameters = { to: Param.new("string", "destino", true) }
      def call(_args) = "sent"
    end.new
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(e) = @sink << e }.new(events) }

  let(:registry) do
    reg = Insika::ToolRegistry.new
    reg.register("send_email") { @email_tool ||= deferred_tool("send_email", "Sends an e-mail") }
    reg.register("create_invoice") { deferred_tool("create_invoice", "Generates invoice") }
    reg
  end
  let(:catalog) { Insika::ToolCatalog.new(tool_registry: registry) }

  let(:task) { Struct.new(:id, :session_id).new("t1", "s1") }
  let(:state) do
    profile = Insika::AgentProfile.build(id: "a", model: "m")
    Insika::TurnState.new(task: task, profile: profile, turn: 1, message: "hi")
  end

  # deferred_allowed = only send_email (create_invoice is deferred but NOT allowed)
  def build_search(chat, deferred_allowed: ["send_email"])
    described_class.new(catalog, deferred_allowed, chat,
                        tool_registry: registry, event_stream: event_stream,
                        checkpoint_store: checkpoint_store, state: state)
  end

  it "def name = 'tool_search' (not the default derived from the class)" do
    expect(build_search(FakeChat.new).name).to eq("tool_search")
  end

  it "match within deferred_allowed: promotes (ToolEnvelope) via chat.with_tools + describes" do
    chat = FakeChat.new
    result = build_search(chat).execute(query: "send email")

    promoted = chat.tools
    expect(promoted.size).to eq(1)
    expect(promoted.first).to be_a(Insika::ToolEnvelope)
    expect(promoted.first.name).to eq("send_email") # Envelope delegates name
    expect(result[:matched].map { |m| m[:name] }).to eq(["send_email"])
    expect(result[:matched].first[:parameters]).to have_key(:to)
  end

  it "match outside deferred_allowed does NOT appear or get promoted (L1)" do
    chat = FakeChat.new
    # 'invoice' matches create_invoice, which is NOT in deferred_allowed
    result = build_search(chat).execute(query: "invoice")
    expect(result[:matched]).to eq([])
    expect(chat.tools).to eq([])
  end

  it "query with no match: nothing promoted, :tool_search still emitted with matched []" do
    chat = FakeChat.new
    result = build_search(chat).execute(query: "xpto inexistente")
    expect(chat.tools).to eq([])
    expect(result[:matched]).to eq([])
    expect(events.last.type).to eq(:tool_search)
    expect(events.last.data).to eq({ query: "xpto inexistente", matched: [] })
  end

  it "emits :tool_search with meta task_id/session_id" do
    build_search(FakeChat.new).execute(query: "email")
    ev = events.find { |e| e.type == :tool_search }
    expect(ev.data).to eq({ query: "email", matched: ["send_email"] })
    expect(ev.meta).to eq({ task_id: "t1", session_id: "s1" })
  end

  it "idempotency: re-searching does not re-promote or re-resolve (but still lists)" do
    chat = FakeChat.new
    search = build_search(chat)
    search.execute(query: "email")
    expect(chat.tools.size).to eq(1)
    result2 = search.execute(query: "email")
    expect(chat.tools.size).to eq(1) # did not duplicate
    expect(result2[:matched].map { |m| m[:name] }).to eq(["send_email"]) # still found
  end

  it "state.skip_side_effects nil -> ToolEnvelope receives [] without raising" do
    chat = FakeChat.new
    expect { build_search(chat).execute(query: "email") }.not_to raise_error
  end

    it "catalog entry missing from the registry: dropped from promotion without breaking" do
    chat = FakeChat.new
    reg2 = Insika::ToolRegistry.new
    reg2.register("send_email", plugin: "p") { deferred_tool("send_email", "Envia e-mail") }
    cat2 = Insika::ToolCatalog.new(tool_registry: reg2)
    cat2.all # forces the lazy snapshot: the catalog captures the entry NOW
    reg2.deregister_plugin("p") # registry goes OUT OF SYNC with the catalog -> resolve raises NotFoundError
    search = described_class.new(cat2, ["send_email"], chat, tool_registry: reg2,
                                 event_stream: event_stream, checkpoint_store: checkpoint_store,
                                 state: state)
    result = nil
    expect { result = search.execute(query: "email") }.not_to raise_error
    expect(chat.tools).to eq([]) # nothing promoted (the only match was dropped)
    expect(result[:matched].first[:parameters]).to eq({}) # describe fell into the rescue
  end

  describe "mid-loop propagation (D6) with FakeChat" do
    it "chat.with_tools inside execute is visible in chat.tools immediately" do
      chat = FakeChat.new
      search = build_search(chat)
      chat.with_tools(search) # only the builtin wired; send_email is deferred

      chat.script = lambda do
        # simulates RubyLLM calling tool_search and, in the SAME ask, a tool
        # promoted by it. The promotion happens inside the execute below.
        search.execute(query: "send email")
        raise "send_email not promoted in time" unless tools.any? { |t| t.name == "send_email" }
      end

      chat.ask("send an email")
      expect(chat.tools.map(&:name)).to include("send_email")
    end
  end
end
