# frozen_string_literal: true

require "spec_helper"
require "insika/tools/tool_search" # the Executor loads it lazily; explicit in the test

RSpec.describe Insika::Tools::ToolSearch do
  # A genuine deferred tool: name/description/parameters/execute (enough for the
  # catalog, the describe and the wrap in ToolEnvelope). Without inheriting RubyLLM::Tool.
  def deferred_tool(name, desc)
    Class.new do
      define_method(:name) { name }
      define_method(:description) { desc }
      def parameters_schema
        { type: "object", properties: { to: { type: "string", description: "destino" } }, required: ["to"] }
      end
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

  it "a promoted tool gets the turn context ({{ctx.*}} headers), like an eager one" do
    tool = registry.resolve("send_email")
    tool.singleton_class.attr_accessor :turn_context
    state.turn_context = { chat_id: "c1" }
    build_search(FakeChat.new).execute(query: "send email")
    expect(tool.turn_context).to eq(chat_id: "c1")
  end

  it "match within deferred_allowed: promotes (ToolEnvelope) via chat.with_tools + describes" do
    chat = FakeChat.new
    result = build_search(chat).execute(query: "send email")

    promoted = chat.tools
    expect(promoted.size).to eq(1)
    expect(promoted.first).to be_a(Insika::ToolEnvelope)
    expect(promoted.first.name).to eq("send_email") # Envelope delegates name
    expect(result[:matched].map { |m| m[:name] }).to eq(["send_email"])
    expect(result[:matched].first[:parameters]).to eq(to: { type: "string", description: "destino", required: true })
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

  it "idempotency: re-searching does not re-promote, and names the tool as already enabled" do
    chat = FakeChat.new
    search = build_search(chat)
    search.execute(query: "email")
    expect(chat.tools.size).to eq(1)
    result2 = search.execute(query: "email")
    expect(chat.tools.size).to eq(1) # did not duplicate
    expect(result2[:matched]).to eq([]) # no schema sent again
    expect(result2[:already_enabled]).to eq(["send_email"]) # still found
  end

  it "tools a resumed turn brought back count as already enabled" do
    chat = FakeChat.new
    search = described_class.new(catalog, ["send_email"], chat,
                                 tool_registry: registry, event_stream: event_stream,
                                 checkpoint_store: checkpoint_store, state: state, enabled: ["send_email"])
    result = search.execute(query: "email")
    expect(chat.tools).to be_empty # not wired a second time
    expect(result[:matched]).to eq([])
    expect(result[:already_enabled]).to eq(["send_email"])
  end

  describe "tool_search_limit" do
    let(:registry) do
      reg = Insika::ToolRegistry.new
      %w[send_email send_sms send_push].each { |n| reg.register(n) { deferred_tool(n, "Sends a message") } }
      reg
    end

    def search_with(limits) = search_with_query(limits, "sends message")

    def search_with_query(limits, query)
      profile = Insika::AgentProfile.build(id: "a", model: "m", limits: limits)
      st = Insika::TurnState.new(task: task, profile: profile, turn: 1, message: "hi")
      chat = FakeChat.new
      search = described_class.new(catalog, %w[send_email send_sms send_push], chat,
                                   tool_registry: registry, event_stream: event_stream,
                                   checkpoint_store: checkpoint_store, state: st)
      [search.execute(query: query), chat]
    end

    it "promotes and lists at most limits[:tool_search_limit] tools" do
      result, chat = search_with(tool_search_limit: 2)
      expect(chat.tools.map(&:name)).to eq(%w[send_email send_sms])
      expect(result[:matched].map { |m| m[:name] }).to eq(%w[send_email send_sms])
      expect(events.last.data[:matched]).to eq(%w[send_email send_sms])
    end

    it "without a limit the default applies, and the profile does not store it" do
      stub_const("Insika::Tools::ToolSearch::DEFAULT_LIMIT", 2)
      _result, chat = search_with({})
      expect(chat.tools.size).to eq(2)
      expect(Insika::AgentProfile.build(id: "a", model: "m").limits).not_to have_key(:tool_search_limit)
    end

    # Review r3 of insika#2: the cap was applied before dropping the enabled tools, so a
    # similar search brought the same top again and the next tool never came.
    it "a repeated search brings the next tools, and says what the limit cut" do
      profile = Insika::AgentProfile.build(id: "a", model: "m", limits: { tool_search_limit: 1 })
      st = Insika::TurnState.new(task: task, profile: profile, turn: 1, message: "hi")
      chat = FakeChat.new
      search = described_class.new(catalog, %w[send_email send_sms send_push], chat,
                                   tool_registry: registry, event_stream: event_stream,
                                   checkpoint_store: checkpoint_store, state: st)
      first = search.execute(query: "sends message")
      expect(first[:matched].map { |m| m[:name] }).to eq(%w[send_email])
      expect(first[:message]).to include("2 more tools match")

      second = search.execute(query: "sends a message")
      expect(second[:matched].map { |m| m[:name] }).to eq(%w[send_sms])
      expect(second[:already_enabled]).to eq(%w[send_email])
      expect(chat.tools.map(&:name)).to eq(%w[send_email send_sms])
    end

    it "names asked for past the name cap are left out, and the result says which" do
      result, chat = search_with_query({ tool_search_limit: 1 }, "send_email send_sms send_push")
      expect(chat.tools.size).to eq(3) # 3 x limit 1
      expect(result[:message]).to be_nil

      stub_const("Insika::ToolCatalog::NAME_CAP_FACTOR", 2)
      result, chat = search_with_query({ tool_search_limit: 1 }, "send_email send_sms send_push")
      expect(chat.tools.map(&:name)).to eq(%w[send_email send_sms])
      expect(result[:message]).to include("Not enabled, over the cap of names per call: send_push")
    end

    it "a limit that is not a number falls back to the default instead of lifting the cap" do
      stub_const("Insika::Tools::ToolSearch::DEFAULT_LIMIT", 2)
      _result, chat = search_with(tool_search_limit: "")
      expect(chat.tools.size).to eq(2)
    end

    it "below 1 means no cap" do
      _result, chat = search_with(tool_search_limit: 0)
      expect(chat.tools.size).to eq(3)
    end
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

  it "a denied tool asked by name says so and enables nothing" do
    profile = Insika::AgentProfile.build(id: "a", model: "m", tools_deferred: %w[send_email create_invoice])
    chat = FakeChat.new
    search = described_class.new(catalog, ["send_email"], chat, tool_registry: registry, event_stream: event_stream,
                                 checkpoint_store: checkpoint_store,
                                 state: Insika::TurnState.new(task: task, profile: profile, turn: 1, message: "hi"))
    result = search.execute(query: "create_invoice")
    expect(chat.tools).to eq([])
    expect(result[:message]).to include("Not available to this agent: create_invoice")
  end

  it "description searches stop after the per-turn budget; exact names still work" do
    state.profile.limits[:tool_search_limit] = 1
    reg = Insika::ToolRegistry.new
    4.times { |i| reg.register("mail_#{i}") { deferred_tool("mail_#{i}", "Sends mail #{i}") } }
    cat = Insika::ToolCatalog.new(tool_registry: reg)
    search = described_class.new(cat, cat.all.map(&:name), FakeChat.new, tool_registry: reg,
                                 event_stream: event_stream, checkpoint_store: checkpoint_store, state: state)
    3.times { search.execute(query: "mail") }
    spent = search.execute(query: "mail")
    expect(spent[:matched]).to eq([])
    expect(spent[:message]).to include("ask for tools by exact name")
    expect(spent[:message]).not_to include("no tool found")
    expect(search.execute(query: "mail_3")[:matched].map { |m| m[:name] }).to eq(["mail_3"])
  end

  it "when the budget, not the limit, cut the matches, the note says budget" do
    state.profile.limits[:tool_search_limit] = 4
    reg = Insika::ToolRegistry.new
    16.times { |i| reg.register("mail_#{i}") { deferred_tool("mail_#{i}", "Sends mail #{i}") } }
    3.times { |i| reg.register("alpha_#{i}") { deferred_tool("alpha_#{i}", "Alpha thing #{i}") } }
    cat = Insika::ToolCatalog.new(tool_registry: reg)
    search = described_class.new(cat, cat.all.map(&:name), FakeChat.new, tool_registry: reg,
                                 event_stream: event_stream, checkpoint_store: checkpoint_store, state: state)
    %w[mail alpha mail].each { |query| search.execute(query: query) } # 4 + 3 + 4 of 12
    last = search.execute(query: "mail")
    expect(last[:matched].size).to eq(1)
    expect(last[:message]).to include("used its searches by description")
    expect(last[:message]).not_to include("past the limit")
  end

  describe "mid-loop propagation with FakeChat" do
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
