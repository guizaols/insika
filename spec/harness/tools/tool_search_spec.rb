# frozen_string_literal: true

require "spec_helper"
require "harness/tools/tool_search" # o Executor o carrega lazy; explícito no teste

RSpec.describe Harness::Tools::ToolSearch do
  # Tool deferred de verdade: name/description/parameters/execute (o suficiente
  # p/ o catálogo, o describe e o wrap no ToolEnvelope). Sem herdar RubyLLM::Tool.
  Param = Struct.new(:type, :description, :required)
  def deferred_tool(name, desc)
    Class.new do
      define_method(:name) { name }
      define_method(:description) { desc }
      def parameters = { to: Param.new("string", "destino", true) }
      def call(_args) = "sent"
    end.new
  end

  let(:backend) { Harness::Stores::Memory.new }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(e) = @sink << e }.new(events) }

  let(:registry) do
    reg = Harness::ToolRegistry.new
    reg.register("send_email") { @email_tool ||= deferred_tool("send_email", "Envia um e-mail") }
    reg.register("create_invoice") { deferred_tool("create_invoice", "Gera fatura") }
    reg
  end
  let(:catalog) { Harness::ToolCatalog.new(tool_registry: registry) }

  let(:task) { Struct.new(:id, :session_id).new("t1", "s1") }
  let(:state) do
    profile = Harness::AgentProfile.build(id: "a", model: "m")
    Harness::TurnState.new(task: task, profile: profile, turn: 1, message: "oi")
  end

  # deferred_allowed = só send_email (create_invoice é deferred mas NÃO permitida)
  def build_search(chat, deferred_allowed: ["send_email"])
    described_class.new(catalog, deferred_allowed, chat,
                        tool_registry: registry, event_stream: event_stream,
                        checkpoint_store: checkpoint_store, state: state)
  end

  it "def name = 'tool_search' (não o default derivado da classe)" do
    expect(build_search(FakeChat.new).name).to eq("tool_search")
  end

  it "match dentro do deferred_allowed: promove (ToolEnvelope) via chat.with_tools + descreve" do
    chat = FakeChat.new
    result = build_search(chat).execute(query: "enviar email")

    promoted = chat.tools
    expect(promoted.size).to eq(1)
    expect(promoted.first).to be_a(Harness::ToolEnvelope)
    expect(promoted.first.name).to eq("send_email") # Envelope delega name
    expect(result[:matched].map { |m| m[:name] }).to eq(["send_email"])
    expect(result[:matched].first[:parameters]).to have_key(:to)
  end

  it "match fora do deferred_allowed NÃO aparece nem promove (L1)" do
    chat = FakeChat.new
    # 'fatura' casa create_invoice, que NÃO está em deferred_allowed
    result = build_search(chat).execute(query: "fatura")
    expect(result[:matched]).to eq([])
    expect(chat.tools).to eq([])
  end

  it "query sem match: nada promovido, :tool_search ainda emitido com matched []" do
    chat = FakeChat.new
    result = build_search(chat).execute(query: "xpto inexistente")
    expect(chat.tools).to eq([])
    expect(result[:matched]).to eq([])
    expect(events.last.type).to eq(:tool_search)
    expect(events.last.data).to eq({ query: "xpto inexistente", matched: [] })
  end

  it "emite :tool_search com meta task_id/session_id" do
    build_search(FakeChat.new).execute(query: "email")
    ev = events.find { |e| e.type == :tool_search }
    expect(ev.data).to eq({ query: "email", matched: ["send_email"] })
    expect(ev.meta).to eq({ task_id: "t1", session_id: "s1" })
  end

  it "idempotência: re-busca não re-promove nem re-resolve (mas ainda lista)" do
    chat = FakeChat.new
    search = build_search(chat)
    search.execute(query: "email")
    expect(chat.tools.size).to eq(1)
    result2 = search.execute(query: "email")
    expect(chat.tools.size).to eq(1) # não duplicou
    expect(result2[:matched].map { |m| m[:name] }).to eq(["send_email"]) # ainda encontrada
  end

  it "state.skip_side_effects nil -> ToolEnvelope recebe [] sem levantar" do
    chat = FakeChat.new
    expect { build_search(chat).execute(query: "email") }.not_to raise_error
  end

    it "entry no catálogo ausente no registry: descarta da promoção sem quebrar" do
    chat = FakeChat.new
    reg2 = Harness::ToolRegistry.new
    reg2.register("send_email", plugin: "p") { deferred_tool("send_email", "Envia e-mail") }
    cat2 = Harness::ToolCatalog.new(tool_registry: reg2)
    cat2.all # força o snapshot lazy: o catálogo captura a entry AGORA
    reg2.deregister_plugin("p") # registry DESSINCRONIZA do catálogo -> resolve levanta NotFoundError
    search = described_class.new(cat2, ["send_email"], chat, tool_registry: reg2,
                                 event_stream: event_stream, checkpoint_store: checkpoint_store,
                                 state: state)
    result = nil
    expect { result = search.execute(query: "email") }.not_to raise_error
    expect(chat.tools).to eq([]) # nada promovido (o único match foi descartado)
    expect(result[:matched].first[:parameters]).to eq({}) # describe caiu no rescue
  end

  describe "propagação mid-loop (D6) com FakeChat" do
    it "chat.with_tools dentro do execute é visível em chat.tools imediatamente" do
      chat = FakeChat.new
      search = build_search(chat)
      chat.with_tools(search) # só a builtin cabeada; send_email é deferred

      chat.script = lambda do
        # simula o RubyLLM chamando o tool_search e, no MESMO ask, uma tool
        # promovida por ele. A promoção acontece dentro do execute abaixo.
        search.execute(query: "enviar email")
        raise "send_email não promovida a tempo" unless tools.any? { |t| t.name == "send_email" }
      end

      chat.ask("envie um email")
      expect(chat.tools.map(&:name)).to include("send_email")
    end
  end
end
